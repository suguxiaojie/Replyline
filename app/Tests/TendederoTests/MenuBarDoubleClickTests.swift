import AppKit
import ApplicationServices
import XCTest
@testable import Tendedero

final class MenuBarDoubleClickTests: XCTestCase {
    func testTriggerChoicesPersistIndependentlyOfOtherPreferences() throws {
        let suite = "Replyline.MenuBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "quietHang")
        XCTAssertEqual(MenuBarTrigger.load(from: defaults), .doubleClick)
        for choice in [MenuBarTrigger.hover, .disabled, .doubleClick] {
            choice.save(to: defaults)
            XCTAssertEqual(MenuBarTrigger.load(from: try XCTUnwrap(UserDefaults(suiteName: suite))), choice)
            XCTAssertTrue(defaults.bool(forKey: "quietHang"))
        }
        defaults.set("invalid", forKey: "menuBarTrigger")
        XCTAssertEqual(MenuBarTrigger.load(from: defaults), .doubleClick)
    }

    private func event(_ count: Int, time: TimeInterval, type: NSEvent.EventType = .leftMouseDown,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers,
                                        timestamp: time, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: count, pressure: 0))
    }

    func testOnlySecondBlankClickOpensAndThirdDoesNot() throws {
        var gesture = MenuBarDoubleClick()
        XCTAssertFalse(gesture.consume(try event(1, time: 1), screen: 1) { true })
        XCTAssertTrue(gesture.consume(try event(2, time: 1.1), screen: 1) { true })
        XCTAssertFalse(gesture.consume(try event(3, time: 1.2), screen: 1) { true })
        XCTAssertFalse(gesture.consume(try event(2, time: 1.3), screen: 1) { true })
    }

    func testBothClicksMustBeBlankAndOnSameDisplay() throws {
        for scenario in 0..<4 {
            var gesture = MenuBarDoubleClick()
            XCTAssertFalse(gesture.consume(try event(1, time: 1), screen: 1) { scenario != 0 })
            let screen: CGDirectDisplayID? = scenario == 2 ? 2 : (scenario == 3 ? nil : 1)
            XCTAssertFalse(gesture.consume(try event(2, time: 1.1), screen: screen) { scenario != 1 })
        }
    }

    func testOutsideClicksRightClicksAndModifiedClicksCancelCandidate() throws {
        let interruptions: [(NSEvent.EventType, NSEvent.ModifierFlags, CGDirectDisplayID?)] = [
            (.leftMouseDown, [], nil), (.rightMouseDown, [], 1),
            (.leftMouseDown, .command, 1), (.leftMouseDown, .control, 1),
            (.leftMouseDown, .option, 1), (.leftMouseDown, .shift, 1)
        ]
        for (type, modifiers, screen) in interruptions {
            var gesture = MenuBarDoubleClick()
            _ = gesture.consume(try event(1, time: 1), screen: 1) { true }
            XCTAssertFalse(gesture.consume(try event(1, time: 1.05, type: type, modifiers: modifiers), screen: screen) { true })
            XCTAssertFalse(gesture.consume(try event(2, time: 1.1), screen: 1) { true })
        }
    }

    func testSlowOrOutOfOrderClicksDoNotOpenAndNextPairRecovers() throws {
        for secondTime in [0.9, 1.6] {
            var gesture = MenuBarDoubleClick()
            _ = gesture.consume(try event(1, time: 1), screen: 1, interval: 0.5) { true }
            XCTAssertFalse(gesture.consume(try event(2, time: secondTime), screen: 1, interval: 0.5) { true })
            _ = gesture.consume(try event(1, time: 2), screen: 1, interval: 0.5) { true }
            XCTAssertTrue(gesture.consume(try event(2, time: 2.5), screen: 1, interval: 0.5) { true })
        }
    }

    func testMenuItemsStatusIconsAndIncompleteHitTestsFailClosed() {
        let point = CGPoint(x: 500, y: 12)
        XCTAssertTrue(MenuBarHitTest.isBlank(role: kAXMenuBarRole, point: point,
                                           children: [CGRect(x: 0, y: 0, width: 300, height: 24)]))
        for role in [kAXMenuBarItemRole, kAXButtonRole, kAXGroupRole, kAXApplicationRole, nil] {
            XCTAssertFalse(MenuBarHitTest.isBlank(role: role, point: point, children: []))
        }
        XCTAssertFalse(MenuBarHitTest.isBlank(role: kAXMenuBarRole, point: point, children: nil))
        XCTAssertFalse(MenuBarHitTest.isBlank(role: kAXMenuBarRole, point: point,
                                            children: [CGRect(x: 480, y: 0, width: 40, height: 24)]))
    }

    func testAXCoordinatesUsePrimaryDisplayTopForOffsetDisplays() {
        XCTAssertEqual(MenuBarHitTest.accessibilityPoint(CGPoint(x: 500, y: 888), primaryTop: 900),
                       CGPoint(x: 500, y: 12))
        XCTAssertEqual(MenuBarHitTest.accessibilityPoint(CGPoint(x: -1000, y: 1088), primaryTop: 900),
                       CGPoint(x: -1000, y: -188))
        XCTAssertEqual(MenuBarHitTest.accessibilityPoint(CGPoint(x: 1600, y: -12), primaryTop: 900),
                       CGPoint(x: 1600, y: 912))
    }
}
