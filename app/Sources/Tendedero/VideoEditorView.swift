import AppKit
import SwiftUI

struct VideoEditorView: View {
    @ObservedObject var model: LibraryModel
    let card: LibraryCard?
    let source: VideoImport?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var keywords: String
    @State private var pinned: Bool
    @State private var replacement: VideoImport?
    @State private var reading = false
    @State private var saving = false
    @State private var dropping = false
    @State private var error: String?
    @State private var info: VideoInfo?
    @State private var infoFailed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: LibraryModel, card: LibraryCard?, source: VideoImport?) {
        self.model = model
        self.card = card
        self.source = source
        _title = State(initialValue: card?.title ?? source?.name ?? "")
        _keywords = State(initialValue: card?.keywords ?? "")
        _pinned = State(initialValue: card?.pinned ?? true)
    }

    private var input: VideoImport? { replacement ?? source }
    private var url: URL? { input?.url ?? card.flatMap(model.assetURL) }
    private var poster: NSImage? {
        if let input { return NSImage(data: input.poster) }
        if let card, let url { return libraryThumbnail(card, url: url) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(card == nil ? "导入视频" : "编辑视频")
                .font(.system(size: 20, weight: .semibold))
            EditorField(title: "标题") { TextField("为视频起一个便于查找的标题", text: $title).textFieldStyle(.plain).modifier(EditorInputSurface()).accessibilityLabel("视频标题") }
            EditorField(title: "关键词") { TextField("例如：操作指引 教程", text: $keywords).textFieldStyle(.plain).modifier(EditorInputSurface()).accessibilityLabel("视频关键词") }
            Button {
                if let url { QuickLook.shared.show([url], at: 0) }
            } label: {
                Group {
                    if let poster { Image(nsImage: poster).resizable().scaledToFit() }
                    else { Image(systemName: "video").font(.system(size: 36)).foregroundStyle(AppTheme.secondary) }
                }
                .frame(maxWidth: .infinity).frame(height: 160)
                .background(AppTheme.sidebar, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    Image(systemName: "play.fill").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.ink).padding(14).background(AppTheme.elevated, in: Circle())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("预览视频")
            if let url {
                VStack(alignment: .leading, spacing: 3) {
                    Text(input?.url.lastPathComponent ?? "\(card?.title ?? "视频").\(url.pathExtension.lowercased())").lineLimit(1)
                    Text("\(url.pathExtension.uppercased()) · \(info?.summary ?? (infoFailed ? "无法读取文件信息" : "正在读取文件信息…"))").monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(AppTheme.muted)
            }
            HStack {
                Button(reading ? "正在读取…" : "替换视频…", action: chooseVideo).disabled(reading)
            }
            Text("支持 MP4、MOV、M4V，也可拖入替换；保存独立副本。")
                .font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
            Toggle("置顶到晾衣架", isOn: $pinned)
            EditorStatus(busy: saving ? "正在保存独立视频副本，请稍候…" : (reading ? "正在读取视频…" : nil), error: error)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "保存中…" : "保存", action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .disabled(reading || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (card == nil && input == nil))
            }
        }
        .padding(24).frame(width: 500)
        .background(AppTheme.panel).foregroundStyle(AppTheme.ink).tint(AppTheme.accent)
        .buttonStyle(SettingsButtonStyle())
        .animation(reduceMotion ? nil : AppMotion.panel, value: error)
        .task(id: url) {
            info = nil
            infoFailed = false
            guard let url else { return }
            let value = try? await VideoInfo.read(url)
            if !Task.isCancelled { info = value; infoFailed = value == nil }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard !saving, !reading else { return false }
            reading = true
            let accepted = LibraryImport.load(providers) { result in
                DispatchQueue.main.async {
                    reading = false
                    switch result {
                    case .success(.video(let input)): replacement = input; error = nil
                    case .success(.image): error = LibraryError.invalidVideo.localizedDescription
                    case .failure(let failure): error = failure.localizedDescription
                    }
                }
            }
            if !accepted { reading = false }
            return accepted
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .padding(6).allowsHitTesting(false)
            }
        }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = VideoImport.contentTypes
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        reading = true
        Task { @MainActor in
            defer { reading = false }
            do { replacement = try await VideoImport.read(url); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard !saving, !reading else { return }
        saving = true
        Task { @MainActor in
            let success: Bool
            if let input {
                success = await model.saveVideo(input, replacing: card?.id, title: title, keywords: keywords, pinned: pinned)
            } else if let card {
                success = model.perform { try $0.update(card.id, title: title, text: "", keywords: keywords, pinned: pinned) }
            } else { success = false }
            saving = false
            if success { dismiss() }
            else { error = model.error ?? LibraryError.invalidVideo.localizedDescription; model.error = nil }
        }
    }
}
