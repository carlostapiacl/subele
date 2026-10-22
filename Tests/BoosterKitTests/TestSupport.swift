import Foundation
@testable import BoosterKit

/// Seno intercalado a un nivel conocido. Todo acá es determinístico a propósito:
/// medir por los parlantes no sirve, porque cualquier otra cosa que suene en la
/// máquina se mezcla en el tap y contamina el medidor.
func sine(decibels: Float, frames: Int, channels: Int,
          sampleRate: Float = 48_000, frequency: Float = 440) -> [Float] {
    let amplitude = decibelsToLinear(decibels)
    var buffer = [Float](repeating: 0, count: frames * channels)
    for frame in 0..<frames {
        let value = amplitude * sinf(2 * .pi * frequency * Float(frame) / sampleRate)
        for channel in 0..<channels { buffer[frame * channels + channel] = value }
    }
    return buffer
}

/// Pasa un buffer por el procesador en bloques y devuelve el audio procesado.
func render(_ processor: BoostProcessor, _ input: [Float],
            channels: Int, blockSize: Int = 512) -> [Float] {
    var buffer = input
    let frames = input.count / channels
    buffer.withUnsafeMutableBufferPointer { raw in
        guard let base = raw.baseAddress else { return }
        var frame = 0
        while frame < frames {
            let count = min(blockSize, frames - frame)
            processor.process(base + frame * channels, frames: count, channels: channels)
            frame += count
        }
    }
    return buffer
}

/// Pico de la segunda mitad, ya asentados el lookahead y el ataque.
func steadyStatePeak(_ samples: [Float], channels: Int) -> Float {
    let start = (samples.count / channels / 2) * channels
    return samples[start...].reduce(0) { max($0, abs($1)) }
}

func peak(_ samples: [Float]) -> Float {
    samples.reduce(0) { max($0, abs($1)) }
}

func makeProcessor(gain: Float, mode: BoostMode,
                   sampleRate: Double = 48_000, channels: Int = 2) -> BoostProcessor {
    let processor = BoostProcessor()
    processor.prepare(sampleRate: sampleRate, channels: channels)
    processor.gain = gain
    processor.mode = mode
    return processor
}

/// El techo del limitador, como nivel que la salida nunca debe pasar.
let ceilingDecibels: Float = -0.3

/// Distorsión armónica total en %, armónicos 2 a 10, sobre la segunda mitad de
/// un canal. Goertzel en cada frecuencia: no hace falta una FFT para diez bins.
func totalHarmonicDistortion(_ samples: [Float], channels: Int, frequency: Double,
                             sampleRate: Double = 48_000) -> Double {
    let frames = samples.count / channels
    let start = frames / 2
    // Un número entero de períodos, para que no haya fuga entre bins.
    let period = sampleRate / frequency
    let count = Int((Double(frames - start) / period).rounded(.down) * period)
    func magnitude(_ target: Double) -> Double {
        let w = 2 * Double.pi * target / sampleRate
        let coefficient = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for frame in start..<(start + count) {
            let s = Double(samples[frame * channels]) + coefficient * s1 - s2
            s2 = s1
            s1 = s
        }
        return sqrt(max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2))
    }
    let fundamental = magnitude(frequency)
    let harmonics = (2...10).map { magnitude(frequency * Double($0)) }
    return 100 * sqrt(harmonics.reduce(0) { $0 + $1 * $1 }) / fundamental
}
