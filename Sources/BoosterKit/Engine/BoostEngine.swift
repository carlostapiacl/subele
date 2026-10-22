import CoreAudio
import Foundation

/// Captura el audio del sistema con un process tap, lo procesa y lo devuelve al
/// mismo dispositivo de salida.
///
/// No instala ningún driver y **no** cambia la salida por defecto del sistema. El
/// tap silencia el camino original de los procesos que captura, y nosotros
/// escribimos el audio procesado al mismo hardware. Nuestro propio proceso queda
/// excluido del tap; si no, lo que escribimos se capturaría y volvería a entrar.
///
/// ```
/// system processes ──┐
///                    ├─→ [tap, mutedWhenTapped] ──→ IOProc ──→ DSP ──┐
/// this process ──────┴──── (excluded) ───────────────────────────────┴─→ output device
/// ```
///
/// El motor es sincrónico y no es seguro entre hilos: `start` y `stop` pueden
/// bloquearse dentro de CoreAudio. Lo maneja `EngineController`, que los llama
/// siempre desde una misma cola que no es la principal.
public final class BoostEngine {

    public struct Info: Sendable, Equatable {
        public let deviceID: AudioDeviceID
        public let deviceName: String
        public let sampleRate: Double
        public let inputChannels: Int
        public let outputChannels: Int
        public let bufferFrames: Int
    }

    public let processor = BoostProcessor()

    /// Se llama en la cola principal cuando cambia algo que deja la cadena vieja:
    /// la salida por defecto, la frecuencia o los streams de ese dispositivo, o
    /// el dispositivo desaparece. Un tap está atado a un dispositivo y a un
    /// formato, así que sin rehacer la cadena seguiríamos procesando para hardware
    /// que ya nadie escucha.
    public var onOutputChanged: (() -> Void)?

    /// Frames por callback que se le piden al dispositivo agregado. Más bajo es
    /// menos latencia y más despertadas; el dispositivo ajusta a lo que soporte.
    /// `nil` deja lo que haya elegido CoreAudio.
    public var preferredBufferFrames: UInt32?

    /// Cuánto esperar a que el agregado exponga el stream del tap antes de
    /// instalar el IOProc. Arrancar antes da callbacks sin entrada.
    public var readinessTimeout: TimeInterval = 1.5

    public private(set) var isRunning = false
    public private(set) var info: Info?

    /// Lo que falló en el último `stop`, si algo falló. El teardown sigue igual
    /// hasta el final; esto queda para el diagnóstico.
    public private(set) var teardownProblems: [String] = []

    /// Medida, no estimada: la distancia entre el timestamp del audio que entra y
    /// el timestamp en que se va a reproducir, tomada del IOProc.
    public var measuredIOLatencySeconds: Double { Double(renderer?.latency.value ?? 0) }

    /// Todo lo que esta cadena agrega por sobre reproducir derecho al dispositivo.
    public var addedLatencySeconds: Double {
        measuredIOLatencySeconds + Double(processor.limiter.lookaheadSeconds)
    }

    /// Vueltas del IOProc desde que arrancó. Si deja de crecer con el motor
    /// corriendo, el audio se detuvo.
    public var callbackCount: UInt32 { renderer?.callbacks.value ?? 0 }

    private let hal: AudioHAL
    private var tapID: AudioObjectID?
    private var aggregateID: AudioDeviceID?
    private var ioProc: IOProcHandle?
    private var renderer: IORenderer?
    private var observers: [AnyObject] = []

    public init(hal: AudioHAL = SystemAudioHAL(), preferredBufferFrames: UInt32? = nil) {
        self.hal = hal
        self.preferredBufferFrames = preferredBufferFrames
    }

    deinit { stop() }

    public func start() throws {
        guard !isRunning else { return }
        do { try begin() } catch { stop(); throw error }
    }

