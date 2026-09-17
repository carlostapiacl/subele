import BoosterKit
import Foundation

/// One binary, two faces. Without arguments it is the menu bar app, which is
/// what the .app bundle launches; `--cli` is the same engine driven from stdin,
/// which is useful for testing without packaging anything.

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("-h") || arguments.contains("--help") {
    print("""

      Audio Booster \(Booster.version)
      Raise macOS volume past 100% without installing a driver.

        (no arguments)   menu bar app
        --cli            interactive console
        --buffer <n>     frames per callback (lower = less latency)
        --version
        --help

      BOOSTER_TRACE=1 traces every startup step to stderr.

    """)
    exit(0)
}

if arguments.contains("--version") {
    print("audio-booster \(Booster.version)")
    exit(0)
}

/// Frames per callback, for measuring what the buffer size costs in latency.
let bufferFrames: UInt32? = {
    guard let index = arguments.firstIndex(of: "--buffer"),
          index + 1 < arguments.count,
          let frames = UInt32(arguments[index + 1]), frames > 0
    else { return nil }
    return frames
}()

if arguments.contains("--cli") {
    ConsoleMode.run(bufferFrames: bufferFrames)
}

MenuBarApp.run()
