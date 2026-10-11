import AppKit
import SwiftUI

@MainActor
enum NativeGlass {
    /// Uses the same clear glass + neutral chrome composition as Codex Monitor.
    static func host<Content: View>(_ content: Content, material: NSVisualEffectView.Material,
                                    cornerRadius: CGFloat = 18) -> NativeGlassSurface {
        let host = NSHostingView(rootView: content)
        return NativeGlassSurface(content: host, material: material, cornerRadius: cornerRadius)
    }
}

@MainActor
final class NativeGlassSurface: NSView {
    private let content: NSView
    private let material: NSVisualEffectView.Material
    private let radius: CGFloat
    private var accessibilityObserver: NSObjectProtocol?
    private(set) var surface: NSView!

    init(content: NSView, material: NSVisualEffectView.Material, cornerRadius: CGFloat) {
        self.content = content
        self.material = material
        radius = cornerRadius
        super.init(frame: .zero)
        installSurface()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.installSurface() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    override var isOpaque: Bool { false }
    override func layout() { super.layout(); surface.frame = bounds }

    private func installSurface() {
        content.removeFromSuperview()
        surface?.removeFromSuperview()
        let composition = GlassComposition(content: content, radius: radius)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView(frame: bounds)
            solid.wantsLayer = true
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            solid.addSubview(content)
            content.frame = solid.bounds
            content.autoresizingMask = [.width, .height]
            surface = solid
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .clear
            glass.tintColor = .clear
            glass.cornerRadius = radius
            glass.contentView = composition
            composition.frame = glass.bounds
            composition.autoresizingMask = [.width, .height]
            surface = glass
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = material
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.addSubview(composition)
            composition.frame = effect.bounds
            composition.autoresizingMask = [.width, .height]
            surface = effect
        }
        surface.wantsLayer = true
        surface.layer?.cornerRadius = radius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        needsLayout = true
    }
}

private final class GlassComposition: NSView {
    private let chrome: GlassChrome
    private let content: NSView

    init(content: NSView, radius: CGFloat) {
        self.content = content
        chrome = GlassChrome(radius: radius)
        super.init(frame: .zero)
        addSubview(chrome)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func layout() {
        super.layout()
        chrome.frame = bounds
        content.frame = bounds
    }
}

private final class GlassChrome: NSView {
    let radius: CGFloat
    init(radius: CGFloat) { self.radius = radius; super.init(frame: .zero) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let light = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        (light ? NSColor.white : NSColor.black).withAlphaComponent(light ? 0.90 : 0.88).setFill()
        shape.fill()
        (light ? NSColor.black : NSColor.white).withAlphaComponent(0.09).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }
}
