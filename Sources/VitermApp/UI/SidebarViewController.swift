import AppKit
import VitermCore

/// Sidebar: a two-level tree of repository → worktree. Sessions appear on the tab bar
/// (`TabBarView`) instead of the sidebar; each worktree row rolls up the state of its
/// sessions. The data source is VitermCore.SidebarViewModel (a value type), replaced
/// wholesale via set(viewModel:).
@MainActor
final class SidebarViewController: NSViewController {
    /// Selection of a worktree row (selection is keyed on the worktree).
    var onSelectWorktree: ((String) -> Void)?
    var onAddRepository: (() -> Void)?
    var onNewWorktree: (() -> Void)?
    var onNewSession: (() -> Void)?
    var onShowPalette: (() -> Void)?
    /// The worktree right-click menu's "セッションを追加" (add session); argument is the worktree path.
    var onAddSession: ((String) -> Void)?
    // Context menu (right-click) actions.
    var onMergeWorktree: ((String) -> Void)?
    var onRemoveWorktree: ((String) -> Void)?
    /// The repository row's "＋" / right-click → new worktree; argument is the repository path.
    var onNewWorktreeInRepository: ((String) -> Void)?
    /// Fired as the filter field's text changes (continuous). Argument is the new filter text.
    var onFilterChange: ((String) -> Void)?
    /// The header segmented control switched the body mode (tree / state lanes).
    var onDisplayModeChange: ((SidebarDisplayMode) -> Void)?
    /// A state-lane card was clicked; argument is the session ID.
    var onSelectSession: ((AgentSession.ID) -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let stateListView = SidebarStateListView()
    private let modeControl = NSSegmentedControl()
    private let emptyState = NSStackView()
    private let emptyStateLabel = NSTextField(labelWithString: "リポジトリが未登録です")
    private var emptyStateButton: NSButton?
    private let searchField = NSSearchField()
    private var viewModel = SidebarViewModel(repositories: [], worktrees: [], sessions: [])

    // NSOutlineView manages items by reference identity, so the tree is converted into class nodes and retained.
    private final class Node {
        enum Kind {
            case repository(RepositoryNode)
            case worktree(WorktreeNode)
        }
        let kind: Kind
        var children: [Node]
        init(kind: Kind, children: [Node] = []) {
            self.kind = kind
            self.children = children
        }
    }

    private var rootNodes: [Node] = []

    override func loadView() {
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        let column = NSTableColumn(identifier: .init("main"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.target = self
        outlineView.action = #selector(didClickRow)
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        // Filter field (design: docs/design/sidebar-state-view.md §3.1). "/" focuses it
        // while the sidebar has focus; Esc clears it. It compresses first when the
        // sidebar gets narrow.
        searchField.placeholderString = "絞り込み"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        // Tree ⇄ state-lane toggle. The search field compresses first when the sidebar
        // narrows; the segmented control keeps its fixed size.
        modeControl.segmentCount = 2
        modeControl.setImage(
            NSImage(systemSymbolName: "list.bullet.indent", accessibilityDescription: "ツリー表示"),
            forSegment: 0
        )
        modeControl.setImage(
            NSImage(systemSymbolName: "circle.grid.2x1", accessibilityDescription: "状態別表示"),
            forSegment: 1
        )
        modeControl.setToolTip("ツリー表示", forSegment: 0)
        modeControl.setToolTip("状態別表示 (⌘B)", forSegment: 1)
        modeControl.controlSize = .small
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(didSwitchDisplayMode)
        modeControl.setContentHuggingPriority(.required, for: .horizontal)
        // Compressible (just above the search field's priority 1): if the sidebar pane
        // ever passes through a zero-width layout, a required fixed width would make the
        // header stack's internal required constraints unsatisfiable, and Auto Layout
        // breaks such conflicts by *permanently* dropping a constraint.
        modeControl.setContentCompressionResistancePriority(.init(2), for: .horizontal)

        let header = NSStackView(views: [searchField, modeControl])
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 6, right: 10)

        // Empty-state guide (no repositories registered / no filter match).
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.font = .systemFont(ofSize: 12)
        let emptyButton = NSButton(title: "リポジトリを追加…", target: self, action: #selector(didTapAddRepository))
        emptyButton.bezelStyle = .rounded
        emptyStateButton = emptyButton
        emptyState.addArrangedSubview(emptyStateLabel)
        emptyState.addArrangedSubview(emptyButton)
        emptyState.isHidden = true

        // Bottom action bar (per the UI mock's sb-actions: faint text rows doubling as hints and buttons).
        let actionBar = NSStackView()
        actionBar.orientation = .vertical
        actionBar.alignment = .leading
        actionBar.spacing = 3
        actionBar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 10, right: 8)
        actionBar.addArrangedSubview(actionRow(hint: "⌘N", title: "新規 worktree", action: #selector(didTapNewWorktree)))
        actionBar.addArrangedSubview(actionRow(hint: "⌘T", title: "新規セッション", action: #selector(didTapNewSession)))
        actionBar.addArrangedSubview(actionRow(hint: "⌘K", title: "コマンドパレット", action: #selector(didTapShowPalette)))
        actionBar.addArrangedSubview(actionRow(hint: "＋", title: "リポジトリを追加", action: #selector(didTapAddRepository)))

        let separator = NSBox()
        separator.boxType = .separator

        let container = SlashKeyStackView()
        // "/" anywhere in the sidebar (e.g. while the outline view has focus) jumps to the
        // filter field. Handled in keyDown so it only fires when the key actually reaches
        // the sidebar's responder chain — typing "/" inside the field itself is unaffected.
        container.onSlashKey = { [weak self] in
            guard let self else { return false }
            return self.view.window?.makeFirstResponder(self.searchField) ?? false
        }
        container.orientation = .vertical
        container.spacing = 0
        // A vertical stack's default alignment is centerX, which would center the whole
        // footer block. Stretch all children to full width; left-aligning the rows happens
        // inside actionBar (per the UI mock).
        container.alignment = .leading
        container.addArrangedSubview(header)
        container.addArrangedSubview(scrollView)
        // The state-lane body is an exclusive sibling of the tree's scroll view;
        // the mode toggle flips isHidden between the two.
        stateListView.isHidden = true
        stateListView.onSelectSession = { [weak self] sessionID in
            self?.onSelectSession?(sessionID)
        }
        container.addArrangedSubview(stateListView)
        container.addArrangedSubview(separator)
        container.addArrangedSubview(actionBar)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // Full-width constraints run at 999, not required: if the pane ever passes
        // through a zero-width layout, a required constraint would conflict with fixed-
        // size content and Auto Layout would permanently drop an arbitrary constraint.
        // At 999 the constraint is merely unsatisfied and recovers on its own.
        let fullWidthConstraints = [
            header.widthAnchor.constraint(equalTo: container.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: container.widthAnchor),
            stateListView.widthAnchor.constraint(equalTo: container.widthAnchor),
            separator.widthAnchor.constraint(equalTo: container.widthAnchor),
            actionBar.widthAnchor.constraint(equalTo: container.widthAnchor),
        ]
        for constraint in fullWidthConstraints {
            constraint.priority = NSLayoutConstraint.Priority(999)
        }
        NSLayoutConstraint.activate(fullWidthConstraints)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        view = container
    }

    /// One sb-actions row: a text line of hint (monospaced, faint) + label, like
    /// "⌘N 新規 worktree". A button, but undecorated (per the mock).
    private func actionRow(hint: String, title: String, action: Selector) -> NSButton {
        // NSButton centers attributedTitle by default, so left alignment is made explicit with a paragraph style.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: hint.padding(toLength: max(hint.count, 2), withPad: " ", startingAt: 0), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph,
        ]))
        attributed.append(NSAttributedString(string: "  " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]))
        let button = NSButton(title: "", target: self, action: action)
        button.attributedTitle = attributed
        button.isBordered = false
        button.alignment = .left
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    @objc private func didSwitchDisplayMode() {
        onDisplayModeChange?(modeControl.selectedSegment == 1 ? .state : .tree)
    }

    @objc private func didTapAddRepository() { onAddRepository?() }
    @objc private func didTapNewWorktree() { onNewWorktree?() }
    @objc private func didTapNewSession() { onNewSession?() }
    @objc private func didTapShowPalette() { onShowPalette?() }

    func set(viewModel: SidebarViewModel) {
        // Write the model's filter text back into the field, but never clobber live
        // editing: skip when the values already match, and skip while the field is
        // composing text with an IME (marked text) — this method also runs on the
        // periodic auto-refresh, which must not destroy in-progress Japanese input.
        let isComposing = (searchField.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if searchField.stringValue != viewModel.filterText, !isComposing {
            searchField.stringValue = viewModel.filterText
        }

        // Don't rebuild the tree for a selection-only redraw (reloadData discards expansion
        // state, and a synchronous reload during a row-click delegate notification easily
        // corrupts NSOutlineView's state). If the visible tree contents (filtered
        // repository/worktree composition and state) are identical to last time, just sync
        // the selection highlight and return. The gate and the rootNodes mapping below must
        // use the same (filtered) tree — comparing one and rendering the other breaks
        // change detection.
        let filtered = viewModel.filteredRepositories
        let treeUnchanged = filtered == self.viewModel.filteredRepositories
        self.viewModel = viewModel

        // Body mode: flip between the tree and the state lanes; keep the segment in sync.
        let isStateMode = viewModel.displayMode == .state
        scrollView.isHidden = isStateMode
        stateListView.isHidden = !isStateMode
        modeControl.selectedSegment = isStateMode ? 1 : 0
        stateListView.set(lanes: viewModel.stateLanes, selectedSessionID: viewModel.selectedSessionID)

        updateEmptyState(filtered: filtered)
        if treeUnchanged {
            syncSelection()
            return
        }

        // reloadData discards expansion state, so sample "the rows actually collapsed right
        // now" directly from the outline beforehand, and after the rebuild re-expand only
        // the rows that weren't collapsed. (Tracking via accumulated event notifications
        // drifts from reality depending on how notifications around reloadData are picked
        // up, so take a snapshot every time. Newly appearing rows default to expanded.)
        let collapsedIDs = snapshotCollapsedIDs()

        rootNodes = filtered.map { repo in
            Node(kind: .repository(repo), children: repo.worktrees.map { wt in
                Node(kind: .worktree(wt))
            })
        }
        outlineView.reloadData()
        restoreExpansion(collapsedIDs: collapsedIDs)
        syncSelection()
    }

    /// Empty state doubles as "no repositories registered" (with the add button) and
    /// "filter matched nothing" (message only).
    private func updateEmptyState(filtered: [RepositoryNode]) {
        // The lane view draws its own placeholder; the overlay is anchored to the tree's
        // (hidden) scroll view and must not float over the lanes.
        if viewModel.displayMode == .state {
            emptyState.isHidden = true
            return
        }
        if viewModel.repositories.isEmpty {
            emptyStateLabel.stringValue = "リポジトリが未登録です"
            emptyStateButton?.isHidden = false
            emptyState.isHidden = false
        } else if filtered.isEmpty {
            emptyStateLabel.stringValue = "該当なし"
            emptyStateButton?.isHidden = true
            emptyState.isHidden = false
        } else {
            emptyState.isHidden = true
        }
    }

    /// Collect the IDs of collapsed repository rows from the current tree (rootNodes before
    /// the rebuild). On first run (rootNodes empty) this is the empty set = all expanded by default.
    private func snapshotCollapsedIDs() -> Set<String> {
        var collapsed: Set<String> = []
        for repoNode in rootNodes {
            if let id = nodeID(repoNode), !outlineView.isItemExpanded(repoNode) {
                collapsed.insert(id)
            }
        }
        return collapsed
    }

    /// After reloadData, re-expand the repository rows that weren't collapsed in the snapshot.
    private func restoreExpansion(collapsedIDs: Set<String>) {
        for repoNode in rootNodes {
            guard let repoID = nodeID(repoNode), !collapsedIDs.contains(repoID) else { continue }
            outlineView.expandItem(repoNode)
        }
    }

    private func nodeID(_ node: Node) -> String? {
        switch node.kind {
        case let .repository(repo): return repo.repository.path
        case let .worktree(wt): return wt.id
        }
    }

    /// While programmatically applying selection, don't let selectionDidChange re-enter the
    /// callback (prevents infinite recursion: render → syncSelection → didChange → render…).
    private var isSyncingSelection = false

    private func syncSelection() {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? Node else { continue }
            if case let .worktree(wt) = node.kind, wt.id == viewModel.selectedWorktreePath {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
                return
            }
        }
        outlineView.deselectAll(nil)
    }

    @objc private func didClickRow() {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node else { return }
        switch node.kind {
        case let .worktree(wt):
            onSelectWorktree?(wt.id)
        case .repository:
            break
        }
    }
}

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return rootNodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return rootNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return !node.children.isEmpty
    }
}

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }

        // Row = [leading accessory?] title …spacer… [right-aligned info] (per the UI mock)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY

        switch node.kind {
        case let .repository(repo):
            let title = label(repo.repository.name, size: 11, weight: .bold)
            stack.addArrangedSubview(title)
            stack.addArrangedSubview(spacer())
            let summary = repo.stateSummary
            if summary.waitingInput > 0 {
                stack.addArrangedSubview(badge("\(summary.waitingInput)"))
            }
            // While collapsed, the worktree rows' state dots are invisible, so also roll
            // up the busy count (waiting stays always-on as the higher-priority signal).
            if summary.busy > 0, !outlineView.isItemExpanded(node) {
                stack.addArrangedSubview(badge("\(summary.busy)", color: .systemOrange))
            }
            // The "＋" to add a worktree to this repository (always shown; makes the creation target explicit).
            stack.addArrangedSubview(addWorktreeButton(repositoryPath: repo.repository.path))

        case let .worktree(wt):
            stack.addArrangedSubview(label(wt.worktree.branch, size: 11, weight: .semibold))
            // Roll up the state dots of the sessions underneath (one dot per session, in
            // display order). With session rows gone after the tab redesign, this is the
            // only place giving an overview of "what's happening in which worktree" (a hard
            // requirement).
            if !wt.sessions.isEmpty {
                let dotsStack = NSStackView(views: wt.sessions.map { stateDot(for: $0.session.state, size: 7) })
                dotsStack.orientation = .horizontal
                dotsStack.spacing = 4
                stack.addArrangedSubview(dotsStack)
            }
            let waiting = wt.waitingSessionCount
            if waiting > 0 {
                stack.addArrangedSubview(badge("\(waiting)"))
            }
            stack.addArrangedSubview(spacer())
            // Git info: ↑↓ (commit diff vs main) + presence of staged (orange ●) / unstaged
            // (red ●) changes. Diff line counts are not shown — "diff vs base or uncommitted
            // diff?" is too easy to confuse.
            var git: [(String, NSColor, String?)] = []
            if wt.worktree.ahead > 0 { git.append(("↑\(wt.worktree.ahead)", .secondaryLabelColor, nil)) }
            if wt.worktree.behind > 0 { git.append(("↓\(wt.worktree.behind)", .secondaryLabelColor, nil)) }
            if wt.worktree.hasStagedChanges { git.append(("●", .systemOrange, "ステージ済みの変更あり")) }
            if wt.worktree.hasUnstagedChanges { git.append(("●", .systemRed, "未ステージの変更あり")) }
            if git.isEmpty { git.append(("clean", .tertiaryLabelColor, nil)) }
            let gitStack = NSStackView()
            gitStack.orientation = .horizontal
            gitStack.spacing = 4
            for (text, color, tooltip) in git {
                let item = label(text, size: 10, color: color, mono: true)
                item.toolTip = tooltip
                gitStack.addArrangedSubview(item)
            }
            stack.addArrangedSubview(gitStack)
            // Show the worktree-removal trash can on hover (excluded for the main worktree = the repository itself, which can't be removed).
            if wt.worktree.path != wt.worktree.repositoryPath {
                let path = wt.id
                return makeCell(stack: stack, hoverTrash: { [weak self] in
                    self?.onRemoveWorktree?(path)
                }, trashTooltip: "worktree を削除")
            }
        }

        return makeCell(stack: stack, hoverTrash: nil)
    }

    /// Wrap the row's stack in a cell. Passing `hoverTrash` shows a trash button on hover.
    private func makeCell(
        stack: NSStackView,
        hoverTrash: (() -> Void)?,
        trashTooltip: String = "セッションを終了"
    ) -> NSTableCellView {
        let cell: NSTableCellView
        if let hoverTrash {
            let hoverCell = HoverTrashCellView()
            hoverCell.onTrash = hoverTrash
            hoverCell.trashButton.toolTip = trashTooltip
            stack.addArrangedSubview(hoverCell.trashButton)
            cell = hoverCell
        } else {
            cell = NSTableCellView()
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Cell parts

    private func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor,
        mono: Bool = false
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono
            ? .monospacedSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    /// State dot (busy = orange ● / waiting = blue ◐ / idle = outline-only ○). Equivalent
    /// to the UI mock's .st. The worktree row's roll-up display uses the slightly smaller
    /// `size: 7` (the mock's `.st.sm`).
    private func stateDot(for state: AgentSession.State, size: CGFloat = 8) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: size),
            dot.heightAnchor.constraint(equalToConstant: size),
        ])
        dot.layer?.cornerRadius = size / 2
        switch state {
        case .busy:
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        case .waitingInput:
            dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        case .idle:
            dot.layer?.backgroundColor = NSColor.clear.cgColor
            dot.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
            dot.layer?.borderWidth = 1.5
        }
        return dot
    }

