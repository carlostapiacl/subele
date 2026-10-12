import Foundation
import Testing
@testable import BoosterKit

@Suite("Curva y espectro")
struct SpectrumTests {

    @Test("la curva que se dibuja es la que suena",
          arguments: [40.0, 250, 1_000, 3_000, 12_000])
    func drawnCurveMatchesAudio(frequency: Double) {
        // La curva se calcula con la fórmula; acá se compara contra un seno pasado
        // de verdad por el ecualizador.
        let gains: [Float] = [6, -3, 4, -5, 8]
        let equalizer = Equalizer()
        equalizer.prepare(sampleRate: 48_000)
        for (band, gain) in gains.enumerated() { equalizer.setGain(gain, ofBand: band) }

        var buffer = sine(decibels: -30, frames: 48_000, channels: 1, frequency: Float(frequency))
        let input = buffer
        buffer.withUnsafeMutableBufferPointer {
            equalizer.process($0.baseAddress!, frames: 48_000, channels: 1)
        }
        // RMS y no pico: a 12 kHz un seno tiene cuatro muestras por ciclo, y el
        // pico muestreado depende de la fase que le dejó el filtro.
        func rms(_ samples: [Float]) -> Float {
            let tail = samples[(samples.count / 2)...]
            return sqrtf(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))
        }
        let measured = linearToDecibels(rms(buffer)) - linearToDecibels(rms(input))
        let drawn = Equalizer.responseDecibels(atFrequency: frequency, gains: gains,
                                               sampleRate: 48_000)
        #expect(abs(Double(measured) - drawn) < 0.15)
    }

    @Test("plano es una línea en 0 dB")
    func flatCurve() {
        for frequency in stride(from: 20.0, to: 20_000, by: 997) {
            #expect(Equalizer.responseDecibels(atFrequency: frequency, gains: [0, 0, 0, 0, 0],
                                               sampleRate: 44_100) == 0)
        }
    }

    @Test("un tono de 1 kHz aparece en su banda y al nivel correcto")
    func analyzerFindsTone() {
        let analyzer = SpectrumAnalyzer()
        let samples = sine(decibels: -6, frames: 4096, channels: 1, frequency: 1_000)
        analyzer.update(samples: samples, sampleRate: 48_000)
        let band = (0..<analyzer.bandCount).min {
            abs(analyzer.centerFrequency(ofBand: $0) - 1_000)
                < abs(analyzer.centerFrequency(ofBand: $1) - 1_000)
        }!
        #expect(abs(analyzer.levels[band] + 6) < 1.5)
        let far = (0..<analyzer.bandCount).first { analyzer.centerFrequency(ofBand: $0) > 80 }!
        #expect(analyzer.levels[far] < -50)
    }

    @Test("el tap entrega lo último que sonó, en orden")
    func tapKeepsLatest() {
        let tap = SpectrumTap()
        tap.isEnabled = true
        var ramp = (0..<10_000).map { Float($0) }
        ramp.withUnsafeBufferPointer { tap.write($0.baseAddress!, frames: 10_000, channels: 1) }
        var out = [Float](repeating: 0, count: 4)
        out.withUnsafeMutableBufferPointer { tap.copyLatest(4, into: $0.baseAddress!) }
        #expect(out == [9_996, 9_997, 9_998, 9_999])
    }

    @Test("apagado, el tap no escribe nada")
    func tapOffWritesNothing() {
        let tap = SpectrumTap()
        let ones = [Float](repeating: 1, count: 64)
        ones.withUnsafeBufferPointer { tap.write($0.baseAddress!, frames: 64, channels: 1) }
        var out = [Float](repeating: 9, count: 4)
        out.withUnsafeMutableBufferPointer { tap.copyLatest(4, into: $0.baseAddress!) }
        #expect(out == [0, 0, 0, 0])
    }
}
