import AppKit

/// Una fila de menú que se ve como un ítem común pero no cierra el menú al
/// elegirla.
///
/// Un NSMenuItem normal cierra todo el árbol de menús al activarse, y no hay
/// propiedad que lo evite. Con los presets del ecualizador eso era un problema:
/// elegías "Voz clara" y desaparecía justo el gráfico que querías seguir
/// ajustando. Un ítem con vista sí recibe el clic sin que el menú se cierre, a
/// cambio de dibujarse solo: el check sale de `enclosingMenuItem.state` y el
/// resaltado de `isHighlighted`, así que se refrescan igual que un ítem común.
final class StayOpenMenuRow: NSView {

    private let title: String
    private let onSelect: () -> Void

    init(title: String, onSelect: @escaping () -> Void) {
        self.title = title
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        autoresizingMask = .width                 // toma el ancho del menú
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        let color: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let font = NSFont.menuFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        let baseline = (bounds.height - size.height) / 2
        if enclosingMenuItem?.state == .on {
            ("✓" as NSString).draw(at: NSPoint(x: 9, y: baseline), withAttributes: attributes)
        }
        (title as NSString).draw(at: NSPoint(x: 24, y: baseline), withAttributes: attributes)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSelect()
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect()
        return true
    }
}
