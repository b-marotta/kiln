import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var store: ConversionTaskStore!

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Programmatic accessory apps still need menu commands for text shortcuts.
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Kiln")
        applicationMenu.addItem(withTitle: "Esci da Kiln", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem(title: "Modifica", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Modifica")
        let commands: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Annulla", Selector(("undo:")), "z", [.command]),
            ("Ripeti", Selector(("redo:")), "z", [.command, .shift]),
            ("Taglia", #selector(NSText.cut(_:)), "x", [.command]),
            ("Copia", #selector(NSText.copy(_:)), "c", [.command]),
            ("Incolla", #selector(NSText.paste(_:)), "v", [.command]),
            ("Seleziona tutto", #selector(NSText.selectAll(_:)), "a", [.command])
        ]
        for (title, action, key, modifiers) in commands {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent: no Dock-centric window.
        NSApp.setActivationPolicy(.accessory)
        store = ConversionTaskStore()
        menuBar = MenuBarController(store: store)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopen from Dock (if shown) → drop overlay as entry point.
        menuBar?.toggleOverlayPublic()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
