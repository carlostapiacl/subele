import Foundation
import Testing
@testable import BoosterKit

@Suite("Limitador")
struct LimiterTests {

    @Test("el material tranquilo pasa sin que lo toquen")
    func transparentBelowCeiling() {
        let processor = makeProcessor(gain: 1, mode: .transparent)
        let output = render(processor, sine(decibels: -20, frames: 48_000, channels: 2),
                            channels: 2)
        #expect(abs(linearToDecibels(steadyStatePeak(output, channels: 2)) - -20) < 0.2)
    }

    @Test("llega al techo pero no lo pasa", arguments: [
        (gain: Float(3), input: Float(-3)),
        (gain: Float(4), input: Float(0)),
        (gain: Float(4), input: Float(-6)),
    ])
    func landsOnTheCeiling(gain: Float, input: Float) {
        let processor = makeProcessor(gain: gain, mode: .transparent)
        let output = render(processor, sine(decibels: input, frames: 48_000, channels: 2),
                            channels: 2)
        let measured = linearToDecibels(steadyStatePeak(output, channels: 2))
        #expect(abs(measured - ceilingDecibels) < 0.1)
    }

    @Test("un transitorio de silencio a fondo de escala no desborda")
    func transientDoesNotOvershoot() {
        // El caso para el que existe el lookahead. Un limitador que solo suaviza
        // ataque y release deja pasar el primer pico antes de haber bajado.
        let channels = 2
        let frames = 24_000
        var input = [Float](repeating: 0, count: frames * channels)
        for frame in (frames / 2)..<frames {
            let value = sinf(2 * .pi * 440 * Float(frame) / 48_000)
            for channel in 0..<channels { input[frame * channels + channel] = value }
        }
        let processor = makeProcessor(gain: 4, mode: .transparent)
        let output = render(processor, input, channels: channels)
        #expect(linearToDecibels(peak(output)) <= ceilingDecibels + 0.05)
    }

    @Test("la salida nunca llega a fondo de escala, así que el clamp no actúa")
    func neverClips() {
        let processor = makeProcessor(gain: 4, mode: .loudness)
        let output = render(processor, sine(decibels: 0, frames: 48_000, channels: 2),
                            channels: 2)
        #expect(peak(output) < 0.999)
    }
}
