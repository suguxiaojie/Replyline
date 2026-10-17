import AppKit
import SwiftUI

/// A single cached image follows the pointer at the system drag's refresh
/// rate. Keep the card's frame and shadow while its clip waits on the rope.
@MainActor enum CardDragPreview {
    static let margin: CGFloat = 18

    static func image(for item: Pegged) -> NSImage {
        image(for: face(for: item), card: PeggedView.cardSize(for: item.thumb.size))
    }

    static func face(for item: Pegged) -> NSImage {
        let renderer = ImageRenderer(content: LineCardFace(item: item))
        renderer.scale = 2
        return renderer.nsImage ?? item.thumb
    }

    static func image(for photo: NSImage) -> NSImage {
        image(for: photo, card: PeggedView.cardSize(for: photo.size))
    }

    private static func image(for photo: NSImage, card: CGSize) -> NSImage {
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
            let fit = CardGeometry.photo(photo.size, maxWidth: inner.width, maxHeight: inner.height)
            photo.draw(in: NSRect(x: inner.midX - fit.width / 2, y: inner.midY - fit.height / 2, width: fit.width, height: fit.height))
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.35).setStroke()
            frame.lineWidth = 0.75
            frame.stroke()
            NSColor.black.withAlphaComponent(0.10).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5), xRadius: Frame.radius, yRadius: Frame.radius).stroke()
            return true
        }
    }
}
