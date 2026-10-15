import AppKit
import SwiftUI
import XCTest
@testable import Tendedero

private final class ReorderDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
}

final class CardReorderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        folder = root.appendingPathComponent(".tmp/card-reorder/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func image(_ name: String) throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let color = NSColor(deviceRed: 0.15, green: 0.60, blue: 0.65, alpha: 1)
        for x in 0..<4 { for y in 0..<4 { rep.setColor(color, atX: x, y: y) } }
        let url = folder.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    @MainActor private func center(_ line: Line, _ index: Int, width: CGFloat = 1400) -> CGFloat {
        Layout.x(index: index, count: line.items.count, width: width,
                 visible: line.visibleCount, scroll: line.scroll, fixedCards: line.hasLibraryItems)
    }

    func testMixedOrderSurvivesRestartAndLibraryEdits() async throws {
        let source = try image("capture.png")
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        let text = try store.addText(title: "话术", text: "您好\n请打开设置")
        try store.addImage(source: source, title: "截图")
        try await MainActor.run {
            let defaults = ReorderDefaults()
            let library = LibraryModel(folder: store.folder)
            let line = Line(library: library, defaults: defaults, breeze: false)
            library.onChange = { line.syncLibrary() }
            let temporary = try XCTUnwrap(line.hang(source, quietly: true))
            let original = line.items.map(\.id)
            line.beginReordering(temporary, pointerX: center(line, 0), width: 1400)
            XCTAssertTrue(line.updateReordering(temporary, pointerX: center(line, 2), width: 1400))
            XCTAssertEqual(line.items.map(\.id), Array(original.dropFirst()) + [temporary])
            XCTAssertTrue(line.commitReordering(temporary))
            line.finishReordering(temporary)
            let expected = line.items.map(\.orderKey)
            XCTAssertTrue(library.perform { try $0.update(text.id, title: "更新话术", text: "新内容", keywords: "", pinned: true) })
            XCTAssertEqual(line.items.map(\.orderKey), expected)
            let restored = Line(library: library, defaults: defaults, breeze: false)
            XCTAssertEqual(restored.items.map(\.orderKey), expected)
            // A fixed text card can move across both kinds of image card.
            let index = try XCTUnwrap(restored.items.firstIndex { $0.libraryCard?.kind == .text })
            let fixed = restored.items[index]
            restored.beginReordering(fixed.id, pointerX: center(restored, index), width: 1400)
            restored.updateReordering(fixed.id, pointerX: center(restored, 2), width: 1400)
            XCTAssertTrue(restored.commitReordering(fixed.id))
            XCTAssertEqual(restored.items.last?.id, fixed.id)
            restored.finishReordering(fixed.id)
            XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: store.assetURL(for: store.cards.first { $0.kind == .image }!)))
        }
    }

    func testCancelAndDragExitRestoreOrderWithoutLosingConcurrentChanges() async throws {
        let urls = try (0..<4).map { try image("\($0).png") }
        try await MainActor.run {
            let defaults = ReorderDefaults()
            let line = Line(defaults: defaults, breeze: false)
            let ids = try urls.prefix(3).map { try XCTUnwrap(line.hang($0, quietly: true)) }
            line.beginReordering(ids[0], pointerX: center(line, 0), width: 1400)
            line.updateReordering(ids[0], pointerX: center(line, 2), width: 1400)
            // A capture during the drag saves the baseline, not the preview.
            let added = try XCTUnwrap(line.hang(urls[3], quietly: true))
            XCTAssertEqual(Line(defaults: defaults, breeze: false).items.map(\.url), urls)
            line.drop(ids[1], quietly: true)
            line.leaveReordering()
            XCTAssertEqual(line.items.filter { !$0.falling }.map(\.id), [ids[0], ids[2], added])
            XCTAssertEqual(line.draggingID, ids[0])
            line.updateReordering(ids[0], pointerX: center(line, line.items.count - 1), width: 1400)
            line.finishReordering(ids[0])
            XCTAssertNil(line.draggingID)
            XCTAssertEqual(line.items.filter { !$0.falling }.map(\.id), [ids[0], ids[2], added])
            XCTAssertFalse(line.commitReordering(ids[0]))
        }
    }

    func testEvictionKeepsArrivalOrderAfterReorderAndRestart() async throws {
        let urls = try (0..<3).map { try image("\($0).png") }
        try await MainActor.run {
            let defaults = ReorderDefaults()
            let line = Line(defaults: defaults, breeze: false)
            let first = try XCTUnwrap(line.hang(urls[0], quietly: true))
            line.hang(urls[1], quietly: true)
            line.beginReordering(first, pointerX: center(line, 0), width: 1400)
            line.updateReordering(first, pointerX: center(line, 1), width: 1400)
            XCTAssertTrue(line.commitReordering(first))
            line.finishReordering(first)
            XCTAssertEqual(defaults.stringArray(forKey: "pegged"), Array(urls.prefix(2)).map(\.path))
            let restored = Line(defaults: defaults, breeze: false)
            XCTAssertEqual(restored.items.map(\.url), [urls[1], urls[0]])
            restored.maxItems = 2
            restored.hang(urls[2], quietly: true)
            XCTAssertTrue(try XCTUnwrap(restored.items.first { $0.url == urls[0] }).falling)
            restored.maxItems = 1
            restored.trim()
            XCTAssertEqual(restored.items.filter { !$0.falling }.map(\.url), [urls[2]])
            for url in urls { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        }
    }

    func testGrabOffsetAndMidpointDeadBandPreventJitter() async throws {
        let urls = try (0..<2).map { try image("\($0).png") }
        try await MainActor.run {
            let line = Line(defaults: ReorderDefaults(), breeze: false)
            let ids = try urls.map { try XCTUnwrap(line.hang($0, quietly: true)) }
            let offset: CGFloat = 46
            let start = center(line, 0), end = center(line, 1), middle = (start + end) / 2
            line.beginReordering(ids[0], pointerX: start + offset, width: 1400)
            line.updateReordering(ids[0], pointerX: start + offset, width: 1400)
            XCTAssertEqual(line.items.map(\.id), ids)
            line.updateReordering(ids[0], pointerX: middle + offset + 1, width: 1400)
            XCTAssertEqual(line.items.map(\.id), ids)
            line.updateReordering(ids[0], pointerX: middle + offset + 8, width: 1400)
            XCTAssertEqual(line.items.map(\.id), ids.reversed())
            for delta in [-1.0, 1, -2, 2] {
                line.updateReordering(ids[0], pointerX: middle + offset + delta, width: 1400)
                XCTAssertEqual(line.items.map(\.id), ids.reversed())
            }
            line.finishReordering(ids[0])
            XCTAssertEqual(line.items.map(\.id), ids)
        }
    }

    func testInvalidOrRemovedSourceCannotCommitAndSingleCardIsNoOp() async throws {
        let url = try image("one.png")
        try await MainActor.run {
            let line = Line(defaults: ReorderDefaults(), breeze: false)
            let id = try XCTUnwrap(line.hang(url, quietly: true))
            line.beginReordering(UUID(), pointerX: 700, width: 1400)
            XCTAssertNil(line.draggingID)
            XCTAssertFalse(line.updateReordering(id, pointerX: 300, width: 1400))
            line.beginReordering(id, pointerX: 700, width: 1400)
            XCTAssertFalse(line.updateReordering(id, pointerX: .nan, width: 1400))
            XCTAssertFalse(line.updateReordering(id, pointerX: 700, width: 0))
            XCTAssertTrue(line.updateReordering(id, pointerX: 30, width: 1400))
            XCTAssertEqual(line.items.map(\.id), [id])
            line.finishReordering(UUID())
            XCTAssertEqual(line.draggingID, id)
            line.drop(id, quietly: true)
            XCTAssertFalse(line.commitReordering(id))
            line.finishReordering(id)
            XCTAssertEqual(line.liveCount, 0)
        }
    }

    func testLegacyRestoreAndDuplicateOrStaleSavedKeysAreSafe() async throws {
        let urls = try (0..<2).map { try image("\($0).png") }
        await MainActor.run {
            let defaults = ReorderDefaults()
            defaults.set(urls.map(\.path), forKey: "pegged")
            let legacy = Line(defaults: defaults, breeze: false)
            XCTAssertEqual(legacy.items.map(\.url), urls)
            let key = legacy.items[1].orderKey
            defaults.set(["library:missing", key, key, legacy.items[0].orderKey], forKey: "lineCardOrder")
            XCTAssertEqual(Line(defaults: defaults, breeze: false).items.map(\.url), urls.reversed())
        }
    }

    func testDragPasteboardRetainsFileAndTextFormats() async throws {
        let url = try image("source.png")
        await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let id = UUID()
            XCTAssertTrue(board.writeObjects([CardDragWriter(id: id, payload: url as NSURL)]))
            XCTAssertEqual(board.string(forType: CardDragWriter.type), id.uuidString)
            XCTAssertEqual((board.readObjects(forClasses: [NSURL.self]) as? [URL]), [url])
            board.clearContents()
            let text = "您好\n这是独立话术 🙂"
            XCTAssertTrue(board.writeObjects([CardDragWriter(id: id, payload: text as NSString)]))
            XCTAssertEqual(board.string(forType: .string), text)
            XCTAssertEqual(board.string(forType: CardDragWriter.type), id.uuidString)
            XCTAssertNil(board.string(forType: .fileURL))
        }
    }

    func testClipOpensWithinSameLayoutAndLiftedPreviewKeepsCardProportions() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            @MainActor func render(open: Bool) throws -> Data {
                let host = NSHostingView(rootView: Clothespin(isOpen: open)
                    .frame(width: 60, height: 70).transaction { $0.disablesAnimations = true })
                host.frame = NSRect(x: 0, y: 0, width: 60, height: 70)
                let panel = NSPanel(contentRect: NSRect(x: -12000, y: -12000, width: 60, height: 70),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.contentView = host
                defer { panel.close() }
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            }
            XCTAssertNotEqual(try render(open: false), try render(open: true))
            for size in [NSSize(width: 300, height: 100), NSSize(width: 100, height: 300)] {
                let photo = NSImage(size: size)
                let preview = CardDragPreview.image(for: photo)
                let frame = PeggedView.cardSize(for: size)
                XCTAssertEqual(preview.size.width, frame.width + 2 * CardDragPreview.margin)
                XCTAssertEqual(preview.size.height, frame.height + 2 * CardDragPreview.margin)
                XCTAssertNotNil(preview.tiffRepresentation)
            }
        }
    }

    func testEdgeScrollingIsBoundedAndDoesNotRunOutsideStrip() async {
        await MainActor.run {
            XCTAssertEqual(Layout.reorderScrollDelta(pointerX: 700, width: 1400, elapsed: 1), 0)
            XCTAssertEqual(Layout.reorderScrollDelta(pointerX: 0, width: 1400, elapsed: 100), 42)
            XCTAssertEqual(Layout.reorderScrollDelta(pointerX: 1400, width: 1400, elapsed: 0.1), -42)
            XCTAssertEqual(Layout.reorderScrollDelta(pointerX: -1, width: 1400, elapsed: 0.1), 0)
            XCTAssertEqual(Layout.reorderScrollDelta(pointerX: .nan, width: 1400, elapsed: 1), 0)
            XCTAssertEqual(Layout.reorderScrollDelta(pointerX: 0, width: 0, elapsed: 1), 0)
            XCTAssertEqual(Layout.reorderScrollDelta(pointerX: 0, width: 1400, elapsed: -.infinity), 0)
            let panel = LinePanel(content: NSView())
            defer { panel.close() }
            XCTAssertTrue(panel.wantsPeriodicDraggingUpdates())
            XCTAssertFalse(panel.canBecomeKey)
        }
    }

    func testEquivalentFilePathsCannotDuplicateOrderingIdentity() async throws {
        let url = try image("one.png")
        let alias = folder.appendingPathComponent("unused/../one.png")
        await MainActor.run {
            let defaults = ReorderDefaults()
            defaults.set([url.path, alias.path], forKey: "pegged")
            let line = Line(defaults: defaults, breeze: false)
            XCTAssertEqual(line.liveCount, 1)
            XCTAssertNil(line.hang(alias, quietly: true))
            XCTAssertEqual(line.liveCount, 1)
        }
    }

    func testDropEndsSystemDragBeforeClipClosesAndAnotherDragCanStart() async throws {
        let url = try image("one.png")
        let fixture = try await MainActor.run { () -> (Line, UUID) in
            let line = Line(defaults: ReorderDefaults(), breeze: false)
            let id = try XCTUnwrap(line.hang(url, quietly: true))
            line.beginReordering(id, pointerX: 700, width: 1400)
            XCTAssertTrue(line.commitReordering(id))
            line.finishReordering(id)
            XCTAssertNil(line.draggingID)
            XCTAssertEqual(line.settlingID, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : id)
            line.beginReordering(id, pointerX: 700, width: 1400)
            XCTAssertEqual(line.draggingID, id)
            XCTAssertNil(line.settlingID)
            return (line, id)
        }
        try await Task.sleep(nanoseconds: 220_000_000)
        await MainActor.run {
            XCTAssertEqual(fixture.0.draggingID, fixture.1)
            fixture.0.finishReordering(fixture.1)
        }
        try await Task.sleep(nanoseconds: 220_000_000)
        await MainActor.run { XCTAssertNil(fixture.0.settlingID) }
    }
}
