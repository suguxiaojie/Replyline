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

private struct LibraryEditor: Identifiable {
    let id = UUID()
    let card: LibraryCard?
    let image: ImageImport?
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    let close: () -> Void
    @State private var query = ""
    @State private var kind: LibraryKind?
    @State private var editor: LibraryEditor?
    @State private var deleting: LibraryCard?
    @FocusState private var searching: Bool
    @State private var dropping = false

    private var visible: [LibraryCard] {
        model.cards.filter { (kind == nil || $0.kind == kind) && $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索标题、话术或关键词", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searching)
                        .onSubmit { if let first = visible.first { model.copy(first.id) } }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                Button { editor = LibraryEditor(card: nil, image: nil) } label: {
                    Label("新建话术", systemImage: "text.bubble")
                }
                Button(action: importImage) { Label("导入图片", systemImage: "photo.badge.plus") }
                Button(action: pasteImage) { Label("粘贴图片", systemImage: "doc.on.clipboard") }
            }
            .disabled(!model.isWritable)
            .padding(20)
            HStack {
                Picker("类型", selection: $kind) {
                    Text("全部").tag(Optional<LibraryKind>.none)
                    Text("话术").tag(Optional(LibraryKind.text))
                    Text("图片").tag(Optional(LibraryKind.image))
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                Spacer()
                Text("\(visible.count) 条素材").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            if let error = model.error, !model.isWritable {
                emptyState("素材库暂时无法打开", detail: error, symbol: "exclamationmark.triangle")
            } else if visible.isEmpty {
                emptyState(query.isEmpty && model.cards.isEmpty ? "把常用回复放在这里" : "没有找到匹配的素材",
                           detail: model.cards.isEmpty ? "话术和图片分别保存，置顶后会挂在晾衣架上。" : "试试标题、话术中的文字或关键词。",
                           symbol: model.cards.isEmpty ? "tray" : "magnifyingglass")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: 14)], spacing: 14) {
                        ForEach(visible) { card in
                            tile(card)
                        }
                    }
                    .padding(20)
                }
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                Text("可拖入图片，或按 ⌘V 粘贴图片；置顶素材长期保留。")
                Spacer()
                Text("Esc 返回").foregroundStyle(.tertiary)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(14)
        }
        .frame(minWidth: 620, minHeight: 420)
        .background(.background)
        .background(ImagePasteShortcut(onImage: receiveImage))
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            guard model.isWritable else { return false }
            return ImageImport.load(providers) { result in
                DispatchQueue.main.async { receiveImage(result) }
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .padding(6).allowsHitTesting(false)
            }
        }
        .onAppear { searching = true; openEditor() }
        .onChange(of: model.editingID) { _, _ in openEditor() }
        .onExitCommand(perform: close)
        .sheet(item: $editor) { draft in
            LibraryEditorView(model: model, card: draft.card, source: draft.image)
        }
        .alert("移除这条素材？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("移到废纸篓", role: .destructive) {
                if let card = deleting { model.remove(card) }
                deleting = nil
            }
        } message: {
            Text("素材会从库和晾衣架移除，库内文件移到废纸篓。导入时的原始图片不会受影响。")
        }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil && model.isWritable },
                                               set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 19, weight: .semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            Spacer()
        }
        .frame(maxWidth: .infinity).padding(28)
    }

    private func tile(_ card: LibraryCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.copy(card.id) } label: {
                Group {
                    if card.kind == .text {
                        Text(card.text).font(.system(size: 13)).lineSpacing(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(14)
                    } else if let url = model.assetURL(card), let image = makeThumbnail(url, maxPixels: 500) {
                        Image(nsImage: image).resizable().scaledToFit().padding(8)
                    } else {
                        Label("图片文件缺失", systemImage: "photo.badge.exclamationmark")
                    }
                }
                .frame(height: 124).frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(card.kind == .text ? "复制完整话术并返回聊天" : "复制图片并返回聊天")
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(card.keywords.isEmpty ? (card.kind == .text ? "话术" : "图片") : card.keywords)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { model.setPinned(card.id, !card.pinned) } label: {
                    Image(systemName: card.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(card.pinned ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain).help(card.pinned ? "从晾衣架取下，保留素材" : "置顶到晾衣架")
            }
            HStack {
                Button("编辑") { editor = LibraryEditor(card: card, image: nil) }
                Spacer()
                Button("复制") { model.copy(card.id) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
        .contextMenu {
            Button("复制") { model.copy(card.id) }
            Button("编辑") { editor = LibraryEditor(card: card, image: nil) }
            Button(card.pinned ? "取消置顶" : "置顶到晾衣架") { model.setPinned(card.id, !card.pinned) }
            Divider()
            Button("移除素材…", role: .destructive) { deleting = card }
        }
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .webP]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入图片"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        receiveImage(Result { try ImageImport.read(source) })
    }

    private func pasteImage() { receiveImage(Result { try ImageImport.from(.general) }) }

    private func receiveImage(_ result: Result<ImageImport, Error>) {
        guard model.isWritable else { return }
        switch result {
        case .success(let input): editor = LibraryEditor(card: nil, image: input)
        case .failure(let error): model.error = error.localizedDescription
        }
    }

    private func openEditor() {
        guard let id = model.editingID, let card = model.cards.first(where: { $0.id == id }) else { return }
        editor = LibraryEditor(card: card, image: nil)
        model.editingID = nil
    }
}

private struct LibraryEditorView: View {
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
            TextField("标题，例如：如何关闭自动续费", text: $title).textFieldStyle(.roundedBorder)
            TextField("关键词，例如：续费 扣费 取消", text: $keywords).textFieldStyle(.roundedBorder)
            if isText {
                Text("话术内容").font(.system(size: 12)).foregroundStyle(.secondary)
                TextEditor(text: $text).font(.system(size: 14)).frame(height: 190)
                    .padding(6).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                Text("复制完整内容，保留换行。").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let image = preview {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 200)
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
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Toggle("置顶到晾衣架", isOn: $pinned)
            Text("取下或清空临时截图，都不会删除固定素材。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "保存中…" : "保存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (isText && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24).frame(width: 500)
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
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7]))
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
