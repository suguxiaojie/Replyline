import AppKit
import ApplicationServices

enum MenuBarTrigger: String {
    case hover, doubleClick, disabled

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: "menuBarTrigger").flatMap(Self.init(rawValue:)) ?? .doubleClick
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "menuBarTrigger")
    }
}

enum MenuBarHoverDelay: Double, CaseIterable {
    case quarter = 0.25, half = 0.5, one = 1, two = 2

    var title: String { "\(rawValue.formatted()) 秒" }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.double(forKey: "menuBarHoverDelay")) ?? .quarter
    }

    func save(to defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: "menuBarHoverDelay") }
}

/// Both clicks must land on blank menu bar space on the same display.
/// A menu item, permission failure, modified click or third click cancels it.
struct MenuBarDoubleClick {
    private var firstClick: (time: TimeInterval, screen: CGDirectDisplayID)?

    mutating func consume(_ event: NSEvent, screen: CGDirectDisplayID?,
                          interval: TimeInterval = NSEvent.doubleClickInterval,
                          isBlank: () -> Bool) -> Bool {
        guard event.type == .leftMouseDown, let screen,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              event.clickCount == 1 || event.clickCount == 2,
              isBlank() else {
            firstClick = nil
            return false
        }
        if event.clickCount == 1 {
            firstClick = (event.timestamp, screen)
            return false
        }
        let first = firstClick
        firstClick = nil
        guard let first else { return false }
        let elapsed = event.timestamp - first.time
        return first.screen == screen && elapsed >= 0 && elapsed <= interval
    }
}

enum MenuBarHitTest {
    static func accessibilityPoint(_ point: CGPoint, primaryTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryTop - point.y)
    }

    static func isBlank(role: String?, point: CGPoint, children: [CGRect]?) -> Bool {
        guard role == kAXMenuBarRole, let children else { return false }
        return !children.contains { $0.contains(point) }
    }

    /// Read-only hit testing; unknown roles or incomplete AX responses fail closed.
    static func isBlank(at point: CGPoint, primaryTop: CGFloat) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let root = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, 0.15)
        let location = accessibilityPoint(point, primaryTop: primaryTop)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(location.x), Float(location.y), &hit) == .success,
              let hit, let role = attribute(kAXRoleAttribute, of: hit) as? String,
              role == kAXMenuBarRole,
              let children = attribute(kAXChildrenAttribute, of: hit) as? [AXUIElement] else { return false }
        var frames: [CGRect] = []
        for child in children {
            guard let position = attribute(kAXPositionAttribute, of: child),
                  let size = attribute(kAXSizeAttribute, of: child),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return false }
            frames.append(CGRect(origin: origin, size: dimensions))
        }
        return isBlank(role: role, point: location, children: frames)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
