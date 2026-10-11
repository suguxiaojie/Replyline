import AppKit
import Combine

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var cards: [LibraryCard] = []
    @Published var error: String?
    @Published var editingID: UUID?
    private(set) var repository: LibraryRepository?
    var onChange: () -> Void = {}
    var onCopy: () -> Void = {}

    init(folder: URL = LibraryRepository.defaultFolder) {
        do {
            repository = try LibraryRepository(folder: folder)
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    var isWritable: Bool { repository != nil }

    func assetURL(_ card: LibraryCard) -> URL? { repository?.assetURL(for: card) }

    func perform(_ operation: (LibraryRepository) throws -> Void) -> Bool {
        guard let repository else { error = LibraryError.invalidLibrary.localizedDescription; return false }
        do {
            try operation(repository)
            refresh()
            onChange()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func setPinned(_ id: UUID, _ pinned: Bool) -> Bool {
        perform { try $0.setPinned(id, pinned) }
    }

    func remove(_ card: LibraryCard) {
        _ = perform { repository in
            let removed = try repository.remove(card.id)
            do {
                let url = repository.assetURL(for: removed)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            } catch {
                try repository.restore(removed)
                throw error
            }
        }
    }

    @discardableResult
    func copy(_ id: UUID, returnToChat: Bool = true) -> Bool {
        guard let card = repository?.find(id) else { return false }
        let pb = NSPasteboard.general
        if card.kind == .text {
            pb.clearContents()
            guard pb.setString(card.text, forType: .string) else { return false }
        } else {
            guard let url = assetURL(card), let data = imagePNG(url) else {
                error = "图片无法读取，请检查素材文件。"
                return false
            }
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            item.setString(url.absoluteString, forType: .fileURL)
            pb.clearContents()
            guard pb.writeObjects([item]) else { return false }
        }
        if returnToChat { onCopy() }
        return true
    }

    private func refresh() {
        cards = (repository?.cards ?? []).sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.createdAt < $1.createdAt
        }
    }
}

func imagePNG(_ url: URL) -> Data? {
    if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
    guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

/// Only the content changes: the existing glass frame, peg and motion wrap it.
@MainActor
func libraryThumbnail(_ card: LibraryCard, url: URL) -> NSImage? {
    if card.kind == .image { return makeThumbnail(url) }
    let size = NSSize(width: 320, height: 222)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    let titleStyle = NSMutableParagraphStyle()
    titleStyle.lineBreakMode = .byTruncatingTail
    (card.title as NSString).draw(in: NSRect(x: 22, y: 175, width: 276, height: 28), withAttributes: [
        .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 1), .paragraphStyle: titleStyle,
    ])
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    style.lineSpacing = 5
    (card.text as NSString).draw(with: NSRect(x: 22, y: 20, width: 276, height: 141),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
        .font: NSFont.systemFont(ofSize: 18),
        .foregroundColor: NSColor(calibratedWhite: 0.30, alpha: 1), .paragraphStyle: style,
    ], context: nil)
    image.unlockFocus()
    return image
}
