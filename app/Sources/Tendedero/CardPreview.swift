import AppKit
import ImageIO
import SwiftUI

struct PreviewBitmap {
    let image: CGImage
    let originalPixels: CGSize

    /// Decode off the main thread. Retain original dimensions for 100% view,
    /// while bounding the one decoded preview to roughly 64 MB of RGBA pixels.
    static func read(_ url: URL) -> PreviewBitmap? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,
              let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 80_000_000 / height else { return nil }
        let ratio = min(1, sqrt(16_000_000 / (Double(width) * Double(height))))
        let longest = max(1, Int(Double(max(width, height)) * ratio))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { return nil }
        // Thumbnail transforms normalize EXIF orientation.
        let orientation = (info[kCGImagePropertyOrientation] as? Int) ?? 1
        let rotated = [5, 6, 7, 8].contains(orientation)
        return PreviewBitmap(image: image, originalPixels: CGSize(width: rotated ? height : width,
                                                                  height: rotated ? width : height))
    }
}

enum PreviewGeometry {
    static func size(content: CGSize, text: String? = nil, title: String = "", screen: CGRect) -> CGSize {
        let availableWidth = max(1, screen.width - 24)
        let availableHeight = max(1, screen.height - 48)
        if let text {
            let font = NSFont.systemFont(ofSize: 15)
            let widestLine = text.components(separatedBy: .newlines)
                .map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
            let width = min(availableWidth, min(500, max(300, widestLine + 40, titleWidth + 170)))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.lineBreakMode = .byWordWrapping
            let bounds = (text as NSString).boundingRect(
                with: CGSize(width: max(1, width - 40), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font, .paragraphStyle: paragraph])
            let bodyHeight = max(24, ceil(bounds.height) + 8)
            return CGSize(width: width, height: min(availableHeight, min(470, bodyHeight + 92)))
        }
        let width = min(availableWidth, max(380, min(840, content.width + 32)))
        let fittedHeight = max(24, content.height * max(1, width - 32) / max(1, content.width))
        let height = min(availableHeight, min(620, ceil(fittedHeight) + 126))
        return CGSize(width: width, height: height)
    }

    static func frame(size: CGSize, anchor: CGRect, screen: CGRect) -> CGRect {
        let width = min(size.width, max(1, screen.width - 24))
        let height = min(size.height, max(1, screen.height - 24))
        let x = min(screen.maxX - width - 12, max(screen.minX + 12, anchor.midX - width / 2))
        let y = min(screen.maxY - height - 12, max(screen.minY + 12, anchor.minY - height - 8))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
final class CardPreviewModel: ObservableObject {
    let title: String
    let text: String?
    @Published var image: NSImage?
    @Published var naturalSize = CGSize(width: 700, height: 450)
    @Published var loading: Bool
    @Published var failed = false
    @Published var selectedText = ""

    init(item: Pegged) {
        title = item.libraryCard?.title ?? item.url.deletingPathExtension().lastPathComponent
        text = item.libraryCard?.kind == .text ? item.libraryCard?.text : nil
        loading = text == nil
        if text == nil, item.thumb.size.width > 0, item.thumb.size.height > 0 {
            // Use the existing thumbnail's aspect ratio while the full image loads.
            naturalSize = CGSize(width: 808, height: 808 * item.thumb.size.height / item.thumb.size.width)
        }
    }
}

final class CardPreviewPanel: NSPanel {
    var onClose: () -> Void = {}
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose() }
    override var canBecomeMain: Bool { false }
}

private final class CardPreviewHost: NSHostingView<CardPreviewView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class CardPreview: NSObject, NSWindowDelegate {
    private var generation = UUID()
    private var current: Pegged?
    private var window: CardPreviewPanel?
    private var model: CardPreviewModel?
    private var anchor = CGRect.zero
    private var screen = CGRect.zero
    private var previousApp: NSRunningApplication?
    private var outsideClick: Any?
    private(set) var currentID: UUID?

    var keepsLineOpen: Bool { currentID != nil }
    var panelFrame: CGRect? { currentID == nil ? nil : window?.frame }
    var onCopy: (UUID) -> Void = { _ in }
    var onOriginal: (UUID) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    func toggle(item: Pegged, anchor: CGRect, screen: CGRect, activate: Bool = true) {
        guard !item.falling, !item.flying, !item.isRecording else { return }
        if currentID == item.id { dismiss(restoreFocus: activate); return }
        let front = NSWorkspace.shared.frontmostApplication
        let previous = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previousApp : front
        dismiss()
        previousApp = previous
        self.anchor = anchor
        self.screen = screen
        show(item, activate: activate)
    }

