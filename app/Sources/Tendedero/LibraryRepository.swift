import Foundation

enum LibraryKind: String, Codable, CaseIterable {
    case text, image
}

struct LibraryCard: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: LibraryKind
    var title: String
    var keywords: String
    var text: String
    var asset: String
    var pinned: Bool
    let createdAt: Date
    var updatedAt: Date

    func matches(_ query: String) -> Bool {
        let haystack = "\(title) \(keywords) \(text)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            haystack.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
    }
}

enum LibraryError: LocalizedError {
    case emptyTitle, emptyText, invalidImage, invalidLibrary, missingCard, noClipboardImage

    var errorDescription: String? {
        switch self {
        case .emptyTitle: return "请填写素材标题。"
        case .emptyText: return "话术内容不能为空。"
        case .invalidImage: return "请选择有效图片，文件不能超过 64 MB，图片不能超过 8,000 万像素。"
        case .invalidLibrary: return "素材库格式异常，已停止写入。请保留原文件后检查。"
        case .missingCard: return "这条素材已不存在，请重新打开素材库。"
        case .noClipboardImage: return "剪贴板里没有图片，请先复制图片或图片文件。"
        }
    }
}

/// All assets belong to the library; imports never depend on the source file.
/// The index is replaced atomically, and a failed write leaves memory unchanged.
final class LibraryRepository {
    private struct Document: Codable {
        var version = 1
        var cards: [LibraryCard]
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Replyline/Library", isDirectory: true)
    }

    let folder: URL
    private(set) var cards: [LibraryCard]
    private let fm = FileManager.default
    private var index: URL { folder.appendingPathComponent("library.json") }
    private var assets: URL { folder.appendingPathComponent("Assets", isDirectory: true) }
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    init(folder: URL = defaultFolder) throws {
        self.folder = folder
        let index = folder.appendingPathComponent("library.json")
        if fm.fileExists(atPath: index.path) {
            let document: Document
            do { document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: index)) }
            catch { throw LibraryError.invalidLibrary }
            guard document.version == 1,
                  Set(document.cards.map(\.id)).count == document.cards.count,
                  document.cards.allSatisfy(Self.valid) else { throw LibraryError.invalidLibrary }
            cards = document.cards
        } else {
            cards = []
        }
    }

    func assetURL(for card: LibraryCard) -> URL {
        assets.appendingPathComponent(card.asset)
    }

    func find(_ id: UUID) -> LibraryCard? { cards.first { $0.id == id } }

    @discardableResult
    func addText(title: String, text: String, keywords: String = "", pinned: Bool = true) throws -> LibraryCard {
        let title = try Self.checkedTitle(title)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.emptyText }
        let now = Date()
        let card = LibraryCard(id: UUID(), kind: .text, title: title, keywords: keywords,
                               text: text, asset: "\(UUID().uuidString).txt", pinned: pinned,
                               createdAt: now, updatedAt: now)
        try add(card, data: Data(text.utf8))
        return card
    }

    @discardableResult
    func addImage(source: URL, title: String, keywords: String = "", pinned: Bool = true) throws -> LibraryCard {
        try addImage(input: ImageImport.read(source), title: title, keywords: keywords, pinned: pinned)
    }

    @discardableResult
    func addImage(input: ImageImport, title: String, keywords: String = "", pinned: Bool = true) throws -> LibraryCard {
        let title = try Self.checkedTitle(title)
        let now = Date()
        let card = LibraryCard(id: UUID(), kind: .image, title: title, keywords: keywords,
                               text: "", asset: "\(UUID().uuidString).\(input.fileExtension)", pinned: pinned,
                               createdAt: now, updatedAt: now)
        try add(card, data: input.data)
        return card
    }

    func update(_ id: UUID, title: String, text: String, keywords: String, pinned: Bool,
                imageSource: URL? = nil, imageInput: ImageImport? = nil) throws {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingCard }
        var next = cards
        next[i].title = try Self.checkedTitle(title)
        next[i].keywords = keywords
        next[i].pinned = pinned
        next[i].updatedAt = Date()
        if next[i].kind == .text {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.emptyText }
            next[i].text = text
            if text != cards[i].text {
                next[i].asset = "\(UUID().uuidString).txt"
                try replaceAsset(next, at: i, data: Data(text.utf8))
                return
            }
        } else if imageSource != nil || imageInput != nil {
            let input: ImageImport
            if let imageInput { input = imageInput }
            else { input = try ImageImport.read(imageSource!) }
            next[i].asset = "\(UUID().uuidString).\(input.fileExtension)"
            try replaceAsset(next, at: i, data: input.data)
            return
        }
        try persist(next)
    }

    private func replaceAsset(_ next: [LibraryCard], at i: Int, data: Data) throws {
        let oldAsset = assetURL(for: cards[i])
        let newAsset = assetURL(for: next[i])
        try prepare()
        try writeAsset(data, to: newAsset)
        do { try persist(next) }
        catch { try? fm.removeItem(at: newAsset); throw error }
        try? fm.removeItem(at: oldAsset)
    }

    func setPinned(_ id: UUID, _ pinned: Bool) throws {
        guard let card = find(id) else { throw LibraryError.missingCard }
        try update(id, title: card.title, text: card.text, keywords: card.keywords, pinned: pinned)
    }

    /// Removing from the index does not destroy its asset. The UI moves that
    /// asset to the Trash only after the user confirms, and can undo on failure.
    func remove(_ id: UUID) throws -> LibraryCard {
        guard let card = find(id) else { throw LibraryError.missingCard }
        try persist(cards.filter { $0.id != id })
        return card
    }

    func restore(_ card: LibraryCard) throws {
        guard find(card.id) == nil else { return }
        try persist(cards + [card])
    }

    private static func checkedTitle(_ title: String) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LibraryError.emptyTitle }
        return title
    }

    private static func valid(_ card: LibraryCard) -> Bool {
        guard !card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !card.asset.isEmpty, !card.asset.contains("/"), !card.asset.contains("\\"),
              !card.asset.hasPrefix(".") else { return false }
        let ext = (card.asset as NSString).pathExtension.lowercased()
        return card.kind == .text
            ? ext == "txt" && !card.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : imageExtensions.contains(ext) && card.text.isEmpty
    }

    private func prepare() throws {
        try fm.createDirectory(at: assets, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    private func writeAsset(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func add(_ card: LibraryCard, data: Data) throws {
        try prepare()
        let url = assetURL(for: card)
        try writeAsset(data, to: url)
        do { try persist(cards + [card]) }
        catch { try? fm.removeItem(at: url); throw error }
    }

    private func persist(_ next: [LibraryCard]) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(cards: next))
        try data.write(to: index, options: .atomic)
        // The parent is private before the atomic replacement, even if this fails.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        cards = next
    }
}
