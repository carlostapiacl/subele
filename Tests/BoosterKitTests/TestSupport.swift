import Foundation
@testable import BoosterKit

/// Interleaved sine at a known level. Everything here is deterministic on
/// purpose: measuring through the speakers is useless, because anything else
/// playing on the machine mixes into the tap and contaminates the meter.
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

/// Runs a buffer through a processor in blocks, returning the processed audio.
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

/// Peak of the second half, once the lookahead and the attack have settled.
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

/// The limiter ceiling, as a level the output must never exceed.
let ceilingDecibels: Float = -0.3
