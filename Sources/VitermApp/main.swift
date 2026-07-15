import AppKit
import VitermServices

// viterm entry point.
// Wires up AppModel (state management) + SessionManager (surface instances) + MainWindowController (UI).

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?

    /// So SIGTERM (pkill / logout, etc.) also goes through the save path
    /// (applicationWillTerminate), catch the signal with a DispatchSource and convert it
    /// to a normal terminate (the default SIGTERM kills the process instantly and
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
        let settings = NSMenuItem(title: "設定…", action: #selector(MainWindowController.showSettings(_:)), keyEquivalent: ",")
        settings.target = controller
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit viterm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        let worktreeMenuItem = NSMenuItem()
        let worktreeMenu = NSMenu(title: "Worktree")
        let newWorktree = NSMenuItem(title: "新規 worktree…", action: #selector(MainWindowController.newWorktree(_:)), keyEquivalent: "n")
        newWorktree.target = controller
        worktreeMenu.addItem(newWorktree)
        let merge = NSMenuItem(title: "デフォルトブランチにマージ…", action: #selector(MainWindowController.mergeCurrentWorktree(_:)), keyEquivalent: "")
        merge.target = controller
        worktreeMenu.addItem(merge)
        let remove = NSMenuItem(title: "worktree を削除…", action: #selector(MainWindowController.removeCurrentWorktree(_:)), keyEquivalent: "")
        remove.target = controller
        worktreeMenu.addItem(remove)
        worktreeMenuItem.submenu = worktreeMenu
        main.addItem(worktreeMenuItem)

        let sessionMenuItem = NSMenuItem()
        let sessionMenu = NSMenu(title: "Session")
        let newSession = NSMenuItem(title: "新規セッション", action: #selector(MainWindowController.newSession(_:)), keyEquivalent: "t")
        newSession.target = controller
        sessionMenu.addItem(newSession)
        let closeTab = NSMenuItem(title: "タブを閉じる", action: #selector(MainWindowController.closeTab(_:)), keyEquivalent: "w")
        closeTab.target = controller
        sessionMenu.addItem(closeTab)

        sessionMenu.addItem(.separator())
        let quickOpen = NSMenuItem(title: "クイックオープン…", action: #selector(MainWindowController.showQuickOpen(_:)), keyEquivalent: "p")
        quickOpen.target = controller
        sessionMenu.addItem(quickOpen)

        sessionMenu.addItem(.separator())
        let jump = NSMenuItem(title: "最新の入力待ちへ", action: #selector(MainWindowController.jumpToWaiting(_:)), keyEquivalent: "u")
        jump.keyEquivalentModifierMask = [.command, .shift]
        jump.target = controller
        sessionMenu.addItem(jump)

        sessionMenu.addItem(.separator())
        let previousWorktree = NSMenuItem(
            title: "前の worktree へ",
            action: #selector(MainWindowController.selectPreviousWorktree(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        )
        previousWorktree.keyEquivalentModifierMask = [.command, .option]
        previousWorktree.target = controller
        sessionMenu.addItem(previousWorktree)
        let nextWorktree = NSMenuItem(
            title: "次の worktree へ",
            action: #selector(MainWindowController.selectNextWorktree(_:)),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        )
        nextWorktree.keyEquivalentModifierMask = [.command, .option]
        nextWorktree.target = controller
        sessionMenu.addItem(nextWorktree)

        sessionMenu.addItem(.separator())
        for number in 1...9 {
            let item = NSMenuItem(
                title: "タブ \(number)",
                action: #selector(MainWindowController.selectShortcutTab(_:)),
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
        let palette = NSMenuItem(title: "コマンドパレット…", action: #selector(MainWindowController.showPalette(_:)), keyEquivalent: "k")
        palette.target = controller
        viewMenu.addItem(palette)
        let addRepo = NSMenuItem(title: "リポジトリを追加…", action: #selector(MainWindowController.addRepository(_:)), keyEquivalent: "")
        addRepo.target = controller
        viewMenu.addItem(addRepo)
        viewMenu.addItem(.separator())
        // ⌘B switches the sidebar body (tree ⇄ state lanes); show/hide moved to ⌘⇧B
        // (an uppercase keyEquivalent implies the Shift modifier).
        let displayMode = NSMenuItem(title: "サイドバーを状態別に表示", action: #selector(MainWindowController.toggleSidebarDisplayMode(_:)), keyEquivalent: "b")
        displayMode.target = controller
        viewMenu.addItem(displayMode)
        let toggle = NSMenuItem(title: "サイドバー表示切替", action: #selector(MainWindowController.toggleSidebar2(_:)), keyEquivalent: "B")
        toggle.target = controller
        viewMenu.addItem(toggle)

        // Font size adjustment. With no target (via the first responder), it reaches the
        // focused GhosttySurfaceView. ⌘= (⌘+ without shift) can't be caught by the menu,
        // but libghostty core's default keybinding (super+equal) handles it via keyDown
        // (same arrangement as upstream Ghostty.app).
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(
            title: "文字を大きく",
            action: #selector(GhosttySurfaceView.increaseFontSize(_:)),
            keyEquivalent: "+"))
        viewMenu.addItem(NSMenuItem(
            title: "文字を小さく",
            action: #selector(GhosttySurfaceView.decreaseFontSize(_:)),
            keyEquivalent: "-"))
        viewMenu.addItem(NSMenuItem(
            title: "文字サイズをリセット",
            action: #selector(GhosttySurfaceView.resetFontSize(_:)),
            keyEquivalent: "0"))
        viewMenuItem.submenu = viewMenu
        main.addItem(viewMenuItem)

        // Edit menu (enables ⌘C/⌘V through the standard system path)
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
