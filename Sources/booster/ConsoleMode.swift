import BoosterKit
import Foundation

/// The engine driven from stdin. Same core as the app, no window server needed.
enum ConsoleMode {

    static func run(bufferFrames: UInt32? = nil) -> Never {
        let engine = BoostEngine(preferredBufferFrames: bufferFrames)

        // A tap left alive with `.mutedWhenTapped` leaves the system silent, so
        // termination has to go through stop(). The signal sources are serviced
        // on the main queue, which is why the command loop runs on its own thread.
        var signalSources: [DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { print("\nStopping…"); engine.stop(); exit(0) }
            source.resume()
            signalSources.append(source)
        }

        do {
            try engine.start()
        } catch {
            FileHandle.standardError.write(
                "Could not start: \(error.localizedDescription)\n\(startupHint)"
                    .data(using: .utf8)!)
            engine.stop()
            exit(1)
        }

        engine.onDefaultOutputChanged = {
            print("  Output device changed. Rebuilding the chain…")
            engine.stop()
            do {
                try engine.start()
                print("  Output: \(engine.info?.deviceName ?? "?")")
            } catch {
                print("  Could not rebuild: \(error.localizedDescription)")
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
        case "q", "quit", "exit":
            DispatchQueue.main.async { engine.stop(); exit(0) }

        case "t":
            engine.processor.mode = .transparent
            print("  Mode: transparent (gain + limiter)")

        case "l":
            engine.processor.mode = .loudness
            print("  Mode: loudness (compressor + makeup + limiter)")

        case "d":
            print(String(format: "  Added latency: %.1f ms  (%.1f ms I/O + %.1f ms lookahead)",
                         engine.addedLatencySeconds * 1000,
                         engine.measuredIOLatencySeconds * 1000,
                         Double(engine.processor.limiter.lookaheadSeconds) * 1000))

        case "s", "":
            print(status(engine))

        case let command:
            guard let value = Float(command), value >= 50, value <= 400 else {
                print("  Not understood. A number between 50 and 400, or t / l / d / s / q.")
                return
            }
            engine.processor.gain = value / 100
            print("  Gain: \(percent(engine.processor.gain))%")
        }
    }

    private static func printBanner(_ engine: BoostEngine) {
        let info = engine.info
        print("""

          Audio Booster \(Booster.version) — console
          ─────────────────────────────────────────────
          Output:   \(info?.deviceName ?? "?")
          Format:   \(Int(info?.sampleRate ?? 0)) Hz · \
        \(info?.inputChannels ?? 0) in → \(info?.outputChannels ?? 0) out · \
        \(info?.bufferFrames ?? 0) frames/callback
          Gain:     \(percent(engine.processor.gain))%   Mode: \(engine.processor.mode.rawValue)

          Commands:  50-400 = gain %  ·  t = transparent  ·  l = loudness
                     d = latency  ·  s = status  ·  q = quit

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

    static let startupHint = """

        Most likely causes, in order:
          · eqMac, Boom 3D or another driver-based booster is running and owns the
            default output device. Ours then taps their virtual device, which is
            itself passing audio through, and the two deadlock. Quit it:
                pkill -f eqMac.app
          · Audio capture permission is missing: System Settings → Privacy &
            Security → Audio Recording.

        """
}
