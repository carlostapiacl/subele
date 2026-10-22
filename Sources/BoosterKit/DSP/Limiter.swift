import Foundation

/// Limitador brickwall con lookahead. Es la pieza que justifica el proyecto: lo
/// que permite subir la ganancia sin que el sonido se desarme.
///
/// Un booster que solo multiplica clipea — le corta las puntas a la onda, y ese es
/// el sonido a lata que la gente asocia con los "amplificadores de volumen". La
/// solución es ver el pico antes de que llegue y estar ya bajado cuando llega.
/// En concreto:
///
/// 1. La señal se retrasa `lookaheadSeconds`.
/// 2. Para cada frame que entra se calcula la ganancia que ese frame necesitaría
///    para no pasar el techo.
/// 3. Una **cola monótona** mantiene el mínimo corrido de esas ganancias sobre
///    toda la ventana de lookahead, en O(1) amortizado por muestra.
/// 4. El frame que sale de la línea de retardo se multiplica por la ganancia más
///    baja que va a exigir cualquier frame entre él y el presente.
///
/// El paso 3 es el fácil de errar, y este proyecto lo erró primero. Suavizar la
/// ganancia con ataque y release en vez de tomar el mínimo de la ventana deja que
/// el release vaya subiendo la ganancia durante esos 3 ms. El limitador entonces
/// desborda unos 0,3 dB — suficiente para llegar a fondo de escala y clipear, en
/// silencio, justo en los transitorios fuertes que uno quería proteger. Con el
/// mínimo de la ventana, desbordar es imposible por construcción y no por haber
/// ajustado constantes hasta que se viera bien.
///
/// **True peak, no solo sample peak.** Las muestras no son la onda: entre dos
/// muestras bajo el techo la señal reconstruida por el conversor puede pasarlo.
/// El caso de libro es un seno a un cuarto de la frecuencia de muestreo con fase
/// de 45°: cada muestra queda a −3 dB del pico real. Por eso el paso 2 no mira
/// solo la muestra sino también tres puntos interpolados entre ella y la
/// siguiente (sobremuestreo ×4, como pide ITU-R BS.1770), y la ganancia se
/// calcula contra el mayor. La interpolación necesita unas muestras de futuro, así
/// que la estimación llega `truePeakDelay` frames tarde; el lookahead la cubre
/// con holgura.
public final class Limiter {

    public static let maximumChannels = 32
    private static let maximumLookaheadFrames = 2048

    /// Interpolador ×4: 12 muestras por fase, núcleo de Lanczos de orden 6.
    private static let interpolatorTaps = 12
    private static let interpolatorPhases = 3        // 1/4, 2/4 y 3/4 entre muestras
    private static let historyFrames = 16            // potencia de 2, ≥ taps
    /// Frames de retraso de la estimación de true peak respecto del frame que entra.
    static let truePeakDelay = 6

    public var ceilingDecibels: Float = -0.3 {
        didSet { ceiling = decibelsToLinear(ceilingDecibels) }
    }
    public var lookaheadSeconds: Float = 0.003
    public var releaseSeconds: Float = 0.080

    private var ceiling: Float = decibelsToLinear(-0.3)
    private var releaseCoefficient: Float = 0
    private var gain: Float = 1
    private var channels = 2

    /// Línea de retardo circular, intercalada con paso fijo de `maximumChannels`
    /// para que un cambio en el conteo de canales no pueda mover los frames que ya
    /// están adentro.
    private let delayLine: UnsafeMutablePointer<Float>
    private let delayCapacityFrames = Limiter.maximumLookaheadFrames
    private var lookaheadFrames = 0
    private var writeIndex = 0

    /// Cola monótona con el mínimo deslizante de las ganancias objetivo. La
    /// capacidad cubre la ventana (lookahead + 1), el elemento extra que se empuja
    /// antes de descartar el frente, y el lugar que un buffer circular tiene que
    /// dejar libre para distinguir lleno de vacío.
    private let queueIndex: UnsafeMutablePointer<Int>
    private let queueValue: UnsafeMutablePointer<Float>
    private let queueCapacity = Limiter.maximumLookaheadFrames + 8
    private var queueHead = 0
    private var queueTail = 0
    private var sampleCounter = 0

