import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct LibraryEditor: Identifiable {
    let id = UUID()
    let card: LibraryCard?
    let image: ImageImport?
    var video: VideoImport? = nil
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    let close: () -> Void
    @State private var query = ""
    @State private var kind: LibraryKind?
    @State private var editor: LibraryEditor?
    @State private var deleting: LibraryCard?
    @State private var layout: LibraryLayout
    @State private var selection: UUID?
    @State private var hovered: UUID?
    @State private var dropping = false
    @State private var importing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Focus: Hashable { case search, results }
    @FocusState private var focus: Focus?

    init(model: LibraryModel, close: @escaping () -> Void, layout: LibraryLayout = .compact) {
        self.model = model; self.close = close; _layout = State(initialValue: layout)
    }

    private var visible: [LibraryCard] {
        model.cards.filter { (kind == nil || $0.kind == kind) && $0.matches(query) }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                Rectangle().fill(AppTheme.line).frame(height: 0.5)
                if let error = model.error, !model.isWritable {
                    empty("素材库暂时无法打开", detail: error, symbol: "exclamationmark.triangle")
                } else if visible.isEmpty {
                    empty(model.cards.isEmpty ? "把常用回复放在这里" : "没有找到匹配的素材",
                          detail: model.cards.isEmpty ? "新增话术，或拖入图片和视频。置顶后会挂在晾衣架上。" : "试试标题、正文或关键词，也可以切换类型。",
                          symbol: model.cards.isEmpty ? "tray" : "magnifyingglass")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Group {
                                if layout == .compact {
                                    LazyVStack(spacing: 6) { ForEach(visible) { item($0, compact: true) } }
                                } else {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: 12)], spacing: 12) {
                                        ForEach(visible) { item($0, compact: false) }
                                    }
                                }
                            }
                            .padding(16)
                            .animation(reduceMotion ? nil : AppMotion.reorder, value: visible.map(\.id))
                        }
                        .focusable().focusEffectDisabled().focused($focus, equals: .results)
                        .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
                    }
                }
                Rectangle().fill(AppTheme.line).frame(height: 0.5)
                HStack(spacing: 10) {
                    Text("\(visible.count) 条素材").monospacedDigit()
                    Spacer()
                    if importing { ProgressView().controlSize(.small); Text("正在读取素材…") }
                    else { Text("↑↓ 选择 · ↵ 复制 · 空格预览"); Text("Esc 返回").foregroundStyle(.tertiary) }
                }
                .font(.system(size: 11)).foregroundStyle(AppTheme.muted).padding(.horizontal, 18).padding(.vertical, 12)
                .background(AppTheme.sidebar)
            }
            .background(LibraryKeyCommands { event, composing in handle(event, composing: composing, width: geometry.size.width) })
        }
        .frame(minWidth: 620, minHeight: 420)
        .background(AppTheme.panel)
        .font(.system(size: 13)).foregroundStyle(AppTheme.ink).tint(AppTheme.accent)
        .buttonStyle(SettingsButtonStyle())
        .background(ImagePasteShortcut(onImage: receiveImage))
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            guard model.isWritable, !importing else { return false }
            importing = true
            let accepted = LibraryImport.load(providers) { result in
                DispatchQueue.main.async {
                    importing = false
                    switch result {
                    case .success(.image(let input)): receiveImage(.success(input))
                    case .success(.video(let input)): editor = LibraryEditor(card: nil, image: nil, video: input)
                    case .failure(let error): model.error = error.localizedDescription
                    }
                }
            }
            if !accepted { importing = false }
            return accepted
        }
        .overlay { if dropping { RoundedRectangle(cornerRadius: 12).strokeBorder(AppTheme.accent, lineWidth: 2).padding(6).allowsHitTesting(false) } }
        .onAppear { focus = .search; openEditor() }
        .onChange(of: model.editingID) { _, _ in openEditor() }
        .onChange(of: query) { _, _ in selection = visible.first?.id }
        .onChange(of: kind) { _, _ in selection = visible.first?.id }
        .onChange(of: model.cards) { _, _ in if !visible.contains(where: { $0.id == selection }) { selection = nil } }
        .onExitCommand(perform: close)
        .sheet(item: $editor) { draft in
            if draft.video != nil || draft.card?.kind == .video { VideoEditorView(model: model, card: draft.card, source: draft.video) }
            else { LibraryEditorView(model: model, card: draft.card, source: draft.image) }
        }
        .alert("移除这条素材？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("移到废纸篓", role: .destructive) { if let card = deleting { model.remove(card) }; deleting = nil }
        } message: { Text("素材会从库和晾衣架移除，库内文件移到废纸篓。导入时的原始文件不会受影响。") }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil && model.isWritable }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.muted).accessibilityHidden(true)
                TextField("搜索标题、正文或关键词", text: $query).textFieldStyle(.plain).focused($focus, equals: .search)
                    .accessibilityLabel("搜索素材")
                if !query.isEmpty { UtilityIconButton(title: "清空搜索", symbol: "xmark.circle.fill") { query = "" } }
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(AppTheme.cardFill, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focus == .search ? AppTheme.accent.opacity(0.65) : AppTheme.line, lineWidth: 1))
            HStack(spacing: 10) {
                GlassSegmentedControl(title: "素材类型", options: [("全部", nil), ("话术", .text), ("图片", .image), ("视频", .video)], selection: $kind).frame(width: 260)
                Spacer(minLength: 4)
                UtilityIconButton(title: layout == .compact ? "切换为缩略图网格" : "切换为紧凑列表", symbol: layout == .compact ? "square.grid.2x2" : "list.bullet") {
                    layout = layout == .compact ? .grid : .compact
                }
                Menu {
                    Button("新建话术", systemImage: "text.bubble") { editor = LibraryEditor(card: nil, image: nil) }
                    Button("导入图片…", systemImage: "photo") { importImage() }
                    Button("导入视频…", systemImage: "video") { importVideo() }
                } label: {
                    Label("新增素材", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.ink)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(AppTheme.selected, in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button("粘贴图片") { receiveImage(Result { try ImageImport.from(.general) }) }.controlSize(.small)
            }
        }
        .disabled(!model.isWritable || importing).padding(16).background(AppTheme.sidebar)
    }

    private func item(_ card: LibraryCard, compact: Bool) -> some View {
        Group {
            if compact {
                HStack(spacing: 12) {
                    Button { model.preview(card.id) } label: { thumbnail(card).frame(width: 52, height: 52) }
                        .buttonStyle(.plain).help("预览：\(card.title)").accessibilityLabel("预览：\(card.title)")
                    Button { copy(card) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink).lineLimit(1)
                            Text(card.kind == .text ? card.text : (model.videoInfo[card.asset]?.summary ?? card.kind.label))
                                .font(.system(size: 12)).foregroundStyle(AppTheme.secondary).lineLimit(1).monospacedDigit()
                            if !card.keywords.isEmpty { Text(card.keywords).font(.system(size: 11)).foregroundStyle(AppTheme.muted).lineLimit(1) }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("复制：\(card.title)")
                    actions(card)
                }.padding(10)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button { copy(card) } label: {
                        Group {
                            if card.kind == .text { Text(card.text).font(.system(size: 12)).lineSpacing(3).lineLimit(3).frame(maxWidth: .infinity, alignment: .topLeading).padding(10) }
                            else { thumbnail(card, playback: false) }
                        }.frame(height: 80).frame(maxWidth: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("复制：\(card.title)")
                    Text(card.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.ink).lineLimit(1)
                    HStack {
                        Text(model.videoInfo[card.asset]?.summary ?? (card.keywords.isEmpty ? card.kind.label : card.keywords))
                            .font(.system(size: 11)).foregroundStyle(AppTheme.muted).lineLimit(1).monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    HStack { UtilityIconButton(title: "预览：\(card.title)", symbol: card.kind == .video ? "play" : "eye") { model.preview(card.id) }; Spacer(minLength: 0); actions(card) }
                }.padding(10)
            }
        }
        .background(selection == card.id ? AppTheme.selected : (hovered == card.id ? AppTheme.sidebar : AppTheme.cardFill), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selection == card.id ? AppTheme.accent.opacity(0.55) : AppTheme.line, lineWidth: 0.5))
        .id(card.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.title)
        .accessibilityAddTraits(selection == card.id ? .isSelected : [])
        .onHover { inside in
            if inside { hovered = card.id } else if hovered == card.id { hovered = nil }
        }
        .animation(reduceMotion ? nil : AppMotion.control, value: hovered == card.id)
        .task(id: card.asset) { await model.loadVideoInfo(card) }
        .contextMenu {
            Button("复制") { copy(card) }; Button("预览") { model.preview(card.id) }
            Button("编辑") { editor = LibraryEditor(card: card, image: nil) }
            Button(card.pinned ? "取消置顶" : "置顶到晾衣架") { model.setPinned(card.id, !card.pinned) }
            Divider(); Button("移除素材…", role: .destructive) { deleting = card }
        }
    }

    private func thumbnail(_ card: LibraryCard, playback: Bool = true) -> some View {
        Group {
            if card.kind == .text { Image(systemName: "text.bubble").font(.system(size: 20)).foregroundStyle(AppTheme.secondary) }
            else if let url = model.assetURL(card), let image = card.kind == .video ? libraryThumbnail(card, url: url) : makeThumbnail(url, maxPixels: 320) {
                Image(nsImage: image).resizable().scaledToFit().padding(3)
            } else { Image(systemName: "exclamationmark.triangle").foregroundStyle(AppTheme.muted) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.inset, in: RoundedRectangle(cornerRadius: 7))
        .overlay { if card.kind == .video && playback { Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(AppTheme.ink).padding(7).background(AppTheme.elevated, in: Circle()).allowsHitTesting(false) } }
    }

    private func actions(_ card: LibraryCard) -> some View {
        HStack(spacing: 2) {
            UtilityIconButton(title: "复制：\(card.title)", symbol: "doc.on.doc") { copy(card) }
            UtilityIconButton(title: "编辑：\(card.title)", symbol: "pencil") { editor = LibraryEditor(card: card, image: nil) }
            UtilityIconButton(title: card.pinned ? "取下：\(card.title)" : "置顶：\(card.title)", symbol: card.pinned ? "pin.fill" : "pin", selected: card.pinned) { model.setPinned(card.id, !card.pinned) }
        }
    }

    private func copy(_ card: LibraryCard) { selection = card.id; model.copy(card.id) }
    private func handle(_ event: NSEvent, composing: Bool, width: CGFloat) -> Bool {
        guard let command = LibraryKeyboard.command(keyCode: event.keyCode, modifiers: event.modifierFlags, composing: composing,
                                                     searching: focus == .search, browsing: focus == .results) else { return false }
        if command == .search { focus = .search; return true }
        if command == .copy || command == .preview {
            guard let card = visible.first(where: { $0.id == selection }) ?? visible.first else { return true }
            if command == .copy { copy(card) } else { model.preview(card.id) }
        } else {
            let columns = layout == .compact ? 1 : max(1, Int((width - 20) / 227))
            selection = LibraryKeyboard.target(command, selection: selection, ids: visible.map(\.id), columns: columns)
            focus = .results
        }
        return true
    }

    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) { Spacer(); Image(systemName: symbol).font(.system(size: 30, weight: .light)); Text(title).font(.system(size: 17, weight: .semibold)); Text(detail).font(.system(size: 12)).multilineTextAlignment(.center).frame(maxWidth: 380); Spacer() }
            .foregroundStyle(AppTheme.secondary).frame(maxWidth: .infinity).padding(24)
    }
    private func importImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .webP]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { receiveImage(Result { try ImageImport.read(url) }) }
    }
    private func importVideo() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = VideoImport.contentTypes; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task { @MainActor in
            defer { importing = false }
            do { editor = LibraryEditor(card: nil, image: nil, video: try await VideoImport.read(url)) }
            catch { model.error = error.localizedDescription }
        }
    }
    private func receiveImage(_ result: Result<ImageImport, Error>) {
        guard model.isWritable, !importing else { return }
        switch result { case .success(let image): editor = LibraryEditor(card: nil, image: image); case .failure(let error): model.error = error.localizedDescription }
    }
    private func openEditor() {
        guard let id = model.editingID, let card = model.cards.first(where: { $0.id == id }) else { return }
        editor = LibraryEditor(card: card, image: nil); model.editingID = nil
    }
}
