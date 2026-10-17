import AppKit
import SwiftUI
import XCTest
@testable import Tendedero

final class PreviewInteractionTests: XCTestCase {
    func testSelectionUpdatesPreviewCopyMode() async throws {
        let part = "第一步：打开设置。"
        let fixture = try await MainActor.run { () -> (CardPreviewModel, NSHostingView<CardPreviewView>, CardPreviewPanel) in
            let text = "您好，以下是操作步骤：\n\(part)\n第二步：选择订阅。"
            let card = LibraryCard(id: UUID(), kind: .text, title: "操作指引", keywords: "", text: text,
                                   asset: "sample.txt", pinned: true, createdAt: Date(), updatedAt: Date())
            var item = Pegged(url: URL(fileURLWithPath: "/nonexistent/sample.txt"), thumb: NSImage(size: NSSize(width: 320, height: 220)))
            item.libraryCard = card
            let model = CardPreviewModel(item: item)
            let host = NSHostingView(rootView: CardPreviewView(model: model, copy: {}, original: {}))
            let size = PreviewGeometry.size(content: .zero, text: text, title: card.title,
                                            screen: CGRect(x: -12000, y: -12000, width: 1440, height: 900))
            host.frame = NSRect(origin: .zero, size: size)
            let panel = CardPreviewPanel()
            panel.setFrame(NSRect(origin: NSPoint(x: -12000, y: -12000), size: size), display: false)
            panel.contentView = host
            host.layoutSubtreeIfNeeded()
            @MainActor func find(_ view: NSView) -> PreviewTextView? {
                if let text = view as? PreviewTextView { return text }
                return view.subviews.compactMap(find).first
            }
            let view = try XCTUnwrap(find(host))
            view.setSelectedRange((text as NSString).range(of: part))
            return (model, host, panel)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        try await MainActor.run {
            defer { fixture.2.close() }
            XCTAssertEqual(fixture.0.selectedText, part)
            fixture.1.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(fixture.1.bitmapImageRepForCachingDisplay(in: fixture.1.bounds))
            fixture.1.cacheDisplay(in: fixture.1.bounds, to: bitmap)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let directory = root.appendingPathComponent(".tmp/click-preview")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("selected-text.png"))
        }
    }

    func testReadonlyTextWrapsToPreviewWidthAndLongContentScrolls() async throws {
        try await MainActor.run {
            let text = String(repeating: "这是很长的操作指引，需要在预览宽度内自动换行。", count: 20)
            let host = NSHostingView(rootView: SelectablePreviewText(text: text, onSelection: { _ in }, close: {}))
            host.frame = NSRect(x: 0, y: 0, width: 268, height: 100)
            let panel = CardPreviewPanel()
            panel.setFrame(NSRect(x: -12000, y: -12000, width: 268, height: 100), display: false)
            panel.contentView = host
            defer { panel.close() }
            host.layoutSubtreeIfNeeded()
            @MainActor func find(_ view: NSView) -> PreviewTextView? {
                if let text = view as? PreviewTextView { return text }
                return view.subviews.compactMap(find).first
            }
            let view = try XCTUnwrap(find(host))
            let container = try XCTUnwrap(view.textContainer)
            view.layoutManager?.ensureLayout(for: container)
            XCTAssertLessThanOrEqual(view.frame.width, 269)
            XCTAssertLessThanOrEqual(container.containerSize.width, 269)
            XCTAssertGreaterThan(view.frame.height, 100)
            XCTAssertEqual(view.string, text)
        }
    }

    func testOnlySelectedTextIsCopiedAndSourceCannotBeEdited() async {
        await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let view = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 160), textContainer: nil)
            view.copyPasteboard = board
            let text = "您好，以下是操作步骤：\n第一步：打开设置。\n第二步：选择订阅。🙂"
            view.setContent(text)
            let part = "第一步：打开设置。"
            view.setSelectedRange((text as NSString).range(of: part))
            XCTAssertEqual(view.selectedText, part)
            XCTAssertTrue(view.isSelectable)
            XCTAssertFalse(view.isEditable)
            view.copy(nil)
            XCTAssertEqual(board.string(forType: .string), part)
            XCTAssertEqual(view.string, text)
            XCTAssertFalse(view.validateUserInterfaceItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")))
            XCTAssertFalse(view.validateUserInterfaceItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")))
            view.setSelectedRange(NSRange(location: 0, length: 0))
            XCTAssertEqual(view.selectedText, "")
        }
    }

    func testCommandCCopiesPartialTextThroughApplicationMenu() async throws {
        try await MainActor.run {
            let app = NSApplication.shared
            let oldMenu = app.mainMenu
            let oldWindow = app.keyWindow
            let panel = CardPreviewPanel()
            panel.setFrame(NSRect(x: -12000, y: -12000, width: 350, height: 160), display: false)
            let text = "复制其中一段，剩余内容保留。"
            let view = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 350, height: 160), textContainer: nil)
            view.setContent(text)
            let board = NSPasteboard.withUniqueName()
            view.copyPasteboard = board
            panel.contentView = view
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
            defer {
                panel.close()
                oldWindow?.makeKey()
                app.mainMenu = oldMenu
                board.releaseGlobally()
            }
            ApplicationMenu.install(on: app)
            view.setSelectedRange((text as NSString).range(of: "其中一段"))
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                      timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                      characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
            XCTAssertTrue(app.mainMenu!.performKeyEquivalent(with: event))
            XCTAssertEqual(board.string(forType: .string), "其中一段")
            XCTAssertEqual(view.string, text)
        }
    }

    func testPreviewCornerClickDoesNotCopyDiscardOrStartDrag() async throws {
        try await MainActor.run {
            let panel = NSPanel(contentRect: NSRect(x: -12000, y: -12000, width: 150, height: 100),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            defer { panel.close() }
            let view = GrabView(frame: NSRect(x: 0, y: 0, width: 150, height: 100))
            panel.contentView = view
            var previews = 0
            var copies = 0
            var discards = 0
            var drags = 0
            view.onPreview = { previews += 1 }
            view.onClick = { copies += 1 }
            view.onDiscard = { discards += 1 }
            view.onDragStart = { drags += 1 }
            @MainActor func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 140, y: 90),
                                                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                                context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            }
            view.mouseDown(with: try event(.leftMouseDown))
            view.mouseDragged(with: try event(.leftMouseDragged))
            view.mouseUp(with: try event(.leftMouseUp))
            XCTAssertEqual(previews, 1)
            XCTAssertEqual(copies, 0)
            XCTAssertEqual(discards, 0)
            XCTAssertEqual(drags, 0)
            view.frame.size.width = 30
            XCTAssertNil(view.cornerAction(at: NSPoint(x: 5, y: 90)))
            XCTAssertEqual(view.cornerAction(at: NSPoint(x: 25, y: 90)), .preview)
            XCTAssertNil(view.cornerAction(at: NSPoint(x: 15, y: 20)))
        }
    }
}
