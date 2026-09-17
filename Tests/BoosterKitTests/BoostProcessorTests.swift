import Foundation
import Testing
@testable import BoosterKit

@Suite("Cadena completa")
struct BoostProcessorTests {

    @Test("la ganancia es exacta mientras haya headroom", arguments: [
        (gain: Float(1), expected: Float(-20)),
        (gain: Float(3), expected: Float(-10.46)),
        (gain: Float(4), expected: Float(-7.96)),
    ])
    func gainIsExact(gain: Float, expected: Float) {
        let processor = makeProcessor(gain: gain, mode: .transparent)
        let output = render(processor, sine(decibels: -20, frames: 48_000, channels: 2),
                            channels: 2)
        #expect(abs(linearToDecibels(steadyStatePeak(output, channels: 2)) - expected) < 0.2)
    }

    @Test("el modo loudness levanta el material bajo")
    func loudnessLifts() {
        let input = sine(decibels: -20, frames: 48_000, channels: 2)
        let transparent = render(makeProcessor(gain: 1, mode: .transparent), input, channels: 2)
        let loudness = render(makeProcessor(gain: 1, mode: .loudness), input, channels: 2)
        let lift = linearToDecibels(steadyStatePeak(loudness, channels: 2))
                 - linearToDecibels(steadyStatePeak(transparent, channels: 2))
        // El umbral de −18 dB a 4:1 deja +13,5 dB de makeup, menos lo que la
        // curva le saca a una señal de −20 dBFS dentro de la rodilla.
        #expect(abs(lift - 13.44) < 0.3)
    }

    @Test("el resultado no depende del tamaño de bloque que entregue CoreAudio")
    func blockSizeInvariant() {
        // Si alguna vez difiere, hay estado perdiéndose o reiniciándose entre bloques.
        let channels = 2
        let frames = 12_000
        var input = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let envelope = 0.5 + 0.5 * sinf(2 * .pi * 3 * Float(frame) / 48_000)
            let value = envelope * sinf(2 * .pi * 440 * Float(frame) / 48_000)
            for channel in 0..<channels { input[frame * channels + channel] = value }
        }
        let small = render(makeProcessor(gain: 2.5, mode: .loudness), input,
                           channels: channels, blockSize: 32)
        let large = render(makeProcessor(gain: 2.5, mode: .loudness), input,
                           channels: channels, blockSize: 1024)
        #expect(zip(small, large).allSatisfy { $0 == $1 })
    }

    @Test("acotado para cualquier conteo de canales", arguments: [1, 2, 4, 6, 8])
    func boundedForEveryChannelCount(channels: Int) {
        // La línea de retardo usa un paso fijo, así que un conteo de canales raro
        // es justo donde un índice se saldría del final.
        let processor = makeProcessor(gain: 3, mode: .loudness, channels: channels)
        let output = render(processor, sine(decibels: -6, frames: 4_800, channels: channels),
                            channels: channels)
        #expect(peak(output) > 0)
        #expect(linearToDecibels(peak(output)) <= ceilingDecibels + 0.05)
    }

    @Test("NaN e infinito no pueden envenenar la cadena")
    func survivesNonFiniteInput() {
        // Un solo NaN se propaga por toda comparación. Sin sanear, el envolvente
        // del compresor no se recupera nunca y la salida se muere para siempre.
        let channels = 2
        var input = sine(decibels: -12, frames: 4_800, channels: channels)
        input[100] = .nan
        input[101] = .infinity
        input[102] = -.infinity
        let output = render(makeProcessor(gain: 2, mode: .loudness), input, channels: channels)

        #expect(output.allSatisfy { $0.isFinite })
        // Sigue viva después: una salida muerta también sería finita.
        let tail = Array(output[(output.count / 2)...])
        #expect(peak(tail) > 0.01)
    }

    @Test("entra silencio, sale silencio")
    func silenceStaysSilent() {
        let processor = makeProcessor(gain: 4, mode: .loudness)
        let output = render(processor, [Float](repeating: 0, count: 9_600), channels: 2)
        #expect(peak(output) == 0)
    }
}
