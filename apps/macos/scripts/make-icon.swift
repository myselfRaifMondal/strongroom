// Renders the Strongroom app icon (a vault door on a midnight squircle) at
// every size macOS needs and packs it into Resources/AppIcon.icns.
//
//     swift apps/macos/scripts/make-icon.swift
//
// Drawn entirely with Core Graphics (no SF Symbols, whose licence forbids use
// in app icons). Geometry follows the macOS icon grid: 1024 canvas, 824
// content square, ~185 corner radius.
import AppKit

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
let output = here.appendingPathComponent("Resources/AppIcon.icns")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

/// Draws the icon into a 1024x1024 coordinate space (origin bottom-left).
func draw(_ ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x0B1030))
    ctx.fillPath()
    ctx.restoreGState()

    // Tile: midnight-indigo vertical gradient.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x2A3A9C), rgb(0x141B57), rgb(0x0A0E2E)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft top highlight.
    ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)]),
                           startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 900), endRadius: 520, options: [])
    ctx.restoreGState()

    let c = CGPoint(x: 512, y: 500)

    // Door: outer steel ring with a shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.45))
    ctx.addEllipse(in: CGRect(x: c.x - 300, y: c.y - 300, width: 600, height: 600))
    ctx.setFillColor(rgb(0xC9D2E3))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - 300, y: c.y - 300, width: 600, height: 600))
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xF4F7FC), rgb(0xAEB9CF), rgb(0x7E8AA6)]),
                           start: CGPoint(x: c.x - 220, y: c.y + 260), end: CGPoint(x: c.x + 220, y: c.y - 260), options: [])
    ctx.restoreGState()

    // Locking bolts around the ring.
    for i in 0..<12 {
        let a = CGFloat(i) * .pi / 6
        let p = CGPoint(x: c.x + cos(a) * 258, y: c.y + sin(a) * 258)
        ctx.addEllipse(in: CGRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34))
        ctx.setFillColor(rgb(0x5D6A88))
        ctx.fillPath()
        ctx.addEllipse(in: CGRect(x: p.x - 9, y: p.y - 13, width: 18, height: 18))
        ctx.setFillColor(rgb(0xE8EDF6, 0.85))
        ctx.fillPath()
    }

    // Inner door face (recessed).
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - 218, y: c.y - 218, width: 436, height: 436))
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x24306F), rgb(0x161E50), rgb(0x0D1336)]),
                           start: CGPoint(x: c.x, y: c.y + 218), end: CGPoint(x: c.x, y: c.y - 218), options: [])
    ctx.restoreGState()
    ctx.addEllipse(in: CGRect(x: c.x - 218, y: c.y - 218, width: 436, height: 436))
    ctx.setStrokeColor(rgb(0x0A0E2E, 0.6))
    ctx.setLineWidth(10)
    ctx.strokePath()

    // Handle wheel: three spokes through a hub, rotated slightly.
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.rotate(by: .pi / 12)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(0xE9EEF7))
    ctx.setLineWidth(34)
    for i in 0..<3 {
        let a = CGFloat(i) * .pi / 3
        ctx.move(to: CGPoint(x: cos(a) * -150, y: sin(a) * -150))
        ctx.addLine(to: CGPoint(x: cos(a) * 150, y: sin(a) * 150))
    }
    ctx.strokePath()
    // Knobs on the spoke ends.
    for i in 0..<6 {
        let a = CGFloat(i) * .pi / 3
        let p = CGPoint(x: cos(a) * 150, y: sin(a) * 150)
        ctx.addEllipse(in: CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60))
    }
    ctx.setFillColor(rgb(0xF4F7FC))
    ctx.fillPath()
    // Hub.
    ctx.addEllipse(in: CGRect(x: -62, y: -62, width: 124, height: 124))
    ctx.setFillColor(rgb(0xC9D2E3))
    ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: -30, y: -30, width: 60, height: 60))
    ctx.setFillColor(rgb(0x2A3A9C))
    ctx.fillPath()
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = gc.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx)
    gc.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try png(size: 1024).write(to: here.appendingPathComponent("Resources/AppIcon-1024.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(output.path)")
