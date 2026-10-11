import AppKit
import SwiftUI
import XCTest
@testable import Tendedero

final class CardPreviewTests: XCTestCase {
    private let screen = CGRect(x: -12000, y: -12000, width: 1440, height: 900)
    private let anchor = CGRect(x: -10720, y: -11270, width: 150, height: 80)

    @MainActor private func textItem() -> Pegged {
        let text = "您好，以下是操作步骤：\n第一步：打开设置。\n第二步：选择订阅。"
        let card = LibraryCard(id: UUID(), kind: .text, title: "操作指引", keywords: "设置", text: text,
                               asset: "sample.txt", pinned: true, createdAt: Date(), updatedAt: Date())
        var item = Pegged(url: URL(fileURLWithPath: "/nonexistent/sample.txt"), thumb: NSImage(size: NSSize(width: 320, height: 220)))
        item.libraryCard = card
        return item
    }

    func testRightEdgeAndLongImagesStayWithinScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1920, y: 200, width: 1920, height: 1080),
                       CGRect(x: 0, y: 0, width: 390, height: 600)]
        for screen in screens {
            for content in [CGSize(width: 3000, height: 400), CGSize(width: 500, height: 12000)] {
                let size = PreviewGeometry.size(content: content, screen: screen)
                let anchor = CGRect(x: screen.maxX - 100, y: screen.maxY - 220, width: 80, height: 40)
                let frame = PreviewGeometry.frame(size: size, anchor: anchor, screen: screen)
                XCTAssertGreaterThanOrEqual(frame.minX, screen.minX + 12)
                XCTAssertLessThanOrEqual(frame.maxX, screen.maxX - 12)
                XCTAssertGreaterThanOrEqual(frame.minY, screen.minY + 12)
                XCTAssertLessThanOrEqual(frame.maxY, screen.maxY - 12)
            }
        }
    }

    func testShortTextUsesCompactSizeAndLongTextIsCapped() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let short = PreviewGeometry.size(content: .zero, text: "您好。", title: "问候", screen: screen)
        let multiline = PreviewGeometry.size(content: .zero, text: "您好。\n请按步骤操作。\n有问题随时联系。", title: "指引", screen: screen)
        let long = PreviewGeometry.size(content: .zero, text: String(repeating: "这是较长的话术，需要完整保留并允许滚动查看。\n", count: 50), screen: screen)
        XCTAssertLessThan(short.height, 160)
        XCTAssertLessThanOrEqual(short.width, 340)
        XCTAssertGreaterThan(multiline.height, short.height)
        XCTAssertGreaterThan(long.height, multiline.height)
        XCTAssertLessThanOrEqual(long.height, 470)
        let wrapped = PreviewGeometry.size(content: .zero, text: String(repeating: "很长的一行文字", count: 20), screen: screen)
        XCTAssertGreaterThan(wrapped.height, short.height)
        XCTAssertLessThanOrEqual(wrapped.width, 500)
    }

    func testImageHeightFollowsFittedAspectRatioAndLongImageScrolls() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let strip = PreviewGeometry.size(content: CGSize(width: 2400, height: 100), screen: screen)
        let wide = PreviewGeometry.size(content: CGSize(width: 1800, height: 320), screen: screen)
        let tall = PreviewGeometry.size(content: CGSize(width: 500, height: 5000), screen: screen)
        XCTAssertLessThan(strip.height, 180)
        XCTAssertLessThan(wide.height, 300)
        XCTAssertGreaterThan(wide.height, strip.height)
        XCTAssertEqual(tall.height, 620)
        let constrained = PreviewGeometry.size(content: CGSize(width: 500, height: 5000), screen: CGRect(x: 0, y: 0, width: 390, height: 400))
        XCTAssertLessThanOrEqual(constrained.height, 352)
        XCTAssertLessThanOrEqual(constrained.width, 366)
    }

    func testPointerUpdatesCannotOpenPreviewWithoutClick() async {
        await MainActor.run {
            let preview = CardPreview()
            let item = textItem()
            for _ in 0..<100 { preview.update(item: item, anchor: anchor, screen: screen) }
            XCTAssertNil(preview.currentID)
            XCTAssertFalse(preview.keepsLineOpen)
        }
    }

    func testClickOpensAndKeepsPreviewUntilSameIconClosesIt() async {
        await MainActor.run {
            let preview = CardPreview()
            defer { preview.dismiss() }
            let item = textItem()
            preview.toggle(item: item, anchor: anchor, screen: screen, activate: false)
            XCTAssertEqual(preview.currentID, item.id)
            XCTAssertNotNil(preview.panelFrame)
            for _ in 0..<100 { preview.update(item: item, anchor: anchor, screen: screen) }
            XCTAssertEqual(preview.currentID, item.id)
            XCTAssertTrue(preview.keepsLineOpen)
            preview.toggle(item: item, anchor: anchor, screen: screen, activate: false)
            XCTAssertNil(preview.currentID)
        }
    }

    func testRemovedFallingAndSuspendedCardsClosePreview() async {
        await MainActor.run {
            let preview = CardPreview()
            let item = textItem()
            preview.toggle(item: item, anchor: anchor, screen: screen, activate: false)
            preview.update(item: item, anchor: anchor, screen: screen, suspended: true)
            XCTAssertNil(preview.currentID)
            var falling = item
            falling.falling = true
            preview.toggle(item: falling, anchor: anchor, screen: screen, activate: false)
            XCTAssertNil(preview.currentID)
            preview.toggle(item: item, anchor: anchor, screen: screen, activate: false)
            preview.update(item: nil, anchor: nil, screen: screen)
            XCTAssertNil(preview.currentID)
        }
    }

    func testPanelSupportsSelectionFocusAndEscapeCloses() async {
        await MainActor.run {
            let panel = CardPreviewPanel()
            XCTAssertTrue(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            var closed = false
            panel.onClose = { closed = true }
            panel.cancelOperation(nil)
            XCTAssertTrue(closed)
            panel.close()
        }
    }

    func testBitmapLoadsOriginalDetailAndInvalidFileIsRejected() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent(".tmp/hover-preview-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("wide.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 300, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: source)
        let bitmap = try XCTUnwrap(PreviewBitmap.read(source))
        XCTAssertEqual(bitmap.originalPixels, CGSize(width: 1800, height: 300))
        XCTAssertEqual(bitmap.image.width, 1800)
        XCTAssertNil(PreviewBitmap.read(folder.appendingPathComponent("missing.png")))
    }

    func testTextPreviewRendersFullBody() async throws {
        try await MainActor.run {
            let model = CardPreviewModel(item: textItem())
            XCTAssertTrue(model.text!.contains("第二步：选择订阅。"))
            let host = NSHostingView(rootView: CardPreviewView(model: model, copy: {}, original: {}))
            let size = PreviewGeometry.size(content: .zero, text: model.text, title: model.title, screen: screen)
            host.frame = NSRect(origin: .zero, size: size)
            let panel = CardPreviewPanel()
            panel.setFrame(NSRect(origin: NSPoint(x: -12000, y: -12000), size: size), display: false)
            panel.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 5000)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let directory = root.appendingPathComponent(".tmp/hover-preview")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("text-preview.png"))
            panel.close()
        }
    }

    func testImagePreviewShowsReadableDetailAndZoomControls() async throws {
        try await MainActor.run {
            let image = NSImage(size: NSSize(width: 1800, height: 320))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1800, height: 320)).fill()
            ("客服操作指引" as NSString).draw(at: NSPoint(x: 32, y: 248), withAttributes: [
                .font: NSFont.systemFont(ofSize: 32, weight: .semibold), .foregroundColor: NSColor.black,
            ])
            ("第一步：打开设置，进入订阅管理页面。\n第二步：找到对应服务，按页面提示完成操作。\n需要查看右侧内容时，可横向滚动或使用「适应宽度」。" as NSString)
                .draw(in: NSRect(x: 32, y: 50, width: 1600, height: 166), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black,
                ])
            image.unlockFocus()
            let item = Pegged(url: URL(fileURLWithPath: "/nonexistent/wide-preview.png"), thumb: image)
            let model = CardPreviewModel(item: item)
            model.image = image
            model.loading = false
            model.naturalSize = CGSize(width: 1800, height: 320)
            let host = NSHostingView(rootView: CardPreviewView(model: model, copy: {}, original: {}))
            let size = PreviewGeometry.size(content: model.naturalSize, screen: screen)
            host.frame = NSRect(origin: .zero, size: size)
            let panel = CardPreviewPanel()
            panel.setFrame(NSRect(origin: NSPoint(x: -12000, y: -12000), size: size), display: false)
            panel.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 5000)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let directory = root.appendingPathComponent(".tmp/hover-preview")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("image-preview.png"))
            panel.close()
        }
    }

    func testCancelledImageLoadCannotResurrectDismissedPreview() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/hover-preview-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: source)
        let preview = await MainActor.run { () -> CardPreview in
            let preview = CardPreview()
            let item = Pegged(url: source, thumb: NSImage(size: NSSize(width: 200, height: 100)))
            preview.toggle(item: item, anchor: anchor, screen: screen, activate: false)
            XCTAssertEqual(preview.currentID, item.id)
            preview.dismiss()
            return preview
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run {
            XCTAssertNil(preview.currentID)
            XCTAssertNil(preview.panelFrame)
            XCTAssertFalse(preview.keepsLineOpen)
        }
    }
}
