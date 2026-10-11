import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Tendedero

final class ImageImportTests: XCTestCase {
    private var folder: URL!
    private var clipboard: NSPasteboard!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        folder = root.appendingPathComponent(".tmp/image-import-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        clipboard = NSPasteboard.withUniqueName()
    }

    override func tearDownWithError() throws {
        clipboard.releaseGlobally()
        try FileManager.default.removeItem(at: folder)
    }

    private func bytes(_ type: NSBitmapImageRep.FileType = .png, red: CGFloat = 0.3) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<3 { for y in 0..<2 { rep.setColor(NSColor(deviceRed: red, green: 0.6, blue: 0.5, alpha: 1), atX: x, y: y) } }
        return rep.representation(using: type, properties: [:])!
    }

    func testClipboardPNGAndTIFFImportAsIndependentAssets() throws {
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        for (format, type) in [(NSBitmapImageRep.FileType.png, NSPasteboard.PasteboardType.png), (.tiff, .tiff)] {
            clipboard.clearContents()
            let data = bytes(format)
            clipboard.setData(data, forType: type)
            XCTAssertTrue(ImageImport.canPasteImage(clipboard))
            let input = try ImageImport.from(clipboard)
            let card = try store.addImage(input: input, title: "粘贴图片")
            XCTAssertEqual(try Data(contentsOf: store.assetURL(for: card)), data)
            XCTAssertNotNil(input.thumbnail())
        }
        XCTAssertEqual(try LibraryRepository(folder: store.folder).cards.count, 2)
    }

    func testCopiedFileUsesOriginalImageInsteadOfFinderIcon() throws {
        let source = folder.appendingPathComponent("source.png")
        let data = bytes(red: 0.8)
        try data.write(to: source)
        let entry = NSPasteboardItem()
        entry.setString(source.absoluteString, forType: .fileURL)
        entry.setData(bytes(red: 0.1), forType: .png)
        clipboard.writeObjects([entry])
        XCTAssertTrue(ImageImport.canPasteImage(clipboard))
        let input = try ImageImport.from(clipboard)
        XCTAssertEqual(input.data, data)
        XCTAssertEqual(input.name, "source")
        try FileManager.default.removeItem(at: source)
        let store = try LibraryRepository(folder: folder.appendingPathComponent("Library"))
        let card = try store.addImage(input: input, title: input.name)
        XCTAssertEqual(try Data(contentsOf: store.assetURL(for: card)), data)
    }

    func testTextPasteIsNotInterceptedEvenWhenItCarriesAnImage() throws {
        let entry = NSPasteboardItem()
        entry.setString("话术正文", forType: .string)
        entry.setData(bytes(), forType: .png)
        clipboard.writeObjects([entry])
        XCTAssertFalse(ImageImport.canPasteImage(clipboard))
        // The explicit Paste Image button still lets the user choose its picture.
        XCTAssertEqual(try ImageImport.from(clipboard).data, bytes())
    }

    func testEmptyCorruptAndOversizedInputsAreRejected() throws {
        XCTAssertThrowsError(try ImageImport.from(clipboard))
        clipboard.setString("只有文字", forType: .string)
        XCTAssertThrowsError(try ImageImport.from(clipboard))
        XCTAssertThrowsError(try ImageImport(data: Data("invalid PNG".utf8), name: "错误"))
        XCTAssertThrowsError(try ImageImport(data: Data(count: 64 * 1024 * 1024 + 1), name: "超大图片"))
    }

    func testDropLoadsImageBytesAndRejectsTextProviders() async throws {
        let data = bytes()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        let loaded = expectation(description: "Image bytes loaded from drop")
        XCTAssertTrue(ImageImport.load([provider]) { result in
            do { let input = try result.get(); XCTAssertEqual(input.data, data) }
            catch { XCTFail(error.localizedDescription) }
            loaded.fulfill()
        })
        await fulfillment(of: [loaded], timeout: 3)
        XCTAssertFalse(ImageImport.load([NSItemProvider(object: "文字" as NSString)]) { _ in XCTFail("Text should not import") })
    }

    func testDropLoadsFileURLAndInvalidImageReportsFailure() async throws {
        let source = folder.appendingPathComponent("dragged.png")
        let data = bytes()
        try data.write(to: source)
        let file = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let loaded = expectation(description: "File URL loaded from drop")
        XCTAssertTrue(ImageImport.load([file]) { result in
            do { let input = try result.get(); XCTAssertEqual(input.data, data) }
            catch { XCTFail(error.localizedDescription) }
            loaded.fulfill()
        })
        await fulfillment(of: [loaded], timeout: 3)
        let invalid = NSItemProvider()
        invalid.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(Data("broken image".utf8), nil)
            return nil
        }
        let rejected = expectation(description: "Invalid image rejected")
        ImageImport.load([invalid]) { result in
            if case .success = result { XCTFail("Invalid image should fail") }
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 3)
    }
}
