import Foundation

/// Idioma de la interfaz. `system` sigue al del sistema.
enum AppLanguage: String, CaseIterable {
    case system
    case english
    case spanish

    /// Los nombres de idioma se muestran en su propio idioma, como es costumbre.
    /// El único que se traduce es "sistema", porque no nombra un idioma.
    var label: String {
        switch self {
        case .system: return Strings.current.systemLanguage
        case .english: return "English"
        case .spanish: return "Español"
        }
    }

    static var stored: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "language"),
                  let language = AppLanguage(rawValue: raw)
            else { return .system }
            return language
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "language") }
    }

    /// El idioma que efectivamente se usa, resuelto contra las preferencias del
    /// sistema cuando la opción elegida es `system`.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("es") ? .spanish : .english
    }
}

/// Todo el texto visible, en un solo lugar y tipado.
///
/// Sin diccionarios con claves de texto: un campo que falte no compila, en vez de
/// aparecer como una clave cruda en pantalla. Tampoco hay `.lproj` porque el
/// bundle se arma a mano y agregar recursos localizados complicaría el build sin
/// dar nada a cambio para dos idiomas.
struct Strings {

    // Menú
    let enabled: String
    let resetGain: String
    let latencyMenu: String
    let languageMenu: String
    let retry: String
    let quit: String
    let systemLanguage: String

    // Opciones de buffer
    let bufferLowest: String
    let bufferLow: String
    let bufferRelaxed: String
    let bufferAutomatic: String

    // Panel
    let transparent: String
    let loudness: String
    let notRunning: String
    let disabled: String
    let passthrough: String
    let silent: String
    let limitingFormat: String
    let stereo: String
    let channelsFormat: String

    // Consola
    let consoleHeader: String
    let outputLabel: String
    let formatLabel: String
    let gainLabel: String
    let modeLabel: String
    let framesPerCallback: String
    let commandsHelp: String
    let stopping: String
    let couldNotStart: String
    let startupHint: String
    let deviceChanged: String
    let couldNotRebuild: String
    let notUnderstood: String
    let modeSetTransparent: String
    let modeSetLoudness: String
    let addedLatencyFormat: String
    /// Ojo: este texto NO pasa por String(format:) a propósito. Contiene un `%`
    /// literal ("100%") y un formateador se lo comía. La versión se sustituye por
    /// reemplazo de texto, que no interpreta nada.
    let helpText: String

    static var current: Strings {
        AppLanguage.stored.resolved == .spanish ? .spanish : .english
    }

    static let english = Strings(
        enabled: "Enabled",
        resetGain: "Reset to 100%",
        latencyMenu: "Latency",
        languageMenu: "Language",
        retry: "Retry",
        quit: "Quit Audio Booster",
        systemLanguage: "System",

        bufferLowest: "Lowest — 128 frames",
        bufferLow: "Low — 256 frames",
        bufferRelaxed: "Relaxed — 512 frames",
        bufferAutomatic: "Automatic",

        transparent: "Transparent",
        loudness: "Loudness",
        notRunning: "Not running",
        disabled: "Disabled",
        passthrough: "Audio passes through untouched",
        silent: "silent",
        limitingFormat: "   ·   limiting %.1f dB",
        stereo: "stereo",
        channelsFormat: "%d ch",

        consoleHeader: "console",
        outputLabel: "Output",
        formatLabel: "Format",
        gainLabel: "Gain",
        modeLabel: "Mode",
        framesPerCallback: "frames/callback",
        commandsHelp: """
          Commands:  50-400 = gain %  ·  t = transparent  ·  l = loudness
                     d = latency  ·  s = status  ·  q = quit
        """,
        stopping: "Stopping…",
        couldNotStart: "Could not start",
        startupHint: """

            Most likely causes, in order:
              · eqMac, Boom 3D or another driver-based booster is running and owns
                the default output device. Ours then taps their virtual device,
                which is itself passing audio through, and the two deadlock.
                Quit it:  pkill -f eqMac.app
              · Audio capture permission is missing: System Settings → Privacy &
                Security → Audio Recording.

            """,
        deviceChanged: "Output device changed. Rebuilding the chain…",
        couldNotRebuild: "Could not rebuild",
        notUnderstood: "Not understood. A number between 50 and 400, or t / l / d / s / q.",
        modeSetTransparent: "Mode: transparent (gain + limiter)",
        modeSetLoudness: "Mode: loudness (compressor + makeup + limiter)",
        addedLatencyFormat: "Added latency: %.1f ms  (%.1f ms I/O + %.1f ms lookahead)",
        helpText: """

              Audio Booster {version}
              Raise macOS volume past 100% without installing a driver.

                (no arguments)   menu bar app
                --cli            interactive console
                --buffer <n>     frames per callback (lower = less latency)
                --version
                --help

              BOOSTER_TRACE=1 traces every startup step to stderr.

            """
    )

    static let spanish = Strings(
        enabled: "Activado",
        resetGain: "Restablecer a 100%",
        latencyMenu: "Latencia",
        languageMenu: "Idioma",
        retry: "Reintentar",
        quit: "Salir de Audio Booster",
        systemLanguage: "Sistema",

        bufferLowest: "Mínima — 128 frames",
        bufferLow: "Baja — 256 frames",
        bufferRelaxed: "Holgada — 512 frames",
        bufferAutomatic: "Automática",

        transparent: "Transparente",
        loudness: "Loudness",
        notRunning: "No está corriendo",
        disabled: "Desactivado",
        passthrough: "El audio pasa sin tocar",
        silent: "silencio",
        limitingFormat: "   ·   limitando %.1f dB",
        stereo: "estéreo",
        channelsFormat: "%d canales",

        consoleHeader: "consola",
        outputLabel: "Salida",
        formatLabel: "Formato",
        gainLabel: "Ganancia",
        modeLabel: "Modo",
        framesPerCallback: "frames/callback",
        commandsHelp: """
          Comandos:  50-400 = ganancia %  ·  t = transparente  ·  l = loudness
                     d = latencia  ·  s = estado  ·  q = salir
        """,
        stopping: "Cerrando…",
        couldNotStart: "No se pudo arrancar",
        startupHint: """

            Lo que lo rompe, en orden de probabilidad:
              · eqMac, Boom 3D u otro booster con driver está corriendo y es dueño
                de la salida por defecto. Entonces tapeamos su dispositivo virtual,
                que a su vez está pasando audio, y los dos se traban.
                Cerralo:  pkill -f eqMac.app
              · Falta permiso de captura de audio: Ajustes del Sistema → Privacidad
                y seguridad → Grabación de audio.

            """,
        deviceChanged: "Cambió el dispositivo de salida. Rehaciendo la cadena…",
        couldNotRebuild: "No se pudo rehacer",
        notUnderstood: "No entendí. Un número entre 50 y 400, o t / l / d / s / q.",
        modeSetTransparent: "Modo: transparente (ganancia + limitador)",
        modeSetLoudness: "Modo: loudness (compresor + makeup + limitador)",
        addedLatencyFormat: "Latencia agregada: %.1f ms  (%.1f ms E/S + %.1f ms lookahead)",
        helpText: """

              Audio Booster {version}
              Sube el volumen de macOS más allá del 100% sin instalar drivers.

                (sin argumentos)  app de barra de menú
                --cli             consola interactiva
                --buffer <n>      frames por callback (menos = menos latencia)
                --version
                --help

              BOOSTER_TRACE=1 traza cada paso del arranque a stderr.

            """
    )
}
