import AppKit
import BoosterKit
import Foundation

/// El frente de barra de menú. Arma el menú, le pasa al controlador lo que pide
/// la gente y muestra el estado que el controlador publica.
///
/// Nunca llama a CoreAudio para arrancar o detener: eso lo hace `EngineController`
/// en su propia cola. Si CoreAudio se cuelga, el menú sigue respondiendo y lo
/// dice, en vez de congelarse con el botón de salir adentro.
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private static var retained: MenuBarApp?

    static func run() -> Never {
        let application = NSApplication.shared
        let delegate = MenuBarApp()
        retained = delegate                       // NSApplication lo guarda débil
        application.delegate = delegate
        application.setActivationPolicy(.accessory)   // barra de menú, sin Dock
        application.run()
        exit(0)
    }

    private static let supportURL = URL(string: "https://paypal.me/carlostapiacl")!

    /// Un arranque o una parada que tarda más que esto es CoreAudio colgado, no
    /// lento: se avisa en el panel.
    private static let stuckAfter: TimeInterval = 5

    private let controller = EngineController()
    private var processor: BoostProcessor { controller.processor }
    private var statusItem: NSStatusItem!
    private var meterTimer: Timer?
    private var isEnabled = true

    private var panel: StatusPanel!
    private let equalizerView = EqualizerView(frame: NSRect(x: 0, y: 0, width: 380, height: 210))
    private let analyzer = SpectrumAnalyzer()
    private var equalizerItem: NSMenuItem!
    private var equalizerMenu: NSMenu!
    private var presetItems: [NSMenuItem] = []
    private var sampleRateMenu: NSMenu!
    private var sampleRateError: String?
    private var enabledItem: NSMenuItem!
    private var retryItem: NSMenuItem!
    private var bufferItems: [NSMenuItem] = []
    private var languageItems: [NSMenuItem] = []

    /// Cacheado, no calculado. `Strings.current` devuelve un struct con más de
    /// cincuenta campos String: leerlo en cada tick del medidor eran otros tantos
    /// retains, veinte veces por segundo, para un valor que solo cambia cuando
    /// cambia el idioma.
    private var strings = Strings.current

    private var state: EngineController.State { controller.state }
    private var failure: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    // MARK: Ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.restore(into: processor)
        controller.setPreferredBufferFrames(AppSettings.preferredBufferFrames)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        rebuildMenu()

        controller.onStateChange = { [weak self] state in
            if state.info != nil { self?.sampleRateError = nil }
            self?.refreshChrome()
        }
        controller.start()
        controller.startWatchdog()

        // .common para que el medidor siga vivo con el menú abierto: un menú
        // abierto corre su propio modo de run loop y si no congelaría el timer.
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.refreshMeter()
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        meterTimer?.invalidate()
        controller.stopAndWait()
    }

    // MARK: Construcción del menú

    /// Se vuelve a llamar entero al cambiar de idioma: los títulos de NSMenuItem no
    /// se recalculan solos y rearmar es más simple que reescribir cada uno.
    private func rebuildMenu() {
        bufferItems.removeAll()
        languageItems.removeAll()
        presetItems.removeAll()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        panel = StatusPanel(strings: strings)
        panel.onGainChange = { [weak self] gain in self?.gainChanged(gain) }
        panel.onModeChange = { [weak self] mode in self?.modeChanged(mode) }
        let panelItem = NSMenuItem()
        panelItem.view = panel.view
        menu.addItem(panelItem)
        menu.addItem(.separator())

        enabledItem = item(strings.enabled, #selector(toggleEnabled))
        menu.addItem(enabledItem)
        menu.addItem(item(strings.resetGain, #selector(resetGain), key: "0"))

        let latencyItem = NSMenuItem(title: strings.latencyMenu, action: nil, keyEquivalent: "")
        let latencyMenu = NSMenu()
        for (index, frames) in AppSettings.bufferChoices.enumerated() {
            let entry = item(bufferTitle(frames), #selector(bufferChosen(_:)))
            entry.tag = index
            latencyMenu.addItem(entry)
            bufferItems.append(entry)
        }
        latencyItem.submenu = latencyMenu
        menu.addItem(latencyItem)

        // Se rearma cada vez que se abre: las frecuencias dependen del dispositivo
        // de salida, que puede haber cambiado desde la última vez.
        let sampleRateItem = NSMenuItem(title: strings.sampleRateMenu, action: nil, keyEquivalent: "")
        sampleRateMenu = NSMenu()
        sampleRateMenu.delegate = self
        sampleRateMenu.autoenablesItems = false
        sampleRateItem.submenu = sampleRateMenu
        menu.addItem(sampleRateItem)

        menu.addItem(buildEqualizerItem())

        let languageItem = NSMenuItem(title: strings.languageMenu, action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for (index, language) in AppLanguage.allCases.enumerated() {
            let entry = item(language.label, #selector(languageChosen(_:)))
            entry.tag = index
            languageMenu.addItem(entry)
            languageItems.append(entry)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        retryItem = item(strings.retry, #selector(retry), key: "r")
        menu.addItem(retryItem)

        menu.addItem(.separator())
        menu.addItem(item(strings.support, #selector(openSupport)))
        menu.addItem(item(strings.quit, #selector(quit), key: "q"))

        statusItem.menu = menu
        refreshChrome()
    }

    private func buildEqualizerItem() -> NSMenuItem {
        equalizerItem = NSMenuItem(title: strings.equalizerMenu, action: nil, keyEquivalent: "")
        equalizerMenu = NSMenu()
        equalizerMenu.delegate = self
        equalizerMenu.autoenablesItems = false

        let equalizerPanel = NSMenuItem()
        equalizerView.title = strings.equalizerHint
        equalizerView.onChange = { [weak self] band, decibels in
            guard let self else { return }
            processor.equalizer.setGain(decibels, ofBand: band)
            AppSettings.saveEqualizer(from: processor.equalizer)
            refreshChrome()
        }
        equalizerPanel.view = equalizerView
        equalizerMenu.addItem(equalizerPanel)
        equalizerMenu.addItem(.separator())

        // Filas con vista en vez de ítems comunes: un ítem común cierra el menú
        // al elegirlo y se llevaba el gráfico que uno quería seguir ajustando.
        for (index, preset) in EqualizerPreset.all.enumerated() {
            let entry = NSMenuItem()
            entry.view = StayOpenMenuRow(title: strings[keyPath: preset.name]) { [weak self] in
                self?.applyPreset(index)
            }
            equalizerMenu.addItem(entry)
            presetItems.append(entry)
        }
        equalizerItem.submenu = equalizerMenu
        return equalizerItem
    }

    private func bufferTitle(_ frames: UInt32) -> String {
        switch frames {
        case 128: return strings.bufferLowest
        case 256: return strings.bufferLow
        case 512: return strings.bufferRelaxed
        default: return strings.bufferAutomatic
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// "44,1 kHz" en español, "44.1 kHz" en inglés. Antes decía "44 kHz", que es
    /// justo el número que confunde a quien quiere saber si está en 44,1 o en 48.
    private func sampleRateTitle(_ rate: Double) -> String {
        let kilohertz = String(format: "%g", rate / 1000)
        let localized = AppLanguage.stored.resolved == .spanish
            ? kilohertz.replacingOccurrences(of: ".", with: ",") : kilohertz
        return "\(localized) kHz"
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func rebuildSampleRateMenu() {
        sampleRateMenu.removeAllItems()
        let (available, current) = BoostEngine.outputSampleRates()
        guard !available.isEmpty else {
            sampleRateMenu.addItem(disabledItem(strings.sampleRateUnavailable))
            return
        }
        for rate in available {
            let entry = item(sampleRateTitle(rate), #selector(sampleRateChosen(_:)))
            entry.representedObject = rate
            entry.state = rate == current ? .on : .off
            sampleRateMenu.addItem(entry)
        }
        sampleRateMenu.addItem(.separator())
        // Cambiarla cambia el dispositivo, y con él a todas las apps que lo usan.
        sampleRateMenu.addItem(disabledItem(strings.sampleRateSystemWide))
        if let sampleRateError {
            sampleRateMenu.addItem(disabledItem(sampleRateError))
        }
    }

    // MARK: Refresco

    /// Todo lo que no cambia veinte veces por segundo.
    private func refreshChrome() {
        let gain = processor.gain
        let percent = Int((gain * 100).rounded())
        panel.show(gain: gain, mode: processor.mode,
                   hint: processor.mode == .loudness ? strings.loudnessHint : strings.transparentHint)

        let equalizer = processor.equalizer
        let gains = (0..<Equalizer.bandCount).map { equalizer.gain(ofBand: $0) }
        equalizerView.gains = gains
        equalizerView.sampleRate = state.info?.sampleRate ?? 48_000
        equalizerItem?.state = equalizer.isFlat ? .off : .on
        for (index, entry) in presetItems.enumerated() {
            entry.state = EqualizerPreset.all[index].gains == gains ? .on : .off
            entry.view?.needsDisplay = true      // la fila dibuja su propio check
        }
        enabledItem?.state = isEnabled ? .on : .off
        retryItem?.isHidden = (failure == nil)

        let chosen = AppSettings.bufferFrames
        for (index, item) in bufferItems.enumerated() {
            item.state = AppSettings.bufferChoices[index] == chosen ? .on : .off
        }
        let language = AppLanguage.stored
        for (index, item) in languageItems.enumerated() {
            item.state = AppLanguage.allCases[index] == language ? .on : .off
        }

        refreshStatusText()

        let running = isEnabled && state.info != nil
        // Los estados excepcionales usan símbolos del sistema, que la gente ya
        // sabe leer. El estado normal usa el ícono propio: un parlante genérico
        // se confunde con el control de volumen de macOS y con cualquier otra app
        // de audio de la barra.
        if let symbol = failure != nil ? "exclamationmark.triangle.fill"
                      : !isEnabled ? "speaker.slash.fill" : nil {
            statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                               accessibilityDescription: "Subele")
        } else {
            statusItem.button?.image = MenuBarIcon.image(boosted: gain > 1.01)
        }
        statusItem.button?.title = (running && percent != 100) ? " \(percent)%" : ""
    }

    private func refreshStatusText() {
        let stuck = Date().timeIntervalSince(controller.stateSince) > Self.stuckAfter
        switch state {
        case .failed(let message):
            panel.show(title: strings.notRunning, subtitle: message, warning: true)
        case _ where !isEnabled:
            panel.show(title: strings.disabled, subtitle: strings.passthrough)
        case .starting, .stopped:
            // Ventana corta mientras se rehace la cadena tras un cambio de
            // dispositivo. Sin esto quedaba en pantalla el dispositivo anterior.
            panel.show(title: strings.starting,
                       subtitle: stuck && state == .starting ? strings.coreAudioStuck : "",
                       warning: stuck)
        case .stopping:
            panel.show(title: strings.stopping, subtitle: stuck ? strings.coreAudioStuck : "",
                       warning: stuck)
        case .running(let info):
            let channels = info.outputChannels == 2
                ? strings.stereo
                : String(format: strings.channelsFormat, info.outputChannels)
            panel.show(title: info.deviceName, subtitle: String(
                format: "%@ · %@ · +%.0f ms",
                sampleRateTitle(info.sampleRate), channels, controller.addedLatencySeconds * 1000))
        }
    }

    private func refreshMeter() {
        if processor.spectrum.isEnabled {
            analyzer.update(from: processor.spectrum, sampleRate: state.info?.sampleRate ?? 48_000)
            equalizerView.spectrum = analyzer.levels
        }
        // Mientras arranca o se detiene, el texto puede pasar a "CoreAudio no
        // responde" sin que llegue ningún estado nuevo: se revisa acá.
        if state == .starting || state == .stopping { refreshStatusText() }
        guard isEnabled, state.info != nil else {
            panel.showMeter(level: 0, limiting: false, label: "")
            return
        }
        let peak = linearToDecibels(processor.outputPeak)
        let reduction = processor.limiterReductionDecibels
        panel.showMeter(
            level: max(0, (peak + 60) / 60),          // −60…0 dBFS sobre la barra
            limiting: reduction < -0.1,
            label: peak <= -59
                ? strings.silent
                : String(format: "%.1f dBFS%@", peak,
                         reduction < -0.1 ? String(format: strings.limitingFormat, reduction) : ""))
    }

    // MARK: Acciones

    func menuWillOpen(_ menu: NSMenu) {
        if menu === equalizerMenu { processor.spectrum.isEnabled = true }
        refreshChrome()
        refreshMeter()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === sampleRateMenu { rebuildSampleRateMenu() }
    }

    func menuDidClose(_ menu: NSMenu) {
        // El espectro solo se calcula con el ecualizador a la vista.
        if menu === equalizerMenu {
            processor.spectrum.isEnabled = false
            analyzer.reset()
            equalizerView.spectrum = []
        }
    }

    private func gainChanged(_ gain: Float) {
        processor.gain = gain
        AppSettings.gain = gain
        refreshChrome()
    }

    private func modeChanged(_ mode: BoostMode) {
        processor.mode = mode
        AppSettings.mode = mode
        refreshChrome()
    }

    private func applyPreset(_ index: Int) {
        processor.equalizer.setGains(EqualizerPreset.all[index].gains)
        AppSettings.saveEqualizer(from: processor.equalizer)
        refreshChrome()
    }

    @objc private func sampleRateChosen(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? Double else { return }
        do {
            // La cadena se rehace sola: el motor observa la frecuencia del
            // dispositivo y el controlador la rearma cuando el cambio se aplicó.
            try BoostEngine.setOutputSampleRate(rate)
            sampleRateError = nil
        } catch {
            sampleRateError = strings.sampleRateFailed
            NSSound.beep()
        }
    }

    @objc private func openSupport() {
        NSWorkspace.shared.open(Self.supportURL)
    }

    @objc private func resetGain() {
        gainChanged(1)
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        isEnabled ? controller.start() : controller.stop()
        refreshChrome()
    }

    @objc private func bufferChosen(_ sender: NSMenuItem) {
        let frames = AppSettings.bufferChoices[sender.tag]
        AppSettings.bufferFrames = frames
        controller.setPreferredBufferFrames(AppSettings.preferredBufferFrames)
        controller.restart()
        refreshChrome()
    }

    @objc private func languageChosen(_ sender: NSMenuItem) {
        AppLanguage.stored = AppLanguage.allCases[sender.tag]
        strings = Strings.current
        rebuildMenu()
    }

    @objc private func retry() {
        isEnabled = true
        controller.start()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
