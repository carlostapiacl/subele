import Foundation

/// Compresor descendente con rodilla suave, usado acá como calculador de ganancia:
/// responde "por cuánto hay que multiplicar este frame", y quien llama lo aplica.
///
/// El umbral es alto a propósito. Un compresor está acá para domar lo que se
/// acerca al techo, no para aplastar todo — y el **makeup no es opcional**. Sin él
/// un compresor hace el audio *más bajo*, que es exactamente lo contrario de para
/// qué existe un booster. El makeup sale de la curva misma: lo que el compresor le
/// sacaría a una señal a fondo de escala se le devuelve a todo.
public final class Compressor {

    public var thresholdDecibels: Float = -18
    public var ratio: Float = 4
    public var kneeDecibels: Float = 6
    public var attackSeconds: Float = 0.010
    public var releaseSeconds: Float = 0.120

    private var attackCoefficient: Float = 0
    private var releaseCoefficient: Float = 0
    private var envelopeDecibels: Float = 0

    /// Ganancia lineal que compensa la curva, calculada en `prepare`.
    public private(set) var makeup: Float = 1

    /// Reducción de ganancia aplicada en este momento, en dB (≤ 0). Para el medidor.
    public var reductionDecibels: Float { envelopeDecibels }

    public init() { prepare(sampleRate: 48_000) }

    public func prepare(sampleRate: Double) {
        let rate = Float(sampleRate)
        attackCoefficient = smoothingCoefficient(seconds: attackSeconds, sampleRate: rate)
        releaseCoefficient = smoothingCoefficient(seconds: releaseSeconds, sampleRate: rate)
        makeup = decibelsToLinear(-staticReductionDecibels(forLevel: 0))
        reset()
    }

    public func reset() {
        envelopeDecibels = 0
    }

    /// La curva estática, sin constantes de tiempo: reducción en dB para un nivel.
    /// Está separada para poder testearla sola y para que `prepare` pueda
    /// preguntarle qué hace a fondo de escala y de ahí derivar el makeup.
    public func staticReductionDecibels(forLevel levelDecibels: Float) -> Float {
        let over = levelDecibels - thresholdDecibels
        let halfKnee = kneeDecibels / 2
        if over <= -halfKnee { return 0 }
        let slope = 1 / ratio - 1
        if over >= halfKnee { return slope * over }
        // Rodilla: interpolación cuadrática, continua en valor y pendiente en las
        // dos puntas.
        let x = over + halfKnee
        return slope * x * x / (2 * kneeDecibels)
    }

    /// Ganancia lineal suavizada para un frame, makeup incluido.
    @inline(__always)
    public func gain(forPeak peak: Float) -> Float {
        let target = staticReductionDecibels(forLevel: linearToDecibels(peak))
        let coefficient = target < envelopeDecibels ? attackCoefficient : releaseCoefficient
        envelopeDecibels = target + coefficient * (envelopeDecibels - target)
        return decibelsToLinear(envelopeDecibels) * makeup
    }
}
