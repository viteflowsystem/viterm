import AppKit
import GhosttyKit
import GitKit
import UserNotifications
import VitermCore
import VitermServices

/// Main window: integration of sidebar + terminal host + status bar (T7b/T8/T9).
/// Ties AppModel (state) and SessionManager (surface instances) together and wires up
/// the keyboard shortcuts.
@MainActor
final class MainWindowController: NSWindowController, NSSplitViewDelegate {
    let appModel: AppModel
    let sessionManager: SessionManager

    private let sidebar = SidebarViewController()
    private let tabBar = TabBarView()
    private let splitHost = SplitHostView()
    /// Placeholder shown when there are no panes.
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
    /// UNUserNotificationCenter is unavailable outside an .app bundle (swift run), so detect at launch.
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
        window.title = "viterm"
        // Per the UI mock: the title bar is dark and merges with the content (not a separate light strip).
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .textBackgroundColor
        window.center()
        window.setFrameAutosaveName("viterm.main")
        super.init(window: window)

        setUpContent()
        sidebar.onSelectWorktree = { [weak self] worktreePath in
            self?.selectWorktree(worktreePath)
        }
        sidebar.onFilterChange = { [weak self] text in
            guard let self else { return }
            self.appModel.setSidebarFilter(text)
            self.render()
        }
        sidebar.onDisplayModeChange = { [weak self] mode in
            guard let self else { return }
            self.appModel.setSidebarDisplayMode(mode)
            self.render()
        }
        sidebar.onSelectSession = { [weak self] sessionID in
            guard let self else { return }
            self.appModel.selectSession(sessionID)
            self.render()
        }
        sidebar.onAddRepository = { [weak self] in self?.addRepository(nil) }
        sidebar.onNewWorktree = { [weak self] in self?.newWorktree(nil) }
        sidebar.onNewSession = { [weak self] in self?.newSession(nil) }
        sidebar.onShowPalette = { [weak self] in self?.showPalette(nil) }
        sidebar.onAddSession = { [weak self] worktreePath in
            self?.appModel.selectWorktree(worktreePath)
            self?.startDefaultSession(in: worktreePath)
        }
        sidebar.onMergeWorktree = { [weak self] path in self?.mergeWorktree(at: path) }
        sidebar.onRemoveWorktree = { [weak self] path in self?.removeWorktreeFlow(at: path) }
        sidebar.onNewWorktreeInRepository = { [weak self] repositoryPath in
            guard let self,
                  let repository = self.appModel.repositories.first(where: { $0.path == repositoryPath }) else { return }
            self.newWorktree(in: repository)
        }
        stateMonitor.onStateChange = { [weak self] sessionID, newState in
            self?.handleStateChange(sessionID: sessionID, newState: newState)
        }
        // Auto-refresh the sidebar's git info (ahead/behind, diffstat, dirty) every 30 seconds.
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

    // MARK: - State detection / notifications (T13b/T14)

    /// Register a launched session with the state monitor.
    private func watchSession(_ session: AgentSession) {
        guard let surfaceView = sessionManager.surface(for: session.id) else { return }
        stateMonitor.watch(sessionID: session.id, surfaceView: surfaceView, toolName: session.presetName)

        // Treat OSC 9/777 desktop notifications and BEL as primary signals (cmux style).
        // This is the moment the agent itself declared "attention needed", so transition to
        // waitingInput immediately without waiting for text pattern detection, and use the
        // agent's message verbatim for the notification.
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
        // Only fires with shell integration enabled (OSC 133). Command finished = back at the prompt = idle.
        surfaceView.onCommandFinished = { [weak self] _, _ in
            guard let self else { return }
            self.appModel.sessionStateChanged(sessionID: sessionID, newState: .idle)
            self.render()
        }
        // OSC 9;4 progress reports. In progress = busy; REMOVE (done) is left to text detection.
        surfaceView.onProgressReport = { [weak self] state, _ in
            guard let self, state != GHOSTTY_PROGRESS_STATE_REMOVE else { return }
            self.appModel.sessionStateChanged(sessionID: sessionID, newState: .busy)
            self.render()
        }
        // When the child process exits, remove the session too (no confirmation — the user exited).
        surfaceView.onSurfaceClose = { [weak self] in
            self?.cleanUpSession(sessionID)
        }
    }