    /// The repository row's "＋" (new worktree) button.
    private func addWorktreeButton(repositoryPath: String) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新規 worktree")
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "このリポジトリに worktree を追加"
        button.identifier = NSUserInterfaceItemIdentifier(repositoryPath)
        button.target = self
        button.action = #selector(didTapAddWorktree(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    @objc private func didTapAddWorktree(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onNewWorktreeInRepository?(path)
    }

    /// Count badge pill (blue = waiting, orange = busy). Equivalent to the UI mock's .badge.
    private func badge(_ text: String, color: NSColor = .systemBlue) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: 9)
        field.textColor = .white
        field.alignment = .center
        field.wantsLayer = true
        field.layer?.backgroundColor = color.cgColor
        field.layer?.cornerRadius = 7
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
            field.heightAnchor.constraint(equalToConstant: 14),
        ])
        return field
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        switch node.kind {
        case .worktree: return true
        case .repository: return false
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        didClickRow()
    }


    // MARK: - Context menu

    private func clickedNode() -> Node? {
        let row = outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? Node
    }

    @objc private func menuAddSession(_ sender: NSMenuItem) {
        guard let node = clickedNode(), case let .worktree(wt) = node.kind else { return }
        onAddSession?(wt.id)
    }

    @objc private func menuMergeWorktree(_ sender: NSMenuItem) {
        guard let node = clickedNode(), case let .worktree(wt) = node.kind else { return }
        onMergeWorktree?(wt.id)
    }

    @objc private func menuRemoveWorktree(_ sender: NSMenuItem) {
        guard let node = clickedNode(), case let .worktree(wt) = node.kind else { return }
        onRemoveWorktree?(wt.id)
    }

    @objc private func menuRevealWorktree(_ sender: NSMenuItem) {
        guard let node = clickedNode(), case let .worktree(wt) = node.kind else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wt.id)])
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = AccentBarRowView()
        // Draw a border above every repository row but the first (equivalent to the UI mock's .repo-sep).
        if let node = item as? Node, case .repository = node.kind,
           let first = rootNodes.first, first !== node {
            rowView.drawsTopSeparator = true
        }
        return rowView
    }

    // The repository row's busy badge is collapsed-only, so re-render the row when its
    // expansion state flips (the cell is not rebuilt automatically).
    func outlineViewItemDidExpand(_ notification: Notification) {
        reloadBadgeRow(from: notification)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        reloadBadgeRow(from: notification)
    }

    private func reloadBadgeRow(from notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? Node else { return }
        outlineView.reloadItem(node, reloadChildren: false)
    }
}

