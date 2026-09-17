#!/usr/bin/env swift
//
//  Genera AppIcon.icns por código, para que el ícono sea reproducible y revisable
//  en diff como cualquier otro archivo del repo.
//
//  El dibujo dice las dos cosas que la app es: un dial que pasa del máximo —arco
//  blanco hasta el tope, ámbar siguiendo más allá— y un parlante al centro. Sin el
//  parlante el dial podría ser de batería, velocidad o carga; sin el dial sería un
//  ícono de audio más.
//
//  El ámbar no es decorativo: es el mismo color que usa el medidor de la app
//  cuando el limitador está trabajando.
//
//  Uso:  swift Tools/make-icon.swift
//

import AppKit
import Foundation

let squircleInsetRatio: CGFloat = 0.086      // margen que macOS espera alrededor
let cornerRatio: CGFloat = 0.2237            // proporción de esquina estilo Big Sur

/// Recorrido del dial. Hasta `maximumFraction` es blanco —el rango normal—, y de
/// ahí al final es ámbar: eso es lo que la app agrega por sobre el 100%.
let arcStartDegrees: CGFloat = 212
let arcEndDegrees: CGFloat = -32
let maximumFraction: CGFloat = 0.72

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha).cgColor
}

let gradientTop = color(108, 122, 255)
let gradientBottom = color(26, 22, 66)
let beyondMaximum = color(255, 176, 32)
let withinRange = NSColor.white.cgColor

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
    let shape = CGPath(roundedRect: plate, cornerWidth: radius,
                       cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(shape)
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
    context.restoreGState()

    // Brillo especular en el borde de arriba. Es el detalle que separa un
    // rectángulo pintado de algo que parece un ícono de macOS: la luz entra desde
    // arriba y el borde superior la devuelve.
    context.saveGState()
    context.addPath(shape)
    context.setLineWidth(side * 0.007)
    context.replacePathWithStrokedPath()
    context.clip()
    if let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor.white.withAlphaComponent(0.6).cgColor,
                                       NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 1]) {
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.midY),
            options: [])
    }
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // Sombra suave, para que el dibujo despegue del fondo.
    context.setShadow(offset: CGSize(width: 0, height: -side * 0.007),
                      blur: side * 0.016,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)

    // El dial.
    let center = CGPoint(x: plate.midX, y: plate.midY - plate.height * 0.03)
    let arcRadius = plate.width * 0.325
    let arcWidth = plate.width * 0.095
    let start = arcStartDegrees * .pi / 180
    let end = arcEndDegrees * .pi / 180
    let maximum = start + (end - start) * maximumFraction

    context.setLineCap(.round)
    context.setLineWidth(arcWidth)
    context.setStrokeColor(withinRange)
    context.addArc(center: center, radius: arcRadius,
                   startAngle: start, endAngle: maximum, clockwise: true)
    context.strokePath()
    context.setStrokeColor(beyondMaximum)
    context.addArc(center: center, radius: arcRadius,
                   startAngle: maximum, endAngle: end, clockwise: true)
    context.strokePath()

    // El parlante. Generoso a propósito: a 32 px el dial se vuelve un anillo fino
    // y esto es lo único que sigue diciendo de qué se trata.
    let unit = plate.width
    let origin = CGPoint(x: center.x - unit * 0.045, y: center.y)
    let body = CGMutablePath()
    body.move(to: CGPoint(x: origin.x - unit * 0.130, y: origin.y - unit * 0.048))
    body.addLine(to: CGPoint(x: origin.x - unit * 0.046, y: origin.y - unit * 0.048))
    body.addLine(to: CGPoint(x: origin.x + unit * 0.062, y: origin.y - unit * 0.145))
    body.addLine(to: CGPoint(x: origin.x + unit * 0.062, y: origin.y + unit * 0.145))
    body.addLine(to: CGPoint(x: origin.x - unit * 0.046, y: origin.y + unit * 0.048))
    body.addLine(to: CGPoint(x: origin.x - unit * 0.130, y: origin.y + unit * 0.048))
    body.closeSubpath()
    context.setFillColor(withinRange)
    context.addPath(body)
    context.fillPath()

    context.setLineWidth(unit * 0.040)
    context.setStrokeColor(withinRange)
    context.addArc(center: CGPoint(x: origin.x + unit * 0.062, y: origin.y),
                   radius: unit * 0.105,
                   startAngle: -52 * .pi / 180, endAngle: 52 * .pi / 180, clockwise: false)
    context.strokePath()

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

// El sitio de GitHub Pages necesita el ícono como archivo servible, así que sale
// del mismo generador: si el dibujo cambia, la página cambia con él.
let siteIcon = URL(fileURLWithPath: "docs/icon.png")
if FileManager.default.fileExists(atPath: "docs") {
    try renderPNG(size: 512).write(to: siteIcon)
}

print("iconset escrito en \(iconset.path)")
