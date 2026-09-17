import Foundation

@inline(__always) public func linearToDecibels(_ value: Float) -> Float {
    20 * log10f(max(value, 1e-9))
}

@inline(__always) public func decibelsToLinear(_ decibels: Float) -> Float {
    powf(10, decibels / 20)
}

/// Coeficiente de un suavizador de un polo que alcanza ~63% de un escalón en
/// `seconds`.
@inline(__always)
public func smoothingCoefficient(seconds: Float, sampleRate: Float) -> Float {
    guard seconds > 0, sampleRate > 0 else { return 0 }
    return expf(-1 / (seconds * sampleRate))
}
