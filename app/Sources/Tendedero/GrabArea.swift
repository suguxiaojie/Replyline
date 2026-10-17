import AppKit
import SwiftUI

/// Bridges each photo to AppKit's drag and drop, so it can be dragged into
/// any app as a real file. Each destination means one thing:
///
/// - The line rearranges the card without moving its file.
/// - An app gets a copy, and the photo stays on the line.
/// - A folder or the Desktop keeps the file, and the photo leaves the line.
/// - The Trash discards it.
/// - Nowhere that accepts it: the photo flies back to the line.
///
/// Click copies, press and hold opens Markup, the corner cross discards.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line
    var discardVisible = false
    var onCornerPress: (GrabView.CornerAction?) -> Void = { _ in }

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        let isRecording = item.isRecording
        view.url = item.url
        view.copyOnly = item.isLibraryItem
        view.text = item.libraryCard?.kind == .text ? item.libraryCard?.text : nil
        view.dragImage = item.thumb
        view.dragCard = item
        view.discardVisible = discardVisible
        view.onCornerPressChange = onCornerPress
        view.cardID = id
        view.previewAtCenter = item.isRecording
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(item.libraryCard?.title ?? item.url.deletingPathExtension().lastPathComponent)
        view.setAccessibilityValue(item.isLibraryItem ? "固定\(item.libraryCard?.kind.label ?? "素材")" : "临时卡片")
        view.setAccessibilityHelp("点按复制，使用预览操作查看详情。")
        view.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: item.isRecording ? "播放视频" : "预览") { [weak view] in
                guard let view else { return false }; view.onPreview(); return true
            },
            NSAccessibilityCustomAction(name: item.isLibraryItem ? "从晾衣架取下，保留素材" : "取下卡片") { [weak view] in
                guard let view else { return false }; view.onDiscard(); return true
            },
        ])
        view.onClick = { line.noteInteraction(); line.copy(id) }
        view.onDoubleClick = { line.open(id) }
        view.onDragStart = { [weak view] in
            guard let view, let window = view.window else { return }
            line.beginReordering(id, pointerX: view.dragStartX, width: window.frame.width)
        }
        view.onDragEnd = {
            line.finishReordering(id)
            // Moved into a folder: it is saved where you wanted it.
            line.prune()
        }
        view.onFileMove = { line.prune() }
        view.onTrash = { line.trash(id) }
        view.onDiscard = { line.discard(id) }
        view.onLongPress = { line.markup(id) }
        view.onForceClick = { line.quickLook(id) }
        view.onPreview = { line.onPreview(id) }
        view.onPressChange = { pressed in line.pressedID = pressed ? id : nil }
        view.menuProvider = {
            let menu = NSMenu()
            // Items say themselves whether they can be used.
            menu.autoenablesItems = false
            menu.addItem(ClosureMenuItem(L("Copy")) { line.copy(id) })
            if item.isLibraryItem {
                if item.libraryCard?.kind == .image {
                    menu.addItem(ClosureMenuItem(L("Open")) { line.open(id) })
                    menu.addItem(ClosureMenuItem(L("Quick Look")) { line.quickLook(id) })
                    menu.addItem(ClosureMenuItem(L("Markup")) { line.markup(id) })
                    menu.addItem(ClosureMenuItem(L("Show in Finder")) { line.reveal(id) })
                    menu.addItem(.separator())
                }
                if item.libraryCard?.kind == .video {
                    menu.addItem(ClosureMenuItem("播放视频…") { line.quickLook(id) })
                    menu.addItem(ClosureMenuItem(L("Open")) { line.open(id) })
                    menu.addItem(ClosureMenuItem(L("Show in Finder")) { line.reveal(id) })
                    menu.addItem(.separator())
                }
                menu.addItem(ClosureMenuItem("编辑素材…") { line.manageLibrary(id) })
                menu.addItem(ClosureMenuItem("从绳上取下，保留素材") { line.discard(id) })
                return menu
            }
            menu.addItem(ClosureMenuItem(L("Open")) { line.open(id) })
            menu.addItem(ClosureMenuItem(L("Quick Look")) { line.quickLook(id) })
            if !isRecording {
                menu.addItem(ClosureMenuItem(L("Markup")) { line.markup(id) })
                menu.addItem(ClosureMenuItem("转为常用素材…") { line.keepInLibrary(id) })
            }
            menu.addItem(ClosureMenuItem(L("Show in Finder")) { line.reveal(id) })
            let inInbox = line.isInInbox(id)
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Save to Desktop")) { line.saveToDesktop(id) })
            }
            menu.addItem(.separator())
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Discard")) { line.discard(id) })
            } else {
                menu.addItem(ClosureMenuItem(L("Take down")) { line.discard(id) })
                menu.addItem(ClosureMenuItem(L("Move to Trash")) { line.trash(id) })
            }
            let left = ClosureMenuItem(L("Take down everything to the left")) { line.takeDown(id, toTheLeft: true) }
            left.isEnabled = !line.neighbours(of: id, toTheLeft: true).isEmpty
            menu.addItem(left)
            let right = ClosureMenuItem(L("Take down everything to the right")) { line.takeDown(id, toTheLeft: false) }
            right.isEnabled = !line.neighbours(of: id, toTheLeft: false).isEmpty
            menu.addItem(right)
            return menu
        }
    }
}

