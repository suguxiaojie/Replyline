import AppKit
import SwiftUI
import XCTest
@testable import Tendedero

private final class RefinementDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
}

final class LineRefinementTests: XCTestCase {
    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".tmp/line-refinement/tests")
    }

    @MainActor private func fixture() throws -> (Line, UUID) {
        let folder = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in NSColor.gray.setFill(); rect.fill(); return true }
        let url = folder.appendingPathComponent("sample.png")
        let rep = NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))!
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        let line = Line(defaults: RefinementDefaults(), breeze: false)
        return (line, try XCTUnwrap(line.hang(url, quietly: true)))
    }

    func testExtremeAspectRatiosKeepIndependentTargetsAndUndistortedPhotos() {
        for maxWidth in [106.0, 136, 189] {
            for size in [CGSize(width: 720, height: 10000), CGSize(width: 10000, height: 100), CGSize(width: 320, height: 222)] {
                let photo = CardGeometry.photo(size, maxWidth: maxWidth, maxHeight: 104)
                let shell = CardGeometry.shell(photo: photo)
                XCTAssertGreaterThanOrEqual(shell.width, 80)
                XCTAssertGreaterThanOrEqual(shell.height, 64)
                XCTAssertEqual(photo.width / photo.height, size.width / size.height, accuracy: 0.000001)
                let bounds = CGRect(origin: .zero, size: shell)
                let left = CardGeometry.cornerRect(in: bounds, trailing: false, flipped: false)
                let right = CardGeometry.cornerRect(in: bounds, trailing: true, flipped: false)
                XCTAssertFalse(left.intersects(right))
                XCTAssertFalse(left.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
                XCTAssertFalse(right.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
                XCTAssertTrue(bounds.contains(left)); XCTAssertTrue(bounds.contains(right))
            }
        }
        for invalid in [CGSize.zero, CGSize(width: CGFloat.nan, height: 12), CGSize(width: 12, height: CGFloat.infinity)] {
            XCTAssertEqual(CardGeometry.photo(invalid, maxWidth: 136, maxHeight: 104), CGSize(width: 136, height: 104))
        }
    }

    func testHiddenDiscardAndReleaseOutsideNeverDiscardOrPreview() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let panel = NSPanel(contentRect: NSRect(x: -12000, y: -12000, width: 80, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let view = GrabView(frame: NSRect(x: 0, y: 0, width: 80, height: 100))
            panel.contentView = view
            defer { panel.close() }
            var discarded = 0, previewed = 0, copied = 0
            view.onDiscard = { discarded += 1 }; view.onPreview = { previewed += 1 }; view.onClick = { copied += 1 }
            @MainActor func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            }
            let left = NSPoint(x: 10, y: 90), right = NSPoint(x: 70, y: 90), outside = NSPoint(x: 90, y: 90)
            XCTAssertNil(view.cornerAction(at: left))
            view.mouseDown(with: try event(.leftMouseDown, left))
            view.mouseUp(with: try event(.leftMouseUp, left))
            XCTAssertEqual(copied, 1); XCTAssertEqual(discarded, 0)
            view.discardVisible = true
            view.mouseDown(with: try event(.leftMouseDown, left))
            XCTAssertEqual(discarded, 0)
            view.mouseUp(with: try event(.leftMouseUp, left))
            XCTAssertEqual(discarded, 1)
            view.mouseDown(with: try event(.leftMouseDown, left))
            view.mouseDragged(with: try event(.leftMouseDragged, right))
            view.mouseUp(with: try event(.leftMouseUp, left))
            XCTAssertEqual(discarded, 1); XCTAssertEqual(copied, 1)
            view.mouseDown(with: try event(.leftMouseDown, right))
            XCTAssertEqual(previewed, 0)
            view.mouseUp(with: try event(.leftMouseUp, outside))
            XCTAssertEqual(previewed, 0)
            view.mouseDown(with: try event(.leftMouseDown, right))
            view.mouseUp(with: try event(.leftMouseUp, right))
            XCTAssertEqual(previewed, 1); XCTAssertEqual(discarded, 1); XCTAssertEqual(copied, 1)
        }
    }

    func testNativeLandingAndAnimationCompletionOwnTheClipLifecycle() async throws {
        let (line, id) = try await MainActor.run { try fixture() }
        await MainActor.run {
            line.beginReordering(id, pointerX: 500, width: 1000)
            XCTAssertTrue(line.commitReordering(id))
            line.awaitReorderLanding(id)
            line.finishReordering(id)
            XCTAssertEqual(line.draggingID, id)
            XCTAssertNil(line.settlingID)
            line.completeReorderLanding(UUID())
            XCTAssertEqual(line.draggingID, id)
            line.completeReorderLanding(id)
            XCTAssertNil(line.draggingID)
        }
        try await Task.sleep(nanoseconds: 230_000_000)
        await MainActor.run {
            let oldToken = line.settlingToken
            XCTAssertEqual(line.settlingID, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : id)
            line.beginReordering(id, pointerX: 500, width: 1000)
            line.completeSettling(id, token: oldToken)
            line.completeReorderLanding(id)
            XCTAssertEqual(line.draggingID, id)
            line.finishReordering(id)
            line.completeSettling(id, token: oldToken)
            XCTAssertEqual(line.settlingID, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : id)
            line.completeSettling(id, token: line.settlingToken)
            XCTAssertNil(line.settlingID)
        }
    }

    func testBreezeOnlyRunsWhenVisibleAndIdleWithoutHoverOrPreview() async throws {
        try await MainActor.run {
            let (line, id) = try fixture()
            line.revealed = true
            line.noteInteraction(at: 100)
            XCTAssertFalse(line.shouldBreeze(at: 129))
            XCTAssertTrue(line.shouldBreeze(at: 130))
            line.hoveredID = id; XCTAssertFalse(line.shouldBreeze(at: 200)); line.hoveredID = nil
            line.previewedID = id; XCTAssertFalse(line.shouldBreeze(at: 200)); line.previewedID = nil
            line.pressedID = id; XCTAssertFalse(line.shouldBreeze(at: 200)); line.pressedID = nil
            line.revealed = false; XCTAssertFalse(line.shouldBreeze(at: 200))
            XCTAssertFalse(line.shouldBreeze(at: .nan))
        }
    }

    func testMountedCardClosesClipAfterItsReturnAnimation() async throws {
        let (line, id, panel) = try await MainActor.run { () -> (Line, UUID, NSPanel) in
            let (line, id) = try fixture()
            let host = NSHostingView(rootView: PeggedView(item: line.items[0], line: line)
                .frame(width: 200, height: 220, alignment: .top))
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 220)
            let panel = NSPanel(contentRect: NSRect(x: -12000, y: -12000, width: 200, height: 220), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            panel.orderFront(nil)
            return (line, id, panel)
        }
        defer { Task { @MainActor in panel.close() } }
        try await Task.sleep(nanoseconds: 100_000_000)
        await MainActor.run { line.beginReordering(id, pointerX: 500, width: 1000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        await MainActor.run { line.finishReordering(id) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await MainActor.run { XCTAssertNil(line.settlingID); XCTAssertNil(line.draggingID) }
    }

    func testRepeatedCopyKeepsTheLatestSuccessFeedback() async throws {
        let (line, id) = try await MainActor.run { try fixture() }
        await MainActor.run { line.showCopied(id) }
        try await Task.sleep(nanoseconds: 800_000_000)
        await MainActor.run { line.showCopied(id) }
        try await Task.sleep(nanoseconds: 500_000_000)
        await MainActor.run { XCTAssertEqual(line.copiedID, id) }
    }

    func testNarrowCardsTextAndMetalRenderWithMatchingDragSizes() async throws {
        let output = directory.deletingLastPathComponent().appendingPathComponent("renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await MainActor.run {
            _ = NSApplication.shared
            let line = Line(defaults: RefinementDefaults(), breeze: false)
            let text = LibraryCard(id: UUID(), kind: .text, title: "如何取消自动续费", keywords: "", text: "您好，请打开订阅设置。\n选择当前订阅并关闭自动续费。\n当前权益保留至到期。", asset: "sample.txt", pinned: true, createdAt: Date(), updatedAt: Date())
            var words = Pegged(url: URL(fileURLWithPath: "/sample.txt"), thumb: NSImage(size: NSSize(width: 320, height: 222)))
            words.libraryCard = text
            let items = [CGSize(width: 720, height: 10000), CGSize(width: 10000, height: 120)].map { size in
                Pegged(url: URL(fileURLWithPath: "/sample.png"), thumb: NSImage(size: size, flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true })
            } + [words]
            for item in items {
                let drag = CardDragPreview.image(for: item)
                let card = PeggedView.cardSize(for: item.thumb.size)
                XCTAssertEqual(drag.size, NSSize(width: card.width + 36, height: card.height + 36))
                XCTAssertNotNil(drag.tiffRepresentation)
            }
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let host = NSHostingView(rootView: HStack(alignment: .top, spacing: 30) {
                    ForEach(items) { PeggedView(item: $0, line: line) }
                    Clothespin(isOpen: true)
                }.padding(30).frame(width: 640, height: 250, alignment: .top)
                    .background(AppTheme.panel).environment(\.colorScheme, scheme).transaction { $0.disablesAnimations = true })
                host.frame = NSRect(x: 0, y: 0, width: 640, height: 250)
                let panel = NSPanel(contentRect: NSRect(x: -12000, y: -12000, width: 640, height: 250), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                panel.contentView = host
                panel.orderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 2000)
                try png.write(to: output.appendingPathComponent("cards-\(name).png"))
                panel.close()
            }
        }
    }
}
