import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable {
    case line, images, shortcuts, general

    var title: String {
        switch self {
        case .line: "晾衣架"
        case .images: "截图与图片"
        case .shortcuts: "快捷键"
        case .general: "通用"
        }
    }

    var icon: String {
        switch self {
        case .line: "tshirt"
        case .images: "photo.on.rectangle"
        case .shortcuts: "keyboard"
        case .general: "gearshape"
        }
    }

    var subtitle: String {
        switch self {
        case .line: "选择晾衣架的展开方式与卡片显示。"
        case .images: "管理截图来源、图片收集与临时卡片。"
        case .shortcuts: "设置常用操作的按键组合。"
        case .general: "管理启动方式与交互反馈。"
        }
    }
}

struct SettingsSnapshot {
    var trigger: MenuBarTrigger = .doubleClick
    var hoverDelay: MenuBarHoverDelay = .quarter
    var peeksAtNew = true
    var fullScreen = false
    var size: Layout.Size = .medium
    var inbox = false
    var clipboard = false
    var screenshotFolder = ScreenshotWatcher.desktop
    var extraFolders: [URL] = []
    var keepCount: Int? = nil
    var shortcut: Shortcut? = .standard
    var recording = false
    var shortcutAvailable = true
    var libraryShortcutAvailable = true
    var accessibility = false
    var sound = true
    var login = false
}

enum SettingsCommand {
    case trigger(MenuBarTrigger), hoverDelay(MenuBarHoverDelay), peek(Bool), fullScreen(Bool), size(Layout.Size)
    case inbox(Bool), clipboard(Bool), keep(Int?), addFolder, removeFolder(URL), openScreenshotFolder
    case recordShortcut, systemScreenshotShortcut, accessibility, sound(Bool), login(Bool), refresh
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var page: SettingsPage = .line
    @Published var snapshot = SettingsSnapshot()
    var onCommand: (SettingsCommand) -> Void = { _ in }

    func selectPage(_ page: SettingsPage) {
        guard page != self.page else { return }
        self.page = page
        onCommand(.refresh)
    }

    func binding<Value>(_ keyPath: KeyPath<SettingsSnapshot, Value>,
                        command: @escaping (Value) -> SettingsCommand) -> Binding<Value> {
        Binding(get: { self.snapshot[keyPath: keyPath] }, set: { self.onCommand(command($0)) })
    }
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    let model = SettingsModel()
    private(set) var window: NSWindow?

