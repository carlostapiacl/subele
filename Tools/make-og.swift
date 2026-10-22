#!/usr/bin/env swift
//
//  Genera las imágenes para compartir el sitio (Open Graph, 1200 × 630): una en
//  español y otra en inglés, con el ícono, el titular de la página y la captura
//  real del menú. Por código, como el ícono, para que se revisen en diff y se
//  rehagan solas si cambia el texto.
//
//  Uso:  swift Tools/make-og.swift      (escribe docs/og-es.png y docs/og-en.png)
//

import AppKit
import Foundation

let width = 1200
let height = 630

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

// Los mismos colores del sitio (docs/site.css).
let ink = color(13, 11, 36)
let ink2 = color(23, 20, 64)
let indigo = color(122, 134, 255)
let amber = color(255, 176, 32)
let text = color(232, 231, 245)
let muted = color(163, 160, 198)

struct Variant {
    let file: String
    let ask: String
    let headline: String
    let footer: String
}

let variants = [
    Variant(file: "og-es.png",
            ask: "¿Tu Mac al 100 % y se escucha bajo?",
            headline: "Subí el volumen de tu Mac más allá del 100 %",
            footer: "Gratis · sin drivers · código abierto"),
    Variant(file: "og-en.png",
            ask: "Mac at 100% and still too quiet?",
            headline: "Turn your Mac up past 100%",
            footer: "Free · no drivers · open source"),
]

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let docs = root.appendingPathComponent("docs")

guard let icon = NSImage(contentsOf: docs.appendingPathComponent("icon.png")),
      let screenshot = NSImage(contentsOf: docs.appendingPathComponent("screenshot-ecualizador.png"))
else { fatalError("faltan docs/icon.png o docs/screenshot-ecualizador.png") }

func draw(_ string: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineHeightMultiple = 1.02
    (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ])
}

func render(_ variant: Variant) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("no se pudo crear el bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let canvas = NSRect(x: 0, y: 0, width: width, height: height)

    NSGradient(starting: ink2, ending: ink)!.draw(in: canvas, angle: -90)
    // El mismo halo índigo que el encabezado del sitio, arriba a la izquierda.
    NSGradient(colors: [indigo.withAlphaComponent(0.30), indigo.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 260, y: 640), radius: 0,
              toCenter: NSPoint(x: 260, y: 640), radius: 620, options: [])

    // La captura, entera y centrada en alto, a la derecha.
    let shotWidth: CGFloat = 520
    let shotHeight = shotWidth * screenshot.size.height / screenshot.size.width
    let shotRect = NSRect(x: CGFloat(width) - shotWidth - 36, y: (CGFloat(height) - shotHeight) / 2,
                          width: shotWidth, height: shotHeight)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    screenshot.draw(in: shotRect)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Columna de texto.
    let left: CGFloat = 72
    let column: CGFloat = 540
    icon.draw(in: NSRect(x: left, y: 470, width: 84, height: 84))
    draw("Subele", in: NSRect(x: left + 104, y: 488, width: 400, height: 50),
         size: 40, weight: .bold, color: text)
    draw(variant.ask, in: NSRect(x: left, y: 392, width: column, height: 44),
         size: 28, weight: .semibold, color: amber)
    draw(variant.headline, in: NSRect(x: left, y: 160, width: column, height: 230),
         size: 56, weight: .heavy, color: text)
    draw(variant.footer, in: NSRect(x: left, y: 64, width: column, height: 40),
         size: 26, weight: .medium, color: muted)

    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("no se pudo codificar el PNG")
    }
    let url = docs.appendingPathComponent(variant.file)
    try data.write(to: url)
    print("  \(url.path)")
}

for variant in variants { try render(variant) }
