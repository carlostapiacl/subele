import CoreAudio
import Foundation

/// Lo que corre en cada vuelta del IOProc: elegir los buffers del tap, pasarlos
/// por el procesador y repartir el resultado en la salida.
///
/// Es una clase propia, separada del motor, por dos razones:
///
/// - **Vida atada al callback.** El bloque del IOProc la retiene fuerte, y ella es
///   dueña de su buffer de trabajo. Si CoreAudio todavía llama al bloque cuando el
///   motor ya se fue —porque detener el IOProc falló, por ejemplo— el buffer sigue
///   ahí. Liberar memoria que un callback vivo usa deja de ser posible por
///   construcción, no por haber detenido todo en el orden justo.
/// - **Testeable sin CoreAudio.** Recibe `AudioBufferList` comunes, así que los
///   tests arman la entrada a mano: un dúplex con micrófono, un buffer nulo,
///   dieciséis canales.
///
/// Sin asignar memoria, sin locks y sin tocar ARC dentro de `render`.
public final class IORenderer: @unchecked Sendable {

    /// Frames por pasada del caso general. Un callback más largo se procesa en
    /// varias pasadas en vez de truncarse.
    public static let chunkFrames = 4096

    /// Qué buffers de la entrada del agregado son del tap.
    ///
    /// La entrada del agregado no es solo el tap: si el dispositivo de salida
    /// también tiene entradas —una interfaz USB con micrófono, unos audífonos con
    /// micrófono— esos streams físicos vienen **antes** que el del tap. Tomar
    /// desde el primer buffer reproducía el micrófono por los parlantes.
    public let tapBuffers: Range<Int>

    private let processor: BoostProcessor
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCount: Int

    /// Vueltas del callback, para que un watchdog note si el audio se detuvo.
    public let callbacks = AtomicUInt32(0)
    /// Latencia de E/S medida, en segundos.
    public let latency = AtomicFloat(0)

    public init(processor: BoostProcessor, tapBuffers: Range<Int>) {
        self.processor = processor
        self.tapBuffers = tapBuffers
        scratchCount = IORenderer.chunkFrames * StreamFormat.maximumChannels
        scratch = .allocate(capacity: scratchCount)
        scratch.initialize(repeating: 0, count: scratchCount)
    }

    deinit {
        scratch.deinitialize(count: scratchCount)
        scratch.deallocate()
    }

