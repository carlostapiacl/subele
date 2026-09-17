import BoosterKit
import Foundation

/// El motor manejado por stdin. El mismo núcleo que la app, sin necesitar servidor
/// de ventanas. Sigue el mismo idioma que el menú.
enum ConsoleMode {

    private static var strings: Strings { Strings.current }

    static func run(bufferFrames: UInt32? = nil) -> Never {
        let engine = BoostEngine(preferredBufferFrames: bufferFrames)

        // Un tap vivo con `.mutedWhenTapped` deja el sistema mudo, así que salir
        // tiene que pasar sí o sí por stop(). Las fuentes de señal se atienden en
        // la cola principal, y por eso el bucle de comandos va en su propio hilo.
        var signalSources: [DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { print("\n\(strings.stopping)"); engine.stop(); exit(0) }
            source.resume()
            signalSources.append(source)
        }

        do {
            try engine.start()
        } catch {
            FileHandle.standardError.write(
                "\(strings.couldNotStart): \(error.localizedDescription)\n\(strings.startupHint)"
                    .data(using: .utf8)!)
            engine.stop()
            exit(1)
        }

        engine.onDefaultOutputChanged = {
            print("  \(strings.deviceChanged)")
            engine.stop()
            do {
                try engine.start()
                print("  \(strings.outputLabel): \(engine.info?.deviceName ?? "?")")
            } catch {
                print("  \(strings.couldNotRebuild): \(error.localizedDescription)")
            }
        }

        printBanner(engine)

        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine(strippingNewline: true) {
                handle(line, engine: engine)
            }
            DispatchQueue.main.async { engine.stop(); exit(0) }
        }

        dispatchMain()
    }

    private static func handle(_ line: String, engine: BoostEngine) {
        switch line.trimmingCharacters(in: .whitespaces).lowercased() {
        case "q", "quit", "exit", "salir":
            DispatchQueue.main.async { engine.stop(); exit(0) }

        case "t":
            engine.processor.mode = .transparent
            print("  \(strings.modeSetTransparent)")

        case "l":
            engine.processor.mode = .loudness
            print("  \(strings.modeSetLoudness)")

        case "d":
            print("  " + String(format: strings.addedLatencyFormat,
                                engine.addedLatencySeconds * 1000,
                                engine.measuredIOLatencySeconds * 1000,
                                Double(engine.processor.limiter.lookaheadSeconds) * 1000))

        case "s", "":
            print(status(engine))

        case let command:
            guard let value = Float(command), value >= 50, value <= 400 else {
                print("  \(strings.notUnderstood)")
                return
            }
            engine.processor.gain = value / 100
            print("  \(strings.gainLabel): \(percent(engine.processor.gain))%")
        }
    }

    private static func printBanner(_ engine: BoostEngine) {
        let info = engine.info
        print("""

          Audio Booster \(Booster.version) — \(strings.consoleHeader)
          ─────────────────────────────────────────────
          \(strings.outputLabel):   \(info?.deviceName ?? "?")
          \(strings.formatLabel):   \(Int(info?.sampleRate ?? 0)) Hz · \
        \(info?.inputChannels ?? 0) → \(info?.outputChannels ?? 0) · \
        \(info?.bufferFrames ?? 0) \(strings.framesPerCallback)
          \(strings.gainLabel):     \(percent(engine.processor.gain))%   \
        \(strings.modeLabel): \(engine.processor.mode.rawValue)

        \(strings.commandsHelp)
        """)
    }

    private static func percent(_ gain: Float) -> Int { Int((gain * 100).rounded()) }

    private static func status(_ engine: BoostEngine) -> String {
        String(format: "  %d%% · %@ · comp %.1f dB · lim %.1f dB · peak %.1f dBFS",
               percent(engine.processor.gain),
               engine.processor.mode.rawValue,
               engine.processor.compressorReductionDecibels,
               engine.processor.limiterReductionDecibels,
               linearToDecibels(engine.processor.outputPeak))
    }
}
