import AppKit

/// El ícono de la barra de menú: la misma idea que el del bundle —un dial con un
/// parlante adentro— simplificada para 18 puntos.
///
/// No es un SF Symbol a propósito. Un parlante genérico se confunde con el control
/// de volumen del sistema y con cualquier otra app de audio de la barra.
///
/// En monocromo no existe el ámbar que en el ícono grande separa el rango normal
/// de lo que está por encima, así que el límite lo marca un corte en el arco. Y el
/// arco **crece con la ganancia**: el ícono mismo dice cuánto está amplificando,
/// sin depender de leer el porcentaje de al lado.
///
/// Va como template: macOS lo tiñe solo en claro, en oscuro y con el menú abierto.
enum MenuBarIcon {

    private static let size = NSSize(width: 18, height: 16)

    private static let startDegrees: CGFloat = 208
    private static let endDegrees: CGFloat = -28
    /// Dónde termina el rango normal, como fracción del recorrido.
    private static let maximumFraction: CGFloat = 0.72

    static func image(boosted: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, boosted: boosted)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(in rect: NSRect, boosted: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.setFill()

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width * 0.425
        let width = rect.width * 0.078
        let start = startDegrees * .pi / 180
        let end = endDegrees * .pi / 180
        let maximum = start + (end - start) * maximumFraction
        // Un corte proporcional al trazo: más chico no se ve, más grande parte el
        // arco en dos cosas distintas.
        let gap = (end - start) * 0.10

        context.setLineCap(.round)
        context.setLineWidth(width)
        context.setStrokeColor(NSColor.black.cgColor)

        context.addArc(center: center, radius: radius,
                       startAngle: start, endAngle: maximum, clockwise: true)
        context.strokePath()

        // El tramo de más allá del máximo solo aparece cuando hay boost.
        if boosted {
            context.addArc(center: center, radius: radius,
                           startAngle: maximum + gap, endAngle: end, clockwise: true)
            context.strokePath()
        }

        // Parlante al centro.
        let unit = rect.width
        let origin = CGPoint(x: center.x - unit * 0.045, y: center.y)
        let body = NSBezierPath()
        body.move(to: CGPoint(x: origin.x - unit * 0.150, y: origin.y - unit * 0.062))
        body.line(to: CGPoint(x: origin.x - unit * 0.052, y: origin.y - unit * 0.062))
        body.line(to: CGPoint(x: origin.x + unit * 0.076, y: origin.y - unit * 0.185))
        body.line(to: CGPoint(x: origin.x + unit * 0.076, y: origin.y + unit * 0.185))
        body.line(to: CGPoint(x: origin.x - unit * 0.052, y: origin.y + unit * 0.062))
        body.line(to: CGPoint(x: origin.x - unit * 0.150, y: origin.y + unit * 0.062))
        body.close()
        body.fill()
    }
}