    /// Últimas `historyFrames` muestras de cada canal, para interpolar.
    private let history: UnsafeMutablePointer<Float>
    private var historyIndex = 0
    /// Coeficientes del interpolador, `interpolatorPhases` × `interpolatorTaps`.
    private let interpolator: UnsafeMutablePointer<Float>

    /// Ganancia más baja aplicada durante el último bloque procesado, en dB (≤ 0).
    public private(set) var reductionDecibels: Float = 0
    /// Pico del último bloque procesado, lineal.
    public private(set) var outputPeak: Float = 0

    public init() {
        let frames = Limiter.maximumLookaheadFrames
        delayLine = .allocate(capacity: frames * Limiter.maximumChannels)
        delayLine.initialize(repeating: 0, count: frames * Limiter.maximumChannels)
        queueIndex = .allocate(capacity: queueCapacity)
        queueIndex.initialize(repeating: 0, count: queueCapacity)
        queueValue = .allocate(capacity: queueCapacity)
        queueValue.initialize(repeating: 1, count: queueCapacity)
        history = .allocate(capacity: Limiter.historyFrames * Limiter.maximumChannels)
        history.initialize(repeating: 0, count: Limiter.historyFrames * Limiter.maximumChannels)
        interpolator = .allocate(capacity: Limiter.interpolatorPhases * Limiter.interpolatorTaps)
        interpolator.initialize(repeating: 0,
                                count: Limiter.interpolatorPhases * Limiter.interpolatorTaps)
        Limiter.designInterpolator(into: interpolator)
        prepare(sampleRate: 48_000, channels: 2)
    }

