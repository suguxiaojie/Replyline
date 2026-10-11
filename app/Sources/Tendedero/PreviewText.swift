import AppKit
import SwiftUI

final class PreviewTextView: NSTextView {
    var copyPasteboard: NSPasteboard = .general
    var onClose: () -> Void = {}
    private var contentStorage: NSTextStorage?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let actualContainer = container ?? NSTextContainer(containerSize: NSSize(width: frameRect.width, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(actualContainer)
        super.init(frame: frameRect, textContainer: actualContainer)
        contentStorage = storage
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = false
        textColor = .labelColor
        font = .systemFont(ofSize: 15)
        textContainerInset = NSSize(width: 4, height: 4)
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: frameRect.width, height: .greatestFiniteMagnitude)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func copy(_ sender: Any?) {
        guard !selectedText.isEmpty else { return }
        copyPasteboard.clearContents()
        _ = writeSelection(to: copyPasteboard, types: writablePasteboardTypes)
    }

    override func cancelOperation(_ sender: Any?) { onClose() }

    var selectedText: String {
        let range = selectedRange()
        let value = string as NSString
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= value.length else { return "" }
        return value.substring(with: range)
    }

    func setContent(_ text: String) {
        guard string != text else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.lineBreakMode = .byWordWrapping
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]))
    }
}

struct SelectablePreviewText: NSViewRepresentable {
    let text: String
    let onSelection: (String) -> Void
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 24), textContainer: nil)
        view.setContent(text)
        view.onClose = close
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? PreviewTextView else { return }
        context.coordinator.onSelection = onSelection
        view.setContent(text)
        view.onClose = close
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelection: (String) -> Void
        init(onSelection: @escaping (String) -> Void) { self.onSelection = onSelection }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? PreviewTextView else { return }
            let selected = view.selectedText
            DispatchQueue.main.async { self.onSelection(selected) }
        }
    }
}
