import CoreAudio
import Foundation
import Testing
@testable import BoosterKit

private func makeEngine(_ hal: FakeAudioHAL) -> BoostEngine {
    let engine = BoostEngine(hal: hal)
    engine.readinessTimeout = 0.1
    return engine
}

@Suite("Motor sobre una HAL simulada")
struct BoostEngineTests {

    @Test("arranca, procesa el tap y al detenerse no deja nada vivo")
    func startsAndCleansUp() throws {
        let hal = FakeAudioHAL()
        let engine = makeEngine(hal)
        try engine.start()
        #expect(engine.isRunning)
        #expect(engine.info?.outputChannels == 2)
        #expect(hal.runningIO)
        #expect(hal.liveObservers == 4)

        let input = TestBufferList([(2, 0.1)], frames: 1024)
        let output = TestBufferList([(2, 0)], frames: 1024)
        hal.drive(input: input, output: output)
        #expect(abs(output.lastFrame(ofBuffer: 0)[0] - 0.1) < 1e-4)

        engine.stop()
        #expect(!engine.isRunning)
        #expect(hal.everythingReleased)
        #expect(engine.teardownProblems.isEmpty)
    }

    @Test("con una interfaz dúplex, el motor ubica el tap después del micrófono")
    func duplexInterface() throws {
        let hal = FakeAudioHAL()
        hal.physicalInputLayout = [2]
        let engine = makeEngine(hal)
        try engine.start()

        let input = TestBufferList([(2, 0.6), (2, 0.1)], frames: 1024)
        let output = TestBufferList([(2, 0)], frames: 1024)
        hal.drive(input: input, output: output)
        #expect(abs(output.lastFrame(ofBuffer: 0)[0] - 0.1) < 1e-4)
        engine.stop()
    }

    @Test("una salida con formato incompatible se rechaza antes de crear el tap")
    func rejectsOutputFormatBeforeTapping() {
        let hal = FakeAudioHAL()
        hal.outputFormat.mBitsPerChannel = 16
        let engine = makeEngine(hal)
        #expect(throws: AudioError.self) { try engine.start() }
        #expect(hal.tapsCreated == 0)
    }

    @Test("demasiados canales se rechazan antes de crear el tap")
    func rejectsTooManyChannelsBeforeTapping() {
        let hal = FakeAudioHAL()
        hal.outputLayout = [24, 24]
        let engine = makeEngine(hal)
        #expect(throws: AudioError.self) { try engine.start() }
        #expect(hal.tapsCreated == 0)
    }

    @Test("un tap con formato incompatible se destruye: el audio vuelve a los demás")
    func badTapFormatReleasesTheTap() {
        let hal = FakeAudioHAL()
        hal.tapFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger
        let engine = makeEngine(hal)
        #expect(throws: AudioError.self) { try engine.start() }
        #expect(hal.tapsCreated == 1)
        #expect(hal.everythingReleased)
    }

    @Test("si falla un paso intermedio no queda nada a medio armar")
    func midwayFailuresCleanUp() {
        for configure in [{ (hal: FakeAudioHAL) in hal.failCreateAggregate = true },
                          { (hal: FakeAudioHAL) in hal.failStartIO = true }] {
            let hal = FakeAudioHAL()
            configure(hal)
            let engine = makeEngine(hal)
            #expect(throws: AudioError.self) { try engine.start() }
            #expect(!engine.isRunning)
            #expect(hal.everythingReleased)
        }
    }

    @Test("espera a que el agregado exponga el tap antes de arrancar")
    func waitsForTheAggregate() throws {
        let hal = FakeAudioHAL()
        hal.pollsUntilReady = 3
        let engine = makeEngine(hal)
        // Tres sondeos de 20 ms no caben en 0,1 s en un runner de CI cargado:
        // acá se prueba que espere, no cuánto tarda en rendirse.
        engine.readinessTimeout = 5
        try engine.start()
        #expect(engine.isRunning)
        engine.stop()
    }

    @Test("si el agregado nunca expone el tap, no arranca y suelta todo")
    func givesUpOnAnAggregateThatNeverGetsReady() {
        let hal = FakeAudioHAL()
        hal.pollsUntilReady = .max
        let engine = makeEngine(hal)
        #expect(throws: AudioError.self) { try engine.start() }
        #expect(hal.startCount == 0)
        #expect(hal.everythingReleased)
    }

