import AppKit
import Carbon
import XCTest
@testable import Tendedero

final class ShortcutTests: XCTestCase {
    func testCombinationIdentityIgnoresDisplayCaseAndNonShortcutFlags() {
        let candidate = Shortcut(keyCode: kVK_ANSI_R, modifiers: [.control, .option, .capsLock], key: "R")
        XCTAssertTrue(candidate.hasSameCombination(as: .library))
        XCTAssertFalse(Shortcut.standard.hasSameCombination(as: .library))
        XCTAssertFalse(Shortcut(keyCode: kVK_ANSI_R, modifiers: [.control, .option, .shift], key: "r")
            .hasSameCombination(as: .library))
    }

    func testRecorderRejectsTypingAndShiftOnlyAndAcceptsModifiedKey() async throws {
        try await MainActor.run {
            func event(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                              timestamp: 0, windowNumber: 0, context: nil,
                                              characters: "s", charactersIgnoringModifiers: "s", isARepeat: false,
                                              keyCode: UInt16(kVK_ANSI_S)))
            }
            XCTAssertNil(Shortcut(event: try event([])))
            XCTAssertNil(Shortcut(event: try event(.shift)))
            let selected = try XCTUnwrap(Shortcut(event: try event([.command, .option])))
            XCTAssertEqual(selected.keyCode, kVK_ANSI_S)
            XCTAssertEqual(selected.modifiers, [.command, .option])
            XCTAssertEqual(selected.display, "⌥⌘S")
        }
    }

    func testShortcutDisplayRetainsAllConfiguredModifiers() {
        let shortcut = Shortcut(keyCode: kVK_ANSI_T, modifiers: [.control, .option, .shift, .command], key: "t")
        XCTAssertEqual(shortcut.display, "⌃⌥⇧⌘T")
        XCTAssertEqual(shortcut.carbonModifiers, controlKey | optionKey | shiftKey | cmdKey)
    }
}
