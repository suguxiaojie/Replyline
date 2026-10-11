import AppKit
import SwiftUI

@MainActor
final class QuickMenuModel: ObservableObject {
    @Published var menu = NSMenu()
    @Published var selectedIndex: Int?
    @Published var fixedCount = 0
    @Published var temporaryCount = 0
    var perform: (NSMenuItem) -> Void = { _ in }

    func moveSelection(by delta: Int) {
        let enabled = menu.items.indices.filter { menu.items[$0].isEnabled && !menu.items[$0].isSeparatorItem }
        guard !enabled.isEmpty else { selectedIndex = nil; return }
        guard let selectedIndex, let index = enabled.firstIndex(of: selectedIndex) else {
            self.selectedIndex = delta > 0 ? enabled.first : enabled.last
            return
        }
        self.selectedIndex = enabled[(index + delta + enabled.count) % enabled.count]
    }

    func activateSelection() {
        guard let selectedIndex, menu.items.indices.contains(selectedIndex) else { return }
        let item = menu.items[selectedIndex]
        if item.isEnabled && !item.isSeparatorItem { perform(item) }
    }
}

private final class QuickMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum QuickMenuPlacement {
    static func frame(anchor: NSRect, screen: NSRect, size: NSSize) -> NSRect {
        let width = min(size.width, max(1, screen.width - 16))
        let height = min(size.height, max(1, screen.height - 16))
        let x = min(max(anchor.midX - width / 2, screen.minX + 8), screen.maxX - width - 8)
        let top = min(anchor.minY - 5, screen.maxY - 5)
        return NSRect(x: x, y: max(screen.minY + 8, top - height), width: width, height: height)
    }
}

@MainActor
final class QuickMenu: NSObject {
    let model = QuickMenuModel()
    private(set) var panel: NSPanel?
    private var keyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var anchor = NSRect.zero
    private(set) var previousApplication: NSRunningApplication?
    var onClose: () -> Void = {}
    var isShown: Bool { panel?.isVisible == true }

    override init() {
        super.init()
        model.perform = { item in
            if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        }
    }

    deinit {
        for monitor in [keyMonitor, localMouseMonitor, globalMouseMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
    }

    @discardableResult func makePanel() -> NSPanel {
        if let panel { return panel }
        let panel = QuickMenuPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 348),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.contentView = NativeGlass.host(QuickMenuView(model: model), material: .popover, cornerRadius: 18)
        self.panel = panel
        return panel
    }

    func show(relativeTo button: NSStatusBarButton, menu: NSMenu, fixedCount: Int, temporaryCount: Int) {
        if isShown { close(restoringFocus: true); return }
        guard let window = button.window, let screen = window.screen else { return }
        anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let front = NSWorkspace.shared.frontmostApplication
        previousApplication = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        model.menu = menu
        model.fixedCount = fixedCount
        model.temporaryCount = temporaryCount
        model.selectedIndex = nil
        let panel = makePanel()
        panel.setFrame(QuickMenuPlacement.frame(anchor: anchor, screen: screen.visibleFrame,
                                                size: NSSize(width: 320, height: 348)), display: false)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduced ? 1 : 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !reduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if self.handleKey(event) { return nil }
            return event
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissOutsideClick(at: NSEvent.mouseLocation)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismissOutsideClick(at: NSEvent.mouseLocation) }
        }
    }

    func refresh(menu: NSMenu, fixedCount: Int, temporaryCount: Int) {
        guard isShown else { return }
        model.menu = menu
        model.fixedCount = fixedCount
        model.temporaryCount = temporaryCount
        if let index = model.selectedIndex,
           !menu.items.indices.contains(index) || !menu.items[index].isEnabled { model.selectedIndex = nil }
    }

    func close(restoringFocus: Bool = false) {
        let previous = previousApplication
        let wasShown = isShown
        panel?.orderOut(nil)
        for monitor in [keyMonitor, localMouseMonitor, globalMouseMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        localMouseMonitor = nil
        globalMouseMonitor = nil
        previousApplication = nil
        if wasShown { onClose() }
        if restoringFocus { previous?.activate(options: []) }
    }

    private func dismissOutsideClick(at point: NSPoint) {
        guard isShown, let panel, !panel.frame.contains(point),
              !anchor.insetBy(dx: -4, dy: -4).contains(point) else { return }
        close()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        if model.menu.performKeyEquivalent(with: event) { return true }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 53: close(restoringFocus: true)
        case 125: model.moveSelection(by: 1)
        case 126: model.moveSelection(by: -1)
        case 36, 49: model.activateSelection()
        default: return false
        }
        return true
    }

}

struct QuickMenuView: View {
    @ObservedObject var model: QuickMenuModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tshirt").font(.system(size: 14)).foregroundStyle(SettingsTheme.secondary).accessibilityHidden(true)
                Text("Replyline").font(.system(size: 13, weight: .semibold)).foregroundStyle(SettingsTheme.ink)
                Spacer()
                Text("\(model.fixedCount) 固定 · \(model.temporaryCount) 临时")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(SettingsTheme.muted)
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 18)
            ForEach(Array(model.menu.items.enumerated()), id: \.offset) { index, item in
                if item.isSeparatorItem {
                    Rectangle().fill(SettingsTheme.line).frame(height: 0.5).padding(.horizontal, 10).padding(.vertical, 6)
                } else {
                    QuickActionCell(model: model, index: index, item: item, primary: index < 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12).frame(width: 320)
        .background(reduceTransparency ? SettingsTheme.panel : .clear)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.selectedIndex)
    }
}

private struct QuickActionCell: View {
    @ObservedObject var model: QuickMenuModel
    let index: Int
    let item: NSMenuItem
    let primary: Bool
    @FocusState private var focused: Bool
    private var selected: Bool { model.selectedIndex == index }
    private var shortcut: String {
        item.keyEquivalent.isEmpty ? "" : Shortcut(keyCode: 0, modifiers: item.keyEquivalentModifierMask, key: item.keyEquivalent).display
    }

    var body: some View {
        Button { model.perform(item) } label: {
            HStack(spacing: 10) {
                symbol.frame(width: 20)
                Text(item.title).font(.system(size: primary ? 13 : 12, weight: primary ? .semibold : .regular))
                    .foregroundStyle(SettingsTheme.ink)
                Spacer(minLength: 8)
                Text(shortcut).font(.system(size: 11)).foregroundStyle(SettingsTheme.muted).accessibilityHidden(true)
            }
            .padding(.horizontal, 10).frame(height: primary ? 42 : SettingsTheme.rowHeight)
            .background(selected ? SettingsTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(SoftPressButtonStyle())
        .disabled(!item.isEnabled).opacity(item.isEnabled ? 1 : 0.4)
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(SettingsTheme.accent.opacity(focused ? 0.8 : 0), lineWidth: 1.5))
        .onHover { inside in
            if inside && item.isEnabled { model.selectedIndex = index }
            else if model.selectedIndex == index { model.selectedIndex = nil }
        }
        .accessibilityLabel(item.title)
        .accessibilityHint(shortcut.isEmpty ? "" : "快捷键 \(shortcut)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var symbol: some View {
        Group {
            if let image = item.image {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 15, height: 15)
            }
        }
        .foregroundStyle(selected ? SettingsTheme.accent : SettingsTheme.secondary).accessibilityHidden(true)
    }
}
