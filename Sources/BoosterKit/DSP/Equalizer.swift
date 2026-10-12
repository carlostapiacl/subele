import CAtomics
import Foundation

/// Ecualizador de cinco bandas: un shelf de graves, tres campanas y un shelf de
/// agudos. Biquads del cookbook de Robert Bristow-Johnson, en forma directa
/// transpuesta II.
///
/// Va antes del compresor y del limitador a propósito: subir graves agrega
/// energía, y si la cadena terminara en el ecualizador ese pico extra clipearía.
/// Puesto antes, el limitador lo ve como a cualquier otro pico.
///
/// Las ganancias las escribe la interfaz y las lee el hilo de audio. Cada una es
/// un float atómico, y un contador de generación avisa que hay que recalcular los
/// coeficientes. El recálculo lo hace el hilo de audio al empezar el bloque: son
/// cinco senos y cinco cosenos, sin asignar memoria, y así los coeficientes nunca
/// se escriben mientras alguien los está usando.
///
/// Con todas las bandas en 0 dB no se toca la señal: la salida es idéntica bit a
/// bit a la entrada.
public final class Equalizer {

    public enum Kind: Sendable { case lowShelf, peak, highShelf }

    public static let bandCount = 5
    public static let maximumGainDecibels: Float = 12

    /// Frecuencia central (o de corte, en los shelves) de cada banda.
    public static func frequency(ofBand band: Int) -> Double {
        // Un switch y no un arreglo estático: leer un `static let` desde el hilo
        // de audio pasa por swift_once la primera vez, que puede tomar un lock.
        switch band {
        case 0: return 60
        case 1: return 250
        case 2: return 1_000
        case 3: return 4_000
        default: return 12_000
        }
    }

    public static func kind(ofBand band: Int) -> Kind {
        switch band {
        case 0: return .lowShelf
        case bandCount - 1: return .highShelf
        default: return .peak
        }
    }

    /// Q de las campanas. Las bandas están separadas dos octavas, así que una
    /// campana ancha deja la respuesta pareja entre ellas en vez de con valles.
    private static let peakQ = 0.9
    /// Pendiente de los shelves (Q de Butterworth): sin sobrepico en la transición.
    private static let shelfQ = 0.7071

    private var sampleRate: Double = 48_000

    /// Ganancias en dB, compartidas con la interfaz.
    private let gains: UnsafeMutablePointer<Float>
    private let generation = AtomicUInt32(0)

    // Todo lo que sigue es del hilo de audio.
    private var seenGeneration: UInt32 = .max
    /// b0, b1, b2, a1, a2 por banda, ya normalizados por a0.
    private let coefficients: UnsafeMutablePointer<Double>
    /// z1, z2 por banda y por canal.
    private let state: UnsafeMutablePointer<Double>
    private let stateCount = Equalizer.bandCount * Limiter.maximumChannels * 2
    private var activeBands: UInt8 = 0

    public init() {
        gains = .allocate(capacity: Equalizer.bandCount)
        gains.initialize(repeating: 0, count: Equalizer.bandCount)
        coefficients = .allocate(capacity: Equalizer.bandCount * 5)
        coefficients.initialize(repeating: 0, count: Equalizer.bandCount * 5)
        state = .allocate(capacity: stateCount)
        state.initialize(repeating: 0, count: stateCount)
    }

    deinit {
        gains.deallocate()
        coefficients.deallocate()
        state.deallocate()
    }

    /// Ganancia de una banda en dB, acotada a ±`maximumGainDecibels`. Se puede
    /// escribir desde cualquier hilo.
    public func gain(ofBand band: Int) -> Float {
        guard (0..<Equalizer.bandCount).contains(band) else { return 0 }
        return ca_load_float(gains + band)
    }

    public func setGain(_ decibels: Float, ofBand band: Int) {
        guard (0..<Equalizer.bandCount).contains(band) else { return }
        let limit = Equalizer.maximumGainDecibels
        let value = decibels.isFinite ? min(max(decibels, -limit), limit) : 0
        ca_store_float(gains + band, value)
        generation.increment()
    }

    public var isFlat: Bool {
        (0..<Equalizer.bandCount).allSatisfy { gain(ofBand: $0) == 0 }
    }

