import AppKit
import BoosterKit
import Foundation

/// The menu bar front end. Owns one engine, a status item, and a 20 Hz timer for
/// the meter; everything else is the engine's business.
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private static var retained: MenuBarApp?

    static func run() -> Never {
        let application = NSApplication.shared
        let delegate = MenuBarApp()
        retained = delegate                       // NSApplication holds it weakly
        application.delegate = delegate
        application.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        application.run()
        exit(0)
    }

    private enum Defaults {
        static let gain = "gain"
        static let mode = "mode"
        static let bufferFrames = "bufferFrames"
    }

    /// Buffer sizes offered in the menu, with the latency each one costs.
    ///
    /// The chain costs about two buffer periods plus the limiter's 3 ms lookahead,
    /// and that ratio held across every size measured, so this is the one lever
    /// that actually moves latency. 256 is the default: it halves the latency
    /// CoreAudio would pick on its own while still leaving plenty of headroom.
    /// 0 means "leave whatever CoreAudio picked".
    private static let bufferChoices: [(title: String, frames: UInt32)] = [
        ("Lowest — 128 frames", 128),
        ("Low — 256 frames", 256),
        ("Relaxed — 512 frames", 512),
        ("Automatic", 0),
    ]

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
    private var enabledItem: NSMenuItem!
    private var retryItem: NSMenuItem!
    private var bufferItems: [NSMenuItem] = []

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        restoreSettings()
        buildStatusItem()

        engine.onDefaultOutputChanged = { [weak self] in self?.scheduleRestart() }
        startEngine()

        // .common so the meter keeps moving while the menu is open: an open menu
        // runs its own run loop mode, which would otherwise freeze the timer.
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

    // MARK: Engine

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

    /// A device change fires several notifications in a row; wait for them to
    /// settle rather than rebuilding the chain once per notification.
    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartEngine() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Building the menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let panel = NSMenuItem()
        panel.view = buildPanel()
        menu.addItem(panel)
        menu.addItem(.separator())

        enabledItem = item("Enabled", #selector(toggleEnabled))
        menu.addItem(enabledItem)
        menu.addItem(item("Reset to 100%", #selector(resetGain), key: "0"))

        let bufferItem = NSMenuItem(title: "Latency", action: nil, keyEquivalent: "")
        let bufferMenu = NSMenu()
        for (index, choice) in Self.bufferChoices.enumerated() {
            let entry = item(choice.title, #selector(bufferChosen(_:)))
            entry.tag = index
            bufferMenu.addItem(entry)
            bufferItems.append(entry)
        }
        bufferItem.submenu = bufferMenu
        menu.addItem(bufferItem)

        retryItem = item("Retry", #selector(retry), key: "r")
        menu.addItem(retryItem)

        menu.addItem(.separator())
        menu.addItem(item("Quit Audio Booster", #selector(quit), key: "q"))

        statusItem.menu = menu
        refreshChrome()
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
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 168))

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
        modeControl.setLabel("Transparent", forSegment: 0)
        modeControl.setLabel("Loudness", forSegment: 1)
        modeControl.segmentStyle = .rounded
        modeControl.frame = NSRect(x: margin, y: 126, width: inner, height: 24)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        for segment in 0..<2 { modeControl.setWidth(inner / 2, forSegment: segment) }
        view.addSubview(modeControl)

        return view
    }

    // MARK: Refreshing

    /// Everything that does not change twenty times a second.
    private func refreshChrome() {
        let percent = Int((engine.processor.gain * 100).rounded())
        gainSlider.floatValue = engine.processor.gain * 100
        gainLabel.stringValue = "\(percent)%"
        modeControl.selectedSegment = engine.processor.mode == .loudness ? 1 : 0
        enabledItem?.state = isEnabled ? .on : .off
        retryItem?.isHidden = (lastError == nil)

        let chosen = storedBufferFrames()
        for (index, item) in bufferItems.enumerated() {
            item.state = Self.bufferChoices[index].frames == chosen ? .on : .off
        }

        if let lastError {
            titleLabel.stringValue = "Not running"
            subtitleLabel.stringValue = lastError
            subtitleLabel.textColor = .systemOrange
        } else if !isEnabled {
            titleLabel.stringValue = "Disabled"
            subtitleLabel.stringValue = "Audio passes through untouched"
            subtitleLabel.textColor = .secondaryLabelColor
        } else if let info = engine.info {
            titleLabel.stringValue = info.deviceName
            let channels = info.outputChannels == 2 ? "stereo" : "\(info.outputChannels) ch"
            let latency = engine.addedLatencySeconds * 1000
            subtitleLabel.stringValue = String(
                format: "%d kHz · %@ · +%.0f ms",
                Int(info.sampleRate / 1000), channels, latency)
            subtitleLabel.textColor = .secondaryLabelColor
        }

        let running = isEnabled && lastError == nil
        let symbol = lastError != nil ? "exclamationmark.triangle.fill"
                   : !isEnabled ? "speaker.slash.fill"
                   : engine.processor.gain > 1.01 ? "speaker.wave.3.fill"
                   : "speaker.wave.2.fill"
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: "Audio Booster")
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
        meter.level = max(0, (peak + 60) / 60)          // −60…0 dBFS across the bar
        meter.isLimiting = reduction < -0.1
        meterLabel.stringValue = peak <= -59
            ? "silent"
            : String(format: "%.1f dBFS%@", peak,
                     reduction < -0.1
                        ? String(format: "   ·   limiting %.1f dB", reduction) : "")
    }

    // MARK: Actions

    func menuWillOpen(_ menu: NSMenu) {
        refreshChrome()
        refreshMeter()
    }

    @objc private func gainChanged() {
        engine.processor.gain = gainSlider.floatValue / 100
        UserDefaults.standard.set(engine.processor.gain, forKey: Defaults.gain)
        refreshChrome()
    }

    @objc private func modeChanged() {
        engine.processor.mode = modeControl.selectedSegment == 1 ? .loudness : .transparent
        UserDefaults.standard.set(engine.processor.mode.rawValue, forKey: Defaults.mode)
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
        let frames = Self.bufferChoices[sender.tag].frames
        UserDefaults.standard.set(Int(frames), forKey: Defaults.bufferFrames)
        engine.preferredBufferFrames = frames == 0 ? nil : frames
        restartEngine()
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
    }

    /// Absent and "automatic" are different answers, so the stored value has to be
    /// read as an optional rather than leaning on integer(forKey:) returning 0.
    private func storedBufferFrames() -> UInt32 {
        guard let stored = UserDefaults.standard.object(forKey: Defaults.bufferFrames) as? Int
        else { return Self.defaultBufferFrames }
        return UInt32(max(0, stored))
    }
}
