import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ImageImport {
    let data: Data
    let fileExtension: String
    let name: String
    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    init(data: Data, name: String) throws {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let ext = UTType(type as String)?.preferredFilenameExtension?.lowercased(),
              Self.extensions.contains(ext),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,
              let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 80_000_000 / height,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary) != nil else { throw LibraryError.invalidImage }
        self.data = data
        self.fileExtension = ext
        self.name = name
    }

    static func read(_ url: URL) throws -> ImageImport {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= 64 * 1024 * 1024 else { throw LibraryError.invalidImage }
        return try ImageImport(data: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
    }

    static func from(_ pasteboard: NSPasteboard) throws -> ImageImport {
        // Finder copies may include the file's icon. Read the original first.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first { return try read(url) }
        guard let type = pasteboard.availableType(from: [.png, .tiff]),
              let data = pasteboard.data(forType: type) else { throw LibraryError.noClipboardImage }
        return try ImageImport(data: data, name: "粘贴的图片")
    }

    static func canPasteImage(_ pasteboard: NSPasteboard) -> Bool {
        // A text copy may also carry a rendered picture; Command-V stays text.
        if pasteboard.availableType(from: [.string]) != nil { return false }
        if let raw = pasteboard.string(forType: .fileURL), let url = URL(string: raw) {
            return extensions.contains(url.pathExtension.lowercased())
        }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    func thumbnail(maxPixels: Int = 600) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    @discardableResult
    static func load(_ providers: [NSItemProvider], completion: @escaping (Result<ImageImport, Error>) -> Void) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }) else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error { completion(.failure(error)); return }
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data, let value = String(data: data, encoding: .utf8) { url = URL(string: value) }
                else if let value = item as? String { url = URL(string: value) }
                else { url = nil }
                guard let url, url.isFileURL else { completion(.failure(LibraryError.invalidImage)); return }
                completion(Result { try read(url) })
            }
        } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error { completion(.failure(error)); return }
                guard let data else { completion(.failure(LibraryError.invalidImage)); return }
                completion(Result { try ImageImport(data: data, name: "拖入的图片") })
            }
        } else { return false }
        return true
    }
}

/// Scoped to this view's window, so text shortcuts in other windows retain
/// standard AppKit handling. Register only on views that accept image imports.
struct ImagePasteShortcut: NSViewRepresentable {
    var onImage: (Result<ImageImport, Error>) -> Void

    func makeNSView(context: Context) -> PasteView {
        let view = PasteView()
        view.onImage = onImage
        view.start()
        return view
    }

    func updateNSView(_ view: PasteView, context: Context) { view.onImage = onImage }
    static func dismantleNSView(_ view: PasteView, coordinator: ()) { view.stop() }

    final class PasteView: NSView {
        var onImage: (Result<ImageImport, Error>) -> Void = { _ in }
        private var monitor: Any?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "v",
                      ImageImport.canPasteImage(.general) else { return event }
                self.onImage(Result { try ImageImport.from(.general) })
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
