import BoosterKit
import Foundation

/// Un binario, dos caras. Sin argumentos es la app de barra de menú, que es lo que
/// lanza el bundle .app; `--cli` es el mismo motor manejado desde stdin, útil para
/// probar sin empaquetar nada.

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("-h") || arguments.contains("--help") {
    print(Strings.current.helpText
        .replacingOccurrences(of: "{version}", with: Booster.version))
    exit(0)
}

if arguments.contains("--version") {
    print("audio-booster \(Booster.version)")
    exit(0)
}

/// Frames por callback, para medir cuánta latencia cuesta el tamaño de buffer.
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
