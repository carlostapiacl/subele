import Foundation

/// Dueño del motor y del único hilo desde el que se arranca y se detiene.
///
/// `BoostEngine.start` y `stop` llaman a CoreAudio, y CoreAudio puede tardar o
/// bloquearse indefinidamente —un tap sobre el dispositivo virtual de otro
/// booster hace exactamente eso—. Llamados desde la interfaz, un cuelgue así
/// congelaba el menú entero, incluido el botón de salir. Acá corren en una cola
/// serial propia: la interfaz pide, el controlador ejecuta de a una transición
/// por vez, y avisa el estado nuevo en `callbackQueue`.
///
/// ```
///             start                    ok
///   stopped ─────────→ starting ─────────────→ running
///      ↑                  │ error                │ stop / restart
///      │                  ↓                      ↓
///      └──── stopping ←── failed            stopping
/// ```
///
/// Además vigila que el IOProc siga girando: si deja de llamarse con el motor
/// corriendo, rehace la cadena. Un tap con `.mutedWhenTapped` y un IOProc
/// detenido es un Mac mudo, y eso no puede quedar esperando a que alguien toque
/// "Reintentar".
public final class EngineController {

    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running(BoostEngine.Info)
        case stopping
        case failed(String)

        public var info: BoostEngine.Info? {
            if case .running(let info) = self { return info }
            return nil
        }
    }

    /// El procesador es seguro desde cualquier hilo: todo lo que expone pasa por
    /// atómicos.
    public var processor: BoostProcessor { engine.processor }

    /// Estado visto desde `callbackQueue`. Solo se lee y se escribe ahí.
    public private(set) var state: State = .stopped
    /// Desde cuándo el estado es el actual, para notar un arranque colgado.
    public private(set) var stateSince = Date()
    public var onStateChange: ((State) -> Void)?

    /// Cuántos reinicios seguidos hace el watchdog antes de rendirse.
    public var maximumWatchdogRestarts = 3

    private let engine: BoostEngine
    private let queue = DispatchQueue(label: "cl.carlostapia.subele.engine", qos: .userInitiated)
    private let callbackQueue: DispatchQueue

    // De `queue`.
    private var wantsRunning = false
    private var pendingRestart: DispatchWorkItem?
    private var lastCallbackCount: UInt32 = 0
    private var stalledChecks = 0
    private var watchdogRestarts = 0
    private var watchdog: DispatchSourceTimer?

    public init(engine: BoostEngine = BoostEngine(), callbackQueue: DispatchQueue = .main) {
        self.engine = engine
        self.callbackQueue = callbackQueue
        engine.onOutputChanged = { [weak self] in self?.scheduleRestart() }
    }

    deinit { watchdog?.cancel() }

    // MARK: Lo que pide la interfaz

    public func start() { queue.async { self.wantsRunning = true; self.restartNow() } }

    public func stop() {
        queue.async {
            self.wantsRunning = false
            self.pendingRestart?.cancel()
            self.performStop()
        }
    }

    /// Rehace la cadena ya, si se quería corriendo.
    public func restart() { queue.async { self.watchdogRestarts = 0; self.restartNow() } }

    /// Un cambio de dispositivo dispara varias notificaciones seguidas; se espera a
    /// que se aquieten en vez de rehacer la cadena una vez por notificación.
    public func scheduleRestart(after delay: TimeInterval = 0.6) {
        queue.async {
            self.pendingRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.restartNow() }
            self.pendingRestart = work
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    public func setPreferredBufferFrames(_ frames: UInt32?) {
        queue.async { self.engine.preferredBufferFrames = frames }
    }

    /// Detiene y espera, para la salida de la app: un tap vivo deja el sistema
    /// mudo, así que no se sale sin intentarlo. Si CoreAudio no responde a tiempo
    /// se sale igual; al morir el proceso, el sistema se lleva el tap.
    @discardableResult
    public func stopAndWait(timeout: TimeInterval = 2) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.wantsRunning = false
            self.pendingRestart?.cancel()
            self.watchdog?.cancel()
            self.performStop()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Arranca y espera el resultado, para la consola.
    public func startAndWait(timeout: TimeInterval = 10) -> State {
        let done = DispatchSemaphore(value: 0)
        var result = State.starting
        queue.async {
            self.wantsRunning = true
            self.restartNow()
            result = self.engineState
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success ? result : .starting
    }

    /// Latencia agregada, segura de leer desde la interfaz.
    public var addedLatencySeconds: Double { engine.addedLatencySeconds }
    public var measuredIOLatencySeconds: Double { engine.measuredIOLatencySeconds }

    /// Para tests: espera a que se vacíe la cola del motor.
    public func drain() { queue.sync {} }

    // MARK: Watchdog

    /// Arranca la vigilancia periódica. Separada del init para que los tests la
    /// manejen a mano con `checkWatchdog`.
    public func startWatchdog(interval: TimeInterval = 1) {
        queue.async {
            self.watchdog?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.checkWatchdogOnQueue() }
            timer.resume()
            self.watchdog = timer
        }
    }

    /// Una vuelta del watchdog, sincrónica. Para tests.
    public func checkWatchdog() { queue.sync { checkWatchdogOnQueue() } }

    /// Tres revisiones sin callbacks nuevos (unos tres segundos con el intervalo
    /// por defecto) es un IOProc detenido, no un bache.
    private func checkWatchdogOnQueue() {
        guard engine.isRunning else { stalledChecks = 0; return }
        let count = engine.callbackCount
        if count != lastCallbackCount {
            lastCallbackCount = count
            stalledChecks = 0
            watchdogRestarts = 0
            return
        }
        stalledChecks += 1
        guard stalledChecks >= 3 else { return }
        stalledChecks = 0
        watchdogRestarts += 1
        trace("watchdog: el IOProc no avanza; reinicio \(watchdogRestarts)")
        guard watchdogRestarts <= maximumWatchdogRestarts else {
            performStop()
            publish(.failed("el audio dejó de responder"))
            return
        }
        restartNow()
    }

    // MARK: Transiciones, todas en `queue`

    private var engineState: State {
        engine.info.map(State.running) ?? .stopped
    }

    private func restartNow() {
        pendingRestart?.cancel()
        pendingRestart = nil
        if engine.isRunning { performStop() }
        guard wantsRunning else { publish(.stopped); return }
        publish(.starting)
        do {
            try engine.start()
            lastCallbackCount = engine.callbackCount
            stalledChecks = 0
            publish(engineState)
        } catch {
            publish(.failed(error.localizedDescription))
        }
    }

    private func performStop() {
        guard engine.isRunning else { publish(.stopped); return }
        publish(.stopping)
        engine.stop()
        publish(.stopped)
    }

    private func publish(_ new: State) {
        callbackQueue.async {
            guard new != self.state else { return }
            self.state = new
            self.stateSince = Date()
            self.onStateChange?(new)
        }
    }
}
