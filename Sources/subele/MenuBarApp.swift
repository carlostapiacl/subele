import AppKit
import BoosterKit
import Foundation

/// El frente de barra de menú. Es dueño de un motor, de un ítem de estado y de un
/// timer a 20 Hz para el medidor; todo lo demás es asunto del motor.
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

    private enum Defaults {
        static let gain = "gain"
        static let mode = "mode"
        static let bufferFrames = "bufferFrames"
        static let equalizer = "equalizerGains"
    }

    private static let supportURL = URL(string: "https://paypal.me/carlostapiacl")!

    /// Tamaños de buffer que ofrece el menú.
    ///
    /// La cadena cuesta unos dos períodos de buffer más los 3 ms de lookahead del
    /// limitador, y esa proporción se mantuvo en todos los tamaños medidos, así
    /// que esta es la única palanca que mueve la latencia de verdad. 256 es el
    /// default: parte al medio la latencia que CoreAudio elegiría solo y todavía
    /// deja margen de sobra. 0 significa "dejar lo que eligió CoreAudio".
    private static let bufferChoices: [UInt32] = [128, 256, 512, 0]
    private static let defaultBufferFrames: UInt32 = 256

    private let engine = BoostEngine()
    private var statusItem: NSStatusItem!
    private var meterTimer: Timer?
    private var restartWork: DispatchWorkItem?
    private var lastError: String?
    private var isEnabled = true

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let gainSlider = NSSlider()
    private let gainLabel = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl()
    private let meter = LevelMeterView()
    private let meterLabel = NSTextField(labelWithString: "")
    private let modeHintLabel = NSTextField(labelWithString: "")
    private var equalizerSliders: [NSSlider] = []
    private var equalizerValueLabels: [NSTextField] = []
    private var equalizerItem: NSMenuItem!
    private var sampleRateMenu: NSMenu!
    private var sampleRateError: String?
    private var enabledItem: NSMenuItem!
    private var retryItem: NSMenuItem!
    private var bufferItems: [NSMenuItem] = []
    private var languageItems: [NSMenuItem] = []

    /// Cacheado, no calculado. `Strings.current` devuelve un struct con treinta
    /// campos String: leerlo en cada tick del medidor eran treinta retains, veinte
    /// veces por segundo, para un valor que solo cambia cuando cambia el idioma.
    private var strings = Strings.current

    // MARK: Ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        restoreSettings()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        rebuildMenu()

        engine.onOutputChanged = { [weak self] in
            self?.sampleRateError = nil
            self?.scheduleRestart()
        }
        startEngine()

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
        engine.stop()
    }

    // MARK: Motor

    private func startEngine() {
        do {
            try engine.start()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshChrome()
    }

    private func restartEngine() {
        engine.stop()
        guard isEnabled else { refreshChrome(); return }
        startEngine()
    }

    /// Un cambio de dispositivo dispara varias notificaciones seguidas; se espera a
    /// que se aquieten en vez de rehacer la cadena una vez por notificación.
    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartEngine() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Construcción del menú

    /// Se vuelve a llamar entero al cambiar de idioma: los títulos de NSMenuItem no
    /// se recalculan solos y rearmar es más simple que reescribir cada uno.
    private func rebuildMenu() {
        bufferItems.removeAll()
        languageItems.removeAll()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let panel = NSMenuItem()
        panel.view = buildPanel()
        menu.addItem(panel)
        menu.addItem(.separator())

        enabledItem = item(strings.enabled, #selector(toggleEnabled))
        menu.addItem(enabledItem)
        menu.addItem(item(strings.resetGain, #selector(resetGain), key: "0"))

        let latencyItem = NSMenuItem(title: strings.latencyMenu, action: nil, keyEquivalent: "")
        let latencyMenu = NSMenu()
        for (index, frames) in Self.bufferChoices.enumerated() {
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

        equalizerItem = NSMenuItem(title: strings.equalizerMenu, action: nil, keyEquivalent: "")
        let equalizerMenu = NSMenu()
        let equalizerPanel = NSMenuItem()
        equalizerPanel.view = buildEqualizerPanel()
        equalizerMenu.addItem(equalizerPanel)
        equalizerMenu.addItem(.separator())
        equalizerMenu.addItem(item(strings.equalizerFlat, #selector(flattenEqualizer)))
        equalizerItem.submenu = equalizerMenu
        menu.addItem(equalizerItem)

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

    private func buildPanel() -> NSView {
        let width: CGFloat = 300
        let margin: CGFloat = 16
        let inner = width - margin * 2
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 180))

        meterLabel.frame = NSRect(x: margin, y: 12, width: inner, height: 15)
        meterLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        meterLabel.textColor = .secondaryLabelColor
        view.addSubview(meterLabel)

        meter.frame = NSRect(x: margin, y: 30, width: inner, height: 6)
        view.addSubview(meter)

        titleLabel.frame = NSRect(x: margin, y: 50, width: inner, height: 18)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(titleLabel)

        subtitleLabel.frame = NSRect(x: margin, y: 69, width: inner, height: 15)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(subtitleLabel)

        gainSlider.frame = NSRect(x: margin, y: 94, width: inner - 56, height: 20)
        gainSlider.minValue = 50
        gainSlider.maxValue = 400
        gainSlider.isContinuous = true
        gainSlider.target = self
        gainSlider.action = #selector(gainChanged)
        view.addSubview(gainSlider)

        gainLabel.frame = NSRect(x: width - margin - 52, y: 95, width: 52, height: 18)
        gainLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        gainLabel.alignment = .right
        view.addSubview(gainLabel)

        modeControl.segmentCount = 2
        modeControl.setLabel(strings.transparent, forSegment: 0)
        modeControl.setLabel(strings.loudness, forSegment: 1)
        modeControl.segmentStyle = .rounded
        modeControl.frame = NSRect(x: margin, y: 126, width: inner, height: 24)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        for segment in 0..<2 { modeControl.setWidth(inner / 2, forSegment: segment) }
        view.addSubview(modeControl)

        // "¿El modo transparente no hace nada?" fue la primera pregunta de alguien
        // que la probó. Con 100% de ganancia, no: hace falta decirlo en la cara.
        modeHintLabel.frame = NSRect(x: margin, y: 155, width: inner, height: 15)
        modeHintLabel.font = .systemFont(ofSize: 10)
        modeHintLabel.textColor = .secondaryLabelColor
        modeHintLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(modeHintLabel)

        return view
    }

    private func buildEqualizerPanel() -> NSView {
        equalizerSliders.removeAll()
        equalizerValueLabels.removeAll()

        let columnWidth: CGFloat = 44
        let margin: CGFloat = 14
        let width = margin * 2 + columnWidth * CGFloat(Equalizer.bandCount)
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 170))
        let limit = Double(Equalizer.maximumGainDecibels)

        for band in 0..<Equalizer.bandCount {
            let x = margin + columnWidth * CGFloat(band)

            let value = NSTextField(labelWithString: "")
            value.frame = NSRect(x: x, y: 8, width: columnWidth, height: 14)
            value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.alignment = .center
            view.addSubview(value)
            equalizerValueLabels.append(value)

            let slider = NSSlider()
            slider.isVertical = true
            slider.frame = NSRect(x: x + (columnWidth - 22) / 2, y: 26, width: 22, height: 116)
            slider.minValue = -limit
            slider.maxValue = limit
            slider.numberOfTickMarks = 3          // −12, 0, +12
            slider.isContinuous = true
            slider.tag = band
            slider.target = self
            slider.action = #selector(equalizerChanged(_:))
            view.addSubview(slider)
            equalizerSliders.append(slider)

            let frequency = Equalizer.frequency(ofBand: band)
            let label = NSTextField(labelWithString: frequency >= 1000
                ? "\(Int(frequency / 1000))k" : "\(Int(frequency))")
            label.frame = NSRect(x: x, y: 146, width: columnWidth, height: 14)
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.alignment = .center
            view.addSubview(label)
        }
        return view
    }

    /// "44,1 kHz" en español, "44.1 kHz" en inglés. Antes decía "44 kHz", que es
    /// justo el número que confunde a quien quiere saber si está en 44,1 o en 48.
    private func sampleRateTitle(_ rate: Double) -> String {
        let kilohertz = String(format: "%g", rate / 1000)
        let localized = AppLanguage.stored.resolved == .spanish
            ? kilohertz.replacingOccurrences(of: ".", with: ",") : kilohertz
        return "\(localized) kHz"
    }

    private func rebuildSampleRateMenu() {
        sampleRateMenu.removeAllItems()
        let (available, current) = BoostEngine.outputSampleRates()
        guard !available.isEmpty else {
            let empty = NSMenuItem(title: strings.sampleRateUnavailable, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sampleRateMenu.addItem(empty)
            return
        }
        for rate in available {
            let entry = item(sampleRateTitle(rate), #selector(sampleRateChosen(_:)))
            entry.representedObject = rate
            entry.state = rate == current ? .on : .off
            sampleRateMenu.addItem(entry)
        }
        if let sampleRateError {
            sampleRateMenu.addItem(.separator())
            let failure = NSMenuItem(title: sampleRateError, action: nil, keyEquivalent: "")
            failure.isEnabled = false
            sampleRateMenu.addItem(failure)
        }
    }

    // MARK: Refresco

    /// Todo lo que no cambia veinte veces por segundo.
    private func refreshChrome() {
        let percent = Int((engine.processor.gain * 100).rounded())
        gainSlider.floatValue = engine.processor.gain * 100
        gainLabel.stringValue = "\(percent)%"
        modeControl.selectedSegment = engine.processor.mode == .loudness ? 1 : 0
        modeHintLabel.stringValue = engine.processor.mode == .loudness
            ? strings.loudnessHint : strings.transparentHint

        let equalizer = engine.processor.equalizer
        for band in 0..<min(Equalizer.bandCount, equalizerSliders.count) {
            let decibels = equalizer.gain(ofBand: band)
            equalizerSliders[band].floatValue = decibels
            equalizerValueLabels[band].stringValue = decibels == 0
                ? "0" : String(format: "%+.0f", decibels)
        }
        equalizerItem?.state = equalizer.isFlat ? .off : .on
        enabledItem?.state = isEnabled ? .on : .off
        retryItem?.isHidden = (lastError == nil)

        let chosen = storedBufferFrames()
        for (index, item) in bufferItems.enumerated() {
            item.state = Self.bufferChoices[index] == chosen ? .on : .off
        }
        let language = AppLanguage.stored
        for (index, item) in languageItems.enumerated() {
            item.state = AppLanguage.allCases[index] == language ? .on : .off
        }

        if let lastError {
            titleLabel.stringValue = strings.notRunning
            subtitleLabel.stringValue = lastError
            subtitleLabel.textColor = .systemOrange
        } else if !isEnabled {
            titleLabel.stringValue = strings.disabled
            subtitleLabel.stringValue = strings.passthrough
            subtitleLabel.textColor = .secondaryLabelColor
        } else if engine.info == nil {
            // Ventana corta mientras se rehace la cadena tras un cambio de
            // dispositivo. Sin esto quedaba en pantalla el dispositivo anterior.
            titleLabel.stringValue = strings.starting
            subtitleLabel.stringValue = ""
            subtitleLabel.textColor = .secondaryLabelColor
        } else if let info = engine.info {
            titleLabel.stringValue = info.deviceName
            let channels = info.outputChannels == 2
                ? strings.stereo
                : String(format: strings.channelsFormat, info.outputChannels)
            subtitleLabel.stringValue = String(
                format: "%@ · %@ · +%.0f ms",
                sampleRateTitle(info.sampleRate), channels, engine.addedLatencySeconds * 1000)
            subtitleLabel.textColor = .secondaryLabelColor
        }

        let running = isEnabled && lastError == nil
        // Los estados excepcionales usan símbolos del sistema, que la gente ya
        // sabe leer. El estado normal usa el ícono propio: un parlante genérico
        // se confunde con el control de volumen de macOS y con cualquier otra app
        // de audio de la barra.
        if let symbol = lastError != nil ? "exclamationmark.triangle.fill"
                      : !isEnabled ? "speaker.slash.fill" : nil {
            statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                               accessibilityDescription: "Subele")
        } else {
            statusItem.button?.image = MenuBarIcon.image(boosted: engine.processor.gain > 1.01)
        }
        statusItem.button?.title = (running && percent != 100) ? " \(percent)%" : ""
    }

    private func refreshMeter() {
        guard isEnabled, lastError == nil else {
            meter.level = 0
            meter.isLimiting = false
            meterLabel.stringValue = ""
            return
        }
        let peak = linearToDecibels(engine.processor.outputPeak)
        let reduction = engine.processor.limiterReductionDecibels
        meter.level = max(0, (peak + 60) / 60)          // −60…0 dBFS sobre la barra
        meter.isLimiting = reduction < -0.1
        meterLabel.stringValue = peak <= -59
            ? strings.silent
            : String(format: "%.1f dBFS%@", peak,
                     reduction < -0.1
                        ? String(format: strings.limitingFormat, reduction) : "")
    }

    // MARK: Acciones

    func menuWillOpen(_ menu: NSMenu) {
        refreshChrome()
        refreshMeter()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === sampleRateMenu { rebuildSampleRateMenu() }
    }

    @objc private func gainChanged() {
        engine.processor.gain = gainSlider.floatValue / 100
        UserDefaults.standard.set(engine.processor.gain, forKey: Defaults.gain)
        refreshChrome()
    }

    @objc private func modeChanged() {
        engine.processor.mode = modeControl.selectedSegment == 1 ? .loudness : .transparent
        UserDefaults.standard.set(engine.processor.mode.rawValue, forKey: Defaults.mode)
        refreshChrome()
    }

    @objc private func equalizerChanged(_ sender: NSSlider) {
        // De a 1 dB: medio dB no se oye en un parlante de laptop y hace que el
        // slider nunca vuelva exacto a cero.
        engine.processor.equalizer.setGain(sender.floatValue.rounded(), ofBand: sender.tag)
        saveEqualizer()
        refreshChrome()
    }

    @objc private func flattenEqualizer() {
        for band in 0..<Equalizer.bandCount {
            engine.processor.equalizer.setGain(0, ofBand: band)
        }
        saveEqualizer()
        refreshChrome()
    }

    private func saveEqualizer() {
        let equalizer = engine.processor.equalizer
        UserDefaults.standard.set((0..<Equalizer.bandCount).map { equalizer.gain(ofBand: $0) },
                                  forKey: Defaults.equalizer)
    }

    @objc private func sampleRateChosen(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? Double else { return }
        do {
            // La cadena se rehace sola: el motor observa la frecuencia del
            // dispositivo y avisa por onOutputChanged cuando el cambio se aplicó.
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
        engine.processor.gain = 1
        UserDefaults.standard.set(Float(1), forKey: Defaults.gain)
        refreshChrome()
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        if isEnabled {
            startEngine()
        } else {
            engine.stop()
            lastError = nil
            refreshChrome()
        }
    }

    @objc private func bufferChosen(_ sender: NSMenuItem) {
        let frames = Self.bufferChoices[sender.tag]
        UserDefaults.standard.set(Int(frames), forKey: Defaults.bufferFrames)
        engine.preferredBufferFrames = frames == 0 ? nil : frames
        restartEngine()
    }

    @objc private func languageChosen(_ sender: NSMenuItem) {
        AppLanguage.stored = AppLanguage.allCases[sender.tag]
        strings = Strings.current
        rebuildMenu()
    }

    @objc private func retry() {
        isEnabled = true
        restartEngine()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func restoreSettings() {
        let defaults = UserDefaults.standard
        if let gain = defaults.object(forKey: Defaults.gain) as? Float,
           gain >= 0.5, gain <= 4 {
            engine.processor.gain = gain
        }
        if let raw = defaults.string(forKey: Defaults.mode),
           let mode = BoostMode(rawValue: raw) {
            engine.processor.mode = mode
        }
        let frames = storedBufferFrames()
        engine.preferredBufferFrames = frames > 0 ? frames : nil
        if let gains = defaults.array(forKey: Defaults.equalizer) as? [Float] {
            for (band, decibels) in gains.prefix(Equalizer.bandCount).enumerated() {
                engine.processor.equalizer.setGain(decibels, ofBand: band)
            }
        }
    }

    /// "Ausente" y "automático" son respuestas distintas, así que el valor guardado
    /// se lee como opcional en vez de apoyarse en que integer(forKey:) devuelva 0.
    private func storedBufferFrames() -> UInt32 {
        guard let stored = UserDefaults.standard.object(forKey: Defaults.bufferFrames) as? Int
        else { return Self.defaultBufferFrames }
        return UInt32(max(0, stored))
    }
}
