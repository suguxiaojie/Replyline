import AppKit
import XCTest
@testable import Tendedero

/// Exercise NSTextView's real selection/paste implementation with a private
/// pasteboard, leaving the user's general clipboard untouched.
private final class PrivateClipboardEditor: NSTextView {
    let clipboard = NSPasteboard.withUniqueName()

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)) {
            return isEditable && clipboard.availableType(from: readablePasteboardTypes) != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    override func copy(_ sender: Any?) {
        clipboard.clearContents()
        _ = writeSelection(to: clipboard, types: writablePasteboardTypes)
    }

    override func paste(_ sender: Any?) {
        _ = readSelection(from: clipboard, type: .string)
    }

    override func cut(_ sender: Any?) {
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }
}

private final class PrivateFieldEditorDelegate: NSObject, NSWindowDelegate {
    let editor = PrivateClipboardEditor()
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { editor }
}

final class EditingMenuTests: XCTestCase {
    func testPasteValidationUsesTheSamePrivateClipboardAsTheAction() async {
        await MainActor.run {
            let editor = PrivateClipboardEditor()
            defer { editor.clipboard.releaseGlobally() }
            let item = NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            XCTAssertFalse(editor.validateUserInterfaceItem(item))
            editor.clipboard.setString("可粘贴的话术", forType: .string)
            XCTAssertTrue(editor.validateUserInterfaceItem(item))
            editor.isEditable = false
            XCTAssertFalse(editor.validateUserInterfaceItem(item))
        }
    }

    func testPasteReachesTextFieldFieldEditor() async throws {
        try await MainActor.run {
            let app = NSApplication.shared
            let oldMenu = app.mainMenu
            let oldWindow = app.keyWindow
            let window = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 100),
                                 styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let delegate = PrivateFieldEditorDelegate()
            delegate.editor.isFieldEditor = true
            window.delegate = delegate
            let field = NSTextField(frame: NSRect(x: 10, y: 30, width: 280, height: 24))
            window.contentView = field
            window.makeKeyAndOrderFront(nil)
            field.selectText(nil)
            defer {
                delegate.editor.clipboard.releaseGlobally()
                window.close()
                oldWindow?.makeKey()
                app.mainMenu = oldMenu
            }
            ApplicationMenu.install(on: app)
            XCTAssertTrue(window.firstResponder === delegate.editor)
            delegate.editor.clipboard.setString("关闭自动续费", forType: .string)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
            XCTAssertTrue(app.mainMenu!.performKeyEquivalent(with: event))
            XCTAssertEqual(delegate.editor.string, "关闭自动续费")
            window.makeFirstResponder(window)
            XCTAssertEqual(field.stringValue, "关闭自动续费")
        }
    }

    func testCommandShortcutsReachFocusedEditor() async throws {
        try await MainActor.run {
            let app = NSApplication.shared
            let oldMenu = app.mainMenu
            let oldWindow = app.keyWindow
            let window = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 120),
                                 styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let editor = PrivateClipboardEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
            editor.allowsUndo = true
            window.contentView = editor
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            defer {
                editor.clipboard.releaseGlobally()
                window.close()
                oldWindow?.makeKey()
                app.mainMenu = oldMenu
            }

            let paste = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                       characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
            app.mainMenu = nil
            XCTAssertFalse(window.performKeyEquivalent(with: paste))
            XCTAssertFalse(app.mainMenu?.performKeyEquivalent(with: paste) ?? false)

            ApplicationMenu.install(on: app)
            let menu = try XCTUnwrap(app.mainMenu)
            XCTAssertTrue(app.keyWindow === window)
            let value = "您好，以下是操作步骤：\n第一步：打开设置。\n第二步：选择订阅。"
            editor.clipboard.setString(value, forType: .string)
            XCTAssertTrue(menu.performKeyEquivalent(with: paste))
            XCTAssertEqual(editor.string, value)

            @MainActor func send(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags = .command) throws {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                          characters: flags.contains(.shift) ? key.uppercased() : key,
                                                          charactersIgnoringModifiers: flags.contains(.shift) ? key.uppercased() : key,
                                                          isARepeat: false, keyCode: code))
                XCTAssertTrue(menu.performKeyEquivalent(with: event), "Command shortcut not handled: \(key)")
            }
            try send("a", code: 0)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (value as NSString).length))
            try send("c", code: 8)
            XCTAssertEqual(editor.clipboard.string(forType: .string), value)
            try send("x", code: 7)
            XCTAssertEqual(editor.string, "")
            XCTAssertEqual(editor.clipboard.string(forType: .string), value)
            editor.undoManager?.removeAllActions()
            try send("v", code: 9)
            XCTAssertEqual(editor.string, value)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            try send("z", code: 6)
            XCTAssertEqual(editor.string, "")
            try send("z", code: 6, flags: [.command, .shift])
            XCTAssertEqual(editor.string, value)
        }
    }

    func testEditingActionsUseResponderChainAndRedoHasDistinctShortcut() async throws {
        try await MainActor.run {
            let app = NSApplication.shared
            let oldMenu = app.mainMenu
            defer { app.mainMenu = oldMenu }
            ApplicationMenu.install(on: app)
            let editing = try XCTUnwrap(app.mainMenu?.items.first { $0.title == "编辑" }?.submenu)
            let actions = editing.items.filter { !$0.isSeparatorItem }
            XCTAssertEqual(Set(actions.compactMap { $0.action.map(NSStringFromSelector) }),
                           ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"])
            XCTAssertTrue(actions.allSatisfy { $0.target == nil })
            let undo = try XCTUnwrap(actions.first { $0.action == Selector(("undo:")) })
            let redo = try XCTUnwrap(actions.first { $0.action == Selector(("redo:")) })
            XCTAssertEqual(undo.keyEquivalentModifierMask, .command)
            XCTAssertEqual(redo.keyEquivalentModifierMask, [.command, .shift])
        }
    }
}
