#!/usr/bin/env swift
//
//  Genera AppIcon.icns por código, para que el ícono sea reproducible y revisable
//  en diff como cualquier otro archivo del repo.
//
//  El dibujo cuenta lo que hace la app: una forma de onda que crece de izquierda a
//  derecha, y dos líneas de techo —arriba y abajo— que las barras más altas tocan
//  pero no cruzan. Eso es exactamente el limitador.
//
//  Simétrica alrededor del centro a propósito: unas barras apoyadas en el piso se
//  leen como un gráfico de estadísticas, no como audio.
//
//  Uso:  swift Tools/make-icon.swift
//

import AppKit
import Foundation

let squircleInsetRatio: CGFloat = 0.086      // margen que macOS espera alrededor
let cornerRatio: CGFloat = 0.2237            // proporción de esquina estilo Big Sur
/// Alturas relativas al techo. Suben pero no en línea recta, para que se lea como
/// audio y no como una rampa; las que pasan de 1 quedan recortadas planas en el
/// techo, que es el punto del dibujo.
let barFractions: [CGFloat] = [0.14, 0.26, 0.20, 0.42, 0.34, 0.58, 0.74, 1.12, 0.88, 1.20]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1).cgColor
}

let gradientTop = color(88, 101, 242)
let gradientBottom = color(22, 20, 58)
let ceilingColor = color(255, 176, 32)
let barColor = NSColor.white

func renderPNG(size: Int) -> Data {
    let side = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("no se pudo crear el bitmap de \(size)px") }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("no se pudo crear el contexto")
    }
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext

    // Fondo: squircle con degradado en diagonal.
    let inset = side * squircleInsetRatio
    let plate = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = plate.width * cornerRatio
    context.saveGState()
    context.addPath(CGPath(roundedRect: plate, cornerWidth: radius,
                           cornerHeight: radius, transform: nil))
    context.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [gradientTop, gradientBottom] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.maxY),
            end: CGPoint(x: plate.maxX, y: plate.minY),
            options: [])
    }

    // Zona de contenido.
    let padding = plate.width * 0.17
    let content = plate.insetBy(dx: padding, dy: padding)
    let midY = content.midY

    // Techos simétricos, uno arriba y otro abajo.
    let ceilingThickness = max(1, content.height * 0.028)
    let halfHeight = content.height / 2 - ceilingThickness * 1.4

    // Barras centradas en el eje: es lo que hace que se lea como audio.
    // El ancho sale de repartir el contenido entre barras y huecos del 62%.
    let barCount = barFractions.count
    let barWidth = content.width / (CGFloat(barCount) + 0.62 * CGFloat(barCount - 1))
    let gap = barWidth * 0.62
    let barRadius = barWidth * 0.34

    barColor.setFill()
    for (index, fraction) in barFractions.enumerated() {
        let half = min(halfHeight * fraction, halfHeight)
        let bar = CGRect(x: content.minX + CGFloat(index) * (barWidth + gap),
                         y: midY - half,
                         width: barWidth,
                         height: half * 2)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: barRadius,
                               cornerHeight: barRadius, transform: nil))
        context.fillPath()
    }

    context.setFillColor(ceilingColor)
    context.fill(CGRect(x: content.minX, y: midY + halfHeight,
                        width: content.width, height: ceilingThickness))
    context.fill(CGRect(x: content.minX, y: midY - halfHeight - ceilingThickness,
                        width: content.width, height: ceilingThickness))

    context.restoreGState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("no se pudo codificar el PNG de \(size)px")
    }
    return data
}

// iconutil espera exactamente estos nombres.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let iconset = URL(fileURLWithPath: "Tools/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    let url = iconset.appendingPathComponent("\(variant.name).png")
    try renderPNG(size: variant.size).write(to: url)
}
print("iconset escrito en \(iconset.path)")
