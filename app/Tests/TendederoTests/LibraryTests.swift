import AppKit
import SwiftUI
import XCTest
@testable import Tendedero

private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
}

final class LibraryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        folder = base.appendingPathComponent(".tmp/library-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func image(at name: String = "source.png") throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let color = NSColor(deviceRed: 0.15, green: 0.60, blue: 0.65, alpha: 1)
        for x in 0..<2 { for y in 0..<2 { rep.setColor(color, atX: x, y: y) } }
        let url = folder.appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    func testTextPersistsExactlyAndSearchesAllFields() throws {
        let root = folder.appendingPathComponent("Library")
        let store = try LibraryRepository(folder: root)
        let text = "您好，GPT-5.6 的使用方法如下：\n  1. 打开设置。\n  2. 选择订阅。\n"
        let card = try store.addText(title: "  取消订阅  ", text: text, keywords: "扣费 Billing")
        let restored = try LibraryRepository(folder: root)
        XCTAssertEqual(restored.cards, [card])
        XCTAssertEqual(card.title, "取消订阅")
        XCTAssertEqual(try String(contentsOf: restored.assetURL(for: card)), text)
        XCTAssertTrue(card.matches("订阅 billing"))
        XCTAssertTrue(card.matches("GPT-5.6 设置"))
        XCTAssertTrue(card.matches("  \n"))
        XCTAssertFalse(card.matches("不存在"))
    }

    func testInvalidInputsDoNotCreateCardsOrFiles() throws {
        let root = folder.appendingPathComponent("Library")
        let store = try LibraryRepository(folder: root)
        XCTAssertThrowsError(try store.addText(title: " \n", text: "回复"))
        XCTAssertThrowsError(try store.addText(title: "标题", text: " \n\t"))
        let fake = folder.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: fake)
        XCTAssertThrowsError(try store.addImage(source: fake, title: "图片"))
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testImportedImageSurvivesSourceRemovalAndUnpinning() throws {
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        let source = try image()
        let bytes = try Data(contentsOf: source)
        let card = try store.addImage(source: source, title: "操作截图")
        try FileManager.default.removeItem(at: source)
        try store.setPinned(card.id, false)
        let loaded = try LibraryRepository(folder: store.folder)
        XCTAssertFalse(loaded.cards[0].pinned)
        XCTAssertEqual(try Data(contentsOf: loaded.assetURL(for: card)), bytes)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: loaded.assetURL(for: card).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testEditingTextUpdatesItsDragFileAndRetainsIdentity() throws {
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        let card = try store.addText(title: "旧标题", text: "旧内容")
        try store.update(card.id, title: "新标题", text: "新内容\n第二行", keywords: "客服", pinned: false)
        let current = try XCTUnwrap(store.find(card.id))
        XCTAssertEqual(current.id, card.id)
        XCTAssertEqual(current.createdAt, card.createdAt)
        XCTAssertEqual(current.text, "新内容\n第二行")
        XCTAssertEqual(try String(contentsOf: store.assetURL(for: current)), current.text)
        XCTAssertFalse(current.pinned)
        XCTAssertThrowsError(try store.update(card.id, title: "", text: "错误", keywords: "", pinned: true))
        XCTAssertEqual(store.find(card.id), current)
    }

    func testImageReplacementRetainsIdentityAndRejectsInvalidSourceAtomically() throws {
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        let source = try image()
        let card = try store.addImage(source: source, title: "旧图")
        let replacement = try image(at: "replacement.png")
        try store.update(card.id, title: "新图", text: "", keywords: "入口", pinned: true, imageSource: replacement)
        let current = try XCTUnwrap(store.find(card.id))
        XCTAssertEqual(current.id, card.id)
        XCTAssertNotEqual(current.asset, card.asset)
        XCTAssertEqual(try Data(contentsOf: store.assetURL(for: current)), try Data(contentsOf: replacement))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let bad = folder.appendingPathComponent("invalid.png")
        try Data("invalid".utf8).write(to: bad)
        XCTAssertThrowsError(try store.update(card.id, title: "不应保存", text: "", keywords: "", pinned: false, imageSource: bad))
        XCTAssertEqual(store.find(card.id), current)
    }

    func testLibraryWindowRendersWithTextAndImageCards() async throws {
        let root = folder!
        let store = try LibraryRepository(folder: root.appendingPathComponent("Library"))
        try store.addText(title: "如何取消订阅", text: "您好，您可以在订阅管理页面关闭自动续费。\n关闭后，当前订阅仍可使用至到期。", keywords: "续费 扣费 取消")
        try store.addText(title: "付款后如何开始使用", text: "您好，请先登录购买时使用的账号，再按操作指引打开服务。", keywords: "付款 登录 使用", pinned: false)
        try store.addImage(source: image(), title: "设置入口截图", keywords: "设置 订阅")
        let snapshot = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("visual-checks")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try await MainActor.run {
            let model = LibraryModel(folder: store.folder)
            let host = NSHostingView(rootView: LibraryView(model: model, close: {}))
            host.frame = NSRect(x: 0, y: 0, width: 780, height: 580)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: snapshot.appendingPathComponent("library.png"))
            XCTAssertGreaterThan(data.count, 5_000)
            window.close()

            let line = Line(library: model, defaults: MemoryDefaults(), breeze: false)
            line.revealed = true
            let lineHost = NSHostingView(rootView: LineView(line: line).transaction { $0.disablesAnimations = true })
            lineHost.frame = NSRect(x: 0, y: 0, width: 1100, height: 220)
            let lineWindow = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 220),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            lineWindow.isReleasedWhenClosed = false
            lineWindow.contentView = lineHost
            lineWindow.orderFront(nil)
            lineHost.layoutSubtreeIfNeeded()
            // Offscreen, nonactivating: exercise onAppear without taking focus.
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let lineBitmap = try XCTUnwrap(lineHost.bitmapImageRepForCachingDisplay(in: lineHost.bounds))
            lineHost.cacheDisplay(in: lineHost.bounds, to: lineBitmap)
            try XCTUnwrap(lineBitmap.representation(using: .png, properties: [:]))
                .write(to: snapshot.appendingPathComponent("line.png"))
            lineWindow.close()
        }
    }

    func testCorruptOrUnsafeIndexCannotBeOpenedOrOverwritten() throws {
        let root = folder.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("library.json")
        let broken = Data("broken JSON".utf8)
        try broken.write(to: index)
        XCTAssertThrowsError(try LibraryRepository(folder: root))
        XCTAssertEqual(try Data(contentsOf: index), broken)
        let unsafe = Data(#"{"version":1,"cards":[{"id":"00000000-0000-0000-0000-000000000001","kind":"text","title":"标题","keywords":"","text":"内容","asset":"../../secret.txt","pinned":true,"createdAt":0,"updatedAt":0}]}"#.utf8)
        try unsafe.write(to: index)
        XCTAssertThrowsError(try LibraryRepository(folder: root))
        XCTAssertEqual(try Data(contentsOf: index), unsafe)
    }

    func testFailedIndexWriteDoesNotChangeMemoryOrLeaveNewAsset() throws {
        let root = folder.appendingPathComponent("Library")
        let store = try LibraryRepository(folder: root)
        try store.addText(title: "已有", text: "原文")
        let before = store.cards
        let index = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.addText(title: "新增", text: "新内容"))
        XCTAssertEqual(store.cards, before)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Assets").path)
        XCTAssertEqual(files, [before[0].asset])
    }

    func testRemoveAndRestorePreserveImportedSource() throws {
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        let source = try image()
        let card = try store.addImage(source: source, title: "图片")
        let removed = try store.remove(card.id)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.assetURL(for: card).path))
        try store.restore(removed)
        XCTAssertEqual(try LibraryRepository(folder: store.folder).cards, [card])
    }

    func testPinnedCardsSurviveCapacityEvictionClearAndDirectTrash() async throws {
        let libraryFolder = folder.appendingPathComponent("Library")
        let root = folder!
        let source = try image()
        let store = try LibraryRepository(folder: libraryFolder)
        let text = try store.addText(title: "常用话术", text: "您好")
        let photo = try store.addImage(source: source, title: "常用图片")
        try await MainActor.run {
            let defaults = MemoryDefaults()
            let library = LibraryModel(folder: libraryFolder)
            let line = Line(library: library, defaults: defaults, breeze: false)
            library.onChange = { line.syncLibrary() }
            line.maxItems = 1
            XCTAssertEqual(line.liveCount, 2)
            for n in 0..<3 {
                let capture = root.appendingPathComponent("capture-\(n).png")
                try FileManager.default.copyItem(at: source, to: capture)
                line.hang(capture, quietly: true)
            }
            XCTAssertEqual(line.temporaryCount, 1)
            XCTAssertEqual(Set(line.items.filter { !$0.falling && $0.isLibraryItem }.compactMap { $0.libraryCard?.id }), [text.id, photo.id])
            line.trim()
            let fixed = try XCTUnwrap(line.items.first { $0.libraryCard?.id == photo.id })
            XCTAssertFalse(line.trash(fixed.id))
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.assetURL(for: photo).path))
            line.clear()
            XCTAssertTrue(library.cards.allSatisfy(\.pinned))
            line.discard(fixed.id, quietly: true)
            XCTAssertFalse(try XCTUnwrap(library.repository?.find(photo.id)).pinned)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.assetURL(for: photo).path))
            XCTAssertFalse(defaults.stringArray(forKey: "pegged")!.contains(store.assetURL(for: photo).path))
        }
    }

    func testFixedCardsUseCopyOnlyDragOperations() async {
        await MainActor.run {
            let view = GrabView()
            view.copyOnly = true
            XCTAssertEqual(view.allowedOperations(outsideApp: true), [.copy])
            XCTAssertEqual(view.allowedOperations(outsideApp: false), [])
            view.copyOnly = false
            XCTAssertEqual(view.allowedOperations(outsideApp: true), [.copy, .move, .delete])
        }
    }
}
