import CoreAudio
import Foundation

/// Captura el audio del sistema con un process tap, lo procesa y lo devuelve al
/// mismo dispositivo de salida.
///
/// No instala ningún driver y **no** cambia la salida por defecto del sistema. El
/// tap silencia el camino original de los procesos que captura, y nosotros
/// escribimos el audio procesado al mismo hardware. Nuestro propio proceso queda
/// excluido del tap; si no, lo que escribimos se capturaría y volvería a entrar.
///
/// ```
/// system processes ──┐
///                    ├─→ [tap, mutedWhenTapped] ──→ IOProc ──→ DSP ──┐
/// this process ──────┴──── (excluded) ───────────────────────────────┴─→ output device
/// ```
public final class BoostEngine {

    public struct Info: Sendable {
        public let deviceName: String
        public let sampleRate: Double
        public let inputChannels: Int
        public let outputChannels: Int
        public let bufferFrames: Int
    }

    public let processor = BoostProcessor()

    /// Se llama en la cola principal cuando macOS cambia el dispositivo de salida
    /// por defecto. Un tap está atado a un dispositivo, así que sin rehacer la
    /// cadena seguiríamos procesando para hardware que ya nadie escucha.
    public var onDefaultOutputChanged: (() -> Void)?

    /// Frames por callback que se le piden al dispositivo agregado. Más bajo es
    /// menos latencia y más despertadas; el dispositivo ajusta a lo que soporte.
    /// `nil` deja lo que haya elegido CoreAudio.
    public var preferredBufferFrames: UInt32?

    public private(set) var isRunning = false
    public private(set) var info: Info?

    /// Medida, no estimada: la distancia entre el timestamp del audio que entra y
    /// el timestamp en que se va a reproducir, tomada del IOProc.
    public var measuredIOLatencySeconds: Double { latencyBox.pointee }

    /// Todo lo que esta cadena agrega por sobre reproducir derecho al dispositivo.
    public var addedLatencySeconds: Double {
        measuredIOLatencySeconds + Double(processor.limiter.lookaheadSeconds)
    }

    private var tap: ProcessTap?
    private var aggregate: AggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var defaultOutputObserver: Any?

    /// Buffer intercalado de trabajo, para reunir la entrada y repartir la salida.
    /// Se asigna una vez y vive tanto como el motor: liberarlo mientras un IOProc
    /// todavía puede correr sería un use-after-free.
    private let maximumFrames = 8192
    private let scratch: UnsafeMutablePointer<Float>

    /// La latencia medida vive en un puntero crudo, no en una propiedad del motor.
    /// El callback necesita escribirla, y llegar hasta `self` desde ahí obligaría a
    /// capturarlo débil: una carga de referencia débil **toma un lock** en el
    /// runtime de Swift, y un lock en el hilo de audio es justo lo que no se puede
    /// hacer — puede invertir prioridades y cortar el audio. Un puntero capturado
    /// por valor no toca ARC ni bloquea nada.
    private let latencyBox: UnsafeMutablePointer<Double>

    public init(preferredBufferFrames: UInt32? = nil) {
        self.preferredBufferFrames = preferredBufferFrames
        scratch = .allocate(capacity: maximumFrames * Limiter.maximumChannels)
        scratch.initialize(repeating: 0, count: maximumFrames * Limiter.maximumChannels)
        latencyBox = .allocate(capacity: 1)
        latencyBox.initialize(to: 0)
    }

    deinit {
        stop()
        scratch.deinitialize(count: maximumFrames * Limiter.maximumChannels)
        scratch.deallocate()
        latencyBox.deinitialize(count: 1)
        latencyBox.deallocate()
    }

    public func start() throws {
        guard !isRunning else { return }
        do { try begin() } catch { stop(); throw error }
    }

    private func begin() throws {
        trace("pidiendo el dispositivo de salida por defecto")
        let outputDevice = try AudioDevices.defaultOutput()
        let outputUID = try AudioDevices.uid(of: outputDevice)
        let deviceName = (try? AudioDevices.name(of: outputDevice)) ?? outputUID
        trace("dispositivo: \(deviceName) uid=\(outputUID)")

        let ownProcess = try AudioDevices.processObject(for: getpid())
        trace("proceso propio=\(ownProcess); creando el tap")
        let tap = try ProcessTap(excluding: [ownProcess], deviceUID: outputUID)
        self.tap = tap

        trace("tap creado id=\(tap.objectID); creando el dispositivo agregado")
        let aggregate = try AggregateDevice(tapUUID: tap.uuid, outputDeviceUID: outputUID)
        self.aggregate = aggregate

        if let preferredBufferFrames {
            aggregate.bufferFrameSize = preferredBufferFrames
        }

        let inputFormat = try AudioDevices.streamFormat(
            of: aggregate.objectID, scope: kAudioObjectPropertyScopeInput)
        let outputFormat = try AudioDevices.streamFormat(
            of: aggregate.objectID, scope: kAudioObjectPropertyScopeOutput)

        guard inputFormat.mFormatID == kAudioFormatLinearPCM,
              inputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw AudioError("el tap no entregó audio float32 lineal")
        }

        let info = Info(deviceName: deviceName,
                        sampleRate: inputFormat.mSampleRate,
                        inputChannels: Int(inputFormat.mChannelsPerFrame),
                        outputChannels: Int(outputFormat.mChannelsPerFrame),
                        bufferFrames: Int(aggregate.bufferFrameSize))
        self.info = info
        trace("formato \(info.sampleRate) Hz \(info.inputChannels)->\(info.outputChannels), "
              + "\(info.bufferFrames) frames por callback; instalando el IOProc")

