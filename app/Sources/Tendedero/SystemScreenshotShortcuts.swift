import AppKit
import ApplicationServices
import os

@MainActor
enum SystemScreenshotShortcuts {
    static let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!
    private static var navigation: Task<Void, Never>?

    static func open(onFailure: @escaping (String) -> Void) {
        Logger(subsystem: "local.coverai.Replyline", category: "ShortcutNavigation").notice("Opening screenshot shortcut category")
        navigation?.cancel()
        guard NSWorkspace.shared.open(url) else {
            onFailure("无法打开系统键盘快捷键窗口。")
            return
        }
        guard AXIsProcessTrusted() else {
            onFailure("自动定位需要 Replyline 的辅助功能授权。当前可在左侧手动选择「截屏」。")
            return
        }
        navigation = Task {
            // The system URL opens the sheet but does not select a category.
            // Wait for its accessibility tree; never change any shortcut values.
            for _ in 0..<12 {
                guard !Task.isCancelled else { return }
                let selected = await Task.detached { ScreenshotCategorySelection.select() }.value
                guard !Task.isCancelled else { return }
                if selected { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            onFailure("系统未提供可定位的截屏分类。请在左侧手动选择「截屏」。")
        }
    }
}

enum ScreenshotCategorySelection {
    private static let labels: Set<String> = {
        var labels: Set<String> = ["Screenshots shortcuts", "截屏快捷键"]
        let path = "/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex/Contents/Resources/DefaultShortcutsTable.loctable"
        if let data = FileManager.default.contents(atPath: path),
           let locales = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for case let locale as [String: Any] in locales.values {
                if let label = locale["Screenshots shortcuts (AX_DESCRIPTION)"] as? String { labels.insert(label) }
            }
        }
        return labels
    }()

    static func matches(_ description: String?) -> Bool {
        description.map { labels.contains($0) } ?? false
    }

    static func select() -> Bool {
        guard AXIsProcessTrusted(),
              let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return false }
        let root = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        var queue = (attribute(kAXWindowsAttribute, of: root) as? [AXUIElement] ?? []).map { ($0, 0) }
        var seen = Set<CFHashCode>()
        var targets: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(1)
        while !queue.isEmpty, seen.count < 400, Date() < deadline {
            let (node, depth) = queue.removeFirst()
            guard depth < 16, seen.insert(CFHash(node)).inserted else { continue }
            AXUIElementSetMessagingTimeout(node, 0.1)
            if matches(attribute(kAXDescriptionAttribute, of: node) as? String) { targets.append(node) }
            queue += (attribute(kAXChildrenAttribute, of: node) as? [AXUIElement] ?? []).map { ($0, depth + 1) }
        }
        // A partial/ambiguous tree must not send a click to a different control.
        Logger(subsystem: "local.coverai.Replyline", category: "ShortcutNavigation").notice("Category scan: nodes=\(seen.count), targets=\(targets.count), pending=\(queue.count)")
        guard queue.isEmpty, targets.count == 1, let target = targets.first,
              let row = selectionRow(containing: target) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(row, kAXSelectedAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        // The text child exposes AXPress but does not change the outline selection.
        let result = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        Logger(subsystem: "local.coverai.Replyline", category: "ShortcutNavigation").notice("Category selection result=\(result.rawValue)")
        return result == .success && attribute(kAXSelectedAttribute, of: row) as? Bool == true
    }

    private static func selectionRow(containing label: AXUIElement) -> AXUIElement? {
        var node = label
        for _ in 0..<4 {
            if attribute(kAXRoleAttribute, of: node) as? String == kAXRowRole { return node }
            guard let parent = attribute(kAXParentAttribute, of: node),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            node = parent as! AXUIElement
        }
        return nil
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
