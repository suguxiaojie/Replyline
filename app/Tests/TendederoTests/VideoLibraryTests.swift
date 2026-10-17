import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import Tendedero

private final class VideoDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
}

final class VideoLibraryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        folder = root.appendingPathComponent(".tmp/video-library/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func movie(_ name: String = "sample.mp4", rotated: Bool = false) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: name.hasSuffix("mov") ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32,
        ])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<32 {
            for x in 0..<64 {
                let i = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                base[i] = 180; base[i + 1] = UInt8(50 + x * 2); base[i + 2] = 40; base[i + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for n in 0..<2 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            guard input.isReadyForMoreMediaData else { throw NSError(domain: "VideoFixture", code: 1) }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(n), timescale: 2)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    func testIndependentMovieCopyPosterAndMixedLibraryReload() async throws {
        let url = try await movie()
        let bytes = try Data(contentsOf: url)
        let input = try await VideoImport.read(url)
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        let text = try store.addText(title: "旧话术", text: "保留原内容\n第二行")
        let card = try await store.saveVideo(input: input, title: "操作视频", keywords: "教程")
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(card.kind, .video)
        XCTAssertTrue(card.pinned)
        XCTAssertEqual(try Data(contentsOf: store.assetURL(for: card)), bytes)
        let poster = VideoImport.posterURL(for: store.assetURL(for: card))
        XCTAssertTrue(FileManager.default.fileExists(atPath: poster.path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.assetURL(for: card).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let restored = try LibraryRepository(folder: store.folder)
        XCTAssertEqual(restored.find(text.id), text)
        XCTAssertEqual(restored.find(card.id), card)
        XCTAssertTrue(card.matches("操作 教程"))
        await MainActor.run {
            let library = LibraryModel(folder: store.folder)
            let line = Line(library: library, defaults: VideoDefaults(), breeze: false)
            library.onChange = { line.syncLibrary() }
            let video = line.items.first { $0.libraryCard?.id == card.id }
            XCTAssertTrue(video?.isRecording == true)
            XCTAssertTrue(video?.isLibraryItem == true)
            XCTAssertFalse(line.trash(video!.id))
            line.maxItems = 0
            line.trim(); line.clear()
            XCTAssertEqual(line.liveCount, 2)
            line.discard(video!.id, quietly: true)
            XCTAssertFalse(library.cards.first { $0.id == card.id }!.pinned)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.assetURL(for: card).path))
        }
        XCTAssertEqual(try Data(contentsOf: restored.assetURL(for: card)), bytes)
    }

    func testMovM4vAndPortraitPosters() async throws {
        let mov = try await movie("portrait.mov", rotated: true)
        let portrait = try await VideoImport.read(mov)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: portrait.poster))
        XCTAssertGreaterThan(bitmap.pixelsHigh, bitmap.pixelsWide)
        let m4v = folder.appendingPathComponent("portrait.M4V")
        try FileManager.default.copyItem(at: mov, to: m4v)
        let input = try await VideoImport.read(m4v)
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        let card = try await store.saveVideo(input: input, title: "竖屏视频")
        XCTAssertTrue(card.asset.hasSuffix(".m4v"))
        let checked = try await VideoImport.read(store.assetURL(for: card))
        XCTAssertFalse(checked.poster.isEmpty)
    }

    func testInvalidEmptyAndAudioOnlyFilesAreRejectedWithoutCreatingLibrary() async throws {
        let corrupt = folder.appendingPathComponent("corrupt.mp4")
        try Data("not a movie".utf8).write(to: corrupt)
        let empty = folder.appendingPathComponent("empty.mov")
        try Data().write(to: empty)
        let audio = folder.appendingPathComponent("audio.mp4")
        let audioSource = folder.appendingPathComponent("audio.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let file = try AVAudioFile(forWriting: audioSource, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
        buffer.frameLength = 8000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 8000)
        try file.write(from: buffer)
        try FileManager.default.copyItem(at: audioSource, to: audio)
        for url in [corrupt, empty, audio, folder.appendingPathComponent("unsupported.avi")] {
            do { _ = try await VideoImport.read(url); XCTFail("Invalid video accepted: \(url.lastPathComponent)") }
            catch { XCTAssertTrue(error is LibraryError) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Library").path))
    }

    func testMetadataEditReplacementAndFailedReplacementRetainIdentity() async throws {
        let source = try await movie()
        let input = try await VideoImport.read(source)
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        let card = try await store.saveVideo(input: input, title: "旧视频")
        try store.update(card.id, title: "新标题", text: "", keywords: "操作", pinned: false)
        let edited = try XCTUnwrap(store.find(card.id))
        XCTAssertEqual(edited.asset, card.asset)
        XCTAssertFalse(edited.pinned)
        let gone = VideoImport(url: folder.appendingPathComponent("gone.mp4"), name: "失效文件", poster: input.poster)
        do { _ = try await store.saveVideo(input: gone, replacing: card.id, title: "不应保存"); XCTFail() } catch {}
        XCTAssertEqual(store.find(card.id), edited)
        let replacement = try await store.saveVideo(input: input, replacing: card.id, title: "替换视频")
        XCTAssertEqual(replacement.id, card.id)
        XCTAssertEqual(replacement.createdAt, card.createdAt)
        XCTAssertNotEqual(replacement.asset, card.asset)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.assetURL(for: card).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: VideoImport.posterURL(for: store.assetURL(for: card)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testIndexFailureCleansOnlyNewVideoAndPoster() async throws {
        let input = try await VideoImport.read(movie())
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        let existing = try store.addText(title: "保留", text: "已有话术")
        let index = store.folder.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        do { _ = try await store.saveVideo(input: input, title: "不应保存"); XCTFail() } catch {}
        XCTAssertEqual(store.cards, [existing])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.folder.appendingPathComponent("Assets").path), [existing.asset])
    }

    func testCopyPublishesVideoFileWithoutPosterAndMissingFilePreservesClipboard() async throws {
        let input = try await VideoImport.read(movie())
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        let card = try await store.saveVideo(input: input, title: "视频")
        try await MainActor.run {
            let model = LibraryModel(folder: store.folder)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            var returns = 0
            model.onCopy = { returns += 1 }
            XCTAssertTrue(model.copy(card.id, pasteboard: board))
            XCTAssertEqual(board.string(forType: .fileURL), store.assetURL(for: card).absoluteString)
            XCTAssertNil(board.data(forType: .png))
            XCTAssertNil(board.data(forType: .tiff))
            XCTAssertEqual(returns, 1)
            let grab = GrabView()
            grab.copyOnly = true
            XCTAssertEqual(grab.allowedOperations(outsideApp: true), [.copy])
            try FileManager.default.removeItem(at: store.assetURL(for: card))
            board.clearContents(); board.setString("保留原剪贴板", forType: .string)
            XCTAssertFalse(model.copy(card.id, pasteboard: board))
            XCTAssertEqual(board.string(forType: .string), "保留原剪贴板")
            XCTAssertEqual(returns, 1)
        }
    }

    func testModelImportAnnouncesNewCardAndPosterCacheCanBeMissing() async throws {
        let input = try await VideoImport.read(movie())
        let (model, liveLine) = await MainActor.run {
            let model = LibraryModel(folder: folder.appendingPathComponent("Library"))
            let line = Line(library: model, defaults: VideoDefaults(), breeze: false)
            model.onChange = { line.syncLibrary() }
            return (model, line)
        }
        let saved = await model.saveVideo(input, title: "视频教程", keywords: "设置", pinned: true)
        XCTAssertTrue(saved)
        try await MainActor.run {
            XCTAssertEqual(liveLine.liveCount, 1)
            XCTAssertEqual(liveLine.items.first?.libraryCard?.kind, .video)
            let card = try XCTUnwrap(model.cards.first)
            let url = try XCTUnwrap(model.assetURL(card))
            try FileManager.default.removeItem(at: VideoImport.posterURL(for: url))
            XCTAssertNotNil(libraryThumbnail(card, url: url))
            let line = Line(library: model, defaults: VideoDefaults(), breeze: false)
            XCTAssertEqual(line.liveCount, 1)
            XCTAssertEqual(line.items.first?.libraryCard?.kind, .video)
        }
    }

    func testConcurrentCopiesMergeWithOtherEditsAndCancellationDoesNotLeaveAssets() async throws {
        let input = try await VideoImport.read(movie())
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        let first = Task { @MainActor in try await store.saveVideo(input: input, title: "视频一") }
        let second = Task { @MainActor in try await store.saveVideo(input: input, title: "视频二") }
        let text = try await MainActor.run { try store.addText(title: "同时加入话术", text: "不应丢失") }
        let videos = try await [first.value, second.value]
        XCTAssertEqual(Set(try LibraryRepository(folder: store.folder).cards.map(\.id)), Set(videos.map(\.id) + [text.id]))
        let before = try FileManager.default.contentsOfDirectory(atPath: store.folder.appendingPathComponent("Assets").path).sorted()
        let cancelled = Task { @MainActor in try await store.saveVideo(input: input, title: "取消的视频") }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled import committed") } catch {}
        XCTAssertEqual(store.cards.count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.folder.appendingPathComponent("Assets").path).sorted(), before)
    }

    func testDroppedMovieUsesVideoImporter() async throws {
        let source = try await movie()
        let provider = NSItemProvider(item: source as NSURL, typeIdentifier: "public.file-url")
        let result: LibraryImport = try await withCheckedThrowingContinuation { continuation in
            XCTAssertTrue(LibraryImport.load([provider]) { continuation.resume(with: $0) })
        }
        guard case .video(let input) = result else { XCTFail("Video was treated as an image"); return }
        XCTAssertEqual(input.url, source)
        XCTAssertFalse(input.poster.isEmpty)
    }

    func testSymlinkImportStoresAnIndependentRegularMovie() async throws {
        let source = try await movie()
        let link = folder.appendingPathComponent("linked.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let input = try await VideoImport.read(link)
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        let card = try await store.saveVideo(input: input, title: "链接导入")
        let saved = store.assetURL(for: card)
        XCTAssertFalse(try saved.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? true)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: link)
        let checked = try await VideoImport.read(saved)
        XCTAssertFalse(checked.poster.isEmpty)
    }

    func testLibraryVideoEditorAndClotheslineRenderUsingGeneratedMovie() async throws {
        let input = try await VideoImport.read(movie())
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        try store.addText(title: "常用话术", text: "您好，请参考操作视频。")
        try store.addImage(input: ImageImport(data: input.poster, name: "操作截图"), title: "操作截图")
        let card = try await store.saveVideo(input: input, title: "操作视频", keywords: "教程 设置")
        let output = folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("visuals")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data(contentsOf: input.url).write(to: output.appendingPathComponent("demo.mp4"), options: .atomic)
        try await MainActor.run {
            _ = NSApplication.shared
            let model = LibraryModel(folder: store.folder)
            @MainActor func render(_ view: AnyView, name: String, size: NSSize, scheme: ColorScheme = .dark, appear: Bool = false) throws {
                let host = NSHostingView(rootView: view.background(AppTheme.panel)
                    .environment(\.colorScheme, scheme))
                host.frame = NSRect(origin: .zero, size: size)
                let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: -12000, y: -12000), size: size),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                panel.contentView = host
                defer { panel.close() }
                if appear { panel.orderFront(nil); RunLoop.main.run(until: Date().addingTimeInterval(0.8)) }
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: output.appendingPathComponent(name))
                XCTAssertGreaterThan(data.count, 2000)
            }
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                for width in [620, 780] {
                    for layout in [LibraryLayout.compact, .grid] {
                        try render(AnyView(LibraryView(model: model, close: {}, layout: layout)), name: "library-\(name)-\(width)-\(layout.rawValue).png", size: NSSize(width: width, height: 580), scheme: scheme)
                    }
                }
                for kind in [LibraryKind.text, .image] {
                    let material = try XCTUnwrap(model.cards.first { $0.kind == kind })
                    try render(AnyView(LibraryEditorView(model: model, card: material, source: nil)), name: "\(kind.rawValue)-editor-\(name).png", size: NSSize(width: 500, height: 700), scheme: scheme, appear: true)
                }
                try render(AnyView(VideoEditorView(model: model, card: card, source: nil)), name: "video-editor-\(name).png", size: NSSize(width: 500, height: 700), scheme: scheme, appear: true)
            }
            let line = Line(library: model, defaults: VideoDefaults(), breeze: false)
            line.revealed = true
            try render(AnyView(LineView(line: line)), name: "line-video.png", size: NSSize(width: 1000, height: Layout.panelHeight), appear: true)
        }
    }
}
