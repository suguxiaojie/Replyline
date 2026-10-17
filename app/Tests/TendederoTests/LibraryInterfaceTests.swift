import AppKit
import SwiftUI
import XCTest
@testable import Tendedero

private final class InterfaceDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
}

final class LibraryInterfaceTests: XCTestCase {
    func testKeyboardLeavesCompositionAndTextEditingAlone() {
        for code: UInt16 in [36, 49, 125, 126, 3] {
            XCTAssertNil(LibraryKeyboard.command(keyCode: code, modifiers: [], composing: true, searching: true, browsing: false))
        }
        XCTAssertEqual(LibraryKeyboard.command(keyCode: 36, modifiers: [], composing: false, searching: true, browsing: false), .copy)
        XCTAssertNil(LibraryKeyboard.command(keyCode: 49, modifiers: [], composing: false, searching: true, browsing: false))
        XCTAssertNil(LibraryKeyboard.command(keyCode: 123, modifiers: [], composing: false, searching: true, browsing: false))
        XCTAssertNil(LibraryKeyboard.command(keyCode: 8, modifiers: .command, composing: false, searching: true, browsing: false))
        XCTAssertNil(LibraryKeyboard.command(keyCode: 36, modifiers: .shift, composing: false, searching: true, browsing: false))
        XCTAssertNil(LibraryKeyboard.command(keyCode: 36, modifiers: [], composing: false, searching: false, browsing: false))
        XCTAssertEqual(LibraryKeyboard.command(keyCode: 49, modifiers: [], composing: false, searching: false, browsing: true), .preview)
    }

    func testSelectionMovesThroughRowsAndGridWithoutWrappingOrStaleIDs() {
        let ids = (0..<8).map { _ in UUID() }
        XCTAssertEqual(LibraryKeyboard.target(.next, selection: nil, ids: ids, columns: 3), ids[0])
        XCTAssertEqual(LibraryKeyboard.target(.next, selection: ids[0], ids: ids, columns: 3), ids[3])
        XCTAssertEqual(LibraryKeyboard.target(.previous, selection: ids[0], ids: ids, columns: 3), ids[0])
        XCTAssertEqual(LibraryKeyboard.target(.right, selection: ids[7], ids: ids, columns: 3), ids[7])
        XCTAssertEqual(LibraryKeyboard.target(.last, selection: ids[0], ids: ids, columns: 1), ids[7])
        XCTAssertEqual(LibraryKeyboard.target(.first, selection: ids[7], ids: ids, columns: 1), ids[0])
        XCTAssertEqual(LibraryKeyboard.target(.next, selection: UUID(), ids: Array(ids.suffix(2)), columns: 1), ids[6])
        XCTAssertNil(LibraryKeyboard.target(.next, selection: ids[0], ids: [], columns: 1))
    }

