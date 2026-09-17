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
/// audio y no como una rampa. Las que pasan de 1 quedan recortadas planas contra
/// el techo y se pintan ámbar, y van juntas al final a propósito: intercaladas se
/// leían como un patrón arbitrario en vez de "creció hasta que chocó con el
/// límite", que es lo que el dibujo tiene que contar.
let barFractions: [CGFloat] = [0.16, 0.30, 0.22, 0.46, 0.36, 0.62, 0.82, 1.05, 1.18, 1.10]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1).cgColor
}

let gradientTop = color(108, 122, 255)
let gradientBottom = color(26, 22, 66)
/// Ámbar para lo que está tocando el techo: el mismo código de color que usa el
/// medidor de la app cuando el limitador trabaja. El bicolor no es decorativo —
/// dice cuáles barras están siendo limitadas.
let limitedColor = color(255, 176, 32)
let freeColor = NSColor.white.cgColor

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

    // Fondo: squircle con degradado vertical, como los íconos del sistema.
    let inset = side * squircleInsetRatio
    let plate = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = plate.width * cornerRatio
    let plateShape = CGPath(roundedRect: plate, cornerWidth: radius,
                            cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(plateShape)
    context.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [gradientTop, gradientBottom] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.minY),
            options: [])
    }

    // Brillo especular en el borde de arriba. Es el detalle que separa un
    // rectángulo pintado de algo que parece un ícono de macOS: la luz entra desde
    // arriba y el borde superior la devuelve.
    context.saveGState()
    context.addPath(plateShape)
    context.setLineWidth(side * 0.006)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
    context.replacePathWithStrokedPath()
    context.clip()
    if let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor.white.withAlphaComponent(0.55).cgColor,
                                       NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 1]) {
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.midY),
            options: [])
    }
    context.restoreGState()

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

    // Sombra suave debajo de la onda, para que despegue del fondo.
    context.setShadow(offset: CGSize(width: 0, height: -side * 0.008),
                      blur: side * 0.018,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)

    for (index, fraction) in barFractions.enumerated() {
        let limited = fraction >= 1
        let half = min(halfHeight * fraction, halfHeight)
        let bar = CGRect(x: content.minX + CGFloat(index) * (barWidth + gap),
                         y: midY - half,
                         width: barWidth,
                         height: half * 2)
        context.setFillColor(limited ? limitedColor : freeColor)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: barRadius,
                               cornerHeight: barRadius, transform: nil))
        context.fillPath()
    }

    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.setFillColor(limitedColor)
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
