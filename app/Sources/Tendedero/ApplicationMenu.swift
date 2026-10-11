import AppKit

@MainActor
enum ApplicationMenu {
    /// AppKit routes Command shortcuts through mainMenu, including in an
    /// accessory app. Nil targets send edits to the focused text responder.
    static func install(on app: NSApplication, settings: @escaping () -> Void = {}) {
        let main = NSMenu()
        let application = NSMenu(title: "Replyline")
        application.addItem(ClosureMenuItem("设置…", key: ",", handler: settings))
        application.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Replyline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app
        application.addItem(quit)
        let appItem = NSMenuItem()
        appItem.submenu = application
        main.addItem(appItem)

        let editing = NSMenu(title: "编辑")
        editing.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editing.addItem(redo)
        editing.addItem(.separator())
        editing.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editing.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editing.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editing.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = editing
        main.addItem(editItem)
        app.mainMenu = main
    }
}