    @Test("si detener el IOProc falla, el teardown sigue y un callback tardío es seguro")
    func failedStopIsSafe() throws {
        let hal = FakeAudioHAL()
        let engine = makeEngine(hal)
        try engine.start()
        hal.stopIOStatus = OSStatus(kAudioHardwareUnspecifiedError)
        engine.stop()

        #expect(engine.teardownProblems.count == 1)
        #expect(hal.liveTaps.isEmpty)
        #expect(hal.liveAggregates.isEmpty)
        // CoreAudio todavía podría llamar al bloque. Lo que usa es del renderer,
        // que el bloque retiene: esto no puede tocar memoria liberada.
        let input = TestBufferList([(2, 0.1)], frames: 256)
        let output = TestBufferList([(2, 0)], frames: 256)
        hal.drive(input: input, output: output)
    }

    @Test("cien arranques y paradas seguidos no pierden recursos")
    func manyCycles() throws {
        let hal = FakeAudioHAL()
        let engine = makeEngine(hal)
        for _ in 0..<100 {
            try engine.start()
            engine.stop()
        }
        #expect(hal.startCount == 100)
        #expect(hal.everythingReleased)
    }

    @Test("pide el tamaño de buffer elegido")
    func appliesBufferSize() throws {
        let hal = FakeAudioHAL()
        let engine = makeEngine(hal)
        engine.preferredBufferFrames = 128
        try engine.start()
        #expect(hal.requestedBufferFrames == 128)
        #expect(engine.info?.bufferFrames == 128)
        engine.stop()
    }
}

@Suite("Controlador del motor")
struct EngineControllerTests {

    private func makeController(_ hal: FakeAudioHAL) -> (EngineController, DispatchQueue) {
        let callbacks = DispatchQueue(label: "test.callbacks")
        let controller = EngineController(engine: makeEngine(hal), callbackQueue: callbacks)
        return (controller, callbacks)
    }

    private func state(_ controller: EngineController, _ callbacks: DispatchQueue)
        -> EngineController.State {
        controller.drain()
        return callbacks.sync { controller.state }
    }

    @Test("arranca y se detiene fuera del hilo que llama")
    func startAndStop() {
        let hal = FakeAudioHAL()
        let (controller, callbacks) = makeController(hal)
        controller.start()
        #expect(state(controller, callbacks).info != nil)
        controller.stop()
        #expect(state(controller, callbacks) == .stopped)
        #expect(hal.everythingReleased)
    }

    @Test("un arranque fallido queda como falla, con el audio devuelto")
    func failedStart() {
        let hal = FakeAudioHAL()
        hal.failStartIO = true
        let (controller, callbacks) = makeController(hal)
        controller.start()
        guard case .failed(let message) = state(controller, callbacks) else {
            Issue.record("se esperaba .failed")
            return
        }
        #expect(message.contains("arranque de prueba"))
        #expect(hal.everythingReleased)
    }

    @Test("varios avisos de cambio seguidos rehacen la cadena una sola vez")
    func coalescesRestarts() throws {
        let hal = FakeAudioHAL()
        let (controller, callbacks) = makeController(hal)
        controller.start()
        controller.drain()
        for _ in 0..<5 { controller.scheduleRestart(after: 0.05) }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(state(controller, callbacks).info != nil)
        #expect(hal.startCount == 2)
    }

    @Test("el watchdog rehace la cadena si el IOProc deja de girar")
    func watchdogRestartsAStalledEngine() {
        let hal = FakeAudioHAL()
        let (controller, callbacks) = makeController(hal)
        controller.start()
        controller.drain()
        // Nadie hace girar el IOProc de la HAL falsa: está detenido.
        for _ in 0..<3 { controller.checkWatchdog() }
        #expect(hal.startCount == 2)
        #expect(state(controller, callbacks).info != nil)
    }

    @Test("el watchdog no toca un motor que gira")
    func watchdogLeavesAHealthyEngineAlone() {
        let hal = FakeAudioHAL()
        let (controller, _) = makeController(hal)
        controller.start()
        controller.drain()
        let input = TestBufferList([(2, 0)], frames: 64)
        let output = TestBufferList([(2, 0)], frames: 64)
        for _ in 0..<6 {
            hal.drive(input: input, output: output)
            controller.checkWatchdog()
        }
        #expect(hal.startCount == 1)
    }

    @Test("si reiniciar no sirve, el watchdog se rinde y lo dice")
    func watchdogGivesUp() {
        let hal = FakeAudioHAL()
        let (controller, callbacks) = makeController(hal)
        controller.maximumWatchdogRestarts = 2
        controller.start()
        controller.drain()
        for _ in 0..<9 { controller.checkWatchdog() }
        guard case .failed = state(controller, callbacks) else {
            Issue.record("se esperaba .failed")
            return
        }
        #expect(hal.everythingReleased)
    }

    @Test("salir detiene y espera")
    func stopAndWait() {
        let hal = FakeAudioHAL()
        let (controller, _) = makeController(hal)
        controller.start()
        #expect(controller.stopAndWait(timeout: 1))
        #expect(hal.everythingReleased)
    }
}
