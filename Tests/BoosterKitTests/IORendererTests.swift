import CoreAudio
import Foundation
import Testing
@testable import BoosterKit

/// Un procesador que deja pasar todo: ganancia 1, ecualizador plano, señales bajo
/// el techo. Así lo que sale es lo que el renderer eligió como entrada.
private func passthrough(channels: Int) -> BoostProcessor {
    makeProcessor(gain: 1, mode: .transparent, channels: channels)
}

private func render(_ renderer: IORenderer, _ input: TestBufferList, _ output: TestBufferList) {
    renderer.render(input: UnsafePointer(input.list.unsafeMutablePointer),
                    output: output.list.unsafeMutablePointer)
}

@Suite("Renderer del IOProc")
struct IORendererTests {

    @Test("con una interfaz dúplex suena el tap, nunca el micrófono")
    func duplexPlaysTheTap() {
        // El micrófono de la interfaz llega primero en la entrada del agregado.
        let input = TestBufferList([(2, 0.5), (2, 0.1)], frames: 1024)
        let output = TestBufferList([(2, 0)], frames: 1024)
        let renderer = IORenderer(processor: passthrough(channels: 2), tapBuffers: 1..<2)
        render(renderer, input, output)
        for sample in output.lastFrame(ofBuffer: 0) { #expect(abs(sample - 0.1) < 1e-4) }
    }

    @Test("un buffer sin datos no silencia a los demás")
    func nullBufferDoesNotSilenceTheRest() {
        // Tap no intercalado de dos canales, con el segundo stream apagado.
        let input = TestBufferList([(1, 0.2), (1, nil)], frames: 1024)
        let output = TestBufferList([(2, 0)], frames: 1024)
        let renderer = IORenderer(processor: passthrough(channels: 2), tapBuffers: 0..<2)
        render(renderer, input, output)
        let last = output.lastFrame(ofBuffer: 0)
        #expect(abs(last[0] - 0.2) < 1e-4)
        #expect(last[1] == 0)
    }

    @Test("una salida sin datos se salta sin correr los canales de las otras")
    func nullOutputBufferKeepsChannelOrder() {
        let input = TestBufferList([(2, 0.3)], frames: 1024)
        let output = TestBufferList([(1, nil), (1, 0)], frames: 1024)
        let renderer = IORenderer(processor: passthrough(channels: 2), tapBuffers: 0..<1)
        render(renderer, input, output)
        #expect(abs(output.lastFrame(ofBuffer: 1)[0] - 0.3) < 1e-4)
    }

    @Test("un callback más largo que el buffer de trabajo se procesa entero")
    func longCallbacksAreNotTruncated() {
        let frames = IORenderer.chunkFrames * 2 + 500
        let input = TestBufferList([(2, 0.25)], frames: frames)
        // Salida no intercalada: obliga al caso general, el que va por pasadas.
        let output = TestBufferList([(1, 0), (1, 0)], frames: frames)
        let renderer = IORenderer(processor: passthrough(channels: 2), tapBuffers: 0..<1)
        render(renderer, input, output)
        for buffer in 0..<2 {
            #expect(abs(output.lastFrame(ofBuffer: buffer)[0] - 0.25) < 1e-4)
        }
    }

    @Test("más de ocho canales se procesan", arguments: [9, 16, 32])
    func manyChannels(channels: Int) {
        let input = TestBufferList([(channels, 0.1)], frames: 1024)
        let output = TestBufferList([(channels, 0)], frames: 1024)
        let renderer = IORenderer(processor: passthrough(channels: channels), tapBuffers: 0..<1)
        render(renderer, input, output)
        let last = output.lastFrame(ofBuffer: 0)
        #expect(last.count == channels)
        for sample in last { #expect(abs(sample - 0.1) < 1e-4) }
    }

    @Test("sin entrada del tap la salida queda en silencio, no con basura")
    func noTapInputMeansSilence() {
        let input = TestBufferList([(2, 0.5)], frames: 512)          // solo el micrófono
        let output = TestBufferList([(2, 0.9)], frames: 512)         // basura previa
        let renderer = IORenderer(processor: passthrough(channels: 2), tapBuffers: 1..<2)
        render(renderer, input, output)
        #expect(output.samples(ofBuffer: 0).allSatisfy { $0 == 0 })
    }

    @Test("cuenta las vueltas, para el watchdog")
    func countsCallbacks() {
        let input = TestBufferList([(2, 0)], frames: 64)
        let output = TestBufferList([(2, 0)], frames: 64)
        let renderer = IORenderer(processor: passthrough(channels: 2), tapBuffers: 0..<1)
        for _ in 0..<5 { render(renderer, input, output) }
        #expect(renderer.callbacks.value == 5)
    }
}

@Suite("Ubicar el tap en la entrada del agregado")
struct TapBufferRangeTests {

    @Test("sin entradas físicas, el tap es todo")
    func onlyTheTap() {
        #expect(IORenderer.tapBufferRange(aggregateInput: [2], physicalInputBuffers: 0,
                                          tapChannels: 2) == 0..<1)
    }

    @Test("las entradas físicas vienen primero")
    func physicalInputsFirst() {
        #expect(IORenderer.tapBufferRange(aggregateInput: [1, 1, 2], physicalInputBuffers: 2,
                                          tapChannels: 2) == 2..<3)
    }

    @Test("si el conteo físico no cierra, se toman los últimos buffers que sumen el tap")
    func fallsBackToTrailingBuffers() {
        #expect(IORenderer.tapBufferRange(aggregateInput: [4, 2], physicalInputBuffers: 0,
                                          tapChannels: 2) == 1..<2)
    }

    @Test("si nada cierra no se adivina")
    func refusesToGuess() {
        #expect(IORenderer.tapBufferRange(aggregateInput: [], physicalInputBuffers: 0,
                                          tapChannels: 2) == nil)
        #expect(IORenderer.tapBufferRange(aggregateInput: [3], physicalInputBuffers: 0,
                                          tapChannels: 2) == nil)
    }
}

@Suite("Formatos de stream")
struct StreamFormatTests {

    @Test("float32 nativo sirve, intercalado o no")
    func acceptsFloat32() {
        #expect(StreamFormat.problem(with: float32Format(channels: 2)) == nil)
        #expect(StreamFormat.problem(with: float32Format(channels: 2, interleaved: false)) == nil)
        #expect(StreamFormat.problem(with: float32Format(channels: 32)) == nil)
    }

    @Test("todo lo demás se rechaza")
    func rejectsTheRest() {
        var int16 = float32Format(channels: 2)
        int16.mFormatFlags = kAudioFormatFlagIsSignedInteger
        int16.mBitsPerChannel = 16
        int16.mBytesPerFrame = 4
        #expect(StreamFormat.problem(with: int16) != nil)

        var float64 = float32Format(channels: 2)
        float64.mBitsPerChannel = 64
        float64.mBytesPerFrame = 16
        #expect(StreamFormat.problem(with: float64) != nil)

        var bigEndian = float32Format(channels: 2)
        bigEndian.mFormatFlags |= kAudioFormatFlagIsBigEndian
        #expect(StreamFormat.problem(with: bigEndian) != nil)

        var compressed = float32Format(channels: 2)
        compressed.mFormatID = kAudioFormatMPEG4AAC
        #expect(StreamFormat.problem(with: compressed) != nil)

        #expect(StreamFormat.problem(with: float32Format(channels: 33)) != nil)
        #expect(StreamFormat.problem(with: float32Format(channels: 0)) != nil)
    }
}
