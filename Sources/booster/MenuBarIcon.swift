import AppKit

/// El ícono de la barra de menú, dibujado a mano con el mismo lenguaje que el del
/// bundle: forma de onda centrada que crece, y dos líneas de techo que las barras
/// más altas tocan pero no cruzan.
///
/// No es un SF Symbol a propósito. Un parlante genérico se confunde con el control
/// de volumen del sistema y con cualquier otra app de audio; esto se reconoce.
///
/// Se dibuja en vez de venir de un archivo para que macOS lo pida en la escala que
/// necesite, y va como template: el sistema lo tiñe solo en claro y en oscuro.
enum MenuBarIcon {

    private static let size = NSSize(width: 19, height: 15)

    /// Alturas relativas al techo. Las que pasan de 1 quedan recortadas planas,
    /// que es lo que cuenta el dibujo. Son menos barras que en el ícono grande
    /// porque a 19 puntos de ancho más se convierten en una mancha.
    private static let normalBars: [CGFloat] = [0.24, 0.44, 0.32, 0.68, 1.05, 1.15]
    /// Con ganancia arriba de 100% la onda crece: el ícono mismo dice que está
    /// amplificando, sin depender de leer el porcentaje de al lado.
    private static let boostedBars: [CGFloat] = [0.42, 0.72, 0.55, 1.10, 1.20, 1.15]

    static func image(boosted: Bool) -> NSImage {
        let fractions = boosted ? boostedBars : normalBars
        let image = NSImage(size: size, flipped: false) { rect in
            draw(fractions: fractions, in: rect)
            return true
        }
        image.isTemplate = true          // que macOS decida el color
        return image
    }

    private static func draw(fractions: [CGFloat], in rect: NSRect) {
        NSColor.black.setFill()

        let lineThickness: CGFloat = 1
        let midY = rect.midY
        let maxHalf = rect.height / 2 - lineThickness - 0.5

        // Barras centradas en el eje, repartidas con huecos del 60%. El margen
        // lateral evita que la primera y la última queden pegadas al borde, que a
        // este tamaño se ve como si estuvieran cortadas.
        let sideMargin = rect.width * 0.03
        let usableWidth = rect.width - sideMargin * 2
        let count = CGFloat(fractions.count)
        let barWidth = usableWidth / (count + 0.6 * (count - 1))
        let gap = barWidth * 0.6
        let radius = barWidth * 0.35

        for (index, fraction) in fractions.enumerated() {
            let half = min(maxHalf * fraction, maxHalf)
            let bar = NSRect(x: rect.minX + sideMargin + CGFloat(index) * (barWidth + gap),
                             y: midY - half,
                             width: barWidth,
                             height: half * 2)
            NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        }

        // Techos arriba y abajo.
        NSBezierPath(rect: NSRect(x: rect.minX, y: midY + maxHalf,
                                  width: rect.width, height: lineThickness)).fill()
        NSBezierPath(rect: NSRect(x: rect.minX, y: midY - maxHalf - lineThickness,
                                  width: rect.width, height: lineThickness)).fill()
    }
}