    private func begin() throws {
        trace("pidiendo el dispositivo de salida por defecto")
        let outputDevice = try hal.defaultOutputDevice()
        let outputUID = try hal.uid(of: outputDevice)
        let deviceName = (try? hal.name(of: outputDevice)) ?? outputUID
        trace("dispositivo: \(deviceName) uid=\(outputUID)")

        // Todo lo que se puede rechazar se rechaza antes de crear el tap: hasta
        // ahí el sistema suena como siempre. Después, el tap ya silenció a todos.
        let outputFormat = try hal.streamFormat(of: outputDevice, scope: kAudioObjectPropertyScopeOutput)
        try StreamFormat.require(outputFormat, "la salida")
        let outputLayout = hal.streamLayout(of: outputDevice, scope: kAudioObjectPropertyScopeOutput)
        let outputChannels = outputLayout.reduce(0, +)
        guard outputChannels > 0 else { throw AudioError("la salida no tiene canales") }
        guard outputChannels <= StreamFormat.maximumChannels else {
            throw AudioError("la salida tiene \(outputChannels) canales; "
                             + "el máximo es \(StreamFormat.maximumChannels)")
        }
        let physicalInputBuffers = hal.streamLayout(
            of: outputDevice, scope: kAudioObjectPropertyScopeInput).count

        let ownProcess = try hal.ownProcessObject()
        trace("proceso propio=\(ownProcess); creando el tap")
        let tap = try hal.createTap(excluding: [ownProcess], deviceUID: outputUID)
        tapID = tap.id

        let tapFormat = try hal.tapFormat(of: tap.id)
        try StreamFormat.require(tapFormat, "el tap")
        let tapChannels = Int(tapFormat.mChannelsPerFrame)

        trace("tap creado id=\(tap.id); creando el dispositivo agregado")
        let aggregate = try hal.createAggregate(tapUUID: tap.uuid, outputDeviceUID: outputUID)
        aggregateID = aggregate

        if let preferredBufferFrames {
            hal.setBufferFrameSize(preferredBufferFrames, of: aggregate)
        }

        let tapBuffers = try waitForTapStream(on: aggregate,
                                              physicalInputBuffers: physicalInputBuffers,
                                              tapChannels: tapChannels)
        let aggregateOutput = hal.streamLayout(of: aggregate, scope: kAudioObjectPropertyScopeOutput)
        guard aggregateOutput.reduce(0, +) == outputChannels else {
            throw AudioError("el agregado no expone los \(outputChannels) canales de la salida")
        }

        let info = Info(deviceID: outputDevice,
                        deviceName: deviceName,
                        sampleRate: tapFormat.mSampleRate,
                        inputChannels: tapChannels,
                        outputChannels: outputChannels,
                        bufferFrames: Int(hal.bufferFrameSize(of: aggregate)))
        trace("formato \(info.sampleRate) Hz \(info.inputChannels)->\(info.outputChannels), "
              + "\(info.bufferFrames) frames por callback, tap en buffers \(tapBuffers); "
              + "instalando el IOProc")

        processor.prepare(sampleRate: info.sampleRate, channels: info.outputChannels)

        // El bloque captura solo el renderer, fuerte: él es dueño de todo lo que
        // el callback toca, así que vive tanto como el bloque y no como el motor.
        let renderer = IORenderer(processor: processor, tapBuffers: tapBuffers)
        self.renderer = renderer
        ioProc = try hal.createIOProc(on: aggregate) { _, inputData, inputTime, outputData, outputTime in
            renderer.recordLatency(input: inputTime, output: outputTime)
            renderer.render(input: inputData, output: outputData)
        }
        try hal.startIO(ioProc!)

        let changed: () -> Void = { [weak self] in self?.onOutputChanged?() }
        observers = [
            hal.observe(AudioObject.system, kAudioHardwarePropertyDefaultOutputDevice,
                        scope: kAudioObjectPropertyScopeGlobal, changed),
            hal.observe(outputDevice, kAudioDevicePropertyNominalSampleRate,
                        scope: kAudioObjectPropertyScopeGlobal, changed),
            hal.observe(outputDevice, kAudioDevicePropertyDeviceIsAlive,
                        scope: kAudioObjectPropertyScopeGlobal, changed),
            hal.observe(outputDevice, kAudioDevicePropertyStreamConfiguration,
                        scope: kAudioObjectPropertyScopeOutput, changed),
        ].compactMap { $0 }

        self.info = info
        isRunning = true
        trace("corriendo")
    }

