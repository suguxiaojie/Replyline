import AppKit

/// A single cached image follows the pointer at the system drag's refresh
/// rate. Keep the card's frame and shadow while its clip waits on the rope.
@MainActor enum CardDragPreview {
    static let margin: CGFloat = 18

    static func image(for photo: NSImage) -> NSImage {
        let card = PeggedView.cardSize(for: photo.size)
        let size = NSSize(width: card.width + margin * 2, height: card.height + margin * 2)
        return NSImage(size: size, flipped: false) { _ in
            let rect = NSRect(origin: NSPoint(x: margin, y: margin), size: card)
            let frame = NSBezierPath(roundedRect: rect, xRadius: Frame.radius, yRadius: Frame.radius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.set()
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            frame.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            let inner = rect.insetBy(dx: Frame.inset, dy: Frame.inset)
            NSBezierPath(roundedRect: inner, xRadius: Frame.radius - Frame.inset,
                         yRadius: Frame.radius - Frame.inset).addClip()
            photo.draw(in: inner)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.55).setStroke()
            frame.lineWidth = 0.75
            frame.stroke()
            return true
        }
    }
}
