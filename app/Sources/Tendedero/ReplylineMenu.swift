import AppKit

enum ReplylineMenuAction { case toggle, library, openFolder, clear, settings, quit }

@MainActor
enum ReplylineMenu {
    static func populate(_ menu: NSMenu, isRevealed: Bool, temporaryCount: Int, shortcut: Shortcut?,
                         perform: @escaping (ReplylineMenuAction) -> Void) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let toggle = ClosureMenuItem(isRevealed ? "隐藏晾衣架" : "显示晾衣架") { perform(.toggle) }
        apply(shortcut, to: toggle)
        menu.addItem(toggle)
        let library = ClosureMenuItem("管理常用素材…") { perform(.library) }
        apply(.library, to: library)
        menu.addItem(library)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("打开截图文件夹") { perform(.openFolder) })
        let clear = ClosureMenuItem("清空临时截图…") { perform(.clear) }
        clear.isEnabled = temporaryCount > 0
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("设置…", key: ",") { perform(.settings) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("退出 Replyline", key: "q") { perform(.quit) })
        let symbols = [isRevealed ? "tshirt.fill" : "tshirt", "square.stack", "folder", "trash", "gearshape", "power"]
        for (item, symbol) in zip(menu.items.filter { !$0.isSeparatorItem }, symbols) {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.image?.isTemplate = true
        }
    }

    private static func apply(_ shortcut: Shortcut?, to item: NSMenuItem) {
        guard let shortcut, shortcut.key.count == 1 else { return }
        item.keyEquivalent = shortcut.key
        item.keyEquivalentModifierMask = shortcut.modifiers
    }
}

struct TemporaryClearPlan {
    let ids: Set<UUID>
    let trashCount: Int
    let takeDownCount: Int

    init(items: [Pegged], inbox: URL) {
        let temporary = items.filter { !$0.falling && !$0.isLibraryItem }
        ids = Set(temporary.map(\.id))
        let prefix = inbox.standardizedFileURL.path + "/"
        trashCount = temporary.filter { $0.url.standardizedFileURL.path.hasPrefix(prefix) }.count
        takeDownCount = temporary.count - trashCount
    }

    var message: String {
        var parts: [String] = []
        if trashCount > 0 { parts.append("\(trashCount) 个 Replyline 截图目录中的文件会移到废纸篓。") }
        if takeDownCount > 0 { parts.append("\(takeDownCount) 个外部文件只从晾衣架取下，原文件保留。") }
        parts.append("常用素材保留。")
        return parts.joined(separator: "\n")
    }
}
