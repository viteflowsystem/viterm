import AppKit
import GhosttyKit
import GitKit
import UserNotifications
import VitermCore
import VitermServices

/// Main window: integrates sidebar + terminal host + status bar (T7b/T8/T9).
/// Ties together AppModel (state) and SessionManager (surface instances), and wires keyboard shortcuts.
@MainActor
final class MainWindowController: NSWindowController, NSSplitViewDelegate {
    let appModel: AppModel
    let sessionManager: SessionManager

    private let sidebar = SidebarViewController()
    private let splitHost = SplitHostView()
    /// Placeholder shown when there are no panes at all.
    private let placeholderView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        let label = NSTextField(labelWithString: L("Press ⌘T to start a session or ⌘N to create a worktree"))
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
    /// UNUserNotificationCenter is unavailable outside an .app bundle (swift run), so detect this at launch.
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
        // Per UI mock: the title bar is dark and blends with the content (not a separate light strip).
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .textBackgroundColor
        window.center()
        window.setFrameAutosaveName("viterm.main")
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

    // MARK: - State detection and notifications (T13b/T14)

    /// Register a launched session with the state monitor.
    private func watchSession(_ session: AgentSession) {
        guard let surfaceView = sessionManager.surface(for: session.id) else { return }
        stateMonitor.watch(sessionID: session.id, surfaceView: surfaceView, toolName: session.presetName)

        // Treat OSC 9/777 desktop notifications and BEL as primary signals (cmux approach).
        // These are moments where the agent itself declared "attention needed", so transition to
        // waitingInput immediately without waiting for text-pattern detection, and use the agent's
        // message as-is for the notification.
        let sessionID = session.id
        surfaceView.onDesktopNotification = { [weak self] title, body in
            guard let self else { return }
            self.appModel.sessionStateChanged(sessionID: sessionID, newState: .waitingInput)
            self.render()
            self.postNotification(
                title: title.isEmpty ? L("Notification: \(self.displayName(of: sessionID))") : title,
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
        // Fires only when shell integration is enabled (OSC 133). Command finished = back at prompt = idle.
        surfaceView.onCommandFinished = { [weak self] _, _ in
            guard let self else { return }
            self.appModel.sessionStateChanged(sessionID: sessionID, newState: .idle)
            self.render()
        }
        // OSC 9;4 progress reports. Busy while in progress; REMOVE (completion) is left to text detection.
        surfaceView.onProgressReport = { [weak self] state, _ in
            guard let self, state != GHOSTTY_PROGRESS_STATE_REMOVE else { return }
            self.appModel.sessionStateChanged(sessionID: sessionID, newState: .busy)
            self.render()
        }
        // When the child process exits, remove the session too (no confirmation — the user exited it).
        surfaceView.onSurfaceClose = { [weak self] in
            self?.cleanUpSession(sessionID)
        }
    }

    /// Session cleanup: unwatch -> detach from pane -> destroy surface -> remove from list.
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
        appModel.sessions.first { $0.id == sessionID }?.displayName ?? L("Session")
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

        // Notify only for non-selected sessions that transitioned to waiting-input (cmux approach).
        guard newState == .waitingInput,
              appModel.sidebar.selectedSessionID != sessionID,
              let session = appModel.sessions.first(where: { $0.id == sessionID }) else { return }
        NSApp.requestUserAttention(.informationalRequest)
        if notificationsAvailable {
            let content = UNMutableNotificationContent()
            content.title = L("Waiting for input: \(session.displayName)")
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
        splitView.addArrangedSubview(sidebarView)
        splitView.addArrangedSubview(splitHost)
        // Prefer keeping the sidebar's width while still allowing adjustment by dragging the divider.
        // Min/max widths are managed by the delegate (constrainMin/MaxCoordinate)
        // (an external width constraint on an arranged subview is treated as required and freezes dragging).
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.delegate = self
        splitView.autosaveName = "viterm.sidebar"

        // Sync pane focus changes to the sidebar selection.
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

    // MARK: - State synchronization

    /// Reflect AppModel's current state into the UI. Call on every state change.
    func render() {
        sidebar.set(viewModel: appModel.sidebar, selectedWorktreePath: selectedWorktreePath)
        statusBar.update(sidebar: appModel.sidebar)
        let selectedID = appModel.sidebar.selectedSessionID
        let surface = selectedID.flatMap { sessionManager.surface(for: $0) }
        if let surface {
            // If already shown in a pane, just focus it. When split, put the selected session
            // into the active pane; with a single pane, replace it wholesale.
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
        // Monitor the visible session at high frequency, hidden ones at a throttled rate (P1).
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
        selectedWorktreePath = nil
        appModel.selectSession(sessionID)
        render()
    }

    /// Selection of a worktree row. If it has sessions, show the first one; otherwise remember it as the target for Cmd-T.
    private var selectedWorktreePath: String?

    private func selectWorktree(_ worktreePath: String) {
        selectedWorktreePath = worktreePath
        if let session = appModel.sessions.first(where: { $0.worktreePath == worktreePath }) {
            appModel.selectSession(session.id)
        } else {
            // Do not launch anything. Sessions are opened explicitly via the "add session" row in the tree.
            appModel.selectSession(nil)
        }
        render()
    }

    /// From the tree's "add session" row / Cmd-T, launch the default preset in the given worktree.
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

    // MARK: - Persisting and restoring the session layout

    private let restoreStore = SessionRestoreStore()
    private var didRestoreSessions = false

    func persistSessions() {
        // Debug launches (smoke tests, etc.) must not overwrite the user's real session layout.
        // In the past, a test launch saved a shrunken list mid-restore and destroyed real data.
        guard ProcessInfo.processInfo.environment["VITERM_AUTOSTART_SESSION"] == nil else { return }
        restoreStore.save(
            sessions: appModel.sessions,
            selectedSessionID: appModel.sidebar.selectedSessionID
        )
    }

    /// Restore the previous session layout once the first refresh after launch completes.
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

    // MARK: - Actions (from menus/shortcuts)

    /// Add a session to the currently selected worktree (or the first worktree if none). Cmd-T
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

    /// Cmd-1..9 direct session switching (number in sender.tag).
    @objc func selectShortcutSession(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        if appModel.selectShortcut(item.tag) {
            render()
        } else {
            NSSound.beep()
        }
    }

    /// Cmd-Shift-U jump to the most recent waiting session.
    @objc func jumpToWaiting(_ sender: Any?) {
        if appModel.jumpToLatestWaitingSession() {
            render()
        } else {
            NSSound.beep()
        }
    }

    /// Cmd-B toggle sidebar visibility.
    @objc func toggleSidebar2(_ sender: Any?) {
        sidebar.view.isHidden.toggle()
    }

    // MARK: - Pane splitting (T16)

    /// Cmd-D split right / Cmd-Shift-D split down. Launches a new session in the current worktree and places it in the new pane.
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

    /// Cmd-Shift-W close pane (the session stays alive in the background and can be brought back from the sidebar).
    @objc func closePane(_ sender: Any?) {
        guard splitHost.closeActivePane() != nil else {
            NSSound.beep()
            return
        }
        render()
    }

    /// Cmd-] move focus to the next pane.
    @objc func focusNextPane(_ sender: Any?) {
        splitHost.focusNextPane()
    }

    /// Cmd-K command palette (T12b).
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
            // Select the worktree's first session (or prompt launching one if there is none).
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

    /// Cmd-, settings window (standalone window; categories switch via the toolbar). Changes are saved and applied immediately.
    ///
    /// Window creation/presentation must always happen on a "plain" main runloop turn. When AppKit
    /// windows/layout are built inside a Swift Task, the executor check in @MainActor methods can
    /// read the Task's executor reference and crash with EXC_BAD_ACCESS (observed in practice).
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
        panel.message = L("Select the root directory of a git repository")
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

    /// Repository for the current context (resolved in order: selected session -> selected worktree -> first repository).
    private var currentRepository: Repository? {
        let worktreePath = appModel.sidebar.selectedSession?.session.worktreePath ?? selectedWorktreePath
        if let worktreePath,
           let worktree = appModel.worktrees.first(where: { $0.path == worktreePath }) {
            return appModel.repositories.first { $0.path == worktree.repositoryPath }
        }
        return appModel.repositories.first
    }

    /// Cmd-N new worktree sheet (T10). Targets the repository of the current context.
    @objc func newWorktree(_ sender: Any?) {
        guard let repository = currentRepository else {
            NSSound.beep()
            return
        }
        newWorktree(in: repository)
    }

    /// Open the worktree creation sheet for the given repository (for the sidebar "+" / right-click).
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
            alert.messageText = L("Merge \(worktree.branch) into \(target)")
            alert.informativeText = L("After a successful merge, the worktree and local branch will be deleted.")
            alert.addButton(withTitle: "Merge (--no-ff)")
            alert.addButton(withTitle: "Rebase → ff-only")
            alert.addButton(withTitle: L("Cancel"))
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
                let failedList = failed.map(String.init(describing:)).joined(separator: ", ")
                Self.presentError(
                    NSError(domain: "viterm", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: L("Some steps failed: \(failedList)")
                    ]),
                    in: window
                )
            }
        }
    }

    /// Remove the selected worktree (confirm if dirty, T11).
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
            alert.messageText = L("Delete Worktree")
            alert.informativeText = worktree.isDirty
                ? L("\(worktree.branch) has uncommitted changes. Force delete?")
                : L("This will delete \(worktree.branch) (\(worktree.path)).")
            alert.alertStyle = .warning
            alert.addButton(withTitle: worktree.isDirty ? L("Force Delete") : L("Delete"))
            alert.addButton(withTitle: L("Cancel"))
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

    // MARK: - Session operations (context menu)

    private func renameSession(_ sessionID: AgentSession.ID, currentName: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Rename Session")
        let field = NSTextField(string: currentName)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("Rename"))
        alert.addButton(withTitle: L("Cancel"))
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
        alert.messageText = L("Terminate Session")
        alert.informativeText = L("The running process will be terminated and the scrollback will be discarded.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Terminate"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.cleanUpSession(sessionID)
        }
    }

    // MARK: - NSSplitViewDelegate (sidebar width constraints)

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 180)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, 480)
    }

    static func presentError(_ error: any Error, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = L("Operation Failed")
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
