import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LibraryWindow: NSObject {
    private let model: LibraryModel
    private var window: NSWindow?
    private var previousApp: NSRunningApplication?

    init(model: LibraryModel) {
        self.model = model
        super.init()
        model.onCopy = { [weak self] in self?.returnToChat() }
    }

    func show(editing id: UUID? = nil, returningTo application: NSRunningApplication? = nil) {
        let front = application ?? NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        if window == nil {
            let view = LibraryView(model: model, close: { [weak self] in self?.returnToChat() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Replyline · 常用素材"
            window.titlebarAppearsTransparent = true
            window.backgroundColor = AppTheme.windowBackground
            window.contentView = NSHostingView(rootView: view)
            window.minSize = NSSize(width: 620, height: 460)
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.editingID = id
    }

    private func returnToChat() {
        window?.orderOut(nil)
        previousApp?.activate(options: [])
    }
}

struct LibraryEditorView: View {
    @ObservedObject var model: LibraryModel
    let card: LibraryCard?
    let source: ImageImport?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var keywords: String
    @State private var text: String
    @State private var pinned: Bool
    @State private var saving = false
    @State private var error: String?
    @State private var replacement: ImageImport?
    @State private var dropping = false

    private var isText: Bool { card?.kind == .text || (card == nil && source == nil) }

    init(model: LibraryModel, card: LibraryCard?, source: ImageImport?) {
        self.model = model
        self.card = card
        self.source = source
        _title = State(initialValue: card?.title ?? source?.name ?? "")
        _keywords = State(initialValue: card?.keywords ?? "")
        _text = State(initialValue: card?.text ?? "")
        _pinned = State(initialValue: card?.pinned ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(card == nil ? (isText ? "新建话术" : "导入图片") : "编辑素材")
                .font(.system(size: 20, weight: .semibold))
            EditorField(title: "标题") {
                TextField("例如：如何关闭自动续费", text: $title).textFieldStyle(.plain).modifier(EditorInputSurface()).accessibilityLabel("素材标题")
            }
            EditorField(title: "关键词") {
                TextField("例如：续费 扣费 取消", text: $keywords).textFieldStyle(.plain).modifier(EditorInputSurface()).accessibilityLabel("素材关键词")
            }
            if isText {
                Text("话术内容").font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.secondary)
                TextEditor(text: $text).font(.system(size: 14)).frame(height: 190)
                    .scrollContentBackground(.hidden).modifier(EditorInputSurface()).accessibilityLabel("话术内容")
                Text("复制完整内容，保留换行。").font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
            } else if let image = preview {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 200)
                    .background(AppTheme.sidebar, in: RoundedRectangle(cornerRadius: 10))
            }
            if !isText {
                HStack {
                    Button("替换图片…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .webP]
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { receiveImage(Result { try ImageImport.read(url) }) }
                    }
                    Button("粘贴图片") { receiveImage(Result { try ImageImport.from(.general) }) }
                }
                Text("也可把图片拖到这里，或按 ⌘V 粘贴图片。")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
            }
            Toggle("置顶到晾衣架", isOn: $pinned)
            Text("取下或清空临时截图，都不会删除固定素材。")
                .font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
            EditorStatus(busy: saving ? "正在保存素材…" : nil, error: error)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "保存中…" : "保存", action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (isText && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24).frame(width: 500)
        .background(AppTheme.panel).foregroundStyle(AppTheme.ink).tint(AppTheme.accent)
        .buttonStyle(SettingsButtonStyle())
        .background {
            if !isText { ImagePasteShortcut(onImage: receiveImage) }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            guard !isText else { return false }
            return ImageImport.load(providers) { result in
                DispatchQueue.main.async { receiveImage(result) }
            }
        }
        .overlay {
            if dropping && !isText {
                RoundedRectangle(cornerRadius: 12).stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .padding(6).allowsHitTesting(false)
            }
        }
    }

    private var preview: NSImage? {
        if let input = replacement ?? source { return input.thumbnail() }
        if let card, let url = model.assetURL(card) { return makeThumbnail(url, maxPixels: 600) }
        return nil
    }

    private func receiveImage(_ result: Result<ImageImport, Error>) {
        switch result {
        case .success(let input): replacement = input; error = nil
        case .failure(let failure): error = failure.localizedDescription
        }
    }

    private func save() {
        saving = true
        let success = model.perform { repository in
            if let card {
                try repository.update(card.id, title: title, text: text, keywords: keywords, pinned: pinned, imageInput: replacement)
            } else if let input = replacement ?? source {
                try repository.addImage(input: input, title: title, keywords: keywords, pinned: pinned)
            } else {
                try repository.addText(title: title, text: text, keywords: keywords, pinned: pinned)
            }
        }
        saving = false
        if success { dismiss() }
        else { error = model.error; model.error = nil }
    }
}
