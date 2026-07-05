import AppKit
import GhosttyKit
import GitKit
import UserNotifications
import ViteaCore
import ViteaServices

/// メインウィンドウ: サイドバー + ターミナルホスト + ステータスバーの統合(T7b/T8/T9)。
/// AppModel(状態)と SessionManager(サーフェス実体)を束ね、キーボードショートカットを配線する。
@MainActor
final class MainWindowController: NSWindowController {
    let appModel: AppModel
    let sessionManager: SessionManager

    private let sidebar = SidebarViewController()
    private let splitHost = SplitHostView()
    /// ペインが1つも無いときに表示するプレースホルダ。
    private let placeholderView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        let label = NSTextField(labelWithString: "⌘T でセッションを起動 / ⌘N で worktree を作成")
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }()
    private let statusBar = StatusBarView()
    private let splitView = NSSplitView()
    private let stateMonitor = SessionStateMonitor()
    /// .app バンドル外(swift run)では UNUserNotificationCenter が使えないため起動時に判定。
    private let notificationsAvailable = Bundle.main.bundleIdentifier != nil

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
        sidebar.onSelectWorktree = { [weak self] worktreePath in
            self?.selectWorktree(worktreePath)
        }
        sidebar.onAddRepository = { [weak self] in self?.addRepository(nil) }
        sidebar.onNewWorktree = { [weak self] in self?.newWorktree(nil) }
        sidebar.onNewSession = { [weak self] in self?.newSession(nil) }
        sidebar.onShowPalette = { [weak self] in self?.showPalette(nil) }
        sidebar.onAddSession = { [weak self] worktreePath in
            self?.selectedWorktreePath = worktreePath
            self?.startDefaultSession(in: worktreePath)
        }
        sidebar.onRenameSession = { [weak self] sessionID, currentName in
            self?.renameSession(sessionID, currentName: currentName)
        }
        sidebar.onTerminateSession = { [weak self] sessionID in
            self?.terminateSession(sessionID)
        }
        sidebar.onMergeWorktree = { [weak self] path in self?.mergeWorktree(at: path) }
        sidebar.onRemoveWorktree = { [weak self] path in self?.removeWorktreeFlow(at: path) }
        stateMonitor.onStateChange = { [weak self] sessionID, newState in
            self?.handleStateChange(sessionID: sessionID, newState: newState)
        }
        // サイドバーの git 情報(ahead/behind・diffstat・dirty)を30秒周期で自動更新。
        appModel.onRefreshCompleted = { [weak self] in
            guard let self else { return }
            self.sessionManager.worktreeBranches = Dictionary(
                uniqueKeysWithValues: self.appModel.worktrees.map { ($0.path, $0.branch) }
            )
            self.render()
        }
        appModel.startAutoRefresh()
        if notificationsAvailable {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // MARK: - 状態検出・通知(T13b/T14)

    /// 起動済みセッションを状態監視に登録する。
    private func watchSession(_ session: AgentSession) {
        guard let surfaceView = sessionManager.surface(for: session.id) else { return }
        stateMonitor.watch(sessionID: session.id, surfaceView: surfaceView, toolName: session.presetName)

        // OSC 9/777 のデスクトップ通知と BEL を一次シグナルとして扱う(cmux 方式)。
        // エージェント自身が「注意が必要」と宣言したタイミングなので、テキストパターン検出を
        // 待たず即座に waitingInput へ遷移させ、通知はエージェントのメッセージをそのまま使う。
        let sessionID = session.id
        surfaceView.onDesktopNotification = { [weak self] title, body in
            guard let self else { return }
            self.appModel.sessionStateChanged(sessionID: sessionID, newState: .waitingInput)
            self.render()
            self.postNotification(
                title: title.isEmpty ? "通知: \(self.displayName(of: sessionID))" : title,
                body: body,
                sessionID: sessionID
            )
        }
        surfaceView.onBell = { [weak self] in
            guard let self, self.appModel.sidebar.selectedSessionID != sessionID else { return }
            self.appModel.sessionStateChanged(sessionID: sessionID, newState: .waitingInput)
            self.render()
            NSApp.requestUserAttention(.informationalRequest)
        }
        // shell integration 有効時のみ発火(OSC 133)。コマンド終了=プロンプトに戻った=idle。
        surfaceView.onCommandFinished = { [weak self] _, _ in
            guard let self else { return }
            self.appModel.sessionStateChanged(sessionID: sessionID, newState: .idle)
            self.render()
        }
        // OSC 9;4 の進捗報告。進捗中は busy、REMOVE(完了)はテキスト検出に委ねる。
        surfaceView.onProgressReport = { [weak self] state, _ in
            guard let self, state != GHOSTTY_PROGRESS_STATE_REMOVE else { return }
            self.appModel.sessionStateChanged(sessionID: sessionID, newState: .busy)
            self.render()
        }
        // 子プロセスが exit したらセッションも消す(確認なし。ユーザーが exit したのだから)。
        surfaceView.onSurfaceClose = { [weak self] in
            self?.cleanUpSession(sessionID)
        }
    }

    /// セッションの後始末: 監視解除 → ペインから外す → サーフェス破棄 → 一覧から削除。
    private func cleanUpSession(_ sessionID: AgentSession.ID) {
        stateMonitor.unwatch(sessionID: sessionID)
        if let surface = sessionManager.surface(for: sessionID) {
            splitHost.closePane(containing: surface)
        }
        sessionManager.terminate(sessionID: sessionID)
        appModel.removeSession(sessionID)
        render()
        persistSessions()
    }

    private func displayName(of sessionID: AgentSession.ID) -> String {
        appModel.sessions.first { $0.id == sessionID }?.displayName ?? "セッション"
    }

    private func postNotification(title: String, body: String, sessionID: AgentSession.ID) {
        NSApp.requestUserAttention(.informationalRequest)
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: "\(sessionID.uuidString)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func handleStateChange(sessionID: AgentSession.ID, newState: AgentSession.State) {
        appModel.sessionStateChanged(sessionID: sessionID, newState: newState)
        render()

        // 入力待ちに遷移した非選択セッションのみ通知(cmux 方式)。
        guard newState == .waitingInput,
              appModel.sidebar.selectedSessionID != sessionID,
              let session = appModel.sessions.first(where: { $0.id == sessionID }) else { return }
        NSApp.requestUserAttention(.informationalRequest)
        if notificationsAvailable {
            let content = UNMutableNotificationContent()
            content.title = "入力待ち: \(session.displayName)"
            let branch = appModel.worktrees.first { $0.path == session.worktreePath }?.branch
            content.body = branch.map { "worktree: \($0)" } ?? session.worktreePath
            let request = UNNotificationRequest(
                identifier: sessionID.uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
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
        splitView.addArrangedSubview(splitHost)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        // ペインのフォーカス移動をサイドバー選択に同期する。
        splitHost.onActivePaneChanged = { [weak self] contentView in
            guard let self, let contentView,
                  let sessionID = self.sessionManager.sessionID(for: contentView),
                  self.appModel.sidebar.selectedSessionID != sessionID else { return }
            self.appModel.selectSession(sessionID)
            self.render()
        }

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
        sidebar.set(viewModel: appModel.sidebar, selectedWorktreePath: selectedWorktreePath)
        statusBar.update(sidebar: appModel.sidebar)
        let selectedID = appModel.sidebar.selectedSessionID
        let surface = selectedID.flatMap { sessionManager.surface(for: $0) }
        if let surface {
            // 既にペインに表示中ならフォーカスのみ。分割中は選択セッションをアクティブペインへ、
            // 単一ペインなら丸ごと差し替え。
            if !splitHost.focusPane(containing: surface) {
                if splitHost.hostedViews.count > 1 {
                    splitHost.replaceActive(with: surface)
                } else {
                    splitHost.showRoot(surface)
                }
            }
        } else if splitHost.hostedViews.isEmpty || splitHost.hostedViews == [placeholderView] {
            splitHost.showRoot(placeholderView)
        }
        // 表示中セッションは高頻度、非表示は間引きで状態監視(P1)。
        stateMonitor.setVisibleSession(selectedID)
    }

    func refreshAndRender() {
        Task { @MainActor in
            await appModel.refresh()
            sessionManager.presets = appModel.config.presets
            sessionManager.worktreeBranches = Dictionary(
                uniqueKeysWithValues: appModel.worktrees.map { ($0.path, $0.branch) }
            )
            render()
            await restoreSessionsIfNeeded()
            // デバッグ再現用: VITEA_AUTOSTART_SESSION=1 で起動直後にセッションを開く。
            if ProcessInfo.processInfo.environment["VITEA_AUTOSTART_SESSION"] != nil {
                newSession(nil)
            }
            // デバッグ再現用: VITEA_OPEN_SETTINGS=1 で起動直後に設定ウィンドウを開き、状態をログする。
            if ProcessInfo.processInfo.environment["VITEA_OPEN_SETTINGS"] != nil {
                showSettings(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    for window in NSApp.windows {
                        NSLog("vitea-debug window: '\(window.title)' visible=\(window.isVisible) frame=\(window.frame)")
                    }
                }
            }
        }
    }

    private func select(sessionID: AgentSession.ID) {
        guard appModel.sidebar.selectedSessionID != sessionID else { return }
        selectedWorktreePath = nil
        appModel.selectSession(sessionID)
        render()
    }

    /// worktree 行の選択。セッションがあれば先頭を表示し、無ければ ⌘T のターゲットとして記憶する。
    private var selectedWorktreePath: String?

    private func selectWorktree(_ worktreePath: String) {
        selectedWorktreePath = worktreePath
        if let session = appModel.sessions.first(where: { $0.worktreePath == worktreePath }) {
            appModel.selectSession(session.id)
        } else {
            // 起動はしない。ツリー内の「＋ セッションを追加」行から明示的に開く。
            appModel.selectSession(nil)
        }
        render()
    }

    /// ツリーの「＋ セッションを追加」行 / ⌘T から、指定 worktree に既定プリセットを起動する。
    func startDefaultSession(in worktreePath: String) {
        Task { @MainActor in
            do {
                let session = try await appModel.startSession(
                    worktreePath: worktreePath,
                    presetName: appModel.config.defaultPreset ?? "shell"
                )
                watchSession(session)
                appModel.selectSession(session.id)
                render()
                persistSessions()
            } catch {
                Self.presentError(error, in: window)
            }
        }
    }

    // MARK: - セッション構成の永続化・復元

    private let restoreStore = SessionRestoreStore()
    private var didRestoreSessions = false

    func persistSessions() {
        restoreStore.save(
            sessions: appModel.sessions,
            selectedSessionID: appModel.sidebar.selectedSessionID
        )
    }

    /// 起動後の初回 refresh 完了時に、前回のセッション構成を復元する。
    private func restoreSessionsIfNeeded() async {
        guard !didRestoreSessions else { return }
        didRestoreSessions = true
        guard let state = restoreStore.load(), !state.sessions.isEmpty else { return }

        let knownWorktrees = Set(appModel.worktrees.map(\.path))
        var restored: [AgentSession] = []
        for persisted in state.sessions where knownWorktrees.contains(persisted.worktreePath) {
            if let session = try? await appModel.startSession(
                worktreePath: persisted.worktreePath,
                presetName: persisted.presetName
            ) {
                watchSession(session)
                restored.append(session)
            }
        }
        if let index = state.selectedIndex, restored.indices.contains(index) {
            appModel.selectSession(restored[index].id)
            selectedWorktreePath = nil
        }
        render()
    }

    // MARK: - アクション(メニュー/ショートカットから)

    /// 現在選択中の worktree(なければ最初の worktree)にセッションを追加する。⌘T
    @objc func newSession(_ sender: Any?) {
        let worktreePath = appModel.sidebar.selectedSession?.session.worktreePath
            ?? selectedWorktreePath
            ?? appModel.worktrees.first?.path
        guard let worktreePath else {
            NSSound.beep()
            return
        }
        startDefaultSession(in: worktreePath)
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

    // MARK: - ペイン分割(T16)

    /// ⌘D 右に分割 / ⌘⇧D 下に分割。現在の worktree に新規セッションを起動して新ペインに配置する。
    @objc func splitPaneRight(_ sender: Any?) { splitPane(vertically: true) }
    @objc func splitPaneDown(_ sender: Any?) { splitPane(vertically: false) }

    private func splitPane(vertically: Bool) {
        let worktreePath = appModel.sidebar.selectedSession?.session.worktreePath
            ?? selectedWorktreePath
            ?? appModel.worktrees.first?.path
        guard let worktreePath else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            do {
                let session = try await appModel.startSession(
                    worktreePath: worktreePath,
                    presetName: appModel.config.defaultPreset ?? "shell"
                )
                watchSession(session)
                guard let surface = sessionManager.surface(for: session.id) else { return }
                if splitHost.hostedViews.isEmpty || splitHost.hostedViews == [placeholderView] {
                    splitHost.showRoot(surface)
                } else {
                    splitHost.splitActive(surface, vertically: vertically)
                }
                appModel.selectSession(session.id)
                render()
                persistSessions()
            } catch {
                Self.presentError(error, in: window)
            }
        }
    }

    /// ⌘⇧W ペインを閉じる(セッションはバックグラウンドで生存し、サイドバーから戻れる)。
    @objc func closePane(_ sender: Any?) {
        guard splitHost.closeActivePane() != nil else {
            NSSound.beep()
            return
        }
        render()
    }

    /// ⌘] 次のペインへフォーカス移動。
    @objc func focusNextPane(_ sender: Any?) {
        splitHost.focusNextPane()
    }

    /// ⌘K コマンドパレット(T12b)。
    @objc func showPalette(_ sender: Any?) {
        guard let window else { return }
        let commands = PaletteCommandProvider.commands(
            repositories: appModel.sidebar.repositories,
            presets: appModel.config.presets,
            defaultPresetName: appModel.config.defaultPreset,
            currentWorktreeID: appModel.sidebar.selectedSession?.session.worktreePath
        )
        PalettePanel.show(over: window, commands: commands) { [weak self] action in
            self?.performPaletteAction(action)
        }
    }

    private func performPaletteAction(_ action: PaletteAction) {
        switch action {
        case .createWorktree:
            newWorktree(nil)
        case let .switchToWorktree(worktreeID):
            // その worktree の先頭セッションを選択(無ければセッション起動を促す)。
            if let session = appModel.sessions.first(where: { $0.worktreePath == worktreeID }) {
                appModel.selectSession(session.id)
                render()
            } else {
                Task { @MainActor in
                    await appModel.switchToWorktree(worktreeID)
                    self.newSession(nil)
                }
            }
        case .mergeWorktree:
            mergeCurrentWorktree(nil)
        case .removeWorktree:
            removeCurrentWorktree(nil)
        case let .startSession(worktreeID, presetName):
            Task { @MainActor in
                do {
                    let session = try await appModel.startSession(worktreePath: worktreeID, presetName: presetName)
                    watchSession(session)
                    appModel.selectSession(session.id)
                    render()
                } catch {
                    Self.presentError(error, in: window)
                }
            }
        case .addRepository:
            addRepository(nil)
        }
    }

    private var settingsWindowController: SettingsWindowController?

    /// ⌘, 設定ウィンドウ(独立ウィンドウ、カテゴリはツールバーで切替)。変更は即時保存・即時反映。
    ///
    /// ウィンドウの生成・表示は必ず「素の」main runloop ターンで行う。Swift Task の中で
    /// AppKit のウィンドウ/レイアウトを構築すると、@MainActor メソッドの executor チェックが
    /// Task の executor 参照を読んで EXC_BAD_ACCESS するケースがあるため(実測)。
    @objc func showSettings(_ sender: Any?) {
        DispatchQueue.main.async { [self] in
            if settingsWindowController == nil {
                let store = SettingsStore { [weak self] in
                    self?.refreshAndRender()
                }
                settingsWindowController = SettingsWindowController(store: store)
            }
            settingsWindowController?.showWindow(nil)
            settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// リポジトリ追加(ディレクトリ選択、T15)。
    @objc func addRepository(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "git リポジトリのルートディレクトリを選択"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    _ = try await self.appModel.addRepository(name: url.lastPathComponent, path: url.path)
                    self.render()
                } catch {
                    Self.presentError(error, in: self.window)
                }
            }
        }
    }

    /// 現在の文脈のリポジトリ(選択セッション → 選択worktree → 先頭リポジトリの順で解決)。
    private var currentRepository: Repository? {
        let worktreePath = appModel.sidebar.selectedSession?.session.worktreePath ?? selectedWorktreePath
        if let worktreePath,
           let worktree = appModel.worktrees.first(where: { $0.path == worktreePath }) {
            return appModel.repositories.first { $0.path == worktree.repositoryPath }
        }
        return appModel.repositories.first
    }

    /// ⌘N worktree 新規作成シート(T10)。
    @objc func newWorktree(_ sender: Any?) {
        guard let repository = currentRepository, let window else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            let repoURL = URL(fileURLWithPath: repository.path)
            let branches = (try? await GitService().branches(in: repoURL)) ?? []
            let form = NewWorktreeFormModel(
                repository: repository,
                defaultPathTemplate: appModel.config.pathTemplate,
                availableBranches: branches.map {
                    AvailableBranch(name: $0.name, kind: $0.kind == .local ? .local : .remote)
                },
                existingWorktreePaths: appModel.worktrees.map(\.path),
                copySessionData: appModel.config.copySessionDataByDefault ?? false
            )
            let sheet = NewWorktreeSheet(
                form: form,
                launchPresetName: appModel.config.defaultPreset ?? "shell"
            ) { [weak self] request in
                self?.createWorktree(request)
            }
            let panel = NSWindow(contentViewController: sheet)
            window.beginSheet(panel, completionHandler: nil)
        }
    }

    private func createWorktree(_ request: NewWorktreeRequest) {
        Task { @MainActor in
            do {
                let result = try await appModel.createWorktree(from: request)
                // createWorktree 内でセッション起動まで済んでいるので、その最新セッションを選択・監視する。
                if let session = appModel.sessions.last(where: { $0.worktreePath == result.worktreePath }) {
                    watchSession(session)
                    appModel.selectSession(session.id)
                }
                render()
            } catch {
                Self.presentError(error, in: window)
            }
        }
    }

    /// 選択中 worktree をデフォルトブランチへマージして後始末(T11)。
    @objc func mergeCurrentWorktree(_ sender: Any?) {
        guard let selected = appModel.sidebar.selectedSession?.session.worktreePath ?? selectedWorktreePath else {
            NSSound.beep()
            return
        }
        mergeWorktree(at: selected)
    }

    func mergeWorktree(at path: String) {
        guard let worktree = appModel.worktrees.first(where: { $0.path == path }),
              let repository = appModel.repositories.first(where: { $0.path == worktree.repositoryPath }),
              let window else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            let repoURL = URL(fileURLWithPath: repository.path)
            let target = (try? await GitService().defaultBranch(in: repoURL)) ?? "main"

            let alert = NSAlert()
            alert.messageText = "\(worktree.branch) を \(target) にマージ"
            alert.informativeText = "マージ成功後、worktree とローカルブランチを削除します。"
            alert.addButton(withTitle: "Merge (--no-ff)")
            alert.addButton(withTitle: "Rebase → ff-only")
            alert.addButton(withTitle: "キャンセル")
            let response = await alert.beginSheetModal(for: window)

            let strategy: MergeStrategy
            switch response {
            case .alertFirstButtonReturn: strategy = .merge()
            case .alertSecondButtonReturn: strategy = .rebase
            default: return
            }

            let request = MergeCleanupRequest(
                source: worktree.branch,
                target: target,
                sourceWorktree: URL(fileURLWithPath: worktree.path),
                targetWorktree: repoURL,
                strategy: strategy
            )
            let result = await appModel.mergeAndCleanUp(request)
            render()
            if !result.isFullySuccessful {
                let failed = result.steps.filter { !$0.isSuccess }
                Self.presentError(
                    NSError(domain: "vitea", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "一部のステップが失敗: \(failed.map(String.init(describing:)).joined(separator: ", "))"
                    ]),
                    in: window
                )
            }
        }
    }

    /// 選択中 worktree を削除(dirty なら確認、T11)。
    @objc func removeCurrentWorktree(_ sender: Any?) {
        guard let selected = appModel.sidebar.selectedSession?.session.worktreePath ?? selectedWorktreePath else {
            NSSound.beep()
            return
        }
        removeWorktreeFlow(at: selected)
    }

    func removeWorktreeFlow(at path: String) {
        guard let worktree = appModel.worktrees.first(where: { $0.path == path }),
              let window else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = "worktree を削除"
            alert.informativeText = worktree.isDirty
                ? "\(worktree.branch) には未コミットの変更があります。強制削除しますか?"
                : "\(worktree.branch)(\(worktree.path))を削除します。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: worktree.isDirty ? "強制削除" : "削除")
            alert.addButton(withTitle: "キャンセル")
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }

            do {
                try await appModel.removeWorktree(
                    at: worktree.path,
                    in: worktree.repositoryPath,
                    force: worktree.isDirty
                )
                render()
            } catch {
                Self.presentError(error, in: window)
            }
        }
    }

    // MARK: - セッション操作(コンテキストメニュー)

    private func renameSession(_ sessionID: AgentSession.ID, currentName: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "セッションをリネーム"
        let field = NSTextField(string: currentName)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "リネーム")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newName.isEmpty else { return }
            self.appModel.renameSession(sessionID, to: newName)
            self.render()
            self.persistSessions()
        }
    }

    private func terminateSession(_ sessionID: AgentSession.ID) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "セッションを終了"
        alert.informativeText = "実行中のプロセスは終了され、スクロールバックも破棄されます。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "終了")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.cleanUpSession(sessionID)
        }
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
