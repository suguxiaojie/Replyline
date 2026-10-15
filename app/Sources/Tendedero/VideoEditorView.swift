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
            TextField("视频标题", text: $title).textFieldStyle(.roundedBorder)
            TextField("关键词，例如：操作指引 教程", text: $keywords).textFieldStyle(.roundedBorder)
            Button {
                if let url { QuickLook.shared.show([url], at: 0) }
            } label: {
                Group {
                    if let poster { Image(nsImage: poster).resizable().scaledToFit() }
                    else { Image(systemName: "video").font(.system(size: 36)).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity).frame(height: 200)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    Image(systemName: "play.fill").font(.system(size: 18, weight: .semibold))
                        .padding(14).background(.regularMaterial, in: Circle())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("预览视频")
            HStack {
                Button(reading ? "正在读取…" : "替换视频…", action: chooseVideo).disabled(reading)
                Text("MP4、MOV、M4V").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("也可拖入视频替换；保存后保留独立副本。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Toggle("置顶到晾衣架", isOn: $pinned)
            Text("复制后回到微信粘贴，确认后发送。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "保存中…" : "保存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(reading || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (card == nil && input == nil))
            }
        }
        .padding(24).frame(width: 500)
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
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7]))
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
