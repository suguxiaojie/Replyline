import AppKit
import ApplicationServices
import Carbon
import Combine
import Quartz
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let library = LibraryModel()
    private lazy var line = Line(library: library)
    private lazy var libraryWindow = LibraryWindow(model: library)
    private let settingsWindow = SettingsWindow()
    private let quickMenu = QuickMenu()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    /// Folders chosen in "Also watch folders", like the one another
    /// screenshot app saves to.
    private var folderWatchers: [ScreenshotWatcher] = []
    private var clipboardWatcher: ClipboardWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var libraryHotKey: HotKey?
    private var recordingShortcut = false
    private let cardPreview = CardPreview()
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var menuBarDoubleClick = MenuBarDoubleClick()
    private var hotZoneSince: Date?
    /// A menu bar click suppresses hover until the pointer leaves the bar.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false

    // What brings the line down, from the menu bar's "Bring the line down".
    // Double click is the initial choice; hover remains configurable.

    /// Something new hanging shows itself for a moment. Off, it hangs
    /// quietly and waits for you to bring the line down.
    static var peeksAtNew: Bool {
        get { !UserDefaults.standard.bool(forKey: "quietHang") }
        set { UserDefaults.standard.set(!newValue, forKey: "quietHang") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.line = line
        panel.placeOnScreen()
        updateCapacity()
        line.onManageLibrary = { [weak self] id in self?.libraryWindow.show(editing: id) }
        cardPreview.onCopy = { [weak self] id in self?.line.copy(id) }
        cardPreview.onOriginal = { [weak self] id in self?.line.quickLook(id) }
        cardPreview.onDismiss = { [weak self] in self?.line.previewedID = nil }
        line.onPreview = { [weak self] id in self?.previewCard(id) }
        library.onChange = { [weak self] in
            guard let self else { return }
            let previous = Set(self.line.items.filter { !$0.falling }.map(\.id))
            self.line.syncLibrary()
            if self.line.items.contains(where: { !$0.falling && !previous.contains($0.id) }) {
                self.comeDown(on: nil)
            }
        }

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()
        clipboardWatcher = ClipboardWatcher { [weak self] url in self?.hangCapture(url) }
        if ClipboardWatcher.isEnabled { clipboardWatcher.start() }

        registerShortcut()
        registerLibraryShortcut()

        setUpStatusItem()
        watchMenuBarClicks()
        if MenuBarTrigger.load() == .doubleClick,
           !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: "menuBarAccessOffered") {
            UserDefaults.standard.set(true, forKey: "menuBarAccessOffered")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Self.requestMenuBarAccess()
            }
        }

        Markup.shared.onSaved = { [weak self] url in
            self?.line.reloadThumbnail(for: url)
            self?.library.objectWillChange.send()
        }
        Trim.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        panel.onScroll = { [weak self] event in
            // Sideways on a trackpad, or the wheel of a mouse.
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            self?.line.scroll(by: event.hasPreciseScrollingDeltas ? delta : delta * 12)
        }
        line.onFall = { [weak self] item in self?.fall(item) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.itemsChanged()
                if self.quickMenu.isShown {
                    self.quickMenu.refresh(menu: self.makeStatusMenu(),
                                           fixedCount: self.line.items.filter { $0.isLibraryItem && !$0.falling }.count,
                                           temporaryCount: self.line.temporaryCount)
                }
            }
            .store(in: &cancellables)
        // Photos kept from last time show themselves for a moment.
        if line.liveCount > 0 { comeDown(on: nil) }

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quickMenu.close()
        clickMonitors.forEach(NSEvent.removeMonitor)
        if Inbox.isEnabled { Inbox.restore() }
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        // A folder may also be watched for screenshots, like the Desktop; an
        // image both report hangs once.
        for folder in Self.extraFolders {
            let extra = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            extra.start()
            folderWatchers.append(extra)
        }
    }

    /// Up to three folders: enough for another screenshot app or an export
    /// folder, few enough that screenshots still have room on the line.
    static let maxExtraFolders = 3

    /// The folders from "Also watch folders" that still exist. New images in
    /// them hang like screenshots; taking one down leaves the file there.
    static var extraFolders: [URL] {
        get {
            let paths = UserDefaults.standard.stringArray(forKey: "extraFolders") ?? []
            return paths.compactMap { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "extraFolders") }
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        panel.message = "保存到此文件夹的新图片会自动加入晾衣架。"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, Self.extraFolders.count < Self.maxExtraFolders,
              !Self.extraFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        Self.extraFolders.append(url)
        startWatcher()
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = "将系统截图保存到 Replyline？"
        alert.informativeText = "开启后，系统截图保存到 Replyline，并关闭系统浮动缩略图。正常退出后恢复原设置；也可在「设置 → 截图与图片」中关闭。截图会加入晾衣架，常用素材独立保存。"
        alert.addButton(withTitle: "保存到 Replyline")
        alert.addButton(withTitle: "保持系统设置")
        if let icon = NSImage(named: "Replyline") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Watching the clipboard is opt in, from Settings only.
    private func setClipboard(_ on: Bool) {
        ClipboardWatcher.isEnabled = on
        if on { clipboardWatcher.start() } else { clipboardWatcher.stop() }
        updateStatusIcon()
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    /// An empty line goes away, unless it was opened on purpose.
    private func itemsChanged() {
        guard line.liveCount == 0, !keepOpen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
            self.wanted = false
            self.refresh()
        }
    }

    /// The line comes down on that screen for a moment, then tucks away.
    /// Without a screen, it uses the one under the pointer.
    private func comeDown(on screen: NSScreen?) {
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
        if Self.peeksAtNew { reveal(peekFor: 2.5) }
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) {
        let from = captureRect(of: url)
        let screen = from.flatMap { from in
            NSScreen.screens.first { NSMouseInRect(CGPoint(x: from.midX, y: from.midY), $0.frame, false) }
        }
        // Every capture brings the line down before it hangs, on the screen it
        // was taken on. On a full line the oldest photo then falls in view as
        // the new one flies in.
        comeDown(on: screen)
        let animated = from != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let id = line.hang(url, flying: animated) else {
            // Nothing hung after all, so an empty line goes away again.
            itemsChanged()
            return
        }
        guard let from, animated else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, CaptureFlight.flightsInProgress < 2, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        // Sharp enough while it starts out at the captured size, which a
        // full Retina screen would otherwise take at full resolution.
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(1500, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = CardDragPreview.face(for: item).cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: line.items.count, width: width,
                         visible: line.visibleCount, scroll: line.scroll, fixedCards: line.hasLibraryItems)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen.
    private func refresh() {
        let blocked = panel.screen.map(FullScreen.blocksLine(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.blocksLine(on:)) ?? false
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // Keep watching the cursor for pass-through and automatic retraction.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        // It always comes down showing the newest.
        if on { line.scroll = 0 }
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            if isPresent { panel.orderFrontRegardless() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            cardPreview.dismiss()
            line.previewedID = nil
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
            keepOpen = true
            wanted = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// Double clicks on blank space open the line. Other menu bar clicks put
    /// it away so menus and status icons keep their usual behavior.
    private func watchMenuBarClicks() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                let p = event.cgEvent.map { MenuBarHitTest.accessibilityPoint($0.location, primaryTop: primaryTop) }
                    ?? NSEvent.mouseLocation
                let screen = NSScreen.screens.first { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }
                let screenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                let shouldOpen = self.menuBarDoubleClick.consume(event, screen: screenID?.uint32Value) {
                    MenuBarTrigger.load() == .doubleClick && MenuBarHitTest.isBlank(
                        at: p, primaryTop: primaryTop)
                }
                guard let screen else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if shouldOpen, !FullScreen.blocksLine(on: screen) {
                    self.keepOpen = true
                    self.wanted = true
                    self.panel.placeOnScreen(screen)
                    self.updateCapacity()
                    self.refresh()
                    self.reveal(pinned: true)
                    return
                }
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()
        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            cardPreview.dismiss()
            if MenuBarTrigger.load() == .hover, let screen = screenUnderPointer,
               inMenuBar, !menuBarSuppressed, !FullScreen.blocksLine(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= MenuBarHoverDelay.load().rawValue {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen(screen)
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)
        if let id = cardPreview.currentID, !line.items.contains(where: { $0.id == id && !$0.falling }) {
            cardPreview.dismiss()
        }
        if let screen = panel.screen {
            let item = line.items.first { $0.id == cardPreview.currentID && !$0.falling && !$0.flying }
            let anchor = item.flatMap { item -> CGRect? in
                guard var frame = cardFrame(for: item.id) else { return nil }
                // Stay below the whole strip so tall neighbouring cards remain visible.
                frame.origin.y = panel.frame.minY + 8
                return frame
            }
            cardPreview.update(item: item, anchor: anchor, screen: screen.visibleFrame,
                                suspended: GrabView.isDragging || GrabView.isShowingMenu || line.pressedID != nil)
        }

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        let busy = pinned || GrabView.isDragging || GrabView.isShowingMenu || line.draggingID != nil || line.settlingID != nil
            || line.pressedID != nil || now < peekUntil || cardPreview.keepsLineOpen
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        var overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        // A line longer than the screen also takes the band the photos hang
        // in, gaps included, so a swipe anywhere along it moves it.
        if !overPhoto, line.items.count > line.visibleCount, Line.keepOnLine != nil {
            let band = line.hitRects.values.reduce(CGRect.null) { $0.union($1) }
            overPhoto = !band.isNull && flipped.y >= band.minY - 4 && flipped.y <= band.maxY + 4
        }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    // MARK: Shortcut

    private func previewCard(_ id: UUID) {
        guard let item = line.items.first(where: { $0.id == id && !$0.falling && !$0.flying }),
              let screen = panel.screen, var anchor = cardFrame(for: id) else { return }
        if item.isRecording { line.quickLook(id); return }
        anchor.origin.y = panel.frame.minY + 8
        cardPreview.toggle(item: item, anchor: anchor, screen: screen.visibleFrame)
        line.previewedID = cardPreview.currentID
    }

    private func registerShortcut() {
        hotKey = nil
        guard let shortcut = Shortcut.current else { return }
        hotKey = HotKey(shortcut) { [weak self] in self?.quickMenu.close(restoringFocus: true); self?.toggle() }
    }

    private func changeShortcut() {
        guard !recordingShortcut else { return }
        recordingShortcut = true
        // Both bindings are suspended while recording, including the reserved
        // library shortcut, so a trial combination cannot switch windows.
        hotKey = nil
        libraryHotKey = nil
        refreshSettings()
        ShortcutRecorder.shared.record { [weak self] result in
            guard let self else { return }
            self.recordingShortcut = false
            var conflict: String?
            if let result {
                let previous = Shortcut.current
                if result?.hasSameCombination(as: .library) == true {
                    conflict = "这个组合已用于打开常用素材，请选择其他快捷键。"
                } else if result?.hasSameCombination(as: .settings) == true {
                    conflict = "这个组合已用于打开设置，请选择其他快捷键。"
                } else {
                    Shortcut.current = result
                    self.registerShortcut()
                    if result != nil && self.hotKey == nil {
                        Shortcut.current = previous
                        conflict = "这个组合已被系统或其他应用占用，已保留原快捷键。"
                    }
                }
            }
            self.registerShortcut()
            self.registerLibraryShortcut()
            self.refreshSettings()
            if let conflict {
                let alert = NSAlert()
                alert.messageText = "无法使用这个快捷键"
                alert.informativeText = conflict
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
            if self.settingsWindow.window?.isVisible == true {
                self.settingsWindow.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func registerLibraryShortcut() {
        libraryHotKey = nil
        libraryHotKey = HotKey(.library) { [weak self] in self?.performMenuAction(.library) }
        if libraryHotKey == nil { log.notice("Library shortcut is unavailable; use the menu bar entry.") }
    }

    private func openSystemScreenshotShortcuts() {
        cardPreview.dismiss()
        setRevealed(false)
        SystemScreenshotShortcuts.open { reason in
            let alert = NSAlert()
            alert.messageText = "未能自动定位到截屏快捷键"
            alert.informativeText = reason + "\n打开「系统设置 → 键盘 → 键盘快捷键 → 截屏」，双击需要修改的组合，再按下新的快捷键。"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func setKeep(_ n: Int?) {
        guard n != Line.keepOnLine else { return }
        Line.keepOnLine = n
        updateCapacity()
        line.trim()
    }

    private func setSize(_ size: Layout.Size) {
        guard size != Layout.size else { return }
        Layout.size = size
        panel.placeOnScreen(panel.screen)
        updateCapacity()
        line.reloadThumbnails()
    }

    private func updateCapacity() {
        let usable = panel.frame.width - 200
        let fits = max(3, min(12, Int(usable / Layout.spacing)))
        line.visibleCount = fits
        line.maxItems = max(fits, Line.keepOnLine ?? fits)
    }

    // MARK: Menu bar

    private static func requestMenuBarAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func setMenuBarTrigger(_ trigger: MenuBarTrigger) {
        trigger.save()
        menuBarDoubleClick = MenuBarDoubleClick()
        hotZoneSince = nil
        if trigger == .doubleClick { Self.requestMenuBarAccess() }
    }

    private func openMenuBarAccessSettings() {
        cardPreview.dismiss()
        setRevealed(false)
        Self.requestMenuBarAccess()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(url) {
            let alert = NSAlert()
            alert.messageText = "请允许 Replyline 使用辅助功能"
            alert.informativeText = "在「系统设置 → 隐私与安全性」中找到辅助功能权限，允许 Replyline 后，再双击菜单栏空白区域。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showStatusMenu(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        quickMenu.onClose = { [weak self] in self?.statusItem.button?.state = .off }
    }

    /// The shirt fills in while copied images are hung, so it shows at a
    /// glance that the clipboard is being watched.
    private func updateStatusIcon() {
        let on = ClipboardWatcher.isEnabled
        let description = on ? L("Replyline, hanging copied images") : "Replyline"
        let image = NSImage(systemSymbolName: on ? "tshirt.fill" : "tshirt", accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = description
    }

    @objc private func showStatusMenu(_ sender: NSStatusBarButton) {
        quickMenu.show(relativeTo: sender, menu: makeStatusMenu(),
                       fixedCount: line.items.filter { $0.isLibraryItem && !$0.falling }.count,
                       temporaryCount: line.temporaryCount)
        sender.state = quickMenu.isShown ? .on : .off
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        ReplylineMenu.populate(menu, isRevealed: isRevealed, temporaryCount: line.temporaryCount,
                               shortcut: Shortcut.current) { [weak self] action in
            self?.performMenuAction(action)
        }
        return menu
    }

    private func performMenuAction(_ action: ReplylineMenuAction) {
        let previous = quickMenu.previousApplication
        quickMenu.close(restoringFocus: action == .toggle)
        switch action {
        case .toggle: toggle()
        case .library: libraryWindow.show(returningTo: previous)
        case .openFolder: NSWorkspace.shared.open(watcher.folder)
        case .clear: confirmClearTemporary()
        case .settings: showSettings()
        case .quit: NSApp.terminate(nil)
        }
    }

    func showSettings() {
        quickMenu.close()
        cardPreview.dismiss()
        setRevealed(false)
        settingsWindow.model.onCommand = { [weak self] command in self?.applySettings(command) }
        settingsWindow.show()
    }

    private func refreshSettings() {
        settingsWindow.model.snapshot = SettingsSnapshot(
            trigger: MenuBarTrigger.load(), hoverDelay: MenuBarHoverDelay.load(),
            peeksAtNew: Self.peeksAtNew, fullScreen: FullScreen.showLineOver, size: Layout.size,
            inbox: Inbox.isEnabled, clipboard: ClipboardWatcher.isEnabled,
            screenshotFolder: watcher?.folder ?? ScreenshotWatcher.screenshotFolder(), extraFolders: Self.extraFolders,
            keepCount: Line.keepOnLine, shortcut: Shortcut.current, recording: recordingShortcut,
            shortcutAvailable: hotKey != nil, libraryShortcutAvailable: libraryHotKey != nil,
            accessibility: AXIsProcessTrusted(), sound: line.soundOn, login: SMAppService.mainApp.status == .enabled)
    }

    private func applySettings(_ command: SettingsCommand) {
        switch command {
        case .trigger(let trigger): setMenuBarTrigger(trigger)
        case .hoverDelay(let delay): delay.save(); hotZoneSince = nil
        case .peek(let on): Self.peeksAtNew = on
        case .fullScreen(let on): FullScreen.showLineOver = on; refresh()
        case .size(let size): setSize(size)
        case .inbox(let on): setInbox(on)
        case .clipboard(let on): setClipboard(on)
        case .keep(let count): setKeep(count)
        case .addFolder: chooseExtraFolder()
        case .removeFolder(let folder): Self.extraFolders.removeAll { $0 == folder }; startWatcher()
        case .openScreenshotFolder: NSWorkspace.shared.open(watcher.folder)
        case .recordShortcut: changeShortcut()
        case .systemScreenshotShortcut: openSystemScreenshotShortcuts()
        case .accessibility: openMenuBarAccessSettings()
        case .sound(let on): line.soundOn = on
        case .login(let on):
            if on != (SMAppService.mainApp.status == .enabled) { Self.toggleLaunchAtLogin() }
        case .refresh: break
        }
        refreshSettings()
    }

    private func confirmClearTemporary() {
        let plan = TemporaryClearPlan(items: line.items, inbox: Inbox.folder)
        guard !plan.ids.isEmpty else { return }
        cardPreview.dismiss()
        setRevealed(false)
        let alert = NSAlert()
        alert.messageText = "清空 \(plan.ids.count) 个临时卡片？"
        alert.informativeText = plan.message
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { line.clear(plan.ids) }
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Replyline to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Quick Look

    /// With no window of ours in front, Quick Look finds its controller here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.release(panel)
    }

}
