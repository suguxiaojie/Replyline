import AppKit
import SwiftUI

// Native mapping of the actual Open Claude UI motion exports. System accent
// and the original clothesline physics remain owned by Replyline.
enum AppMotion {
    static let control = Animation.interpolatingSpring(mass: 1, stiffness: 600, damping: 30)
    static let panel = Animation.interpolatingSpring(mass: 1, stiffness: 320, damping: 28)
    static let reorder = Animation.interpolatingSpring(mass: 0.1, stiffness: 1200, damping: 80)
}

struct UtilityIconButton: View {
    let title: String
    let symbol: String
    var selected = false
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? AppTheme.accent : AppTheme.secondary)
                .frame(width: 28, height: 28)
                .background(selected ? AppTheme.selected : (hovering ? AppTheme.inset : .clear), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(UtilityPressStyle())
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(AppTheme.accent.opacity(focused ? 0.8 : 0), lineWidth: 1.5))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : AppMotion.control, value: hovering)
        .help(title).accessibilityLabel(title)
    }
}

private struct UtilityPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.985)
            .animation(reduceMotion ? nil : AppMotion.control, value: configuration.isPressed)
    }
}

struct EditorField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.secondary)
            content()
        }
    }
}

struct EditorInputSurface: ViewModifier {
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.focused($focused)
            .padding(9)
            .background(AppTheme.cardFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? AppTheme.accent.opacity(0.75) : AppTheme.line, lineWidth: 1))
            .animation(reduceMotion ? nil : AppMotion.control, value: focused)
    }
}

struct EditorStatus: View {
    var busy: String? = nil
    var error: String? = nil
    var body: some View {
        if let busy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy) }
                .font(.system(size: 12)).foregroundStyle(AppTheme.secondary)
                .accessibilityElement(children: .combine)
        }
        if let error {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
        }
    }
}

enum LibraryLayout: String { case compact, grid }
enum LibraryKeyCommand { case search, copy, preview, next, previous, left, right, first, last }

enum LibraryKeyboard {
    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, composing: Bool,
                        searching: Bool, browsing: Bool) -> LibraryKeyCommand? {
        guard !composing else { return nil }
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        if flags == .command && keyCode == 3 { return .search }
        guard flags.isEmpty, searching || browsing else { return nil }
        switch keyCode {
        case 36, 76: return .copy
        case 125: return .next
        case 126: return browsing ? .previous : nil
        case 123: return browsing ? .left : nil
        case 124: return browsing ? .right : nil
        case 49: return browsing ? .preview : nil
        case 115: return browsing ? .first : nil
        case 119: return browsing ? .last : nil
        default: return nil
        }
    }

    static func target(_ command: LibraryKeyCommand, selection: UUID?, ids: [UUID], columns: Int) -> UUID? {
        guard !ids.isEmpty else { return nil }
        let index = selection.flatMap { ids.firstIndex(of: $0) }
        let stride = max(1, columns)
        let next: Int
        switch command {
        case .next: next = index.map { $0 + stride } ?? 0
        case .previous: next = index.map { $0 - stride } ?? 0
        case .left: next = (index ?? 0) - 1
        case .right: next = (index ?? -1) + 1
        case .first: next = 0
        case .last: next = ids.count - 1
        default: return selection
        }
        return ids[min(ids.count - 1, max(0, next))]
    }
}

/// Only this window receives these keys. Native text composition and sheet
/// editing retain their normal responder chain and clipboard shortcuts.
struct LibraryKeyCommands: NSViewRepresentable {
    let handle: (NSEvent, Bool) -> Bool
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView(); view.handle = handle; view.start(); return view
    }
    func updateNSView(_ view: KeyView, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }
    final class KeyView: NSView {
        var handle: (NSEvent, Bool) -> Bool = { _, _ in false }
        private var monitor: Any?
        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil else { return event }
                let composing = (window.firstResponder as? NSTextView)?.hasMarkedText() == true
                return self.handle(event, composing) ? nil : event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
