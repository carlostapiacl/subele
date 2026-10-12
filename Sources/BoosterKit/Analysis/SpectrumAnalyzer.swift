import Accelerate
import Foundation

/// Convierte las últimas muestras de la salida en un espectro por bandas
/// logarítmicas, listo para dibujar.
///
/// Corre en el hilo de la interfaz, nunca en el de audio: una FFT de 4096 puntos
/// veinte veces por segundo es nada para la CPU, pero no tiene por qué competir
/// con el callback.
///
/// Bandas logarítmicas porque el oído lo es: en un eje lineal todo lo que importa
/// (graves, voz) quedaría apretado en el primer décimo del ancho.
public final class SpectrumAnalyzer {

    public static let lowestFrequency = 20.0
    public static let highestFrequency = 20_000.0

    public let bandCount: Int
    /// Nivel suavizado de cada banda, en dBFS.
    public private(set) var levels: [Float]

    private let log2n: vDSP_Length = 12
    private let size = 4096
    private let setup: FFTSetup
    private var window: [Float]
    private var input: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]
    /// Escala que lleva |X| a la amplitud del tono: zrip devuelve el doble de la
    /// DFT y un tono de amplitud A llega con A·Σventana/2, así que A = |X|/Σventana.
    private let amplitudeScale: Float

    /// Cuánto baja una banda por cuadro cuando el nivel cae: subir es inmediato,
    /// bajar es lento, como un medidor analógico. Sin esto el gráfico titila.
    public var releaseDecibelsPerFrame: Float = 2.5
    public static let floorDecibels: Float = -90

    public init(bandCount: Int = 56) {
        self.bandCount = bandCount
        levels = [Float](repeating: SpectrumAnalyzer.floorDecibels, count: bandCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        amplitudeScale = 1 / window.reduce(0, +)
        input = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
        magnitudes = [Float](repeating: 0, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Frecuencia central de una banda, para dibujarla en el eje.
    public func centerFrequency(ofBand band: Int) -> Double {
        let low = log10(SpectrumAnalyzer.lowestFrequency)
        let high = log10(SpectrumAnalyzer.highestFrequency)
        return pow(10, low + (high - low) * (Double(band) + 0.5) / Double(bandCount))
    }

    public func reset() {
        levels = [Float](repeating: SpectrumAnalyzer.floorDecibels, count: bandCount)
    }

    /// Analiza las últimas muestras del tap y actualiza `levels`.
    public func update(from tap: SpectrumTap, sampleRate: Double) {
        input.withUnsafeMutableBufferPointer { tap.copyLatest(size, into: $0.baseAddress!) }
        update(samples: input, sampleRate: sampleRate)
    }

    public func update(samples: [Float], sampleRate: Double) {
        let count = min(samples.count, size)
        var block = [Float](repeating: 0, count: size)
        block.replaceSubrange((size - count)..<size, with: samples.suffix(count))
        vDSP_vmul(block, 1, window, 1, &input, 1, vDSP_Length(size))

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                            imagp: imaginaryBuffer.baseAddress!)
                input.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              &split, 1, vDSP_Length(size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
            }
        }

        let scale = amplitudeScale
        let binWidth = sampleRate / Double(size)
        let lastBin = size / 2 - 1
        let low = log10(SpectrumAnalyzer.lowestFrequency)
        let high = log10(SpectrumAnalyzer.highestFrequency)

        for band in 0..<bandCount {
            let lowerEdge = pow(10, low + (high - low) * Double(band) / Double(bandCount))
            let upperEdge = pow(10, low + (high - low) * Double(band + 1) / Double(bandCount))
            var first = Int((lowerEdge / binWidth).rounded(.up))
            var last = Int((upperEdge / binWidth).rounded(.down))
            if first > last {
                // En los graves una banda es más angosta que un bin: se usa el
                // bin más cercano al centro.
                let nearest = Int((sqrt(lowerEdge * upperEdge) / binWidth).rounded())
                first = nearest
                last = nearest
            }
            first = min(max(first, 1), lastBin)
            last = min(max(last, first), lastBin)

            var peak: Float = 0
            for bin in first...last { peak = max(peak, magnitudes[bin]) }
            let decibels = max(linearToDecibels(peak * scale), SpectrumAnalyzer.floorDecibels)

            levels[band] = decibels >= levels[band]
                ? decibels
                : max(decibels, levels[band] - releaseDecibelsPerFrame)
        }
    }
}
