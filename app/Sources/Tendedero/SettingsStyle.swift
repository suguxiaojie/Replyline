import AppKit
import SwiftUI

struct SidebarMaterial: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        SettingsTheme.sidebar.opacity(reduceTransparency ? 1 : 0.98)
    }
}

struct SettingsCard<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(SettingsTheme.secondary).padding(.leading, 2)
            }
            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsTheme.cardFill, in: RoundedRectangle(cornerRadius: SettingsTheme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: SettingsTheme.radius).strokeBorder(SettingsTheme.line, lineWidth: 0.5))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(SettingsTheme.muted)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }
        }
    }
}

struct SettingsButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SettingsTheme.ink)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(prominent ? SettingsTheme.accent.opacity(configuration.isPressed ? 0.22 : 0.12) : (configuration.isPressed ? SettingsTheme.line : SettingsTheme.inset), in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .animation(reduceMotion ? nil : AppMotion.control, value: configuration.isPressed)
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(SettingsTheme.ink)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(SettingsTheme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            content()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

struct SettingsRule: View {
    var body: some View { Rectangle().fill(SettingsTheme.line).frame(height: 0.5).padding(.leading, 14) }
}

struct SettingsSwitch: View {
    let title: String
    var subtitle: String? = nil
    @Binding var value: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle(title, isOn: $value).labelsHidden().toggleStyle(.switch)
        }
    }
}

struct GlassSegmentedControl<Value: Hashable>: View {
    let title: String
    let options: [(title: String, value: Value)]
    @Binding var selection: Value
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @Namespace private var indicator
    @FocusState private var focused: Value?
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button { select(option.value) } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selection == option.value ? .semibold : .medium))
                        .foregroundStyle(selection == option.value ? AppTheme.ink : AppTheme.secondary)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background {
                            if selection == option.value {
                                Capsule()
                                    .fill(AppTheme.elevated)
                                    .shadow(color: .black.opacity(scheme == .dark ? 0.2 : 0.08), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: indicator)
                            } else if hovered == option.value {
                                Capsule().fill(AppTheme.inset)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(SoftPressButtonStyle())
                .focused($focused, equals: option.value)
                .onHover { hovered = $0 ? option.value : nil }
                .overlay(Capsule()
                    .strokeBorder(AppTheme.accent.opacity(focused == option.value ? 0.8 : 0), lineWidth: 1.5))
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(scheme == .dark ? AppTheme.panel : AppTheme.inset, in: Capsule())
        .animation(reduceMotion ? nil : AppMotion.control, value: selection)
        .opacity(enabled ? 1 : 0.45)
        .onMoveCommand(perform: move)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(options.first { $0.value == selection }?.title ?? "")
    }

    private func select(_ value: Value) {
        guard enabled, value != selection else { return }
        selection = value
        focused = value
    }

    func move(_ direction: MoveCommandDirection) {
        guard enabled, let current = options.firstIndex(where: { $0.value == selection }) else { return }
        let next: Int
        switch direction {
        case .left: next = current - 1
        case .right: next = current + 1
        default: return
        }
        guard options.indices.contains(next) else { return }
        select(options[next].value)
    }
}
