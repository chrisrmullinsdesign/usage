// Renders Resources/AppIcon.png (1024²) — the source art for AppIcon.icns.
// Run via Scripts/make-icon.sh, which also produces the .iconset and .icns.
//
// The mark is the app's own meter, drawn as a gauge: a track arc, an accent fill
// sweeping to ~62%, and a needle. Same shapes and palette as the popover, so the
// icon and the UI read as one thing.

import AppKit
import CoreGraphics
import Foundation

let size: CGFloat = 1024
/// Apple leaves ~10% of the canvas as transparent margin around a macOS app icon.
let inset: CGFloat = 100
let squircle = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// Apple's icon corners are a continuous superellipse, not a circular round-rect.
/// |x/a|^n + |y/b|^n = 1 with n = 5 matches the system shape closely.
func squirclePath(in rect: CGRect, exponent: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = Double(rect.width / 2), b = Double(rect.height / 2)
    let cx = Double(rect.midX), cy = Double(rect.midY)
    let steps = 720
    for step in 0...steps {
        let t = Double(step) / Double(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = cx + copysign(pow(abs(cosT), 2 / exponent), cosT) * a
        let y = cy + copysign(pow(abs(sinT), 2 / exponent), sinT) * b
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

guard let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("couldn't create the bitmap context")
}

let body = squirclePath(in: squircle)

// Contact shadow, so the icon sits on the Finder/Dock background rather than floating.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: srgb(0x000000, 0.34))
context.addPath(body)
context.setFillColor(srgb(0x1B2331))
context.fillPath()
context.restoreGState()

// Body: a deep slate gradient, lit from the top left.
context.saveGState()
context.addPath(body)
context.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [srgb(0x33415C), srgb(0x202B3D), srgb(0x131924)] as CFArray,
                          locations: [0, 0.55, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size * 0.35, y: 0), options: [])

// Specular sheen across the upper third.
let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: [srgb(0xFFFFFF, 0.16), srgb(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 1])!
context.drawLinearGradient(sheen, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: size * 0.58), options: [])
context.restoreGState()

// Inner hairline: catches the light along the top edge the way system icons do.
context.saveGState()
context.addPath(body)
context.setStrokeColor(srgb(0xFFFFFF, 0.14))
context.setLineWidth(3)
context.strokePath()
context.restoreGState()

// MARK: - Gauge

let center = CGPoint(x: size / 2, y: size * 0.455)
let radius: CGFloat = 268
let thickness: CGFloat = 78
/// Open at the bottom: sweeps clockwise from 200° through the top to -20°.
let startAngle = 200 * CGFloat.pi / 180
let endAngle = -20 * CGFloat.pi / 180
/// Where the needle sits and the accent fill stops — a plausible, comfortable reading.
let fraction: CGFloat = 0.62
let needleAngle = startAngle + (endAngle - startAngle) * fraction

func arc(from: CGFloat, to: CGFloat, color: CGColor) {
    context.saveGState()
    context.setLineWidth(thickness)
    context.setLineCap(.round)
    context.setStrokeColor(color)
    context.addArc(center: center, radius: radius, startAngle: from, endAngle: to, clockwise: true)
    context.strokePath()
    context.restoreGState()
}

arc(from: startAngle, to: endAngle, color: srgb(0x0E1420, 0.72))   // track
arc(from: startAngle, to: needleAngle, color: srgb(0x3987E5))      // fill

// Tick dots just outside the arc, echoing SF Symbols' gauge.with.dots.needle.
for index in 0...4 {
    let t = CGFloat(index) / 4
    let angle = startAngle + (endAngle - startAngle) * t
    let distance = radius + thickness / 2 + 30
    let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
    context.setFillColor(srgb(0xFFFFFF, t <= fraction ? 0.8 : 0.3))
    context.fillEllipse(in: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22))
}

// Needle: a tapered blade from the hub, plus the hub itself.
context.saveGState()
context.translateBy(x: center.x, y: center.y)
context.rotate(by: needleAngle)
let length = radius - thickness / 2 - 14
let needle = CGMutablePath()
needle.move(to: CGPoint(x: length, y: 0))
needle.addLine(to: CGPoint(x: 6, y: 27))
needle.addLine(to: CGPoint(x: -38, y: 11))
needle.addLine(to: CGPoint(x: -38, y: -11))
needle.addLine(to: CGPoint(x: 6, y: -27))
needle.closeSubpath()
context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: srgb(0x000000, 0.5))
context.addPath(needle)
context.setFillColor(srgb(0xF7F7F5))
context.fillPath()
context.restoreGState()

context.setFillColor(srgb(0xF7F7F5))
context.fillEllipse(in: CGRect(x: center.x - 53, y: center.y - 53, width: 106, height: 106))
context.setFillColor(srgb(0x1B2331))
context.fillEllipse(in: CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52))

// MARK: - Write

guard let image = context.makeImage() else { fatalError("couldn't render the icon") }
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.png")
try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("couldn't encode PNG") }
try png.write(to: output)
print("Wrote \(output.path)")