    /// Session cleanup: unwatch → detach from the pane → destroy the surface → remove from the list.
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

        // Notify only for non-selected sessions that transitioned to waiting-input (cmux style).
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

        // Terminal side: stack the tab bar (top) and splitHost (bottom) vertically.
        let termContainer = NSView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        splitHost.translatesAutoresizingMaskIntoConstraints = false
        termContainer.addSubview(tabBar)
        termContainer.addSubview(splitHost)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: termContainer.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: termContainer.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: termContainer.trailingAnchor),
            splitHost.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            splitHost.leadingAnchor.constraint(equalTo: termContainer.leadingAnchor),
            splitHost.trailingAnchor.constraint(equalTo: termContainer.trailingAnchor),
            splitHost.bottomAnchor.constraint(equalTo: termContainer.bottomAnchor),
        ])

        splitView.addArrangedSubview(sidebarView)
        splitView.addArrangedSubview(termContainer)
        // Preferentially preserve the sidebar's width while keeping the divider draggable.
        // Min/max widths are managed by the delegate (constrainMin/MaxCoordinate)
        // (an external width constraint on an arranged subview is treated as required and
        // freezes dragging).
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.delegate = self
        splitView.autosaveName = "viterm.sidebar"

        tabBar.onSelectTab = { [weak self] sessionID in self?.select(sessionID: sessionID) }
        tabBar.onCloseTab = { [weak self] sessionID in self?.terminateSession(sessionID) }
        tabBar.onRenameTab = { [weak self] sessionID, currentName in
            self?.renameSession(sessionID, currentName: currentName)
        }
        tabBar.onAddTab = { [weak self] in self?.newSession(nil) }

        // Sync pane focus movement to the sidebar selection (kept for when pane splitting is re-enabled).
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

    // MARK: - State sync

    /// Reflect AppModel's current state into the UI. Called on every state change.
    /// Applies in order: worktree selection → tab bar update → showRoot on the selected
    /// session's surface (pane splitting is sealed off for now, so treating everything as
    /// a single-pane display is fine).
    func render() {
        sidebar.set(viewModel: appModel.sidebar)
        statusBar.update(sidebar: appModel.sidebar)

        let tabs = appModel.sidebar.selectedWorktree?.sessions.map(\.session) ?? []
        tabBar.set(viewModel: TabBarViewModel(sessions: tabs, activeTabID: appModel.sidebar.selectedSessionID))

        let selectedID = appModel.sidebar.selectedSessionID
        let surface = selectedID.flatMap { sessionManager.surface(for: $0) }
        if let surface {
            if splitHost.hostedViews != [surface] {
                splitHost.showRoot(surface)
            }
        } else if splitHost.hostedViews != [placeholderView] {
            splitHost.showRoot(placeholderView)
        }
        // Monitor the visible session at high frequency, hidden ones throttled (P1).
        stateMonitor.setVisibleSession(selectedID)

        // Reflect the current context in the title (mock: "viterm — feat/sidebar · claude #1").
        if let selected = appModel.sidebar.selectedSession {
            let branch = appModel.worktrees.first { $0.path == selected.session.worktreePath }?.branch
            let parts = [branch, selected.session.displayName].compactMap { $0 }
            window?.title = "viterm — " + parts.joined(separator: " · ")
        } else {
            window?.title = "viterm"
        }
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
            // For debug reproduction: VITERM_AUTOSTART_SESSION=1 opens a session right after launch.
            if ProcessInfo.processInfo.environment["VITERM_AUTOSTART_SESSION"] != nil {
                newSession(nil)
            }
            // For debug reproduction: VITERM_OPEN_SETTINGS=1 opens the settings window right after launch and logs its state.
            if ProcessInfo.processInfo.environment["VITERM_OPEN_SETTINGS"] != nil {
                showSettings(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    for window in NSApp.windows {
                        NSLog("viterm-debug window: '\(window.title)' visible=\(window.isVisible) frame=\(window.frame)")
                    }
                }
            }
        }
    }

    private func select(sessionID: AgentSession.ID) {
        guard appModel.sidebar.selectedSessionID != sessionID else { return }
        appModel.selectSession(sessionID)
        render()
    }

    /// Selecting a worktree row. Restores the last active tab if remembered, else picks the
    /// first tab (delegated to `SidebarViewModel.selectWorktree`; nothing is launched — with
    /// no tabs, add one explicitly via the ＋ button / ⌘T).
    private func selectWorktree(_ worktreePath: String) {
        appModel.selectWorktree(worktreePath)
        render()
    }

    /// Launch the default preset in the given worktree, from the tree's "＋ add session" row / ⌘T.
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

    // MARK: - Session layout persistence / restore

    private let restoreStore = SessionRestoreStore()
    private var didRestoreSessions = false

    func persistSessions() {
        // Debug launches (smoke tests, etc.) must not overwrite the user's real session
        // layout. There was an incident where a test launch saved the shrunken list from a
        // half-finished restore and lost real data.
        guard ProcessInfo.processInfo.environment["VITERM_AUTOSTART_SESSION"] == nil else { return }
        restoreStore.save(
            sessions: appModel.sessions,
            selectedSessionID: appModel.sidebar.selectedSessionID,
            selectedWorktreePath: appModel.sidebar.selectedWorktreePath,
            activeSessionByWorktree: appModel.sidebar.activeSessionByWorktree
        )
    }

    /// After the first refresh at launch completes, restore the previous session layout
    /// (including the selected worktree and each worktree's last active session).
    private func restoreSessionsIfNeeded() async {
        guard !didRestoreSessions else { return }
        didRestoreSessions = true
        guard let state = restoreStore.load(), !state.sessions.isEmpty else { return }

        let knownWorktrees = Set(appModel.worktrees.map(\.path))
        // If some entries fail to restore, the indices in `state.sessions` drift out of
        // step with the actually restored sessions, so keep them keyed by original index.
        var restoredByOriginalIndex: [Int: AgentSession] = [:]
        for (index, persisted) in state.sessions.enumerated() where knownWorktrees.contains(persisted.worktreePath) {
            if let session = try? await appModel.startSession(
                worktreePath: persisted.worktreePath,
                presetName: persisted.presetName
            ) {
                watchSession(session)
                restoredByOriginalIndex[index] = session
            }
        }

        // Restore each worktree's last active session first (select(sessionID:)
        // automatically remembers the session's own worktree, so the key's worktreePath
        // itself is unnecessary). This lets the subsequent selectWorktree / selectSession
        // resolve "restore if remembered" correctly.
        for index in (state.activeSessionIndexByWorktree ?? [:]).values {
            guard let session = restoredByOriginalIndex[index] else { continue }
            appModel.selectSession(session.id)
        }

        if let worktreePath = state.selectedWorktreePath, knownWorktrees.contains(worktreePath) {
            appModel.selectWorktree(worktreePath)
        } else if let selectedIndex = state.selectedIndex, let session = restoredByOriginalIndex[selectedIndex] {
            // Backward compatibility with the old format (no selectedWorktreePath).
            appModel.selectSession(session.id)
        }
        render()
    }

    // MARK: - Actions (from menus / shortcuts)

    /// Add a session to the currently selected worktree (or the first worktree if none). ⌘T
    @objc func newSession(_ sender: Any?) {
        let worktreePath = appModel.sidebar.selectedWorktreePath ?? appModel.worktrees.first?.path
        guard let worktreePath else {
            NSSound.beep()
            return
        }
        startDefaultSession(in: worktreePath)
    }

    /// ⌘1..9 tab switching within the selected worktree (number in sender.tag; numbering is tab-local).
    @objc func selectShortcutTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let worktree = appModel.sidebar.selectedWorktree else {
            NSSound.beep()
            return
        }
        var tabBarViewModel = TabBarViewModel(
            sessions: worktree.sessions.map(\.session),
            activeTabID: appModel.sidebar.selectedSessionID
        )
        if tabBarViewModel.selectShortcut(item.tag), let activeTabID = tabBarViewModel.activeTabID {
            appModel.selectSession(activeTabID)
            render()
        } else {
            NSSound.beep()
        }
    }

    /// ⌘⇧U jump to the most recent waiting session.
    @objc func jumpToWaiting(_ sender: Any?) {
        if appModel.jumpToLatestWaitingSession() {
            render()
        } else {
            NSSound.beep()
        }
    }

    /// ⌘⌥↑ to the previous worktree (across repositories, wrapping).
    @objc func selectPreviousWorktree(_ sender: Any?) {
        appModel.selectPreviousWorktree()
        render()
    }

    /// ⌘⌥↓ to the next worktree (across repositories, wrapping).
    @objc func selectNextWorktree(_ sender: Any?) {
        appModel.selectNextWorktree()
        render()
    }

    /// ⌘W close the active tab (session). With no tabs, close the window (standard behavior).
    @objc func closeTab(_ sender: Any?) {
        guard let sessionID = appModel.sidebar.selectedSessionID else {
            window?.performClose(sender)
            return
        }
        terminateSession(sessionID)
    }

    /// The sidebar width before the last hide, restored on the next show.
    private var lastSidebarWidth: CGFloat = 240
    /// Whether the sidebar pane is detached (⌘⇧B). Also lifts the delegate's min-width
    /// constraint while collapsed.
    private var isSidebarCollapsed = false

    /// ⌘⇧B show/hide the sidebar. Detach/re-insert instead of hiding or collapsing the
    /// divider to 0: squeezing the live sidebar through a zero-width layout left stale
    /// pixels on screen (ghost rendering with correct frames), and moving the divider
    /// while the subview was hidden wedged the divider state. Removing the pane avoids
    /// both. (An NSSplitViewController migration was tried and reverted: the sidebar
    /// ended up on the wrong side.)
    @objc func toggleSidebar2(_ sender: Any?) {
        if isSidebarCollapsed {
            isSidebarCollapsed = false
            splitView.insertArrangedSubview(sidebar.view, at: 0)
            splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
            splitView.setPosition(max(lastSidebarWidth, 180), ofDividerAt: 0)
        } else {
            lastSidebarWidth = sidebar.view.frame.width
            isSidebarCollapsed = true
            sidebar.view.removeFromSuperview()
        }
    }

    /// ⌘B toggle the sidebar body between the tree and the state lanes.
    /// If the sidebar is hidden, reveal it first (the toggle should never be invisible).
    @objc func toggleSidebarDisplayMode(_ sender: Any?) {
        if isSidebarCollapsed {
            toggleSidebar2(nil)
        }
        let next: SidebarDisplayMode = appModel.sidebar.displayMode == .tree ? .state : .tree
        appModel.setSidebarDisplayMode(next)
        render()
    }

    // MARK: - Pane splitting (T16)

    /// ⌘D split right / ⌘⇧D split down. Launches a new session in the current worktree and places it in the new pane.
    @objc func splitPaneRight(_ sender: Any?) { splitPane(vertically: true) }
    @objc func splitPaneDown(_ sender: Any?) { splitPane(vertically: false) }

    private func splitPane(vertically: Bool) {
        let worktreePath = appModel.sidebar.selectedWorktreePath ?? appModel.worktrees.first?.path
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

    /// ⌘⇧W close the pane (the session stays alive in the background, reachable from the sidebar).
    @objc func closePane(_ sender: Any?) {
        guard splitHost.closeActivePane() != nil else {
            NSSound.beep()
            return
        }
        render()
    }

    /// ⌘] move focus to the next pane.
    @objc func focusNextPane(_ sender: Any?) {
        splitHost.focusNextPane()
    }

    /// ⌘K command palette (T12b).
    @objc func showPalette(_ sender: Any?) {
        guard let window else { return }
        let commands = PaletteCommandProvider.commands(
            repositories: appModel.sidebar.repositories,
            presets: appModel.config.presets,
            defaultPresetName: appModel.config.defaultPreset,
            currentWorktreeID: appModel.sidebar.selectedWorktreePath
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
            // Select the worktree's first session (or prompt to launch one if there is none).
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

    /// ⌘, settings window (standalone window, categories switched via the toolbar).
    /// Changes save and apply immediately.
    ///
    /// Window creation/display must happen on a "plain" main runloop turn. Building AppKit
    /// windows/layout inside a Swift Task can crash with EXC_BAD_ACCESS when the @MainActor
    /// method's executor check reads the Task's executor reference (observed).
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

    /// Add a repository (directory picker, T15).
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

    /// The repository of the current context (resolved from the selected worktree, then the first repository).
    private var currentRepository: Repository? {
        if let worktreePath = appModel.sidebar.selectedWorktreePath,
           let worktree = appModel.worktrees.first(where: { $0.path == worktreePath }) {
            return appModel.repositories.first { $0.path == worktree.repositoryPath }
        }
        return appModel.repositories.first
    }

    /// ⌘N new-worktree sheet (T10). Targets the repository of the current context.
    @objc func newWorktree(_ sender: Any?) {
        guard let repository = currentRepository else {
            NSSound.beep()
            return
        }
        newWorktree(in: repository)
    }

    /// Open the worktree creation sheet for the given repository (for the sidebar's "＋" / right-click).
    func newWorktree(in repository: Repository) {
        guard let window else {
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
                // createWorktree already launched the session, so select and watch that latest session.
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

    /// Merge the selected worktree into the default branch and clean up (T11).
    @objc func mergeCurrentWorktree(_ sender: Any?) {
        guard let selected = appModel.sidebar.selectedWorktreePath else {
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
                    NSError(domain: "viterm", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "一部のステップが失敗: \(failed.map(String.init(describing:)).joined(separator: ", "))"
                    ]),
                    in: window
                )
            }
        }
    }

    /// Remove the selected worktree (confirm when dirty, T11).
    @objc func removeCurrentWorktree(_ sender: Any?) {
        guard let selected = appModel.sidebar.selectedWorktreePath else {
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

            // Offer to also delete the local branch. Disable it when the same branch is
            // checked out by another worktree in this repository (git can't delete it, and
            // this also naturally covers the repository's default branch, which stays
            // checked out in the main worktree).
            let branchCheckedOutElsewhere = appModel.worktrees.contains {
                $0.repositoryPath == worktree.repositoryPath
                    && $0.path != worktree.path
                    && $0.branch == worktree.branch
            }
            let deleteBranchCheckbox = NSButton(
                checkboxWithTitle: "ブランチ \(worktree.branch) も削除",
                target: nil,
                action: nil
            )
            deleteBranchCheckbox.state = .off
            if branchCheckedOutElsewhere {
                deleteBranchCheckbox.isEnabled = false
                deleteBranchCheckbox.toolTip = "このブランチは他の worktree でチェックアウトされているため削除できません"
            }
            alert.accessoryView = deleteBranchCheckbox

            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            let shouldDeleteBranch = deleteBranchCheckbox.state == .on && deleteBranchCheckbox.isEnabled

            do {
                try await appModel.removeWorktree(
                    at: worktree.path,
                    in: worktree.repositoryPath,
                    force: worktree.isDirty
                )
            } catch {
                Self.presentError(error, in: window)
                return
            }

            // The worktree is already gone; a branch-deletion failure (e.g. unmerged
            // commits with `git branch -d`) is surfaced but not treated as a failure of
            // the whole operation.
            if shouldDeleteBranch {
                do {
                    try await appModel.deleteBranch(worktree.branch, in: worktree.repositoryPath)
                } catch {
                    Self.presentError(error, in: window)
                }
            }
            render()
        }
    }

    // MARK: - Session operations (context menu)

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

    // MARK: - NSSplitViewDelegate (sidebar width constraints)

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // While collapsed, the divider must be allowed to sit at 0.
        isSidebarCollapsed ? proposedMinimumPosition : max(proposedMinimumPosition, 180)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        isSidebarCollapsed ? proposedMaximumPosition : min(proposedMaximumPosition, 480)
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