extension SidebarViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        onFilterChange?(searchField.stringValue)
    }

    /// Esc in the filter field: clear it and hand focus back to the tree.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        searchField.stringValue = ""
        onFilterChange?("")
        view.window?.makeFirstResponder(outlineView)
        return true
    }
}

/// Sidebar container that turns a bare "/" key press (reaching the sidebar's responder
/// chain, e.g. while the outline view has focus) into "focus the filter field". Key events
/// consumed by a focused text field never get here, so typing "/" into the filter itself
/// (branch names like feature/foo) is unaffected.
private final class SlashKeyStackView: NSStackView {
    var onSlashKey: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "/",
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           onSlashKey?() == true {
            return
        }
        super.keyDown(with: event)
    }
}

/// Row cell that shows a trash button only on hover (used for worktree removal).
private final class HoverTrashCellView: NSTableCellView {
    var onTrash: (() -> Void)?

    let trashButton: NSButton = {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "削除")
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.isHidden = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }()

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        trashButton.target = self
        trashButton.action = #selector(didTapTrash)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func didTapTrash() {
        onTrash?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        trashButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        trashButton.isHidden = true
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode() else { return }
        switch node.kind {
        case .worktree:
            menu.addItem(makeItem("セッションを追加", #selector(menuAddSession(_:))))
            menu.addItem(makeItem("Finder で表示", #selector(menuRevealWorktree(_:))))
            menu.addItem(.separator())
            menu.addItem(makeItem("デフォルトブランチにマージ…", #selector(menuMergeWorktree(_:))))
            menu.addItem(makeItem("worktree を削除…", #selector(menuRemoveWorktree(_:))))
        case .repository:
            menu.addItem(makeItem("新規 worktree…", #selector(menuNewWorktree(_:))))
        }
    }

    @objc private func menuNewWorktree(_ sender: NSMenuItem) {
        guard let node = clickedNode(), case let .repository(repo) = node.kind else { return }
        onNewWorktreeInRepository?(repo.repository.path)
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}

/// Selected-row highlight (equivalent to the UI mock's .sess.active: background + a 2px
/// accent bar at the left edge) and the repository-separator top border (equivalent to .repo-sep).
private final class AccentBarRowView: NSTableRowView {
    var drawsTopSeparator = false

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if drawsTopSeparator {
            NSColor.separatorColor.setFill()
            NSRect(x: 8, y: 0, width: bounds.width - 16, height: 1).fill()
        }
    }
}
