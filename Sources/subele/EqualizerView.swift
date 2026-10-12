import AppKit
import BoosterKit

/// El ecualizador como gráfico: la curva de respuesta real, cinco puntos que se
/// arrastran y, detrás, el espectro de lo que está sonando.
///
/// La curva no es un dibujo aproximado: sale de `Equalizer.responseDecibels`, que
/// evalúa los mismos biquads que procesan el audio. Lo que se ve es lo que suena.
///
/// Gestos: arrastrar un punto cambia su banda (de a 1 dB), doble clic la vuelve a
/// cero, y la rueda del mouse o el trackpad la mueven sobre el punto que esté
/// bajo el cursor.
final class EqualizerView: NSView {

    var gains = [Float](repeating: 0, count: Equalizer.bandCount) {
        didSet { if gains != oldValue { needsDisplay = true } }
    }
    var sampleRate: Double = 48_000 { didSet { needsDisplay = true } }
    /// Niveles del analizador en dBFS, de graves a agudos, o vacío si no hay.
    var spectrum: [Float] = [] { didSet { needsDisplay = true } }
    var title = ""
    var onChange: ((Int, Float) -> Void)?

    private var activeBand: Int?
    private var hoveredBand: Int?
    private var scrollRemainder: CGFloat = 0

    /// Un poco más que el máximo para que los puntos en ±12 no toquen el borde.
    private let range = Double(Equalizer.maximumGainDecibels) + 3
    private let lowest = SpectrumAnalyzer.lowestFrequency
    private let highest = SpectrumAnalyzer.highestFrequency

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self))
    }

    // MARK: Geometría

    private var plot: NSRect {
        NSRect(x: bounds.minX + 30, y: bounds.minY + 24,
               width: bounds.width - 30 - 14, height: bounds.height - 24 - 30)
    }

    private func x(_ frequency: Double) -> CGFloat {
        let position = (log10(frequency) - log10(lowest)) / (log10(highest) - log10(lowest))
        return plot.minX + plot.width * CGFloat(position)
    }

    private func frequency(atX x: CGFloat) -> Double {
        let position = Double((x - plot.minX) / plot.width)
        return pow(10, log10(lowest) + position * (log10(highest) - log10(lowest)))
    }

    private func y(_ decibels: Double) -> CGFloat {
        plot.midY + plot.height / 2 * CGFloat(max(-range, min(range, decibels)) / range)
    }

    private func decibels(atY y: CGFloat) -> Float {
        let value = Double((y - plot.midY) / (plot.height / 2)) * range
        let limit = Double(Equalizer.maximumGainDecibels)
        return Float(max(-limit, min(limit, value)).rounded())
    }

    /// El punto marca la ganancia de la banda, no el valor de la curva en esa
    /// frecuencia: en un shelf la curva pasa por la mitad de la ganancia en la
    /// frecuencia de corte, y un punto que no queda bajo el cursor al arrastrarlo
    /// se siente roto.
    private func handlePoint(_ band: Int) -> NSPoint {
        NSPoint(x: x(Equalizer.frequency(ofBand: band)), y: y(Double(gains[band])))
    }

    /// La banda más cercana en horizontal: así se puede agarrar un punto clicando
    /// en cualquier lugar de su columna, sin apuntarle exacto.
    private func band(near point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        return (0..<Equalizer.bandCount).min {
            abs(x(Equalizer.frequency(ofBand: $0)) - point.x)
                < abs(x(Equalizer.frequency(ofBand: $1)) - point.x)
        }
    }

    // MARK: Dibujo

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let boost = NSColor.systemOrange

        // Fondo
        let panel = NSBezierPath(roundedRect: plot.insetBy(dx: -1, dy: -1), xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        panel.fill()

        NSGraphicsContext.saveGraphicsState()
        panel.addClip()

        // Espectro: barras suaves detrás de todo, de −72 a 0 dBFS a lo alto.
        if !spectrum.isEmpty {
            let count = spectrum.count
            let columnWidth = plot.width / CGFloat(count)
            for (index, level) in spectrum.enumerated() {
                let normalized = CGFloat(max(0, min(1, (level + 72) / 72)))
                guard normalized > 0.01 else { continue }
                let bar = NSRect(x: plot.minX + CGFloat(index) * columnWidth + 0.75,
                                 y: plot.minY,
                                 width: max(1, columnWidth - 1.5),
                                 height: plot.height * normalized)
                let gradient = NSGradient(colors: [
                    accent.withAlphaComponent(0.03),
                    accent.withAlphaComponent(0.06 + 0.16 * normalized),
                ])
                gradient?.draw(in: NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5),
                               angle: 90)
            }
        }

        // Grilla: 0 dB marcado, ±6 y ±12 tenues, décadas en vertical.
        for decibels in [-12.0, -6, 6, 12] {
            line(from: NSPoint(x: plot.minX, y: y(decibels)),
                 to: NSPoint(x: plot.maxX, y: y(decibels)),
                 color: NSColor.labelColor.withAlphaComponent(0.06))
        }
        line(from: NSPoint(x: plot.minX, y: y(0)), to: NSPoint(x: plot.maxX, y: y(0)),
             color: NSColor.labelColor.withAlphaComponent(0.18))
        for frequency in [100.0, 1_000, 10_000] {
            line(from: NSPoint(x: x(frequency), y: plot.minY),
                 to: NSPoint(x: x(frequency), y: plot.maxY),
                 color: NSColor.labelColor.withAlphaComponent(0.06))
        }

        // Curva de respuesta, con relleno hasta 0 dB.
        let curve = NSBezierPath()
        let steps = Int(plot.width / 1.5)
        for step in 0...steps {
            let px = plot.minX + plot.width * CGFloat(step) / CGFloat(steps)
            let response = Equalizer.responseDecibels(atFrequency: frequency(atX: px),
                                                      gains: gains, sampleRate: sampleRate)
            let point = NSPoint(x: px, y: y(response))
            step == 0 ? curve.move(to: point) : curve.line(to: point)
        }
        let fill = curve.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: plot.maxX, y: y(0)))
        fill.line(to: NSPoint(x: plot.minX, y: y(0)))
        fill.close()
        // Naranja donde sube, azul donde baja: se lee de un vistazo qué se está
        // sacando y qué se está agregando.
        for (color, area) in [
            (boost, NSRect(x: plot.minX, y: y(0), width: plot.width, height: plot.maxY - y(0))),
            (NSColor.systemBlue, NSRect(x: plot.minX, y: plot.minY, width: plot.width,
                                        height: y(0) - plot.minY)),
        ] {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: area).addClip()
            color.withAlphaComponent(0.18).setFill()
            fill.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        curve.lineWidth = 2
        curve.lineJoinStyle = .round
        accent.setStroke()
        curve.stroke()

        NSGraphicsContext.restoreGraphicsState()

        // Puntos.
        for band in 0..<Equalizer.bandCount {
            let point = handlePoint(band)
            let emphasised = band == activeBand || band == hoveredBand
            let radius: CGFloat = emphasised ? 7 : 5.5
            let circle = NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2))
            let color = gains[band] > 0 ? boost : gains[band] < 0 ? NSColor.systemBlue : accent
            if emphasised {
                color.withAlphaComponent(0.25).setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - radius - 4, y: point.y - radius - 4,
                                            width: (radius + 4) * 2, height: (radius + 4) * 2)).fill()
            }
            NSColor.white.setFill()
            circle.fill()
            circle.lineWidth = 2
            color.setStroke()
            circle.stroke()
        }

        // Etiquetas de frecuencia bajo cada punto, y de dB a la izquierda.
        let small = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        for band in 0..<Equalizer.bandCount {
            let frequency = Equalizer.frequency(ofBand: band)
            let isActive = band == activeBand || band == hoveredBand
            text(frequencyLabel(frequency), centeredAt: NSPoint(x: x(frequency), y: plot.minY - 12),
                 font: small, color: isActive ? .labelColor : .secondaryLabelColor)
        }
        for decibels in [-12.0, 0, 12] {
            text(decibels == 0 ? "0" : String(format: "%+.0f", decibels),
                 rightAlignedAt: NSPoint(x: plot.minX - 6, y: y(decibels)),
                 font: .monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                 color: .tertiaryLabelColor)
        }

        // Encabezado: el título, o el valor de la banda que se está tocando.
        let headerY = plot.maxY + 15
        if let band = activeBand ?? hoveredBand {
            let value = gains[band] == 0 ? "0 dB" : String(format: "%+.0f dB", gains[band])
            text("\(frequencyLabel(Equalizer.frequency(ofBand: band))) Hz   \(value)",
                 leftAlignedAt: NSPoint(x: plot.minX, y: headerY),
                 font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), color: .labelColor)
        } else {
            text(title, leftAlignedAt: NSPoint(x: plot.minX, y: headerY),
                 font: .systemFont(ofSize: 11, weight: .semibold), color: .labelColor)
        }
    }

    private func frequencyLabel(_ frequency: Double) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }

    private func line(from start: NSPoint, to end: NSPoint, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }

    private func attributes(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    private func text(_ string: String, centeredAt point: NSPoint, font: NSFont, color: NSColor) {
        let size = (string as NSString).size(withAttributes: attributes(font, color))
        (string as NSString).draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                                  withAttributes: attributes(font, color))
    }

    private func text(_ string: String, rightAlignedAt point: NSPoint, font: NSFont, color: NSColor) {
        let size = (string as NSString).size(withAttributes: attributes(font, color))
        (string as NSString).draw(at: NSPoint(x: point.x - size.width, y: point.y - size.height / 2),
                                  withAttributes: attributes(font, color))
    }

    private func text(_ string: String, leftAlignedAt point: NSPoint, font: NSFont, color: NSColor) {
        let size = (string as NSString).size(withAttributes: attributes(font, color))
        (string as NSString).draw(at: NSPoint(x: point.x, y: point.y - size.height / 2),
                                  withAttributes: attributes(font, color))
    }

    // MARK: Gestos

    private func set(_ band: Int, _ decibels: Float) {
        guard gains[band] != decibels else { return }
        gains[band] = decibels
        onChange?(band, decibels)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let band = band(near: point) else { return }
        if event.clickCount == 2 {
            set(band, 0)
            return
        }
        activeBand = band
        // Clic sobre el punto: solo lo agarra. Clic en otro lado de la columna:
        // lo lleva ahí de una.
        if abs(handlePoint(band).y - point.y) > 10 { set(band, decibels(atY: point.y)) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let band = activeBand else { return }
        set(band, decibels(atY: convert(event.locationInWindow, from: nil).y))
    }

    override func mouseUp(with event: NSEvent) {
        activeBand = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let band = band(near: convert(event.locationInWindow, from: nil))
        if band != hoveredBand { hoveredBand = band; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredBand = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let band = hoveredBand ?? band(near: convert(event.locationInWindow, from: nil))
        else { return }
        // El trackpad manda deltas chicos y muchos; se acumulan hasta 1 dB.
        scrollRemainder += event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        let steps = scrollRemainder.rounded(.towardZero)
        guard steps != 0 else { return }
        scrollRemainder -= steps
        let limit = Equalizer.maximumGainDecibels
        set(band, max(-limit, min(limit, gains[band] + Float(steps))))
    }
}