    func show() {
        model.onCommand(.refresh)
        let window = window ?? makeWindow()
        let animate = !window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate { window.alphaValue = 0 }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                window.animator().alphaValue = 1
            }
        } else { window.alphaValue = 1 }
    }

    @discardableResult func makeWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Replyline 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.minSize = NSSize(width: 730, height: 530)
        window.delegate = self
        window.contentView = NativeGlass.host(SettingsView(model: model), material: .underWindowBackground, cornerRadius: 18)
        window.center()
        self.window = window
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) { model.onCommand(.refresh) }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var navigation
    private var state: SettingsSnapshot { model.snapshot }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "tshirt").font(.system(size: 20, weight: .light)).foregroundStyle(SettingsTheme.accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Replyline").font(.system(size: 14, weight: .semibold))
                        Text("偏好设置").font(.system(size: 11)).foregroundStyle(SettingsTheme.secondary)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 44).padding(.bottom, 25)
                VStack(spacing: 4) {
                    ForEach(SettingsPage.allCases, id: \.self) { page in
                        SettingsNavigationRow(page: page, selected: model.page == page, navigation: navigation) {
                            model.selectPage(page)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .animation(reduceMotion ? nil : AppMotion.control, value: model.page)
                Spacer()
                Label("更改自动保存", systemImage: "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(SettingsTheme.muted)
                    .padding(.horizontal, 18).padding(.bottom, 18)
            }
            .frame(width: 188)
            .frame(maxHeight: .infinity)
            .background(SidebarMaterial())
            Rectangle().fill(SettingsTheme.line).frame(width: 0.5)
            ZStack(alignment: .topLeading) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.page.title)
                                .font(.system(size: 21, weight: .semibold)).tracking(-0.3)
                                .foregroundStyle(SettingsTheme.ink)
                            Text(model.page.subtitle).font(.system(size: 12)).foregroundStyle(SettingsTheme.secondary)
                        }.padding(.bottom, 2)
                        switch model.page {
                        case .line: lineSettings
                        case .images: imageSettings
                        case .shortcuts: shortcutSettings
                        case .general: generalSettings
                        }
                    }
                    .padding(.horizontal, 26).padding(.top, 44).padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(model.page)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsTheme.panel.opacity(reduceTransparency ? 1 : 0.98))
            .animation(reduceMotion ? nil : AppMotion.panel, value: model.page)
        }
        .font(.system(size: 13)).foregroundStyle(SettingsTheme.ink)
        .tint(SettingsTheme.accent)
        .buttonStyle(SettingsButtonStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lineSettings: some View {
        Group {
            SettingsCard(title: "手动展开", footer: triggerHelp) {
                SettingsRow(title: "菜单栏触发方式") {
                    GlassSegmentedControl(title: "菜单栏触发方式",
                                          options: [("关闭", MenuBarTrigger.disabled), ("悬停", .hover), ("双击", .doubleClick)],
                                          selection: model.binding(\.trigger, command: SettingsCommand.trigger)).frame(width: 218)
                }
                if state.trigger == .hover {
                    SettingsRule()
                    SettingsRow(title: "悬停等待时间") {
                        Picker("悬停等待时间", selection: model.binding(\.hoverDelay, command: SettingsCommand.hoverDelay)) {
                            ForEach(MenuBarHoverDelay.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 110)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else if state.trigger == .doubleClick {
                    SettingsRule()
                    SettingsRow(title: "辅助功能权限", subtitle: state.accessibility ? "已开启，可识别菜单栏空白处" : "开启后可识别菜单栏空白处") {
                        if state.accessibility {
                            Label("已开启", systemImage: "checkmark.circle")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(SettingsTheme.secondary).accessibilityLabel("已授权")
                        } else {
                            Button("去开启…") { model.onCommand(.accessibility) }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(reduceMotion ? nil : AppMotion.panel, value: state.trigger)
            SettingsCard(title: "自动展开", footer: "加入新截图、剪贴板图片或置顶素材时短暂展开，与手动触发方式独立。") {
                SettingsSwitch(title: "新卡片加入时自动展开", value: model.binding(\.peeksAtNew, command: SettingsCommand.peek))
            }
            SettingsCard(title: "显示") {
                SettingsSwitch(title: "允许在全屏应用中显示", value: model.binding(\.fullScreen, command: SettingsCommand.fullScreen))
                SettingsRule()
                SettingsRow(title: "卡片大小") {
                    GlassSegmentedControl(title: "卡片大小",
                                          options: [(L("Small"), Layout.Size.small), (L("Medium"), .medium), (L("Large"), .large)],
                                          selection: model.binding(\.size, command: SettingsCommand.size)).frame(width: 218)
                }
            }
        }
    }

    private var triggerHelp: String {
        switch state.trigger {
        case .disabled: "菜单栏手势已关闭，菜单和快捷键仍可展开晾衣架。"
        case .hover: "指针停留达到等待时间后展开。"
        case .doubleClick: "双击菜单栏空白处展开，菜单文字和状态图标不触发。"
        }
    }

    private var imageSettings: some View {
        Group {
            SettingsCard(title: "系统截图", footer: state.inbox ?
                         "系统截图保存到 Replyline，并关闭系统浮动缩略图。关闭此选项或正常退出后恢复原设置。" :
                         "继续使用系统的保存位置，Replyline 收集该目录中的新截图。") {
                SettingsRow(title: "保存方式") {
                    GlassSegmentedControl(title: "保存方式", options: [("系统位置", false), ("Replyline", true)],
                                          selection: model.binding(\.inbox, command: SettingsCommand.inbox)).frame(width: 218)
                }
                SettingsRule()
                SettingsRow(title: "当前截图文件夹", subtitle: state.screenshotFolder.path) {
                    Button { model.onCommand(.openScreenshotFolder) } label: { Image(systemName: "folder") }
                        .help("打开截图文件夹").accessibilityLabel("打开截图文件夹")
                }
            }
            SettingsCard(footer: "新复制的图片会加入临时卡片，普通文字复制不受影响。") {
                SettingsSwitch(title: "自动收集剪贴板图片", value: model.binding(\.clipboard, command: SettingsCommand.clipboard))
            }
            SettingsCard(title: "额外图片文件夹", footer: "最多添加 3 个目录，自动收集其中的新图片。移除目录只停止收集，不删除文件。") {
                if state.extraFolders.isEmpty {
                    SettingsRow(title: "尚未添加文件夹") { Image(systemName: "folder.badge.plus").foregroundStyle(.tertiary) }
                }
                ForEach(state.extraFolders, id: \.self) { folder in
                    SettingsRow(title: folder.lastPathComponent, subtitle: folder.path) {
                        Button { model.onCommand(.removeFolder(folder)) } label: { Image(systemName: "minus") }
                            .help("移除文件夹").accessibilityLabel("移除 \(folder.lastPathComponent)")
                    }
                    SettingsRule()
                }
                HStack {
                    Button("添加文件夹…") { model.onCommand(.addFolder) }.disabled(state.extraFolders.count >= AppDelegate.maxExtraFolders)
                    Spacer()
                }.padding(13)
            }
            SettingsCard(footer: "只限制临时卡片，固定素材长期保留。超出数量后，Replyline 目录的旧文件移到废纸篓；外部文件只从晾衣架取下。") {
                SettingsRow(title: "临时卡片保留数量") {
                    Picker("临时卡片保留数量", selection: model.binding(\.keepCount, command: SettingsCommand.keep)) {
                        Text("适应屏幕").tag(Optional<Int>.none)
                        ForEach(Line.keepChoices, id: \.self) { Text("\($0) 张").tag(Optional($0)) }
                    }.labelsHidden().frame(width: 122)
                }
            }
        }
    }

    private var shortcutSettings: some View {
        Group {
            SettingsCard(title: "Replyline", footer: "录制时按 Esc 取消，按 Delete 禁用。常用素材组合为固定保留键。") {
                SettingsRow(title: "显示／隐藏晾衣架", subtitle: !state.shortcutAvailable && state.shortcut != nil && !state.recording ? "当前组合无法注册，请修改或使用菜单。" : nil) {
                    Text(state.shortcut?.display ?? "未设置").monospaced().foregroundStyle(.secondary)
                    Button(state.recording ? "录制中…" : "修改…") { model.onCommand(.recordShortcut) }.disabled(state.recording)
                }
                SettingsRule()
                SettingsRow(title: "管理常用素材", subtitle: !state.libraryShortcutAvailable && !state.recording ? "组合被占用，请通过菜单打开。" : nil) {
                    Text(Shortcut.library.display).monospaced().foregroundStyle(.secondary)
                }
            }
            SettingsCard(title: "macOS", footer: "打开后自动定位到「截屏」分类，使用已有辅助功能授权。快捷键仍在系统设置中修改。") {
                SettingsRow(title: "系统截屏快捷键") {
                    Button("设置截屏快捷键…") { model.onCommand(.systemScreenshotShortcut) }
                }
            }
        }
    }

    private var generalSettings: some View {
        Group {
            SettingsCard(title: "启动") {
                SettingsSwitch(title: "登录时启动 Replyline", value: model.binding(\.login, command: SettingsCommand.login))
            }
            SettingsCard(title: "反馈") {
                SettingsSwitch(title: "播放交互音效", subtitle: "卡片操作时播放轻量提示音", value: model.binding(\.sound, command: SettingsCommand.sound))
            }
        }
    }
}

private struct SettingsNavigationRow: View {
    let page: SettingsPage
    let selected: Bool
    let navigation: Namespace.ID
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.icon).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? SettingsTheme.accent : SettingsTheme.secondary)
                    .frame(width: 24, height: 26).accessibilityHidden(true)
                Text(page.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(SettingsTheme.ink)
                Spacer(minLength: 0)
                if selected {
                    Circle().fill(SettingsTheme.accent).frame(width: 4, height: 4).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.selected)
                        .matchedGeometryEffect(id: "selectedPage", in: navigation)
                } else if hovered {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SettingsTheme.inset)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(SoftPressButtonStyle())
        .onHover { hovered = $0 }
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsTheme.accent.opacity(focused ? 0.8 : 0), lineWidth: 1.5))
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SoftPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.985)
            .animation(reduceMotion ? nil : AppMotion.control, value: configuration.isPressed)
    }
}
