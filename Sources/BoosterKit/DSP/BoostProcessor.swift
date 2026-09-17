import Foundation

public enum BoostMode: String, CaseIterable, Sendable {
    /// Solo ganancia y limitación. La dinámica queda intacta: lo que sonaba fuerte
    /// respecto de lo que sonaba bajo sigue igual. Lo correcto para música.
    case transparent
    /// Agrega compresión con makeup, que sube lo bajo en vez de aplastar lo alto.
    /// Lo correcto para voz, llamadas y video con audio flojo.
    case loudness
}

/// La cadena completa: ganancia → [compresor + makeup] → limitador brickwall.
///
/// Dos pasadas sobre el bloque en vez de un solo bucle entrelazado. Las etapas son
/// secuenciales, así que el resultado es idéntico, y tenerlas separadas permite
/// leer, testear y reemplazar el compresor y el limitador por su cuenta.
///
/// Sin asignar memoria y sin locks: se puede llamar desde un IOProc de CoreAudio.
public final class BoostProcessor {

    /// Ganancia de entrada, lineal. 1.0 deja la señal intacta, 4.0 es 400%.
    public var gain: Float = 1
    public var mode: BoostMode = .transparent

    public let compressor = Compressor()
    public let limiter = Limiter()

    private var sampleRate: Double = 48_000
    private var channels = 2

    public var outputPeak: Float { limiter.outputPeak }
    public var limiterReductionDecibels: Float { limiter.reductionDecibels }
    public var compressorReductionDecibels: Float { compressor.reductionDecibels }

    public init() {}

    public func prepare(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = min(max(channels, 1), Limiter.maximumChannels)
        compressor.prepare(sampleRate: sampleRate)
        limiter.prepare(sampleRate: sampleRate, channels: self.channels)
    }

    public func reset() {
        compressor.reset()
        limiter.reset()
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let channels = min(max(channels, 1), Limiter.maximumChannels)
        self.channels = channels

        let gain = self.gain
        let applyCompression = (mode == .loudness)

        for frame in 0..<frames {
            let base = frame * channels

            var framePeak: Float = 0
            for channel in 0..<channels {
                let raw = buffer[base + channel] * gain
                // Un solo NaN envenenaría el envolvente del compresor para
                // siempre: NaN se propaga por toda comparación, así que el
                // envolvente nunca se recupera y la salida se muere. Un isFinite
                // por muestra no cuesta nada medible y deja el procesador acotado
                // por diseño.
                let sample = raw.isFinite ? raw : 0
                buffer[base + channel] = sample
                framePeak = max(framePeak, abs(sample))
            }

            if applyCompression {
                // Link estéreo: una sola ganancia para todos los canales, así la
                // imagen no se mueve cuando un lado suena más fuerte que el otro.
                let compressorGain = compressor.gain(forPeak: framePeak)
                for channel in 0..<channels {
                    buffer[base + channel] *= compressorGain
                }
            }
        }

        limiter.process(buffer, frames: frames, channels: channels)
    }
}
