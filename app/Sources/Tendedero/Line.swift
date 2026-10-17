import AppKit
import AVFoundation
import Combine
import os

let log = Logger(subsystem: "local.coverai.Replyline", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    var libraryCard: LibraryCard?
    var isLibraryItem: Bool { libraryCard != nil }
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { Tendedero.isRecording(url) }
    var orderKey: String {
        libraryCard.map { "library:\($0.id.uuidString)" } ?? "file:\(url.standardizedFileURL.path)"
    }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
            && a.libraryCard == b.libraryCard
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published private(set) var settlingID: UUID?
    @Published var pressedID: UUID?
    @Published var previewedID: UUID?
    var onPreview: (UUID) -> Void = { _ in }
    /// Whether the line has slid down into view.
    @Published var revealed = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    var maxItems = 8
    /// How many photos fit across the screen. With Keep on line set, the
    /// line can hold more, and the rest are reached by scrolling.
    var visibleCount = 8
    /// How far the line is scrolled towards older photos, in points; 0 shows
    /// the newest.
    @Published var scroll: CGFloat = 0

    /// Keep on line, from the menu bar: how many photos the line keeps, or
    /// nil for as many as fit across the screen.
    nonisolated static let keepChoices = [25, 50, 100]
    nonisolated static var keepOnLine: Int? {
        get {
            let n = UserDefaults.standard.integer(forKey: "keepOnLine")
            return keepChoices.contains(n) ? n : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "keepOnLine") }
    }


    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }
    var temporaryCount: Int { items.filter { !$0.falling && !$0.isLibraryItem }.count }
    var hasLibraryItems: Bool { items.contains { $0.isLibraryItem && !$0.falling } }
    var onManageLibrary: (UUID?) -> Void = { _ in }

    private let storeKey = "pegged"
    private let orderKey = "lineCardOrder"
    // Arrival order is independent of visual order: moving a card must never
    // change which temporary file is evicted when the line reaches capacity.
    private var arrivals: [UUID] = []
    private var reorderOrder: [String]?
    private var reorderScroll: CGFloat = 0
    private var grabOffset: CGFloat = 0
    private(set) var settlingToken = UUID()
    private var landingID: UUID?
    private var copiedToken = UUID()
    private var lastInteraction = ProcessInfo.processInfo.systemUptime
    var hoveredID: UUID?
    private let defaults: UserDefaults
    private let library: LibraryModel?

    init(library: LibraryModel? = nil, defaults: UserDefaults = .standard, breeze: Bool = true) {
        self.library = library
        self.defaults = defaults
        let order = defaults.stringArray(forKey: orderKey) ?? []
        restore()
        arrivals = items.map(\.id)
        syncLibrary()
        items = arranged(items, accordingTo: order)
        save()
        if breeze { scheduleGust() }
    }

    /// Fixed cards keep their existing IDs and position, so the original
    /// arrival/swing animations are used only when a card first appears.
    func syncLibrary() {
        guard let library else { return }
        let order = items.map(\.orderKey)
        let pinned = library.cards.filter(\.pinned)
        let ids = Set(pinned.map(\.id))
        for item in items where item.isLibraryItem && !item.falling {
            if let card = item.libraryCard, !ids.contains(card.id) { drop(item.id, quietly: true) }
        }
        let fixed = pinned.compactMap { card -> Pegged? in
            guard let url = library.assetURL(card), let thumb = libraryThumbnail(card, url: url) else { return nil }
            var item = items.first { $0.libraryCard?.id == card.id && !$0.falling }
                ?? Pegged(url: url, thumb: thumb)
            item.url = url
            item.thumb = thumb
            item.libraryCard = card
            return item
        }
        items = arranged(items.filter { !$0.isLibraryItem || $0.falling } + fixed, accordingTo: order)
        scroll(by: 0)
        save()
    }

    func manageLibrary(_ id: UUID) {
        onManageLibrary(items.first { $0.id == id }?.libraryCard?.id)
    }

    func keepInLibrary(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.isRecording else { return }
        let title = item.url.deletingPathExtension().lastPathComponent
        if library?.perform({ try $0.addImage(source: item.url, title: title) }) == true {
            drop(id, quietly: true)
        } else { onManageLibrary(nil) }
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        if let order = reorderOrder {
            var baseline = arranged(items, accordingTo: order).filter { !$0.falling }
            baseline.insert(item, at: baseline.firstIndex { $0.isLibraryItem } ?? baseline.endIndex)
            reorderOrder = baseline.map(\.orderKey)
        }
        let fixedStart = items.firstIndex { $0.isLibraryItem } ?? items.endIndex
        items.insert(item, at: fixedStart)
        arrivals.append(item.id)
        scroll = 0
        // A full line lets the oldest photo fall off the far end. Only one: a
        // line hung on a wider screen keeps its length here instead of losing
        // several photos to a single capture.
        if temporaryCount > maxItems, let oldest = oldestTemporary {
            letGo(oldest.id)
        }
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        if settlingID == id { settlingToken = UUID(); settlingID = nil }
        if landingID == id { landingID = nil }
        if hoveredID == id { hoveredID = nil }
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    /// "Take everything down": every photo goes the way of its corner cross.
    func clear(_ approvedIDs: Set<UUID>? = nil) {
        takeDown(items.filter { !$0.falling && !$0.isLibraryItem && (approvedIDs?.contains($0.id) ?? true) })
    }

    /// The photos hung before (left) or after (right) this one.
    func neighbours(of id: UUID, toTheLeft: Bool) -> [Pegged] {
        let live = items.filter { !$0.falling }
        guard let i = live.firstIndex(where: { $0.id == id }) else { return [] }
        return toTheLeft ? Array(live[..<i]) : Array(live[(i + 1)...])
    }

    /// Takes down everything on one side of a photo. Each one goes the way
    /// of its own corner button: to the Trash from Tendedero's folder, and
    /// only off the line from anywhere else.
    func takeDown(_ id: UUID, toTheLeft: Bool) {
        takeDown(neighbours(of: id, toTheLeft: toTheLeft))
    }

    /// One after another, and only the first makes a sound.
    private func takeDown(_ live: [Pegged]) {
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.discard(item.id, quietly: n > 0)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        noteInteraction()
        guard let item = items.first(where: { $0.id == id }) else { return }
        if let card = item.libraryCard {
            guard library?.copy(card.id, returnToChat: false) == true else { return }
            showCopied(id)
            return
        }
        let entry = NSPasteboardItem()
        // A recording is copied as the file, which apps paste as the video.
        if !item.isRecording, let png = pngData(item.url) { entry.setData(png, forType: .png) }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])

        showCopied(id)
    }

    func showCopied(_ id: UUID) {
        copiedID = id
        let token = UUID()
        copiedToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id && self?.copiedToken == token { self?.copiedID = nil }
        }
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.libraryCard?.kind == .text { manageLibrary(id); return }
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    @discardableResult
    func trash(_ id: UUID, quietly: Bool = false) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        guard !item.isLibraryItem else { return false }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Line.trashSound?.play() }
            drop(id, quietly: true)
            return true
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !quietly { NSSound.beep() }
            return false
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Tendedero's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID, quietly: Bool = false) {
        if let card = items.first(where: { $0.id == id })?.libraryCard {
            if library?.setPinned(card.id, false) != true { onManageLibrary(nil) }
            return
        }
        if isInInbox(id) { trash(id, quietly: quietly) } else { drop(id, quietly: quietly) }
    }

    /// The oldest photo falling off a full line. Like the cross, a file from
    /// Tendedero's folder goes to the Trash, or nothing would ever take it out
    /// of that folder. If the Trash refuses it, it still leaves the line.
    /// Moves along a line that holds more than fit, from a scroll gesture.
    func scroll(by delta: CGFloat) {
        if delta != 0 { noteInteraction() }
        let most = CGFloat(max(0, items.count - visibleCount)) * Layout.spacing
        let next = min(most, max(0, scroll + delta))
        if next != scroll { scroll = next }
    }

    /// After Keep on line is lowered, the oldest photos past it go the way
    /// of a full line.
    func trim() {
        while temporaryCount > maxItems, let oldest = oldestTemporary {
            letGo(oldest.id)
        }
        scroll = 0
    }

    private var oldestTemporary: Pegged? {
        for id in arrivals {
            if let item = items.first(where: { $0.id == id && !$0.falling && !$0.isLibraryItem }) { return item }
        }
        return nil
    }

    // MARK: Drag ordering

    func beginReordering(_ id: UUID, pointerX: CGFloat, width: CGFloat) {
        guard draggingID == nil, pointerX.isFinite, width.isFinite, width > 0,
              let index = items.firstIndex(where: { $0.id == id && !$0.falling && !$0.flying }) else { return }
        reorderOrder = items.filter { !$0.falling }.map(\.orderKey)
        reorderScroll = scroll
        grabOffset = pointerX - Layout.x(index: index, count: items.count, width: width,
                                        visible: visibleCount, scroll: scroll, fixedCards: hasLibraryItems)
        draggingID = id
        noteInteraction()
        landingID = nil
        settlingToken = UUID()
        settlingID = nil
    }

    @discardableResult
    func updateReordering(_ id: UUID, pointerX: CGFloat, width: CGFloat) -> Bool {
        guard draggingID == id, reorderOrder != nil, width.isFinite, width > 0, pointerX.isFinite,
              let source = items.firstIndex(where: { $0.id == id && !$0.falling }) else { return false }
        let center = pointerX - grabOffset
        let slots = items.indices.filter { !items[$0].falling }
        let positions = items.indices.map {
            Layout.x(index: $0, count: items.count, width: width,
                     visible: visibleCount, scroll: scroll, fixedCards: hasLibraryItems)
        }
        guard let target = slots.min(by: { abs(positions[$0] - center) < abs(positions[$1] - center) }) else { return false }
        let currentX = Layout.x(index: source, count: items.count, width: width,
                                visible: visibleCount, scroll: scroll, fixedCards: hasLibraryItems)
        let targetX = Layout.x(index: target, count: items.count, width: width,
                               visible: visibleCount, scroll: scroll, fixedCards: hasLibraryItems)
        // A small dead band prevents hand tremor at a midpoint from swapping
        // two neighbours back and forth while they are still animating.
        if source != target, abs(targetX - center) + 8 < abs(currentX - center) {
            var next = items
            let item = next.remove(at: source)
            next.insert(item, at: target)
            items = next
        }
        return true
    }

    /// Moving outside the strip returns the other cards to their places,
    /// while the native drag continues into Finder, WeChat or another app.
    func leaveReordering() {
        guard let order = reorderOrder else { return }
        items = arranged(items, accordingTo: order)
        scroll = reorderScroll
        scroll(by: 0)
    }

    @discardableResult
    func commitReordering(_ id: UUID) -> Bool {
        guard draggingID == id, reorderOrder != nil,
              items.contains(where: { $0.id == id && !$0.falling }) else { return false }
        reorderOrder = nil
        save()
        return true
    }

    func awaitReorderLanding(_ id: UUID) {
        guard draggingID == id, reorderOrder == nil else { return }
        landingID = id
    }

    func finishReordering(_ id: UUID) {
        guard draggingID == id, landingID != id else { return }
        leaveReordering()
        reorderOrder = nil
        // Let the returned card settle into the jaws before closing them.
        // Keep this separate from the system drag, which has already ended.
        settlingToken = UUID()
        settlingID = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && items.contains(where: { $0.id == id && !$0.falling }) ? id : nil
        draggingID = nil
    }

    /// AppKit calls this once the accepted drag image has reached its frame.
    func completeReorderLanding(_ id: UUID) {
        guard landingID == id else { return }
        landingID = nil
        finishReordering(id)
    }

    /// The card's return animation owns this completion, not a delay timer.
    func completeSettling(_ id: UUID, token: UUID) {
        guard settlingID == id, settlingToken == token, draggingID != id else { return }
        settlingID = nil
    }

    /// Reorder surviving known cards only. Concurrent arrivals retain their
    /// slots and removed cards are never resurrected on cancel or restore.
    private func arranged(_ source: [Pegged], accordingTo order: [String]) -> [Pegged] {
        let live = source.filter { !$0.falling }
        let known = Dictionary(uniqueKeysWithValues: live.map { ($0.orderKey, $0) })
        var seen = Set<String>()
        var sorted = order.compactMap { key -> Pegged? in
            guard seen.insert(key).inserted else { return nil }
            return known[key]
        }.makeIterator()
        return source.map { item in
            guard !item.falling, seen.contains(item.orderKey) else { return item }
            return sorted.next() ?? item
        }
    }

    private func letGo(_ id: UUID) {
        if isInInbox(id), trash(id, quietly: true) { return }
        drop(id, quietly: true)
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor. Markup does
    /// not edit video, so a recording opens in the trimming editor instead.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.libraryCard?.kind == .text { manageLibrary(id); return }
        if item.libraryCard?.kind == .video { quickLook(id); return }
        if item.isRecording {
            Trim.shared.edit(item.url, size: item.thumb.size)
        } else {
            Markup.shared.edit(item.url)
        }
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
    }

    /// Quick Look on this photo, with the rest of the line a key press away.
    func quickLook(_ id: UUID) {
        let live = items.filter { !$0.falling }
        guard let index = live.firstIndex(where: { $0.id == id }) else { return }
        QuickLook.shared.show(live.map(\.url), at: index)
    }

    /// After a change of size, every photo is redrawn sharp at the new one.
    func reloadThumbnails() {
        for i in items.indices where !items[i].falling {
            if let card = items[i].libraryCard,
               let thumb = libraryThumbnail(card, url: items[i].url) {
                items[i].thumb = thumb
                continue
            }
            if let thumb = makeThumbnail(items[i].url) { items[i].thumb = thumb }
        }
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if self.shouldBreeze(at: ProcessInfo.processInfo.systemUptime),
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self.gust += 1 }
            self.scheduleGust()
        }
    }

    func noteInteraction(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if time.isFinite { lastInteraction = time }
    }

    func shouldBreeze(at time: TimeInterval) -> Bool {
        time.isFinite && time - lastInteraction >= 30 && revealed && liveCount > 0
            && draggingID == nil && settlingID == nil && pressedID == nil
            && previewedID == nil && hoveredID == nil && !GrabView.isShowingMenu
    }

    // MARK: Persistence

    private func save() {
        let live = items.filter { !$0.falling }
        let temporary = Dictionary(uniqueKeysWithValues: live.filter { !$0.isLibraryItem }.map { ($0.id, $0.url.path) })
        arrivals.removeAll { temporary[$0] == nil }
        let paths = arrivals.compactMap { temporary[$0] }
        defaults.set(paths, forKey: storeKey)
        // Captures and library edits may arrive during a drag. Persist those
        // changes without accidentally committing a provisional arrangement.
        let baseline = arranged(live, accordingTo: reorderOrder ?? []).map(\.orderKey)
        if reorderOrder != nil { reorderOrder = baseline }
        defaults.set(baseline, forKey: orderKey)
    }

    /// Everything comes back as it was. This runs before the line knows its
    /// screen, so the capacity is still the default one: hanging through
    /// `hang` would let photos fall off a wide screen's line at every launch.
    private func restore() {
        let paths = defaults.stringArray(forKey: storeKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard !items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
                  let thumb = makeThumbnail(url) else { continue }
            items.append(Pegged(url: url, thumb: thumb))
        }
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Screen recordings, as macOS saves them.
func isRecording(_ url: URL) -> Bool {
    VideoImport.extensions.contains(url.pathExtension.lowercased())
}

/// The default size covers a card at twice its size in points, as on a
/// Retina screen, and no more: every photo on the line keeps one in memory.
func makeThumbnail(_ url: URL, maxPixels: Int = Int(320 * Layout.size.scale)) -> NSImage? {
    if isRecording(url) { return firstFrame(url, maxPixels: maxPixels) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// A recording shows its first frame.
private func firstFrame(_ url: URL, maxPixels: Int) -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
    guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
