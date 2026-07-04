import AppKit
import ViteaCore
import ViteaServices

/// メインウィンドウ: サイドバー + ターミナルホスト + ステータスバーの統合(T7b/T8/T9)。
/// AppModel(状態)と SessionManager(サーフェス実体)を束ね、キーボードショートカットを配線する。
@MainActor
final class MainWindowController: NSWindowController {
    let appModel: AppModel
    let sessionManager: SessionManager

    private let sidebar = SidebarViewController()
    private let terminalHost = TerminalHostView()
    private let statusBar = StatusBarView()
    private let splitView = NSSplitView()

    init(appModel: AppModel, sessionManager: SessionManager) {
        self.appModel = appModel
        self.sessionManager = sessionManager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "vitea"
        window.center()
        window.setFrameAutosaveName("vitea.main")
        super.init(window: window)

        setUpContent()
        sidebar.onSelectSession = { [weak self] sessionID in
            self?.select(sessionID: sessionID)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setUpContent() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebarView = sidebar.view
        sidebarView.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        splitView.addArrangedSubview(sidebarView)
        splitView.addArrangedSubview(terminalHost)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        let root = NSView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)
        root.addSubview(statusBar)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window?.contentView = root
        DispatchQueue.main.async { [self] in
            splitView.setPosition(240, ofDividerAt: 0)
        }
    }

    // MARK: - 状態同期

    /// AppModel の現在状態を UI に反映する。状態変化のたびに呼ぶ。
    func render() {
        sidebar.set(viewModel: appModel.sidebar)
        statusBar.update(sidebar: appModel.sidebar)
        let selectedID = appModel.sidebar.selectedSessionID
        terminalHost.show(selectedID.flatMap { sessionManager.surface(for: $0) })
    }

    func refreshAndRender() {
        Task { @MainActor in
            await appModel.refresh()
            sessionManager.presets = appModel.config.presets
            render()
        }
    }

    private func select(sessionID: AgentSession.ID) {
        appModel.selectSession(sessionID)
        render()
    }

    // MARK: - アクション(メニュー/ショートカットから)

    /// 現在選択中の worktree(なければ最初の worktree)にセッションを追加する。⌘T
    @objc func newSession(_ sender: Any?) {
        let worktreePath = appModel.sidebar.selectedSession?.session.worktreePath
            ?? appModel.worktrees.first?.path
        guard let worktreePath else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            do {
                let session = try await appModel.startSession(
                    worktreePath: worktreePath,
                    presetName: appModel.config.defaultPreset ?? "claude"
                )
                appModel.selectSession(session.id)
                render()
            } catch {
                Self.presentError(error, in: window)
            }
        }
    }

    /// ⌘1..9 セッション直接切替(sender.tag に番号)。
    @objc func selectShortcutSession(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        if appModel.selectShortcut(item.tag) {
            render()
        } else {
            NSSound.beep()
        }
    }

    /// ⌘⇧U 最新の waiting セッションへ。
    @objc func jumpToWaiting(_ sender: Any?) {
        if appModel.jumpToLatestWaitingSession() {
            render()
        } else {
            NSSound.beep()
        }
    }

    /// ⌘B サイドバー表示切替。
    @objc func toggleSidebar2(_ sender: Any?) {
        sidebar.view.isHidden.toggle()
    }

    static func presentError(_ error: any Error, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "操作に失敗しました"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
