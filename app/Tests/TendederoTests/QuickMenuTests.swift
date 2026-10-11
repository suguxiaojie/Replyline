import AppKit
import SwiftUI
import XCTest
@testable import Tendedero

final class QuickMenuTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { _ = NSApplication.shared }
    }

    func testPanelPlacementStaysOnTheAnchorScreenAtEitherEdge() {
        let screen = NSRect(x: -1440, y: 40, width: 1440, height: 860)
        for x in [-1440.0, -720, -20] {
            let anchor = NSRect(x: x, y: 900, width: 20, height: 24)
            let frame = QuickMenuPlacement.frame(anchor: anchor, screen: screen, size: NSSize(width: 320, height: 384))
            XCTAssertTrue(screen.contains(frame))
            XCTAssertLessThan(frame.maxY, anchor.minY)
        }
        let tiny = NSRect(x: 0, y: 0, width: 240, height: 280)
        XCTAssertTrue(tiny.contains(QuickMenuPlacement.frame(anchor: NSRect(x: 220, y: 280, width: 20, height: 24),
                                                            screen: tiny, size: NSSize(width: 320, height: 384))))
    }

    func testPanelCanReceiveKeyboardWithoutBecomingMainAndReusesItsGlass() async {
        await MainActor.run {
            let controller = QuickMenu()
            let panel = controller.makePanel()
            defer { panel.close() }
            XCTAssertTrue(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertFalse(panel.isOpaque)
            XCTAssertEqual(panel.level, .popUpMenu)
            XCTAssertTrue(panel.contentView is NativeGlassSurface)
            XCTAssertIdentical(controller.makePanel(), panel)
            XCTAssertFalse(controller.isShown)
        }
    }

    @MainActor private func source(temporary: Int = 0, action: @escaping (ReplylineMenuAction) -> Void = { _ in }) -> NSMenu {
        let menu = NSMenu()
        ReplylineMenu.populate(menu, isRevealed: false, temporaryCount: temporary, shortcut: .standard, perform: action)
        return menu
    }

    func testKeyboardSelectionSkipsDisabledRowsAndWraps() async {
        await MainActor.run {
            let model = QuickMenuModel()
            model.menu = source()
            let enabled = model.menu.items.indices.filter { !model.menu.items[$0].isSeparatorItem && model.menu.items[$0].isEnabled }
            XCTAssertEqual(enabled.count, 5)
            for index in enabled {
                model.moveSelection(by: 1)
                XCTAssertEqual(model.selectedIndex, index)
            }
            model.moveSelection(by: 1)
            XCTAssertEqual(model.selectedIndex, enabled.first)
            model.moveSelection(by: -1)
            XCTAssertEqual(model.selectedIndex, enabled.last)
        }
    }

    func testNativeShortcutsAndReturnDispatchExactlyOneAction() async throws {
        try await MainActor.run {
            let controller = QuickMenu()
            var actions: [ReplylineMenuAction] = []
            controller.model.menu = source { actions.append($0) }
            func key(_ code: UInt16, text: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                              windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                                              isARepeat: false, keyCode: code))
            }
            XCTAssertTrue(controller.handleKey(try key(43, text: ",", flags: .command)))
            XCTAssertEqual(actions, [.settings])
            XCTAssertTrue(controller.handleKey(try key(125, text: "")))
            XCTAssertTrue(controller.handleKey(try key(36, text: "\r")))
            XCTAssertEqual(actions, [.settings, .toggle])
            XCTAssertFalse(controller.handleKey(try key(0, text: "a")))
            XCTAssertTrue(controller.handleKey(try key(53, text: "")))
            XCTAssertEqual(actions.count, 2)
        }
    }

    func testDisabledClearCannotBeActivatedAndEveryActionHasSymbol() async {
        await MainActor.run {
            let model = QuickMenuModel()
            model.menu = source()
            let clear = model.menu.items.firstIndex { $0.title == "清空临时截图…" }!
            model.selectedIndex = clear
            model.perform = { _ in XCTFail("Disabled clear must not run") }
            model.activateSelection()
            XCTAssertTrue(model.menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil && $0.image!.isTemplate })
        }
    }

    func testQuickMenuAndSettingsRenderInBothAppearances() async throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".tmp/apple-menu/renders")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try await MainActor.run {
            for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                               ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
                let model = QuickMenuModel()
                model.menu = source()
                model.fixedCount = 6
                model.selectedIndex = 1
                model.perform = { _ in XCTFail("Rendering cannot execute commands") }
                let host = NSHostingView(rootView: QuickMenuView(model: model).background(SettingsTheme.panel).environment(\.colorScheme, scheme))
                host.frame = NSRect(x: 0, y: 0, width: 320, height: 348)
                let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 320, height: 348),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: base.appendingPathComponent("menu-\(name).png"))
                window.close()

                let settings = SettingsModel()
                settings.onCommand = { _ in XCTFail("Rendering cannot write settings") }
                let settingsHost = NSHostingView(rootView: SettingsView(model: settings).background(SettingsTheme.panel).environment(\.colorScheme, scheme))
                settingsHost.frame = NSRect(x: 0, y: 0, width: 760, height: 570)
                let settingsWindow = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 760, height: 570),
                                              styleMask: [.titled], backing: .buffered, defer: false)
                settingsWindow.isReleasedWhenClosed = false
                settingsWindow.appearance = NSAppearance(named: appearance)
                settingsWindow.contentView = settingsHost
                settingsHost.layoutSubtreeIfNeeded()
                let settingsBitmap = try XCTUnwrap(settingsHost.bitmapImageRepForCachingDisplay(in: settingsHost.bounds))
                settingsHost.cacheDisplay(in: settingsHost.bounds, to: settingsBitmap)
                let png = try XCTUnwrap(settingsBitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 5000)
                try png.write(to: base.appendingPathComponent("settings-\(name).png"))
                settingsWindow.close()
            }
        }
    }
}