    func testZoomPreservesImageCoordinateAtCenterAndPointer() {
        let viewport = CGSize(width: 400, height: 300)
        for point in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.25, y: 0.7)] {
            let anchor = PreviewZoomAnchor(image: CGPoint(x: 0.5, y: 0.6), viewport: point)
            let value = PreviewZoomGeometry.layout(natural: CGSize(width: 2000, height: 8000), scale: 1.5, viewport: viewport, anchor: anchor)
            XCTAssertEqual((value.offset.x + point.x * viewport.width - value.image.minX) / value.image.width, anchor.image.x, accuracy: 0.00001)
            XCTAssertEqual((value.offset.y + point.y * viewport.height - value.image.minY) / value.image.height, anchor.image.y, accuracy: 0.00001)
        }
        let small = PreviewZoomGeometry.layout(natural: CGSize(width: 40, height: 20), scale: 1, viewport: viewport, anchor: nil)
        XCTAssertEqual(small.document, viewport)
        XCTAssertEqual(small.image.midX, viewport.width / 2)
        XCTAssertEqual(small.offset, .zero)
    }

    func testNativeScrollViewKeepsLongImageReadingPositionAcrossZoom() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let view = PreviewImageScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let image = NSImage(size: NSSize(width: 800, height: 8000))
            view.update(image: image, natural: image.size, scale: 0.5)
            view.layoutSubtreeIfNeeded()
            view.contentView.scroll(to: NSPoint(x: 0, y: 1700))
            let before = try XCTUnwrap(view.currentAnchor())
            view.update(image: image, natural: image.size, scale: 1)
            let after = try XCTUnwrap(view.currentAnchor())
            XCTAssertEqual(before.image.x, after.image.x, accuracy: 0.00001)
            XCTAssertEqual(before.image.y, after.image.y, accuracy: 0.00001)
            XCTAssertGreaterThan(view.contentView.bounds.minY, 3000)
            view.update(image: image, natural: image.size, scale: 0.5)
            XCTAssertEqual(view.contentView.bounds.minY, 1700, accuracy: 1)
        }
    }

    func testVideoPlayTargetDoesNotCopyAndCardPressRemainsCopy() async throws {
        try await MainActor.run {
            let view = GrabView(frame: NSRect(x: 0, y: 0, width: 150, height: 100))
            view.previewAtCenter = true
            var previewed = 0, copied = 0
            view.onPreview = { previewed += 1 }; view.onClick = { copied += 1 }
            let panel = NSPanel(contentRect: NSRect(x: -12000, y: -12000, width: 150, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = view
            defer { panel.close() }
            let point = view.convert(NSPoint(x: 75, y: 50), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            view.mouseDown(with: event)
            XCTAssertEqual(previewed, 0)
            view.mouseUp(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.1,
                                                             windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)))
            XCTAssertEqual(previewed, 1); XCTAssertEqual(copied, 0)
            XCTAssertTrue(view.accessibilityPerformPress())
            XCTAssertEqual(copied, 1)
            view.previewAtCenter = false
            XCTAssertNil(view.cornerAction(at: NSPoint(x: 75, y: 50)))
        }
    }

    func testReducedMotionCompletesFlightWithoutCreatingAFlightWindow() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            guard let screen = NSScreen.main else { throw XCTSkip("No screen") }
            let image = try XCTUnwrap(NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
                NSColor.gray.setFill(); rect.fill(); return true
            }.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let before = CaptureFlight.flightsInProgress
            var completed = false
            CaptureFlight.fly(image: image, from: .zero, to: .zero, tilt: 0, on: screen, reducedMotion: true) { completed = true }
            CaptureFlight.fall(image: image, card: .zero, tilt: 0, on: screen, reducedMotion: true)
            XCTAssertTrue(completed)
            XCTAssertEqual(CaptureFlight.flightsInProgress, before)
        }
    }

    func testVideoInfoFormattingUsesStableReadableDurationAndSize() {
        XCTAssertTrue(VideoInfo(duration: 75, bytes: 1_000_000).summary.hasPrefix("01:15 · "))
        XCTAssertTrue(VideoInfo(duration: .nan, bytes: 0).summary.hasPrefix("00:00 · "))
    }

    func testCardBridgeExposesNamedPreviewAndTakeDownAccessibilityActions() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let line = Line(defaults: InterfaceDefaults(), breeze: false)
            var item = Pegged(url: URL(fileURLWithPath: "/nonexistent/fixture.mp4"), thumb: NSImage(size: NSSize(width: 160, height: 90)))
            item.libraryCard = LibraryCard(id: UUID(), kind: .video, title: "操作视频", keywords: "", text: "", asset: "fixture.mp4", pinned: true, createdAt: Date(), updatedAt: Date())
            var previewed = 0
            line.onPreview = { _ in previewed += 1 }
            let host = NSHostingView(rootView: GrabArea(item: item, line: line))
            let panel = NSPanel(contentRect: NSRect(x: -12000, y: -12000, width: 160, height: 90), styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = host
            defer { panel.close() }
            host.layoutSubtreeIfNeeded()
            @MainActor func find(_ view: NSView) -> GrabView? {
                if let grab = view as? GrabView { return grab }
                return view.subviews.compactMap(find).first
            }
            let bridge = try XCTUnwrap(find(host))
            XCTAssertEqual(bridge.accessibilityLabel(), "操作视频")
            XCTAssertEqual(bridge.accessibilityRole(), .button)
            let actions = try XCTUnwrap(bridge.accessibilityCustomActions())
            XCTAssertEqual(actions.map(\.name), ["播放视频", "从晾衣架取下，保留素材"])
            XCTAssertTrue(try XCTUnwrap(actions.first?.handler)())
            XCTAssertEqual(previewed, 1)
        }
    }
}
