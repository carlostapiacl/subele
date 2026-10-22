import AppKit
import BoosterKit

/// El panel de arriba del menú: medidor, dispositivo, slider de ganancia y modo.
///
/// Solo dibuja y avisa: no sabe nada del motor. `MenuBarApp` le pasa lo que tiene
/// que mostrar y escucha `onGainChange` y `onModeChange`.
final class StatusPanel {

    let view: NSView

    var onGainChange: ((Float) -> Void)?
    var onModeChange: ((BoostMode) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let gainSlider = NSSlider()
    private let gainLabel = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl()
    private let meter = LevelMeterView()
    private let meterLabel = NSTextField(labelWithString: "")
    private let modeHintLabel = NSTextField(labelWithString: "")
    private let target = Target()

    init(strings: Strings) {
        let width: CGFloat = 300
        let margin: CGFloat = 16
        let inner = width - margin * 2
        view = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 180))

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
        gainSlider.target = target
        gainSlider.action = #selector(Target.fire)
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
        modeControl.target = target
        modeControl.action = #selector(Target.fire)
        for segment in 0..<2 { modeControl.setWidth(inner / 2, forSegment: segment) }
        view.addSubview(modeControl)

        // "¿El modo transparente no hace nada?" fue la primera pregunta de alguien
        // que la probó. Con 100% de ganancia, casi nada: hace falta decirlo en la cara.
        modeHintLabel.frame = NSRect(x: margin, y: 155, width: inner, height: 15)
        modeHintLabel.font = .systemFont(ofSize: 10)
        modeHintLabel.textColor = .secondaryLabelColor
        modeHintLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(modeHintLabel)

        target.action = { [weak self] sender in self?.controlChanged(sender) }
    }

    private func controlChanged(_ sender: AnyObject) {
        if sender === gainSlider {
            onGainChange?(gainSlider.floatValue / 100)
        } else if sender === modeControl {
            onModeChange?(modeControl.selectedSegment == 1 ? .loudness : .transparent)
        }
    }

    // MARK: Lo que muestra

    func show(gain: Float, mode: BoostMode, hint: String) {
        gainSlider.floatValue = gain * 100
        gainLabel.stringValue = "\(Int((gain * 100).rounded()))%"
        modeControl.selectedSegment = mode == .loudness ? 1 : 0
        modeHintLabel.stringValue = hint
    }

    func show(title: String, subtitle: String, warning: Bool = false) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.textColor = warning ? .systemOrange : .secondaryLabelColor
    }

    func showMeter(level: Float, limiting: Bool, label: String) {
        meter.level = level
        meter.isLimiting = limiting
        meterLabel.stringValue = label
    }

    /// NSControl necesita un objetivo Objective-C; este lo reenvía a un cierre.
    private final class Target: NSObject {
        var action: ((AnyObject) -> Void)?
        @objc func fire(_ sender: AnyObject) { action?(sender) }
    }
}