    /// La fase k estima la señal a (k+1)/4 del camino entre la muestra n−6 y la
    /// n−5, a partir de las doce muestras n−11…n. Cada fase se normaliza a ganancia 1 en
    /// continua, para que una señal constante no se lea más alta de lo que es.
    private static func designInterpolator(into coefficients: UnsafeMutablePointer<Float>) {
        func sinc(_ x: Double) -> Double { x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x) }
        let order = Double(interpolatorTaps / 2)
        for phase in 0..<interpolatorPhases {
            let fraction = Double(phase + 1) / Double(interpolatorPhases + 1)
            var taps = [Double](repeating: 0, count: interpolatorTaps)
            for tap in 0..<interpolatorTaps {
                let t = Double(tap) - Double(truePeakDelay - 1) - fraction
                taps[tap] = abs(t) < order ? sinc(t) * sinc(t / order) : 0
            }
            let sum = taps.reduce(0, +)
            for tap in 0..<interpolatorTaps {
                coefficients[phase * interpolatorTaps + tap] = Float(taps[tap] / sum)
            }
        }
    }

    deinit {
        delayLine.deinitialize(count: delayCapacityFrames * Limiter.maximumChannels)
        delayLine.deallocate()
        queueIndex.deinitialize(count: queueCapacity)
        queueIndex.deallocate()
        queueValue.deinitialize(count: queueCapacity)
        queueValue.deallocate()
        history.deinitialize(count: Limiter.historyFrames * Limiter.maximumChannels)
        history.deallocate()
        interpolator.deinitialize(count: Limiter.interpolatorPhases * Limiter.interpolatorTaps)
        interpolator.deallocate()
    }

    public func prepare(sampleRate: Double, channels: Int) {
        self.channels = min(max(channels, 1), Limiter.maximumChannels)
        ceiling = decibelsToLinear(ceilingDecibels)
        // Nunca menos que el retraso de la estimación de true peak: si no, el
        // frame saldría antes de que llegue su propia estimación.
        lookaheadFrames = min(max(Int(lookaheadSeconds * Float(sampleRate)),
                                  Limiter.truePeakDelay + 1),
                              Limiter.maximumLookaheadFrames - 1)
        releaseCoefficient = smoothingCoefficient(seconds: releaseSeconds,
                                                  sampleRate: Float(sampleRate))
        reset()
    }

    public func reset() {
        delayLine.update(repeating: 0, count: delayCapacityFrames * Limiter.maximumChannels)
        writeIndex = 0
        history.update(repeating: 0, count: Limiter.historyFrames * Limiter.maximumChannels)
        historyIndex = 0
        queueHead = 0
        queueTail = 0
        sampleCounter = 0
        gain = 1
        reductionDecibels = 0
        outputPeak = 0
    }

    /// Procesa audio intercalado en sitio. Sin asignar memoria y sin locks: se
    /// puede llamar desde un IOProc de CoreAudio.
    public func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        // Nunca llamar a prepare() desde acá: hace memset de la línea de retardo y
        // eso no va en un callback de tiempo real. Un cambio en el conteo de
        // canales simplemente se adopta; la línea se limpia sola dentro de una
        // ventana de lookahead.
        let channels = min(max(channels, 1), Limiter.maximumChannels)
        self.channels = channels

        let stride = Limiter.maximumChannels
        var lowestGain: Float = 1
        var peak: Float = 0

        let historyStride = Limiter.historyFrames
        let historyMask = Limiter.historyFrames - 1
        let taps = Limiter.interpolatorTaps

        for frame in 0..<frames {
            let base = frame * channels

            // True peak del frame que entró hace `truePeakDelay`: su muestra y
            // los tres puntos interpolados hasta la siguiente, en cada canal.
            var framePeak: Float = 0
            let newest = historyIndex
            for channel in 0..<channels {
                let ring = history + channel * historyStride
                ring[newest] = buffer[base + channel]
                framePeak = max(framePeak,
                                abs(ring[(newest &- Limiter.truePeakDelay) & historyMask]))
                for phase in 0..<Limiter.interpolatorPhases {
                    let k = interpolator + phase * taps
                    var value: Float = 0
                    // Tap 0 es la muestra más vieja (n−11), tap 11 la que acaba de entrar.
                    for tap in 0..<taps {
                        value += k[tap] * ring[(newest &- (taps - 1) &+ tap) & historyMask]
                    }
                    framePeak = max(framePeak, abs(value))
                }
            }
            historyIndex = (historyIndex + 1) & historyMask

            // Línea de retardo: guardar el frame que entra, ubicar el que sale.
            let writeBase = writeIndex * stride
            let readIndex = (writeIndex + delayCapacityFrames - lookaheadFrames)
                % delayCapacityFrames
            let readBase = readIndex * stride
            for channel in 0..<channels {
                delayLine[writeBase + channel] = buffer[base + channel]
            }
            writeIndex = (writeIndex + 1) % delayCapacityFrames

            // Mínimo deslizante de la ganancia objetivo.
            let target: Float = framePeak > ceiling ? ceiling / framePeak : 1
            while queueTail != queueHead {
                let back = (queueTail + queueCapacity - 1) % queueCapacity
                if queueValue[back] >= target { queueTail = back } else { break }
            }
            queueIndex[queueTail] = sampleCounter
            queueValue[queueTail] = target
            queueTail = (queueTail + 1) % queueCapacity
            while queueIndex[queueHead] < sampleCounter - lookaheadFrames {
                queueHead = (queueHead + 1) % queueCapacity
            }
            let windowMinimum = queueValue[queueHead]
            sampleCounter += 1

            // Bajar es inmediato — el lookahead ya lo adelantó. Volver a subir se
            // suaviza para que la ganancia no haga zipper.
            if windowMinimum < gain {
                gain = windowMinimum
            } else {
                gain = windowMinimum + releaseCoefficient * (gain - windowMinimum)
            }
            lowestGain = min(lowestGain, gain)

            for channel in 0..<channels {
                let sample = max(-1, min(1, delayLine[readBase + channel] * gain))
                buffer[base + channel] = sample
                peak = max(peak, abs(sample))
            }
        }

        outputPeak = peak
        reductionDecibels = linearToDecibels(lowestGain)
    }
}
