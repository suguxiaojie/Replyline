import AppKit

/// Add a private local identity without replacing the file/text formats
/// consumed by other apps. Only LinePanel accepts this private type.
final class CardDragWriter: NSObject, NSPasteboardWriting {
    static let type = NSPasteboard.PasteboardType("local.coverai.Replyline.card-reorder")
    let id: UUID
    private let payload: NSPasteboardWriting

    init(id: UUID, payload: NSPasteboardWriting) {
        self.id = id
        self.payload = payload
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        payload.writableTypes(for: pasteboard) + [Self.type]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == Self.type ? id.uuidString : payload.pasteboardPropertyList(forType: type)
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == Self.type ? [] : payload.writingOptions?(forType: type, pasteboard: pasteboard) ?? []
    }
}
