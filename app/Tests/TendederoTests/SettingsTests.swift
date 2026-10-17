import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import Tendedero

final class SettingsTests: XCTestCase {
    func testSegmentedKeyboardNavigationUsesTheBindingAndStopsAtEdges() async {
        await MainActor.run {
            var selection = MenuBarTrigger.disabled
            var edits = 0
            let control = GlassSegmentedControl(title: "菜单栏触发方式",
                                                options: [("关闭", MenuBarTrigger.disabled), ("悬停", .hover), ("双击", .doubleClick)],
                                                selection: Binding(get: { selection }, set: { selection = $0; edits += 1 }))
            control.move(.left)
            XCTAssertEqual(edits, 0)
            control.move(.right)
            XCTAssertEqual(selection, .hover)
            control.move(.right)
            XCTAssertEqual(selection, .doubleClick)
            control.move(.right)
            control.move(.up)
            XCTAssertEqual(edits, 2)
            control.move(.left)
            XCTAssertEqual(selection, .hover)
            XCTAssertEqual(edits, 3)
        }
    }

    private var temporaryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".tmp/settings-restructure")
    }

    func testHoverDelayPersistsAndInvalidValuesPreserveOriginalDefault() throws {
        let suite = "Replyline.SettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MenuBarHoverDelay.load(from: defaults), .quarter)
        MenuBarTrigger.hover.save(to: defaults)
        for delay in MenuBarHoverDelay.allCases {
            delay.save(to: defaults)
            XCTAssertEqual(MenuBarHoverDelay.load(from: try XCTUnwrap(UserDefaults(suiteName: suite))), delay)
            XCTAssertEqual(MenuBarTrigger.load(from: defaults), .hover)
        }
        for invalid in [-1.0, 0, 0.3, 5] {
            defaults.set(invalid, forKey: "menuBarHoverDelay")
            XCTAssertEqual(MenuBarHoverDelay.load(from: defaults), .quarter)
        }
    }

    func testNativeMenuHasOnlyActionsAndUsesActualConfiguredKeyEquivalents() async throws {
        try await MainActor.run {
            let menu = NSMenu()
            var actions: [ReplylineMenuAction] = []
            let custom = Shortcut(keyCode: kVK_ANSI_S, modifiers: [.control, .shift], key: "s")
            ReplylineMenu.populate(menu, isRevealed: false, temporaryCount: 2, shortcut: custom) { actions.append($0) }
            let items = menu.items.filter { !$0.isSeparatorItem }
            XCTAssertEqual(items.map(\.title), ["显示晾衣架", "管理常用素材…", "打开截图文件夹", "清空临时截图…", "设置…", "退出 Replyline"])
            XCTAssertTrue(items.allSatisfy { $0.submenu == nil && $0.state == .off })
            XCTAssertEqual(items[0].keyEquivalent, "s")
            XCTAssertEqual(items[0].keyEquivalentModifierMask, [.control, .shift])
            XCTAssertEqual(items[1].keyEquivalent, "r")
            XCTAssertEqual(items[1].keyEquivalentModifierMask, [.control, .option])
            XCTAssertTrue(items[3].isEnabled)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                      timestamp: 0, windowNumber: 0, context: nil, characters: ",",
                                                      charactersIgnoringModifiers: ",", isARepeat: false, keyCode: UInt16(kVK_ANSI_Comma)))
            XCTAssertTrue(menu.performKeyEquivalent(with: event))
            XCTAssertEqual(actions, [.settings])
            ReplylineMenu.populate(menu, isRevealed: true, temporaryCount: 0, shortcut: nil) { actions.append($0) }
            XCTAssertEqual(menu.items[0].title, "隐藏晾衣架")
            XCTAssertEqual(menu.items[0].keyEquivalent, "")
            XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == "清空临时截图…" }).isEnabled)
        }
    }

    func testCommandCommaOpensSettingsThroughMainMenuWithoutReplacingEditingMenu() async throws {
        try await MainActor.run {
            let app = NSApplication.shared
            let previous = app.mainMenu
            defer { app.mainMenu = previous }
            var opened = 0
            ApplicationMenu.install(on: app, settings: { opened += 1 })
            let menu = try XCTUnwrap(app.mainMenu)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                      timestamp: 0, windowNumber: 0, context: nil, characters: ",",
                                                      charactersIgnoringModifiers: ",", isARepeat: false, keyCode: UInt16(kVK_ANSI_Comma)))
            XCTAssertTrue(menu.performKeyEquivalent(with: event))
            XCTAssertEqual(opened, 1)
            XCTAssertNotNil(menu.items.first { $0.title == "编辑" }?.submenu)
            XCTAssertFalse(menu.items[0].submenu!.items.contains { $0.title.contains("关于") })
            XCTAssertTrue(Shortcut.settings.hasSameCombination(as: Shortcut(keyCode: kVK_ANSI_Comma, modifiers: .command, key: ",")))
        }
    }

    func testSettingsBindingsSendChangesOnlyForExplicitEdits() async {
        await MainActor.run {
            let model = SettingsModel()
            model.snapshot.trigger = .hover
            model.snapshot.hoverDelay = .half
            model.snapshot.peeksAtNew = false
            var edits = 0
            model.onCommand = { command in
                if case .hoverDelay(let delay) = command { XCTAssertEqual(delay, .one); edits += 1 }
                else { XCTFail("Unexpected settings action") }
            }
            let binding = model.binding(\.hoverDelay, command: SettingsCommand.hoverDelay)
            XCTAssertEqual(binding.wrappedValue, .half)
            XCTAssertEqual(edits, 0)
            binding.wrappedValue = .one
            XCTAssertEqual(edits, 1)
            XCTAssertEqual(model.snapshot.trigger, .hover)
            XCTAssertFalse(model.snapshot.peeksAtNew)
        }
    }

    func testSettingsWindowUsesNormalLevelAndSidebarChangesOnlySelectedPage() async {
        await MainActor.run {
            let controller = SettingsWindow()
            var refreshes = 0
            controller.model.onCommand = { command in
                guard case .refresh = command else { XCTFail("Unexpected side effect"); return }
                refreshes += 1
            }
            let window = controller.makeWindow()
            defer { window.close() }
            XCTAssertEqual(window.level, .normal)
            XCTAssertTrue(window.styleMask.contains(.resizable))
            XCTAssertNil(window.toolbar)
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.backgroundColor, .clear)
            let container = window.contentView as? NativeGlassSurface
            XCTAssertNotNil(container)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                XCTAssertFalse(container?.surface is NSVisualEffectView)
            } else if #available(macOS 26.0, *) {
                let glass = container?.surface as? NSGlassEffectView
                XCTAssertNotNil(glass?.contentView)
                XCTAssertEqual(glass?.style, .clear)
            } else {
                let glass = container?.surface as? NSVisualEffectView
                XCTAssertEqual(glass?.blendingMode, .behindWindow)
                XCTAssertEqual(glass?.material, .underWindowBackground)
            }
            for page in SettingsPage.allCases {
                controller.model.selectPage(page)
                XCTAssertEqual(controller.model.page, page)
            }
            XCTAssertEqual(refreshes, 3)
            XCTAssertIdentical(controller.makeWindow(), window)
        }
    }

    func testClearPlanCountsOnlyLiveTemporaryCardsAndUsesDirectoryBoundary() async {
        await MainActor.run {
            let inbox = URL(fileURLWithPath: "/test/Inbox")
            let image = NSImage(size: NSSize(width: 2, height: 2))
            var fixed = Pegged(url: inbox.appendingPathComponent("fixed.png"), thumb: image)
            fixed.libraryCard = LibraryCard(id: UUID(), kind: .text, title: "固定话术", keywords: "", text: "保留", asset: "fixed.txt", pinned: true, createdAt: Date(), updatedAt: Date())
            var falling = Pegged(url: inbox.appendingPathComponent("falling.png"), thumb: image)
            falling.falling = true
            let local = Pegged(url: inbox.appendingPathComponent("capture.png"), thumb: image)
            let external = Pegged(url: URL(fileURLWithPath: "/test/InboxSibling/image.png"), thumb: image)
            let plan = TemporaryClearPlan(items: [fixed, falling, local, external], inbox: inbox)
            XCTAssertEqual(plan.ids, [local.id, external.id])
            XCTAssertEqual(plan.trashCount, 1)
            XCTAssertEqual(plan.takeDownCount, 1)
            XCTAssertTrue(plan.message.contains("废纸篓"))
            XCTAssertTrue(plan.message.contains("原文件保留"))
            XCTAssertTrue(TemporaryClearPlan(items: [fixed, falling], inbox: inbox).ids.isEmpty)
        }
    }

    func testConfirmedClearLeavesLateArrivalsAndFixedMaterialUntouched() async throws {
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "Replyline.ClearTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let cleared = expectation(description: "Confirmed card begins its existing fall animation")
        let (line, firstID, lateID, library) = try await MainActor.run {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let first = directory.appendingPathComponent("first.png")
            let late = directory.appendingPathComponent("late.png")
            try data.write(to: first)
            try data.write(to: late)
            let library = LibraryModel(folder: directory.appendingPathComponent("Library"))
            XCTAssertTrue(library.perform { try $0.addText(title: "常用", text: "保留") })
            let line = Line(library: library, defaults: defaults, breeze: false)
            let firstID = try XCTUnwrap(line.hang(first))
            let approved = TemporaryClearPlan(items: line.items, inbox: Inbox.folder)
            let lateID = try XCTUnwrap(line.hang(late))
            line.onFall = { item in if item.id == firstID { cleared.fulfill() } }
            line.clear(approved.ids)
            return (line, firstID, lateID, library)
        }
        await fulfillment(of: [cleared], timeout: 2)
        try await MainActor.run {
            XCTAssertTrue(try XCTUnwrap(line.items.first { $0.id == firstID }).falling)
            XCTAssertFalse(try XCTUnwrap(line.items.first { $0.id == lateID }).falling)
            XCTAssertFalse(try XCTUnwrap(line.items.first { $0.isLibraryItem }).falling)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("first.png").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("late.png").path))
            XCTAssertEqual(library.cards.count, 1)
        }
    }

    func testAllSettingsPagesRenderWithoutApplyingSettings() async throws {
        let directory = temporaryRoot.appendingPathComponent("renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await MainActor.run {
            let model = SettingsModel()
            model.snapshot.trigger = .hover
            model.snapshot.screenshotFolder = URL(fileURLWithPath: "/Users/demo/Library/Application Support/Replyline/Screenshots")
            model.snapshot.extraFolders = [URL(fileURLWithPath: "/Users/demo/Pictures/客服截图")]
            model.onCommand = { _ in XCTFail("Rendering must not apply settings") }
            for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                               ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
              for narrow in [false, true] {
               for page in SettingsPage.allCases {
                model.page = page
                model.snapshot.trigger = narrow ? .doubleClick : .hover
                model.snapshot.accessibility = narrow
                let size = narrow ? NSSize(width: 730, height: 530) : NSSize(width: 800, height: 600)
                let host = NSHostingView(rootView: SettingsView(model: model).background(SettingsTheme.panel)
                    .environment(\.colorScheme, scheme))
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(data.count, 5000)
                try data.write(to: directory.appendingPathComponent("\(page.rawValue)-\(name)-\(narrow ? "narrow" : "regular").png"))
                window.close()
               }
              }
            }
        }
    }
}
