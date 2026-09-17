import AppKit

/// Output level bar. It turns orange while the limiter is working, which is the
/// honest signal that you are asking for more gain than the material can take.
final class LevelMeterView: NSView {

    var level: Float = 0 { didSet { if level != oldValue { needsDisplay = true } } }
    var isLimiting = false { didSet { if isLimiting != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        guard level > 0.001 else { return }
        let width = max(bounds.height, bounds.width * CGFloat(min(level, 1)))
        let filled = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        (isLimiting ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

/// Top-left origin, so the panel can be laid out downwards like it reads.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
