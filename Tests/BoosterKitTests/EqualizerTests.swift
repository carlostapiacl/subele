import Foundation
import Testing
@testable import BoosterKit

/// Pasa un buffer por el ecualizador solo, en bloques.
private func equalize(_ equalizer: Equalizer, _ input: [Float],
                      channels: Int, blockSize: Int = 512) -> [Float] {
    var buffer = input
    let frames = input.count / channels
    buffer.withUnsafeMutableBufferPointer { raw in
        guard let base = raw.baseAddress else { return }
        var frame = 0
        while frame < frames {
            let count = min(blockSize, frames - frame)
            equalizer.process(base + frame * channels, frames: count, channels: channels)
            frame += count
        }
    }
    return buffer
}

/// Cuánto cambia el nivel de un seno de `frequency` Hz al pasar por el ecualizador.
private func response(_ equalizer: Equalizer, frequency: Float,
                      sampleRate: Double = 48_000) -> Float {
    let input = sine(decibels: -24, frames: Int(sampleRate), channels: 2,
                     sampleRate: Float(sampleRate), frequency: frequency)
    let output = equalize(equalizer, input, channels: 2)
    return linearToDecibels(steadyStatePeak(output, channels: 2))
         - linearToDecibels(steadyStatePeak(input, channels: 2))
}

private func makeEqualizer(_ gains: [Int: Float], sampleRate: Double = 48_000) -> Equalizer {
    let equalizer = Equalizer()
    equalizer.prepare(sampleRate: sampleRate)
    for (band, decibels) in gains { equalizer.setGain(decibels, ofBand: band) }
    return equalizer
}

@Suite("Ecualizador")
struct EqualizerTests {

    @Test("plano no toca la señal, ni un bit")
    func flatIsBitExact() {
        let input = sine(decibels: -3, frames: 9_600, channels: 2)
        let output = equalize(makeEqualizer([:]), input, channels: 2)
        #expect(output == input)
    }

    @Test("volver a cero deja de tocar la señal")
    func backToFlatIsBitExact() {
        let equalizer = makeEqualizer([2: 6])
        _ = equalize(equalizer, sine(decibels: -12, frames: 4_800, channels: 2), channels: 2)
        equalizer.setGain(0, ofBand: 2)
        let input = sine(decibels: -12, frames: 4_800, channels: 2)
        #expect(equalize(equalizer, input, channels: 2) == input)
    }

    @Test("cada campana sube su frecuencia lo que dice", arguments: [1, 2, 3])
    func peakBandHitsItsGain(band: Int) {
        let frequency = Float(Equalizer.frequency(ofBand: band))
        #expect(abs(response(makeEqualizer([band: 6]), frequency: frequency) - 6) < 0.2)
        #expect(abs(response(makeEqualizer([band: -6]), frequency: frequency) + 6) < 0.2)
    }

    @Test("el shelf de graves sube los graves y deja la voz quieta")
    func lowShelf() {
        let equalizer = makeEqualizer([0: 9])
        #expect(abs(response(equalizer, frequency: 25) - 9) < 0.5)
        #expect(abs(response(makeEqualizer([0: 9]), frequency: 2_000)) < 0.2)
    }

    @Test("el shelf de agudos sube los agudos y deja los graves quietos")
    func highShelf() {
        #expect(abs(response(makeEqualizer([4: 9]), frequency: 20_000) - 9) < 0.7)
        #expect(abs(response(makeEqualizer([4: 9]), frequency: 200)) < 0.2)
    }

    @Test("las ganancias se acotan y un NaN no entra")
    func clamping() {
        let equalizer = Equalizer()
        equalizer.setGain(40, ofBand: 0)
        equalizer.setGain(-40, ofBand: 1)
        equalizer.setGain(.nan, ofBand: 2)
        equalizer.setGain(3, ofBand: 99)
        #expect(equalizer.gain(ofBand: 0) == Equalizer.maximumGainDecibels)
        #expect(equalizer.gain(ofBand: 1) == -Equalizer.maximumGainDecibels)
        #expect(equalizer.gain(ofBand: 2) == 0)
    }

    @Test("estable a todo máximo en cualquier frecuencia de muestreo",
          arguments: [44_100.0, 48_000, 88_200, 96_000, 192_000])
    func stableAtEverySampleRate(sampleRate: Double) {
        // La banda de 12 kHz es la que se acerca a Nyquist a 44,1 kHz.
        var gains: [Int: Float] = [:]
        for band in 0..<Equalizer.bandCount { gains[band] = Equalizer.maximumGainDecibels }
        let equalizer = makeEqualizer(gains, sampleRate: sampleRate)
        var input = [Float](repeating: 0, count: Int(sampleRate) * 2)
        var seed: UInt32 = 1
        for index in input.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            input[index] = Float(seed >> 8) / Float(1 << 24) * 0.5 - 0.25
        }
        let output = equalize(equalizer, input, channels: 2)
        #expect(output.allSatisfy { $0.isFinite })
        // +12 dB en todas las bandas es a lo más ~+13 dB: nada se dispara.
        #expect(peak(output) < peak(input) * 6)
    }

    @Test("con graves al máximo, la cadena completa sigue sin pasar el techo")
    func boostedBassStaysUnderCeiling() {
        let processor = makeProcessor(gain: 4, mode: .transparent)
        processor.equalizer.setGain(Equalizer.maximumGainDecibels, ofBand: 0)
        let output = render(processor, sine(decibels: -1, frames: 48_000, channels: 2,
                                            frequency: 50), channels: 2)
        #expect(linearToDecibels(peak(output)) <= ceilingDecibels + 0.05)
    }

    @Test("con ecualizador, el resultado no depende del tamaño de bloque")
    func blockSizeInvariant() {
        func run(_ blockSize: Int) -> [Float] {
            let processor = makeProcessor(gain: 2, mode: .loudness)
            processor.equalizer.setGain(8, ofBand: 0)
            processor.equalizer.setGain(-4, ofBand: 3)
            return render(processor, sine(decibels: -10, frames: 12_000, channels: 2,
                                          frequency: 90), channels: 2, blockSize: blockSize)
        }
        #expect(run(32) == run(1024))
    }
}
