import AppKit
import VitermServices

// viterm entry point.
// Wires up AppModel (state management) + SessionManager (surface instances) + MainWindowController (UI).

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?

    /// So that SIGTERM (pkill, logout, etc.) also goes through the save path
    /// (applicationWillTerminate), catch the signal with a DispatchSource and convert it
    /// into a normal terminate (by default SIGTERM kills the process instantly and
    /// applicationWillTerminate is never called).
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigtermSource = source

        let sessionManager = SessionManager()
        let appModel = AppModel(sessionLauncher: sessionManager)
        let controller = MainWindowController(appModel: appModel, sessionManager: sessionManager)
        windowController = controller

        NSApp.mainMenu = Self.buildMenu(for: controller)
        controller.showWindow(nil)
        controller.refreshAndRender()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.persistSessions()
    }

    private static func buildMenu(for controller: MainWindowController) -> NSMenu {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(MainWindowController.showSettings(_:)), keyEquivalent: ",")
        settings.target = controller
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit viterm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        let worktreeMenuItem = NSMenuItem()
        let worktreeMenu = NSMenu(title: "Worktree")
        let newWorktree = NSMenuItem(title: L("New Worktree…"), action: #selector(MainWindowController.newWorktree(_:)), keyEquivalent: "n")
        newWorktree.target = controller
        worktreeMenu.addItem(newWorktree)
        let merge = NSMenuItem(title: L("Merge into Default Branch…"), action: #selector(MainWindowController.mergeCurrentWorktree(_:)), keyEquivalent: "")
        merge.target = controller
        worktreeMenu.addItem(merge)
        let remove = NSMenuItem(title: L("Delete Worktree…"), action: #selector(MainWindowController.removeCurrentWorktree(_:)), keyEquivalent: "")
        remove.target = controller
        worktreeMenu.addItem(remove)
        worktreeMenuItem.submenu = worktreeMenu
        main.addItem(worktreeMenuItem)

        let sessionMenuItem = NSMenuItem()
        let sessionMenu = NSMenu(title: "Session")
        let newSession = NSMenuItem(title: L("New Session"), action: #selector(MainWindowController.newSession(_:)), keyEquivalent: "t")
        newSession.target = controller
        sessionMenu.addItem(newSession)

        let jump = NSMenuItem(title: L("Jump to Latest Waiting Session"), action: #selector(MainWindowController.jumpToWaiting(_:)), keyEquivalent: "u")
        jump.keyEquivalentModifierMask = [.command, .shift]
        jump.target = controller
        sessionMenu.addItem(jump)

        sessionMenu.addItem(.separator())
        let splitRight = NSMenuItem(title: L("Split Right"), action: #selector(MainWindowController.splitPaneRight(_:)), keyEquivalent: "d")
        splitRight.target = controller
        sessionMenu.addItem(splitRight)
        let splitDown = NSMenuItem(title: L("Split Down"), action: #selector(MainWindowController.splitPaneDown(_:)), keyEquivalent: "d")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        splitDown.target = controller
        sessionMenu.addItem(splitDown)
        let closePane = NSMenuItem(title: L("Close Pane"), action: #selector(MainWindowController.closePane(_:)), keyEquivalent: "w")
        closePane.keyEquivalentModifierMask = [.command, .shift]
        closePane.target = controller
        sessionMenu.addItem(closePane)
        let nextPane = NSMenuItem(title: L("Next Pane"), action: #selector(MainWindowController.focusNextPane(_:)), keyEquivalent: "]")
        nextPane.target = controller
        sessionMenu.addItem(nextPane)

        sessionMenu.addItem(.separator())
        for number in 1...9 {
            let item = NSMenuItem(
                title: L("Session \(number)"),
                action: #selector(MainWindowController.selectShortcutSession(_:)),
                keyEquivalent: "\(number)"
            )
            item.tag = number
            item.target = controller
            sessionMenu.addItem(item)
        }
        sessionMenuItem.submenu = sessionMenu
        main.addItem(sessionMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let palette = NSMenuItem(title: L("Command Palette…"), action: #selector(MainWindowController.showPalette(_:)), keyEquivalent: "k")
        palette.target = controller
        viewMenu.addItem(palette)
        let addRepo = NSMenuItem(title: L("Add Repository…"), action: #selector(MainWindowController.addRepository(_:)), keyEquivalent: "")
        addRepo.target = controller
        viewMenu.addItem(addRepo)
        viewMenu.addItem(.separator())
        let toggle = NSMenuItem(title: L("Toggle Sidebar"), action: #selector(MainWindowController.toggleSidebar2(_:)), keyEquivalent: "b")
        toggle.target = controller
        viewMenu.addItem(toggle)
        viewMenuItem.submenu = viewMenu
        main.addItem(viewMenuItem)

        // Edit menu (enables Cmd+C/Cmd+V through the standard system path)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenuItem.submenu = editMenu
        main.addItem(editMenuItem)

        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