    public func render(input inputData: UnsafePointer<AudioBufferList>,
                       output outputData: UnsafeMutablePointer<AudioBufferList>) {
        callbacks.increment()
        let output = UnsafeMutableAudioBufferListPointer(outputData)

        // Los buffers de salida se llenan siempre. CoreAudio no garantiza que
        // lleguen en cero, así que volver sin escribir reproduce lo que haya
        // dejado el ciclo anterior — que es ruido.
        for buffer in output {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        // Los canales se suman sobre los buffers: un dispositivo no intercalado
        // presenta un buffer por canal. Un buffer sin datos (un stream apagado)
        // cuenta sus canales igual, para no correr el resto de lugar, y después
        // simplemente no se escribe.
        var outputChannels = 0
        var frames = Int.max
        for buffer in output {
            let channels = Int(buffer.mNumberChannels)
            outputChannels += channels
            if buffer.mData != nil, channels > 0 {
                frames = min(frames, Int(buffer.mDataByteSize) / (4 * channels))
            }
        }
        guard outputChannels > 0, outputChannels <= StreamFormat.maximumChannels else { return }

        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let lower = min(tapBuffers.lowerBound, input.count)
        let upper = min(tapBuffers.upperBound, input.count)
        var inputChannels = 0
        var anyInput = false
        for index in lower..<upper {
            let buffer = input[index]
            let channels = Int(buffer.mNumberChannels)
            inputChannels += channels
            if buffer.mData != nil, channels > 0 {
                anyInput = true
                frames = min(frames, Int(buffer.mDataByteSize) / (4 * channels))
            }
        }
        // Sin datos del tap no hay nada que procesar: el silencio ya está escrito.
        guard anyInput, frames > 0, frames != .max else { return }

        // El caso común: un buffer intercalado del tap y uno de salida, iguales.
        // Se procesa en sitio sobre la salida, del largo que venga.
        if upper - lower == 1, output.count == 1, inputChannels == outputChannels,
           let source = input[lower].mData, let destination = output[0].mData {
            let target = destination.assumingMemoryBound(to: Float.self)
            target.update(from: source.assumingMemoryBound(to: Float.self),
                          count: frames * outputChannels)
            processor.process(target, frames: frames, channels: outputChannels)
            return
        }

        // Caso general: reunir en un buffer intercalado, procesar, repartir. Por
        // pasadas, para que un callback largo no se corte en el tamaño del buffer.
        var start = 0
        while start < frames {
            let count = min(IORenderer.chunkFrames, frames - start)
            gather(input, lower..<upper, from: start, frames: count, channels: outputChannels)
            processor.process(scratch, frames: count, channels: outputChannels)
            scatter(output, from: start, frames: count, channels: outputChannels)
            start += count
        }
    }

    private func gather(_ input: UnsafeMutableAudioBufferListPointer, _ range: Range<Int>,
                        from start: Int, frames: Int, channels outputChannels: Int) {
        scratch.update(repeating: 0, count: frames * outputChannels)
        var channel = 0
        for index in range {
            let buffer = input[index]
            let channels = Int(buffer.mNumberChannels)
            defer { channel += channels }
            guard let data = buffer.mData else { continue }
            let source = data.assumingMemoryBound(to: Float.self)
            for offset in 0..<channels where channel + offset < outputChannels {
                let target = channel + offset
                for frame in 0..<frames {
                    scratch[frame * outputChannels + target] =
                        source[(start + frame) * channels + offset]
                }
            }
        }
    }

    private func scatter(_ output: UnsafeMutableAudioBufferListPointer,
                         from start: Int, frames: Int, channels outputChannels: Int) {
        var channel = 0
        for buffer in output {
            let channels = Int(buffer.mNumberChannels)
            defer { channel += channels }
            guard let data = buffer.mData else { continue }
            let destination = data.assumingMemoryBound(to: Float.self)
            for offset in 0..<channels {
                let source = channel + offset
                for frame in 0..<frames {
                    destination[(start + frame) * channels + offset] =
                        scratch[frame * outputChannels + source]
                }
            }
        }
    }

    /// La distancia entre "este audio se capturó" y "este audio se va a escuchar",
    /// directo de los timestamps que CoreAudio le pasa al callback.
    public func recordLatency(input: UnsafePointer<AudioTimeStamp>,
                              output: UnsafePointer<AudioTimeStamp>) {
        let inputStamp = input.pointee
        let outputStamp = output.pointee
        guard inputStamp.mFlags.contains(.hostTimeValid),
              outputStamp.mFlags.contains(.hostTimeValid) else { return }
        let inputNanos = AudioConvertHostTimeToNanos(inputStamp.mHostTime)
        let outputNanos = AudioConvertHostTimeToNanos(outputStamp.mHostTime)
        guard outputNanos > inputNanos else { return }
        latency.value = Float(Double(outputNanos - inputNanos) / 1_000_000_000)
    }

    /// Qué buffers de la entrada del agregado son del tap, dado cuántos canales
    /// trae cada buffer, cuántos buffers de entrada tiene el dispositivo físico y
    /// cuántos canales entrega el tap.
    ///
    /// Primero se confía en el orden documentado (físicos primero, tap después);
    /// si los canales no cierran, se toman los últimos buffers que sumen lo del
    /// tap. Si tampoco cierran, no se adivina: nil, y el motor no arranca.
    public static func tapBufferRange(aggregateInput layout: [Int], physicalInputBuffers: Int,
                                      tapChannels: Int) -> Range<Int>? {
        guard tapChannels > 0 else { return nil }
        if physicalInputBuffers < layout.count,
           layout[physicalInputBuffers...].reduce(0, +) == tapChannels {
            return physicalInputBuffers..<layout.count
        }
        var sum = 0
        var lower = layout.count
        while lower > 0, sum < tapChannels {
            lower -= 1
            sum += layout[lower]
        }
        return sum == tapChannels && lower < layout.count ? lower..<layout.count : nil
    }
}
