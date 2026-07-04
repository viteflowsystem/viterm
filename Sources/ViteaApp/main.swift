import AppKit
import ViteaServices

// vitea エントリポイント。
// AppModel(状態管理)+ SessionManager(サーフェス実体)+ MainWindowController(UI)を配線する。

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        appMenu.addItem(withTitle: "Quit vitea", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

        let jump = NSMenuItem(title: "最新の入力待ちへ", action: #selector(MainWindowController.jumpToWaiting(_:)), keyEquivalent: "u")
        jump.keyEquivalentModifierMask = [.command, .shift]
        jump.target = controller
        sessionMenu.addItem(jump)

        sessionMenu.addItem(.separator())
        for number in 1...9 {
            let item = NSMenuItem(
                title: "セッション \(number)",
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
        let palette = NSMenuItem(title: "コマンドパレット…", action: #selector(MainWindowController.showPalette(_:)), keyEquivalent: "k")
        palette.target = controller
        viewMenu.addItem(palette)
        let addRepo = NSMenuItem(title: "リポジトリを追加…", action: #selector(MainWindowController.addRepository(_:)), keyEquivalent: "")
        addRepo.target = controller
        viewMenu.addItem(addRepo)
        viewMenu.addItem(.separator())
        let toggle = NSMenuItem(title: "サイドバー表示切替", action: #selector(MainWindowController.toggleSidebar2(_:)), keyEquivalent: "b")
        toggle.target = controller
        viewMenu.addItem(toggle)
        viewMenuItem.submenu = viewMenu
        main.addItem(viewMenuItem)

        // Edit メニュー(⌘C/⌘V をシステム標準経路で有効にする)
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
