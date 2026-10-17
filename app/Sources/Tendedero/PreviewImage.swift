import AppKit
import SwiftUI

struct PreviewZoomAnchor {
    var image: CGPoint
    var viewport: CGPoint = CGPoint(x: 0.5, y: 0.5)
}

enum PreviewZoomGeometry {
    static func layout(natural: CGSize, scale: CGFloat, viewport: CGSize, anchor: PreviewZoomAnchor?) -> (image: CGRect, document: CGSize, offset: CGPoint) {
        let size = CGSize(width: max(1, natural.width * scale), height: max(1, natural.height * scale))
        let document = CGSize(width: max(size.width, viewport.width), height: max(size.height, viewport.height))
        let image = CGRect(x: (document.width - size.width) / 2, y: (document.height - size.height) / 2,
                           width: size.width, height: size.height)
        guard let anchor else { return (image, document, .zero) }
        let x = image.minX + anchor.image.x * size.width - anchor.viewport.x * viewport.width
        let y = image.minY + anchor.image.y * size.height - anchor.viewport.y * viewport.height
        return (image, document, CGPoint(x: min(max(0, x), max(0, document.width - viewport.width)),
                                        y: min(max(0, y), max(0, document.height - viewport.height))))
    }
}

struct SelectablePreviewImage: NSViewRepresentable {
    let image: NSImage
    let naturalSize: CGSize
    let scale: CGFloat
    let scaleChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> PreviewImageScrollView {
        let view = PreviewImageScrollView()
        view.scaleChanged = scaleChanged
        view.update(image: image, natural: naturalSize, scale: scale)
        return view
    }
    func updateNSView(_ view: PreviewImageScrollView, context: Context) {
        view.scaleChanged = scaleChanged
        view.update(image: image, natural: naturalSize, scale: scale)
    }
}

/// Keep a single native scroll view while zoom changes. Its anchor is an
/// image coordinate, not a stale point in the old scrollable document.
final class PreviewImageScrollView: NSScrollView {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let canvas = Document()
    private let picture = NSImageView()
    private var natural = CGSize(width: 1, height: 1)
    private(set) var imageScale: CGFloat = 1
    private var lastViewport = CGSize.zero
    private var layingOut = false
    var scaleChanged: (CGFloat) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = true; hasHorizontalScroller = true
        autohidesScrollers = true
        picture.imageScaling = .scaleAxesIndependently
        picture.setAccessibilityLabel("图片预览")
        canvas.addSubview(picture)
        documentView = canvas
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(image: NSImage, natural: CGSize, scale: CGFloat) {
        let changedImage = picture.image !== image
        let anchor = changedImage ? nil : currentAnchor()
        picture.image = image
        self.natural = natural
        imageScale = max(0.01, scale)
        arrange(anchor: anchor)
    }

    override func layout() {
        super.layout()
        guard !layingOut, contentView.bounds.size != lastViewport else { return }
        arrange(anchor: lastViewport == .zero ? nil : currentAnchor(viewport: lastViewport))
    }

    func currentAnchor(viewport: CGSize? = nil, at point: CGPoint? = nil) -> PreviewZoomAnchor? {
        guard picture.image != nil, picture.frame.width > 0, picture.frame.height > 0 else { return nil }
        let size = viewport ?? contentView.bounds.size
        let location = point ?? CGPoint(x: size.width / 2, y: size.height / 2)
        return PreviewZoomAnchor(image: CGPoint(x: (contentView.bounds.minX + location.x - picture.frame.minX) / picture.frame.width,
                                               y: (contentView.bounds.minY + location.y - picture.frame.minY) / picture.frame.height),
                                 viewport: CGPoint(x: location.x / max(1, size.width), y: location.y / max(1, size.height)))
    }

    private func arrange(anchor: PreviewZoomAnchor?) {
        guard !layingOut, contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }
        layingOut = true
        defer { layingOut = false }
        let geometry = PreviewZoomGeometry.layout(natural: natural, scale: imageScale, viewport: contentView.bounds.size, anchor: anchor)
        canvas.setFrameSize(geometry.document)
        picture.frame = geometry.image
        contentView.scroll(to: geometry.offset)
        reflectScrolledClipView(contentView)
        lastViewport = contentView.bounds.size
    }

    override func magnify(with event: NSEvent) {
        let point = contentView.convert(event.locationInWindow, from: nil)
        let inViewport = CGPoint(x: point.x - contentView.bounds.minX, y: point.y - contentView.bounds.minY)
        guard let anchor = currentAnchor(at: inViewport) else { return }
        let fitted = contentView.bounds.width / max(1, natural.width)
        imageScale = min(max(4, fitted), max(0.01, imageScale * (1 + event.magnification)))
        arrange(anchor: anchor)
        scaleChanged(imageScale)
    }
}