final class GrabView: NSView, NSDraggingSource {
    static var isDragging = false
    /// A photo's menu is open. It reaches past the line, so the line waits.
    static var isShowingMenu = false

    var url: URL?
    var copyOnly = false
    var text: String?
    var dragImage: NSImage?
    var dragCard: Pegged?
    var discardVisible = false
    private(set) var liftedDragImage: NSImage?
    var cardID: UUID?
    var previewAtCenter = false
    private(set) var dragStartX: CGFloat = 0
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onFileMove: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onForceClick: () -> Void = {}
    var onPreview: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var onCornerPressChange: (CornerAction?) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var holdTimer: Timer?
    private var didLongPress = false
    private var pendingCorner: CornerAction?
    private var cornerGesture = false

    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    /// The discard cross drawn in the top left corner of the card. It is
    /// handled here because this view sits on top of the SwiftUI card.
    static let crossHitSize = CardGeometry.corner

    enum CornerAction { case discard, preview, playback }

    func cornerAction(at point: NSPoint) -> CornerAction? {
        guard bounds.contains(point) else { return nil }
        if discardVisible, bounds.width >= CardGeometry.minimum.width,
           CardGeometry.cornerRect(in: bounds, trailing: false, flipped: isFlipped).contains(point) { return .discard }
        if CardGeometry.cornerRect(in: bounds, trailing: true, flipped: isFlipped).contains(point) { return .preview }
        if previewAtCenter, NSRect(x: bounds.midX - 14, y: bounds.midY - 14, width: 28, height: 28).contains(point) { return .playback }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        pendingCorner = nil
        cornerGesture = false
        if let corner = cornerAction(at: convert(event.locationInWindow, from: nil)) {
            endPress()
            downPoint = event.locationInWindow
            startedDrag = false
            didLongPress = false
            cornerGesture = corner != .playback
            pendingCorner = event.clickCount == 1 ? corner : nil
            onCornerPressChange(pendingCorner)
            return
        }
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick()
            return
        }
        downPoint = event.locationInWindow
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    /// A force click on a trackpad opens Quick Look, as it does in Finder.
    /// It counts instead of the click and of a long press.
    override func pressureChange(with event: NSEvent) {
        guard event.stage == 2, downPoint != nil, !startedDrag, !didLongPress, pendingCorner == nil, !cornerGesture else { return }
        didLongPress = true
        endPress()
        onForceClick()
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        if cornerGesture {
            if cornerAction(at: convert(event.locationInWindow, from: nil)) != pendingCorner {
                pendingCorner = nil
                onCornerPressChange(nil)
            }
            return
        }
        guard let start = downPoint, !startedDrag, let url else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, !didLongPress else { return }
        startedDrag = true
        pendingCorner = nil
        onCornerPressChange(nil)
        endPress()

        let payload: NSPasteboardWriting = text.map { $0 as NSString } ?? (url as NSURL)
        let writer: NSPasteboardWriting = cardID.map { CardDragWriter(id: $0, payload: payload) } ?? payload
        let item = NSDraggingItem(pasteboardWriter: writer)
        liftedDragImage = dragCard.map(CardDragPreview.image) ?? dragImage.map(CardDragPreview.image)
        let previewFrame = liftedDragImage == nil ? bounds : bounds.insetBy(dx: -CardDragPreview.margin, dy: -CardDragPreview.margin)
        item.setDraggingFrame(previewFrame, contents: liftedDragImage ?? dragImage)
        dragStartX = start.x
        GrabView.isDragging = true
        onDragStart()
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        let point = convert(event.locationInWindow, from: nil)
        if downPoint != nil && !startedDrag && !didLongPress && event.clickCount == 1 && bounds.contains(point) {
            if let corner = pendingCorner, cornerAction(at: point) == corner {
                if corner == .discard { onDiscard() } else { onPreview() }
            } else if !cornerGesture && pendingCorner == nil { onClick() }
        }
        pendingCorner = nil
        cornerGesture = false
        onCornerPressChange(nil)
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        endPress()
        downPoint = nil
        pendingCorner = nil
        cornerGesture = false
        onCornerPressChange(nil)
        // The menu runs until it closes, and the line stays down meanwhile.
        GrabView.isShowingMenu = true
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
        GrabView.isShowingMenu = false
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Apps pick copy. Finder picks move, so a folder or the Desktop keeps
        // the file. Delete is what lets the Dock's Trash accept it.
        allowedOperations(outsideApp: context == .outsideApplication)
    }

    func allowedOperations(outsideApp: Bool) -> NSDragOperation {
        guard outsideApp else { return [.move] }
        return copyOnly ? [.copy] : [.copy, .move, .delete]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false
        startedDrag = false
        downPoint = nil
        liftedDragImage = nil
        log.notice("Drag ended with operation \(operation.rawValue, privacy: .public)")
        // Dropped on the Trash: macOS only tells us, we move the file.
        if operation.contains(.delete) && !copyOnly {
            onDragEnd()
            onTrash()
            return
        }
        onDragEnd()
        // Finder finishes a move a moment later. Check again then, so a photo
        // saved into a folder leaves the line.
        if operation.contains(.move) {
            let done = onFileMove
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
        }
    }

}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
