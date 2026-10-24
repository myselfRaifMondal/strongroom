import AppKit

/// The menu-bar icon: the app icon's vault door (outer ring, handle wheel with
/// three spokes, hub), reduced to a monochrome template image drawn in code.
/// Unlocked: outline door. Locked: solid door with the wheel cut out.
public enum MenuBarIcon {
    public static let size = NSSize(width: 18, height: 18)

    public static func image(locked: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, rect: rect, locked: locked)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = locked ? "Strongroom (locked)" : "Strongroom (unlocked)"
        return image
    }

    static func draw(in ctx: CGContext, rect: CGRect, locked: Bool) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer: CGFloat = 8.0
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)

        if locked {
            // Solid door; the wheel is punched out of it.
            ctx.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
            ctx.fillPath()
            ctx.setBlendMode(.clear)
            // Thin gap between the ring and the door face.
            ctx.setLineWidth(0.9)
            let gap: CGFloat = 5.9
            ctx.addEllipse(in: CGRect(x: c.x - gap, y: c.y - gap, width: gap * 2, height: gap * 2))
            ctx.strokePath()
            wheel(ctx, c, radius: 3.6, lineWidth: 1.4, hub: 1.5)
            ctx.setBlendMode(.normal)
        } else {
            ctx.setLineWidth(1.5)
            let r = outer - 0.75
            ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.strokePath()
            wheel(ctx, c, radius: 4.2, lineWidth: 1.4, hub: 1.6)
        }
    }

    private static func wheel(_ ctx: CGContext, _ c: CGPoint, radius: CGFloat, lineWidth: CGFloat, hub: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: .pi / 12)
        ctx.setLineCap(.round)
        ctx.setLineWidth(lineWidth)
        for i in 0 ..< 3 {
            let a = CGFloat(i) * .pi / 3
            ctx.move(to: CGPoint(x: -cos(a) * radius, y: -sin(a) * radius))
            ctx.addLine(to: CGPoint(x: cos(a) * radius, y: sin(a) * radius))
        }
        ctx.strokePath()
        ctx.addEllipse(in: CGRect(x: -hub, y: -hub, width: hub * 2, height: hub * 2))
        ctx.fillPath()
        ctx.restoreGState()
    }
}