        processor.prepare(sampleRate: info.sampleRate, channels: info.outputChannels)

        try installIOProc(on: aggregate)

        try check(AudioDeviceStart(aggregate.objectID, ioProcID),
                  "arrancar el dispositivo agregado")

        defaultOutputObserver = AudioDevices.observeDefaultOutput { [weak self] in
            self?.onDefaultOutputChanged?()
        }
        isRunning = true
        trace("corriendo")
    }

    private func installIOProc(on aggregate: AggregateDevice) throws {
        // Todo lo que el callback usa se captura por valor acá: referencias fuertes
        // que el bloque retiene una sola vez, y punteros crudos. Nada que obligue a
        // tocar ARC o a tomar un lock por cada vuelta.
        let processor = self.processor
        let scratch = self.scratch
        let latencyBox = self.latencyBox
        let maximumFrames = self.maximumFrames
        let maximumChannels = Limiter.maximumChannels

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregate.objectID, nil) {
            _, inputData, inputTime, outputData, outputTime in

            let output = UnsafeMutableAudioBufferListPointer(outputData)

            // Los buffers de salida se llenan siempre. CoreAudio no garantiza que
            // lleguen en cero, así que volver sin escribir reproduce lo que haya
            // dejado el ciclo anterior — que es ruido.
            for buffer in output {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }

            let input = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            guard input.count > 0, output.count > 0 else { return }

            // Los canales se suman sobre los buffers: un dispositivo NO
            // intercalado presenta un buffer por canal, no un buffer con N
            // canales. Mirar solo buffer[0] dejaría los demás en silencio.
            var inputChannels = 0
            var outputChannels = 0
            var frames = Int.max
            for buffer in input {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, buffer.mData != nil else { return }
                inputChannels += channels
                frames = min(frames, Int(buffer.mDataByteSize) / (4 * channels))
            }
            for buffer in output {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, buffer.mData != nil else { return }
                outputChannels += channels
                frames = min(frames, Int(buffer.mDataByteSize) / (4 * channels))
            }
            guard frames > 0, outputChannels > 0, outputChannels <= maximumChannels
            else { return }
            frames = min(frames, maximumFrames)

            BoostEngine.recordLatency(input: inputTime, output: outputTime, into: latencyBox)

            if input.count == 1, output.count == 1, inputChannels == outputChannels {
                // El caso común: un solo buffer intercalado en cada punta.
                let source = input[0].mData!.assumingMemoryBound(to: Float.self)
                let destination = output[0].mData!.assumingMemoryBound(to: Float.self)
                destination.update(from: source, count: frames * outputChannels)
                processor.process(destination, frames: frames, channels: outputChannels)
                return
            }

            // Caso general: reunir todo en un solo buffer intercalado…
            var channel = 0
            for buffer in input {
                let channels = Int(buffer.mNumberChannels)
                let source = buffer.mData!.assumingMemoryBound(to: Float.self)
                for offset in 0..<channels where channel + offset < outputChannels {
                    let target = channel + offset
                    for frame in 0..<frames {
                        scratch[frame * outputChannels + target] =
                            source[frame * channels + offset]
                    }
                }
                channel += channels
            }
            if inputChannels < outputChannels {
                for frame in 0..<frames {
                    for channel in inputChannels..<outputChannels {
                        scratch[frame * outputChannels + channel] = 0
                    }
                }
            }

            processor.process(scratch, frames: frames, channels: outputChannels)

            // …y repartirlo de vuelta.
            channel = 0
            for buffer in output {
                let channels = Int(buffer.mNumberChannels)
                let destination = buffer.mData!.assumingMemoryBound(to: Float.self)
                for offset in 0..<channels {
                    let source = channel + offset
                    for frame in 0..<frames {
                        destination[frame * channels + offset] =
                            scratch[frame * outputChannels + source]
                    }
                }
                channel += channels
            }
        }, "instalar el IOProc")
    }

    /// La distancia entre "este audio se capturó" y "este audio se va a escuchar",
    /// directo de los timestamps que CoreAudio le pasa al callback.
    ///
    /// Estática y sin tocar `self` a propósito: se llama desde el hilo de audio.
    private static func recordLatency(input: UnsafePointer<AudioTimeStamp>,
                                      output: UnsafePointer<AudioTimeStamp>,
                                      into box: UnsafeMutablePointer<Double>) {
        let inputStamp = input.pointee
        let outputStamp = output.pointee
        guard inputStamp.mFlags.contains(.hostTimeValid),
              outputStamp.mFlags.contains(.hostTimeValid) else { return }
        let inputNanos = AudioConvertHostTimeToNanos(inputStamp.mHostTime)
        let outputNanos = AudioConvertHostTimeToNanos(outputStamp.mHostTime)
        guard outputNanos > inputNanos else { return }
        box.pointee = Double(outputNanos - inputNanos) / 1_000_000_000
    }

    public func stop() {
        defaultOutputObserver = nil
        if let ioProcID, let aggregate {
            AudioDeviceStop(aggregate.objectID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregate.objectID, ioProcID)
        }
        ioProcID = nil
        // El orden importa: el agregado referencia al tap, así que va primero.
        // Los dos se destruyen solos en deinit.
        aggregate = nil
        tap = nil
        info = nil
        isRunning = false
    }
}
