import BoosterKit
import Foundation

/// El motor manejado por stdin. El mismo núcleo que la app, sin necesitar servidor
/// de ventanas. Sigue el mismo idioma que el menú.
enum ConsoleMode {

    private static var strings: Strings { Strings.current }

    static func run(bufferFrames: UInt32? = nil) -> Never {
        let controller = EngineController(engine: BoostEngine(preferredBufferFrames: bufferFrames))

        // Un tap vivo con `.mutedWhenTapped` deja el sistema mudo, así que salir
        // tiene que pasar sí o sí por stop(). Las fuentes de señal se atienden en
        // la cola principal, y por eso el bucle de comandos va en su propio hilo.
        var signalSources: [DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { print("\n\(strings.consoleStopping)"); quit(controller) }
            source.resume()
            signalSources.append(source)
        }

        let first = controller.startAndWait()
        guard let info = first.info else {
            let reason: String
            if case .failed(let message) = first { reason = message } else { reason = strings.coreAudioStuck }
            FileHandle.standardError.write(
                "\(strings.couldNotStart): \(reason)\n\(strings.startupHint)".data(using: .utf8)!)
            controller.stopAndWait()
            exit(1)
        }

        printBanner(controller, info)

        // Los cambios de dispositivo los rehace el controlador solo; acá se cuentan.
        // Se instala por la cola principal a propósito: los estados del primer
        // arranque ya están encolados ahí y pasan antes, sin anunciarse como un
        // cambio de dispositivo.
        var announced = true
        DispatchQueue.main.async { controller.onStateChange = { state in
            switch state {
            case .starting where announced:
                announced = false
                print("  \(strings.deviceChanged)")
            case .running(let info):
                announced = true
                print("  \(strings.outputLabel): \(info.deviceName)")
            case .failed(let message):
                announced = true
                print("  \(strings.couldNotRebuild): \(message)")
            default:
                break
            }
        } }
        controller.startWatchdog()

        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine(strippingNewline: true) {
                handle(line, controller: controller)
            }
            DispatchQueue.main.async { quit(controller) }
        }

        dispatchMain()
    }

    private static func quit(_ controller: EngineController) -> Never {
        controller.stopAndWait()
        exit(0)
    }

    private static func handle(_ line: String, controller: EngineController) {
        let processor = controller.processor
        switch line.trimmingCharacters(in: .whitespaces).lowercased() {
        case "q", "quit", "exit", "salir":
            DispatchQueue.main.async { quit(controller) }

        case "m", "t":   // t y l, de cuando los modos se llamaban transparente y loudness
            processor.mode = .transparent
            print("  \(strings.modeSetTransparent)")

        case "v", "l":
            processor.mode = .loudness
            print("  \(strings.modeSetLoudness)")

        case "d":
            print("  " + String(format: strings.addedLatencyFormat,
                                controller.addedLatencySeconds * 1000,
                                controller.measuredIOLatencySeconds * 1000,
                                Double(processor.limiter.lookaheadSeconds) * 1000))

        case "s", "":
            print(status(processor))

        case let command:
            guard let value = Float(command), value >= 50, value <= 400 else {
                print("  \(strings.notUnderstood)")
                return
            }
            processor.gain = value / 100
            print("  \(strings.gainLabel): \(percent(processor.gain))%")
        }
    }

    private static func printBanner(_ controller: EngineController, _ info: BoostEngine.Info) {
        let processor = controller.processor
        print("""

          Subele \(Booster.version) — \(strings.consoleHeader)
          ─────────────────────────────────────────────
          \(strings.outputLabel):   \(info.deviceName)
          \(strings.formatLabel):   \(Int(info.sampleRate)) Hz · \
        \(info.inputChannels) → \(info.outputChannels) · \
        \(info.bufferFrames) \(strings.framesPerCallback)
          \(strings.gainLabel):     \(percent(processor.gain))%   \
        \(strings.modeLabel): \(modeName(processor.mode))

        \(strings.commandsHelp)
        """)
    }

    private static func modeName(_ mode: BoostMode) -> String {
        (mode == .loudness ? strings.loudness : strings.transparent).lowercased()
    }

    private static func percent(_ gain: Float) -> Int { Int((gain * 100).rounded()) }

    private static func status(_ processor: BoostProcessor) -> String {
        String(format: "  %d%% · %@ · comp %.1f dB · lim %.1f dB · peak %.1f dBFS",
               percent(processor.gain),
               modeName(processor.mode),
               processor.compressorReductionDecibels,
               processor.limiterReductionDecibels,
               linearToDecibels(processor.outputPeak))
    }
}
