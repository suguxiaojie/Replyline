import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Keep movie bytes on disk. Validation and poster extraction are async;
/// importing a large movie never reads its entire contents into memory.
struct VideoImport: Sendable {
    static let extensions: Set<String> = ["mp4", "mov", "m4v"]
    static let contentTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, UTType(filenameExtension: "m4v")!]
    let url: URL
    let name: String
    let poster: Data

    static func read(_ url: URL) async throws -> VideoImport {
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()) else { throw LibraryError.invalidVideo }
        let file = url.resolvingSymlinksInPath()
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size > 0 else { throw LibraryError.invalidVideo }
        let asset = AVURLAsset(url: file)
        do {
            guard try await asset.load(.isPlayable),
                  !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw LibraryError.invalidVideo }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 600)
            let frame = try await generator.image(at: .zero).image
            let rep = NSBitmapImageRep(cgImage: frame)
            guard let poster = rep.representation(using: .png, properties: [:]) else { throw LibraryError.invalidVideo }
            return VideoImport(url: url, name: url.deletingPathExtension().lastPathComponent, poster: poster)
        } catch is CancellationError { throw CancellationError() }
        catch { throw LibraryError.invalidVideo }
    }

    static func posterURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("poster.png")
    }

    /// Only called for a newly generated, unreferenced library asset path.
    static func copy(_ source: URL, to destination: URL) async throws -> VideoImport {
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }.value
            try Task.checkCancellation()
            // Validate the actual saved copy: a source can change while an
            // editor is open. Its cached poster must match the saved bytes.
            return try await read(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

enum LibraryImport {
    case image(ImageImport), video(VideoImport)

    @discardableResult
    static func load(_ providers: [NSItemProvider], completion: @escaping (Result<LibraryImport, Error>) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return ImageImport.load(providers) { completion($0.map(LibraryImport.image)) }
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
            if let error { completion(.failure(error)); return }
            let url: URL?
            if let value = value as? URL { url = value }
            else if let data = value as? Data, let text = String(data: data, encoding: .utf8) { url = URL(string: text) }
            else if let text = value as? String { url = URL(string: text) }
            else { url = nil }
            guard let url, url.isFileURL else { completion(.failure(LibraryError.invalidVideo)); return }
            Task {
                do {
                    if VideoImport.extensions.contains(url.pathExtension.lowercased()) {
                        completion(.success(.video(try await VideoImport.read(url))))
                    } else { completion(.success(.image(try ImageImport.read(url)))) }
                } catch { completion(.failure(error)) }
            }
        }
        return true
    }
}
