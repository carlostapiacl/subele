import Foundation

/// Los valores crudos se quedan en `transparent` y `loudness` aunque la interfaz
/// los llame Música y Voz: son los nombres técnicos de lo que hace cada uno, y
/// la API pública no tiene por qué seguir a la interfaz.
public enum BoostMode: String, CaseIterable, Sendable {
    /// Solo ganancia y limitación. La dinámica queda intacta: lo que sonaba fuerte
    /// respecto de lo que sonaba bajo sigue igual. Lo correcto para música.
    ///
    /// Ojo: con la ganancia en 100% este modo no hace nada, a propósito. Recién se
    /// escucha al subir, cuando el limitador empieza a trabajar.
    case transparent
    /// Agrega compresión con makeup, que sube lo bajo en vez de aplastar lo alto.
    /// Lo correcto para voz, llamadas y video con audio flojo.
    case loudness
}

/// La cadena completa: ganancia → ecualizador → [compresor + makeup] → limitador.
///
/// Una pasada por etapa en vez de un solo bucle entrelazado. Las etapas son
/// secuenciales, así que el resultado es idéntico, y tenerlas separadas permite
/// leer, testear y reemplazar cada una por su cuenta.
///
/// Sin asignar memoria y sin locks: se puede llamar desde un IOProc de CoreAudio.
///
/// Todo lo que cruza de hilo —ganancia y modo hacia el audio, medidores hacia la
/// interfaz— pasa por atómicos. Antes eran propiedades comunes, que en arm64 y
/// x86-64 funcionaban de casualidad pero eran formalmente una carrera de datos.
public final class BoostProcessor {

    private let gainParameter = AtomicFloat(1)
    private let modeParameter = AtomicUInt32(0)

    /// Ganancia de entrada, lineal. 1.0 deja la señal intacta, 4.0 es 400%.
    public var gain: Float {
        get { gainParameter.value }
        set { gainParameter.value = newValue }
    }

    public var mode: BoostMode {
        get { modeParameter.value == 1 ? .loudness : .transparent }
        set { modeParameter.value = newValue == .loudness ? 1 : 0 }
    }

    public let equalizer = Equalizer()
    public let compressor = Compressor()
    public let limiter = Limiter()
    /// Lo que sale, para el espectro del ecualizador. Apagado no cuesta nada.
    public let spectrum = SpectrumTap()

    private var sampleRate: Double = 48_000
    private var channels = 2

    // Copias de los medidores para la interfaz, publicadas al final de cada bloque.
    private let publishedPeak = AtomicFloat(0)
    private let publishedLimiterReduction = AtomicFloat(0)
    private let publishedCompressorReduction = AtomicFloat(0)

    public var outputPeak: Float { publishedPeak.value }
    public var limiterReductionDecibels: Float { publishedLimiterReduction.value }
    public var compressorReductionDecibels: Float { publishedCompressorReduction.value }

    public init() {}

    public func prepare(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = min(max(channels, 1), Limiter.maximumChannels)
        equalizer.prepare(sampleRate: sampleRate)
        compressor.prepare(sampleRate: sampleRate)
        limiter.prepare(sampleRate: sampleRate, channels: self.channels)
    }

    public func reset() {
        equalizer.reset()
        compressor.reset()
        limiter.reset()
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let channels = min(max(channels, 1), Limiter.maximumChannels)
        self.channels = channels

        let gain = self.gain
        let applyCompression = (mode == .loudness)
        let samples = frames * channels

        for index in 0..<samples {
            let raw = buffer[index] * gain
            // Un solo NaN envenenaría el envolvente del compresor y los estados del
            // ecualizador para siempre: NaN se propaga por toda cuenta, así que
            // nunca se recuperan y la salida se muere. Un isFinite por muestra no
            // cuesta nada medible y deja el procesador acotado por diseño.
            buffer[index] = raw.isFinite ? raw : 0
        }

        equalizer.process(buffer, frames: frames, channels: channels)

        if applyCompression {
            for frame in 0..<frames {
                let base = frame * channels
                var framePeak: Float = 0
                for channel in 0..<channels {
                    framePeak = max(framePeak, abs(buffer[base + channel]))
                }
                // Link estéreo: una sola ganancia para todos los canales, así la
                // imagen no se mueve cuando un lado suena más fuerte que el otro.
                let compressorGain = compressor.gain(forPeak: framePeak)
                for channel in 0..<channels {
                    buffer[base + channel] *= compressorGain
                }
            }
        }

        limiter.process(buffer, frames: frames, channels: channels)
        spectrum.write(buffer, frames: frames, channels: channels)

        publishedPeak.value = limiter.outputPeak
        publishedLimiterReduction.value = limiter.reductionDecibels
        publishedCompressorReduction.value = applyCompression ? compressor.reductionDecibels : 0
    }
}