    /// Refresh an already open card; pointer movement can never open a preview.
    func update(item: Pegged?, anchor: CGRect?, screen: CGRect, suspended: Bool = false) {
        guard let id = currentID else { return }
        guard !suspended, let item, item.id == id, !item.falling, !item.flying, let anchor else {
            dismiss()
            return
        }
        self.anchor = anchor
        self.screen = screen
        if current?.thumb !== item.thumb {
            show(item, activate: false)
        } else { reposition() }
    }

    func dismiss(restoreFocus: Bool = false) {
        guard currentID != nil || model != nil else { return }
        let previous = previousApp
        generation = UUID()
        current = nil
        currentID = nil
        model = nil
        previousApp = nil
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        window?.orderOut(nil)
        window?.contentView = nil
        onDismiss()
        if restoreFocus { previous?.activate(options: []) }
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { dismiss() }
    }

    private func show(_ item: Pegged, activate: Bool) {
        current = item
        currentID = item.id
        let model = CardPreviewModel(item: item)
        self.model = model
        let window = self.window ?? CardPreviewPanel()
        self.window = window
        window.delegate = self
        window.onClose = { [weak self] in self?.dismiss(restoreFocus: true) }
        let view = CardPreviewView(model: model, copy: { [weak self] in
            guard let self else { return }
            if !model.selectedText.isEmpty {
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(model.selectedText, forType: .string)
            } else { self.onCopy(item.id) }
            self.dismiss(restoreFocus: true)
        }, original: { [weak self] in
            self?.dismiss()
            self?.onOriginal(item.id)
        }, close: { [weak self] in self?.dismiss(restoreFocus: true) })
        let host = CardPreviewHost(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        reposition()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        } else { window.orderFrontRegardless() }
        guard model.text == nil else { return }
        let token = UUID()
        generation = token
        let url = item.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let bitmap = PreviewBitmap.read(url)
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.currentID == item.id else { return }
                model.loading = false
                if let bitmap {
                    model.image = NSImage(cgImage: bitmap.image, size: NSSize(width: bitmap.image.width, height: bitmap.image.height))
                    model.naturalSize = bitmap.originalPixels
                } else { model.failed = true }
                self.reposition()
            }
        }
    }

    private func reposition() {
        guard let window, let model else { return }
        let size = PreviewGeometry.size(content: model.naturalSize, text: model.text, title: model.title, screen: screen)
        let frame = PreviewGeometry.frame(size: size, anchor: anchor, screen: screen)
        if window.frame != frame { window.setFrame(frame, display: true) }
    }
}

struct CardPreviewView: View {
    @ObservedObject var model: CardPreviewModel
    let copy: () -> Void
    let original: () -> Void
    var close: () -> Void = {}
    @State private var zoom: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let fitted = max(0.01, (geometry.size.width - 32) / model.naturalSize.width)
            let scale = zoom ?? fitted
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: model.text == nil ? "photo" : "text.bubble")
                        .foregroundStyle(.secondary)
                    Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Button(model.text == nil ? "复制图片" : (model.selectedText.isEmpty ? "复制全文" : "复制选中"), action: copy)
                    Button(model.text == nil ? "原图" : "查看", action: original)
                    Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭预览")
                }
                .controlSize(.small)
                if let text = model.text {
                    SelectablePreviewText(text: text, onSelection: { selected in
                        if model.selectedText != selected { model.selectedText = selected }
                    }, close: close)
                } else if let image = model.image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: model.naturalSize.width * scale, height: model.naturalSize.height * scale)
                    }
                    .id(scale)
                    HStack(spacing: 10) {
                        Button { zoom = max(0.01, scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        Text("\(Int((scale * 100).rounded()))%").monospacedDigit().frame(width: 48)
                        Button { zoom = min(max(4, fitted), scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        Spacer()
                        Button("适应宽度") { zoom = nil }
                        Button("100%") { zoom = 1 }
                    }
                    .controlSize(.small).font(.system(size: 11))
                } else {
                    Spacer()
                    if model.loading { ProgressView().controlSize(.small) }
                    else { Text("无法读取图片，可点「原图」查看。").foregroundStyle(.secondary) }
                    Spacer()
                }
                Text(model.text == nil ? "滚动查看细节；Esc 关闭。" : "选中文字后按 ⌘C 复制；Esc 关闭。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.22), lineWidth: 0.75))
            .onExitCommand(perform: close)
        }
    }
}