    public func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        reset()
        seenGeneration = generation.value &- 1   // fuerza el recálculo
    }

    public func reset() {
        state.update(repeating: 0, count: stateCount)
    }

    /// Procesa audio intercalado en sitio. Sin asignar memoria y sin locks.
    public func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let current = generation.value
        if current != seenGeneration {
            seenGeneration = current
            updateCoefficients()
        }
        guard activeBands != 0 else { return }

        let channels = min(max(channels, 1), Limiter.maximumChannels)
        for band in 0..<Equalizer.bandCount where activeBands & (1 << band) != 0 {
            let c = coefficients + band * 5
            let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]
            for channel in 0..<channels {
                let z = state + (band * Limiter.maximumChannels + channel) * 2
                var z1 = z[0], z2 = z[1]
                for frame in 0..<frames {
                    let index = frame * channels + channel
                    let x = Double(buffer[index])
                    let y = b0 * x + z1
                    z1 = b1 * x - a1 * y + z2
                    z2 = b2 * x - a2 * y
                    buffer[index] = Float(y)
                }
                // Los estados decaen hacia cero en silencio y terminan en números
                // desnormalizados, que en Intel son decenas de veces más lentos.
                z[0] = abs(z1) < 1e-20 ? 0 : z1
                z[1] = abs(z2) < 1e-20 ? 0 : z2
            }
        }
    }

    private func updateCoefficients() {
        var active: UInt8 = 0
        for band in 0..<Equalizer.bandCount {
            let decibels = Double(ca_load_float(gains + band))
            let c = coefficients + band * 5
            guard decibels != 0 else {
                // Banda apagada: se limpia su estado para que al volver a
                // encenderla no arrastre una cola vieja.
                if activeBands & (1 << band) != 0 {
                    let z = state + band * Limiter.maximumChannels * 2
                    z.update(repeating: 0, count: Limiter.maximumChannels * 2)
                }
                continue
            }
            active |= 1 << band

            let k = Equalizer.coefficients(band: band, decibels: decibels,
                                           sampleRate: sampleRate)
            c[0] = k.b0
            c[1] = k.b1
            c[2] = k.b2
            c[3] = k.a1
            c[4] = k.a2
        }
        activeBands = active
    }

    // MARK: Coeficientes y respuesta

    public typealias Coefficients = (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double)

    /// Coeficientes normalizados de una banda. Es una función pura, así la usan
    /// igual el hilo de audio y la interfaz cuando dibuja la curva: lo que se ve
    /// es exactamente lo que suena.
    public static func coefficients(band: Int, decibels: Double,
                                    sampleRate: Double) -> Coefficients {
        // Nunca por encima de ~0,45 de la frecuencia de muestreo: a 44,1 kHz la
        // banda de 12 kHz entra, pero un biquad pegado a Nyquist se vuelve
        // inestable.
        let frequency = min(Equalizer.frequency(ofBand: band), sampleRate * 0.45)
        let a = pow(10, decibels / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)

        var b0, b1, b2, a0, a1, a2: Double
        switch Equalizer.kind(ofBand: band) {
        case .peak:
            let alpha = sinw / (2 * Equalizer.peakQ)
            b0 = 1 + alpha * a
            b1 = -2 * cosw
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosw
            a2 = 1 - alpha / a
        case .lowShelf:
            let k = 2 * sqrt(a) * sinw / (2 * Equalizer.shelfQ)
            b0 = a * ((a + 1) - (a - 1) * cosw + k)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
            b2 = a * ((a + 1) - (a - 1) * cosw - k)
            a0 = (a + 1) + (a - 1) * cosw + k
            a1 = -2 * ((a - 1) + (a + 1) * cosw)
            a2 = (a + 1) + (a - 1) * cosw - k
        case .highShelf:
            let k = 2 * sqrt(a) * sinw / (2 * Equalizer.shelfQ)
            b0 = a * ((a + 1) + (a - 1) * cosw + k)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
            b2 = a * ((a + 1) + (a - 1) * cosw - k)
            a0 = (a + 1) - (a - 1) * cosw + k
            a1 = 2 * ((a - 1) - (a + 1) * cosw)
            a2 = (a + 1) - (a - 1) * cosw - k
        }
        return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    /// Respuesta en dB de toda la cadena de bandas a una frecuencia, para unas
    /// ganancias dadas. Evalúa cada biquad en el círculo unitario: es la curva
    /// teórica exacta, no una aproximación dibujada a mano.
    public static func responseDecibels(atFrequency frequency: Double, gains: [Float],
                                        sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1) = (cos(w), sin(w))
        let (c2, s2) = (cos(2 * w), sin(2 * w))
        var total = 0.0
        for (band, gain) in gains.prefix(bandCount).enumerated() where gain != 0 {
            let k = coefficients(band: band, decibels: Double(gain), sampleRate: sampleRate)
            // H(e^jw) = (b0 + b1 e^-jw + b2 e^-2jw) / (1 + a1 e^-jw + a2 e^-2jw)
            let numeratorReal = k.b0 + k.b1 * c1 + k.b2 * c2
            let numeratorImaginary = -(k.b1 * s1 + k.b2 * s2)
            let denominatorReal = 1 + k.a1 * c1 + k.a2 * c2
            let denominatorImaginary = -(k.a1 * s1 + k.a2 * s2)
            let numerator = numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
            let denominator = denominatorReal * denominatorReal
                + denominatorImaginary * denominatorImaginary
            total += 10 * log10(max(numerator, 1e-30) / max(denominator, 1e-30))
        }
        return total
    }
}