    /// Un agregado recién creado puede tardar en exponer el stream del tap. Se
    /// espera a verlo, y de paso se ubica dentro de la entrada.
    private func waitForTapStream(on aggregate: AudioDeviceID, physicalInputBuffers: Int,
                                  tapChannels: Int) throws -> Range<Int> {
        let deadline = Date().addingTimeInterval(readinessTimeout)
        while true {
            let layout = hal.streamLayout(of: aggregate, scope: kAudioObjectPropertyScopeInput)
            if let range = IORenderer.tapBufferRange(aggregateInput: layout,
                                                     physicalInputBuffers: physicalInputBuffers,
                                                     tapChannels: tapChannels) {
                return range
            }
            guard Date() < deadline else {
                throw AudioError("el dispositivo agregado no expuso el stream del tap "
                                 + "(entrada: \(layout), tap: \(tapChannels) canales)")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Desarma la cadena en orden: detener el IOProc, destruirlo, destruir el
    /// agregado (que referencia al tap) y al final el tap, que es el que devuelve
    /// el audio a los demás procesos.
    ///
    /// Cada paso se intenta aunque el anterior haya fallado, y lo que falla queda
    /// en `teardownProblems`. Lo que el callback usa es del renderer, que retiene
    /// el propio bloque: si CoreAudio lo llamara después de un stop fallido, no hay
    /// memoria liberada debajo.
    public func stop() {
        observers.removeAll()
        let hadChain = ioProc != nil || aggregateID != nil || tapID != nil
        var problems: [String] = []
        func note(_ status: OSStatus, _ what: String) {
            guard status != noErr else { return }
            let error = AudioError(what, status: status).localizedDescription
            trace(error)
            problems.append(error)
        }
        if let ioProc {
            note(hal.stopIO(ioProc), "detener el IOProc")
            note(hal.destroyIOProc(ioProc), "destruir el IOProc")
        }
        if let aggregateID { note(hal.destroyAggregate(aggregateID), "destruir el agregado") }
        if let tapID { note(hal.destroyTap(tapID), "destruir el tap") }
        ioProc = nil
        aggregateID = nil
        tapID = nil
        renderer = nil
        info = nil
        isRunning = false
        // Un stop sin nada armado (el de deinit, uno repetido) no borra el
        // diagnóstico del último teardown de verdad.
        if hadChain { teardownProblems = problems }
    }

    // MARK: Frecuencia de muestreo

    /// Frecuencias que acepta la salida por defecto, y la que tiene puesta ahora.
    public static func outputSampleRates() -> (available: [Double], current: Double?) {
        guard let device = try? AudioDevices.defaultOutput() else { return ([], nil) }
        return (AudioDevices.availableSampleRates(of: device),
                try? AudioDevices.nominalSampleRate(of: device))
    }

    /// Cambia la frecuencia de la salida por defecto, como Configuración de Audio
    /// MIDI pero sin abrirla. **Es para todo el Mac**, no solo para Subele: el
    /// dispositivo es uno, y las demás apps que lo usan pasan a esa frecuencia.
    ///
    /// No rehace la cadena acá: el cambio es asíncrono, y el observador de
    /// frecuencia dispara `onOutputChanged` cuando el dispositivo lo terminó de
    /// aplicar. Así el camino es el mismo que si lo cambiaran desde afuera.
    ///
    /// Lo que gana y lo que no: subir de 44,1 a 96 kHz no agrega detalle a una
    /// grabación de 44,1. Lo que puede cambiar es que el sistema deje de convertir
    /// de frecuencia cuando el material ya viene a la del dispositivo, y hay
    /// interfaces que suenan distinto según a cuánto corren.
    public static func setOutputSampleRate(_ rate: Double) throws {
        let device = try AudioDevices.defaultOutput()
        try AudioDevices.setNominalSampleRate(rate, of: device)
    }
}
