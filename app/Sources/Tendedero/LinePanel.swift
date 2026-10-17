import AppKit

/// A transparent strip along the top of the screen that floats over every
/// app and every Space except full screen ones, never takes focus, and lets clicks pass through
/// everywhere except over the photos.
final class LinePanel: NSPanel, NSDraggingDestination {
    weak var line: Line?
    private var lastDragUpdate: TimeInterval?
    private var landingID: UUID?
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // Every Space, full screen ones included. Whether the line comes down
        // over a full screen app is up to the user, see FullScreen.showLineOver.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
        registerForDraggedTypes([CardDragWriter.type])
    }

    /// Two-finger swipes and the scroll wheel, for moving along a long line.
    var onScroll: ((NSEvent) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, let onScroll {
            onScroll(event)
        } else {
            super.sendEvent(event)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Window registration also covers gaps between cards, so crossing a gap
    // never interrupts the native drag or makes the line stop accepting it.
    private func localCard(_ sender: NSDraggingInfo) -> UUID? {
        guard let source = sender.draggingSource as? GrabView,
              let value = sender.draggingPasteboard.string(forType: CardDragWriter.type),
              let id = UUID(uuidString: value), source.cardID == id,
              line?.draggingID == id,
              NSRect(origin: .zero, size: frame.size).contains(sender.draggingLocation) else { return nil }
        return id
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        lastDragUpdate = nil
        return draggingUpdated(sender)
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = localCard(sender), let line else { return [] }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastDragUpdate.map { now - $0 } ?? 0
        lastDragUpdate = now
        line.scroll(by: Layout.reorderScrollDelta(pointerX: sender.draggingLocation.x,
                                                 width: frame.width, elapsed: elapsed))
        return line.updateReordering(id, pointerX: sender.draggingLocation.x, width: frame.width) ? .move : []
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        lastDragUpdate = nil
        line?.leaveReordering()
    }

    func wantsPeriodicDraggingUpdates() -> Bool { true }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard localCard(sender) != nil else { return false }
        sender.animatesToDestination = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return true
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = localCard(sender), let line,
              line.updateReordering(id, pointerX: sender.draggingLocation.x, width: frame.width) else { return false }
        if let host = contentView, let index = line.items.firstIndex(where: { $0.id == id }) {
            let card = line.items[index]
            let x = Layout.x(index: index, count: line.items.count, width: frame.width,
                             visible: line.visibleCount, scroll: line.scroll, fixedCards: line.hasLibraryItems)
            let size = PeggedView.cardSize(for: card.thumb.size)
            let top = Layout.ropeY(x: x, width: frame.width) - Layout.pinAbove
                + PeggedView.cardOffsetBelowTop
                + (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 8)
            let rect = NSRect(x: x - size.width / 2, y: frame.height - top - size.height,
                              width: size.width, height: size.height)
                .insetBy(dx: -CardDragPreview.margin, dy: -CardDragPreview.margin)
            let landing = host.convert(rect, from: nil)
            let preview = (sender.draggingSource as? GrabView)?.liftedDragImage ?? CardDragPreview.image(for: card)
            sender.enumerateDraggingItems(options: [], for: host, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                item.setDraggingFrame(landing, contents: preview)
            }
        }
        lastDragUpdate = nil
        let accepted = line.commitReordering(id)
        if accepted { landingID = id; line.awaitReorderLanding(id) }
        return accepted
    }

    func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        guard let id = landingID else { return }
        landingID = nil
        line?.completeReorderLanding(id)
        contentView?.layoutSubtreeIfNeeded()
        contentView?.displayIfNeeded()
    }

    /// The line hangs on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let visible = (screen ?? LinePanel.screenUnderPointer())?.visibleFrame else { return }
        let target = NSRect(x: visible.minX, y: visible.maxY - Layout.panelHeight,
                            width: visible.width, height: Layout.panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
}
