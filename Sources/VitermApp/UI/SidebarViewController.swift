import AppKit
import VitermCore

/// Sidebar: three-level tree of repository -> worktree -> session (T7b).
/// Data source is VitermCore.SidebarViewModel (a value type), replaced wholesale via set(viewModel:).
@MainActor
final class SidebarViewController: NSViewController {
    var onSelectSession: ((AgentSession.ID) -> Void)?
    /// Selection of a worktree row (so a worktree without sessions can still be the Cmd-T target).
    var onSelectWorktree: ((String) -> Void)?
    var onAddRepository: (() -> Void)?
    var onNewWorktree: (() -> Void)?
    var onNewSession: (() -> Void)?
    var onShowPalette: (() -> Void)?
    /// Click on the "add session" row (argument is the worktree path).
    var onAddSession: ((String) -> Void)?
    // Context menu (right-click) actions.
    var onRenameSession: ((AgentSession.ID, String) -> Void)?
    var onTerminateSession: ((AgentSession.ID) -> Void)?
    var onMergeWorktree: ((String) -> Void)?
    var onRemoveWorktree: ((String) -> Void)?
    /// Repository row "+" / right-click -> new worktree (argument is the repository path).
    var onNewWorktreeInRepository: ((String) -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let emptyState = NSStackView()
    private var viewModel = SidebarViewModel(repositories: [], worktrees: [], sessions: [])
    /// Highlight target when a worktree without any launched session is selected.
    private var selectedWorktreePath: String?

    // NSOutlineView tracks items by reference identity, so the tree is converted to and held as class nodes.
    private final class Node {
        enum Kind {
            case repository(RepositoryNode)
            case worktree(WorktreeNode)
            case session(SessionNode)
            /// "Add session" action row shown for a worktree with no sessions.
            case addSession(worktreePath: String)
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

        // Empty-state guide (no repositories registered).
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        let emptyLabel = NSTextField(labelWithString: "リポジトリが未登録です")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        let emptyButton = NSButton(title: "リポジトリを追加…", target: self, action: #selector(didTapAddRepository))
        emptyButton.bezelStyle = .rounded
        emptyState.addArrangedSubview(emptyLabel)
        emptyState.addArrangedSubview(emptyButton)
        emptyState.isHidden = true

        // Bottom action bar (per the UI mock's sb-actions: faint text rows serving as both hints and buttons).
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

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 0
        // A vertical stack's default alignment is centerX, which would center the footer block as a whole.
        // Stretch all children to full width; left-alignment of rows is handled inside actionBar (per UI mock).
        container.alignment = .leading
        container.addArrangedSubview(scrollView)
        container.addArrangedSubview(separator)
        container.addArrangedSubview(actionBar)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalTo: container.widthAnchor),
            separator.widthAnchor.constraint(equalTo: container.widthAnchor),
            actionBar.widthAnchor.constraint(equalTo: container.widthAnchor),
        ])

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        view = container
    }

    /// One sb-actions row: a text line of hint (monospaced, faint) + label, like "Cmd-N new worktree".
    /// It is a button but has no decoration (per mock).
    private func actionRow(hint: String, title: String, action: Selector) -> NSButton {
        // NSButton centers attributedTitle by default, so force left alignment via a paragraph style.
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

    @objc private func didTapAddRepository() { onAddRepository?() }
    @objc private func didTapNewWorktree() { onNewWorktree?() }
    @objc private func didTapNewSession() { onNewSession?() }
    @objc private func didTapShowPalette() { onShowPalette?() }

    func set(viewModel: SidebarViewModel, selectedWorktreePath: String? = nil) {
        // Do not rebuild the tree for a redraw that only changes the selection (reloadData discards
        // expansion state, and a synchronous reload during a row-click delegate notification easily
        // corrupts NSOutlineView's state). If the tree content (repository/worktree/session
        // structure and states) is identical to last time, just sync the selection highlight and return.
        let treeUnchanged = viewModel.repositories == self.viewModel.repositories
        self.viewModel = viewModel
        self.selectedWorktreePath = selectedWorktreePath
        emptyState.isHidden = !viewModel.repositories.isEmpty
        if treeUnchanged {
            syncSelection()
            return
        }

        // reloadData discards expansion state, so right before it, sample "rows actually collapsed
        // right now" directly from the outline, and after rebuilding re-expand only the rows that
        // were not collapsed. (Tracking via accumulated event notifications drifts from reality
        // depending on how notifications around reloadData are picked up, so take a snapshot every
        // time. Newly appearing rows are expanded by default.)
        let collapsedIDs = snapshotCollapsedIDs()

        rootNodes = viewModel.repositories.map { repo in
            Node(kind: .repository(repo), children: repo.worktrees.map { wt in
                // Always append the "add session" row at the end, regardless of session count.
                let children = wt.sessions.map { Node(kind: .session($0)) }
                    + [Node(kind: .addSession(worktreePath: wt.id))]
                return Node(kind: .worktree(wt), children: children)
            })
        }
        outlineView.reloadData()
        restoreExpansion(collapsedIDs: collapsedIDs)
        syncSelection()
    }

    /// Collect the IDs of collapsed repo/worktree rows from the current tree (rootNodes before rebuild).
    /// On first run (rootNodes empty) this is an empty set = everything expanded by default.
    private func snapshotCollapsedIDs() -> Set<String> {
        var collapsed: Set<String> = []
        for repoNode in rootNodes {
            if let id = nodeID(repoNode), !outlineView.isItemExpanded(repoNode) {
                collapsed.insert(id)
            }
            for wtNode in repoNode.children {
                if let id = nodeID(wtNode), !outlineView.isItemExpanded(wtNode) {
                    collapsed.insert(id)
                }
            }
        }
        return collapsed
    }

    /// After reloadData, re-expand the rows that were not collapsed in the snapshot.
    private func restoreExpansion(collapsedIDs: Set<String>) {
        for repoNode in rootNodes {
            guard let repoID = nodeID(repoNode), !collapsedIDs.contains(repoID) else { continue }
            outlineView.expandItem(repoNode)
            for wtNode in repoNode.children {
                guard let wtID = nodeID(wtNode), !collapsedIDs.contains(wtID) else { continue }
                outlineView.expandItem(wtNode)
            }
        }
    }

    private func nodeID(_ node: Node) -> String? {
        switch node.kind {
        case let .repository(repo): return repo.repository.path
        case let .worktree(wt): return wt.id
        case .session, .addSession: return nil
        }
    }

    /// While programmatically applying selection, do not let selectionDidChange re-enter the callback
    /// (prevents infinite recursion: render -> syncSelection -> didChange -> render...).
    private var isSyncingSelection = false

    private func syncSelection() {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? Node else { continue }
            switch node.kind {
            case let .session(s) where s.id == viewModel.selectedSessionID:
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
                return
            case let .worktree(wt) where viewModel.selectedSessionID == nil && wt.id == selectedWorktreePath:
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
                return
            default:
                continue
            }
        }
        outlineView.deselectAll(nil)
    }

    @objc private func didClickRow() {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node else { return }
        switch node.kind {
        case let .session(s):
            onSelectSession?(s.id)
        case let .worktree(wt):
            onSelectWorktree?(wt.id)
        case let .addSession(worktreePath):
            onAddSession?(worktreePath)
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

        // Row = [leading accessory?] title ...spacer... [right-aligned info group] (per UI mock)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY

        switch node.kind {
        case let .repository(repo):
            let title = label(repo.repository.name, size: 11, weight: .bold)
            stack.addArrangedSubview(title)
            stack.addArrangedSubview(spacer())
            let waiting = repo.waitingSessionCount
            if waiting > 0 {
                stack.addArrangedSubview(badge("\(waiting)"))
            }
            // "+" to add a worktree to this repository (always visible; makes the creation target explicit).
            stack.addArrangedSubview(addWorktreeButton(repositoryPath: repo.repository.path))

        case let .worktree(wt):
            stack.addArrangedSubview(label(wt.worktree.branch, size: 11, weight: .semibold))
            stack.addArrangedSubview(spacer())
            // Git info: up/down arrows (commit delta vs main) + presence of staged (orange dot) / unstaged (red dot) changes.
            // Diff line counts are not shown because "delta vs base or uncommitted delta" is confusing.
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
            // Show a trash button for worktree removal on hover (excluded for the main worktree = the repository itself, which cannot be removed).
            if wt.worktree.path != wt.worktree.repositoryPath {
                let path = wt.id
                return makeCell(stack: stack, hoverTrash: { [weak self] in
                    self?.onRemoveWorktree?(path)
                }, trashTooltip: "worktree を削除")
            }

        case let .session(s):
            stack.addArrangedSubview(stateDot(for: s.session.state))
            stack.addArrangedSubview(label(s.session.displayName, size: 11))
            stack.addArrangedSubview(spacer())
            if s.session.state == .waitingInput {
                stack.addArrangedSubview(badge("1"))
            }
            if let n = s.shortcutNumber {
                stack.addArrangedSubview(label("⌘\(n)", size: 10, color: .tertiaryLabelColor, mono: true))
            }
            // Session rows use a cell that shows a trash (terminate) button on hover.
            let sessionID = s.id
            return makeCell(stack: stack, hoverTrash: { [weak self] in
                self?.onTerminateSession?(sessionID)
            })

        case .addSession:
            stack.addArrangedSubview(label("＋ セッションを追加", size: 11, color: .secondaryLabelColor))
            stack.addArrangedSubview(spacer())
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

    /// State dot (busy = orange filled / waiting = blue filled / idle = outline only). Equivalent to the UI mock's .st.
    private func stateDot(for state: AgentSession.State) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        dot.layer?.cornerRadius = 4
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

    /// The repository row's "+" (new worktree) button.
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

    /// Badge for the waiting count (blue pill). Equivalent to the UI mock's .badge.
    private func badge(_ text: String) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: 9)
        field.textColor = .white
        field.alignment = .center
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.systemBlue.cgColor
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
        case .session, .worktree: return true
        // addSession is not selectable (click action only). If it were selectable, it would fire
        // from both selectionDidChange and the click action, launching the session twice.
        case .repository, .addSession: return false
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

    @objc private func menuRenameSession(_ sender: NSMenuItem) {
        guard let node = clickedNode(), case let .session(s) = node.kind else { return }
        onRenameSession?(s.id, s.session.displayName)
    }

    @objc private func menuTerminateSession(_ sender: NSMenuItem) {
        guard let node = clickedNode(), case let .session(s) = node.kind else { return }
        onTerminateSession?(s.id)
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
        // Draw a border above repository rows other than the first (equivalent to the UI mock's .repo-sep).
        if let node = item as? Node, case .repository = node.kind,
           let first = rootNodes.first, first !== node {
            rowView.drawsTopSeparator = true
        }
        return rowView
    }
}

/// Session row cell that shows the trash (terminate session) button only while hovered.
private final class HoverTrashCellView: NSTableCellView {
    var onTrash: (() -> Void)?

    let trashButton: NSButton = {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "セッションを終了")
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "セッションを終了"
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
        case .session:
            menu.addItem(makeItem("リネーム…", #selector(menuRenameSession(_:))))
            menu.addItem(.separator())
            menu.addItem(makeItem("セッションを終了", #selector(menuTerminateSession(_:))))
        case .worktree:
            menu.addItem(makeItem("セッションを追加", #selector(menuAddSession(_:))))
            menu.addItem(makeItem("Finder で表示", #selector(menuRevealWorktree(_:))))
            menu.addItem(.separator())
            menu.addItem(makeItem("デフォルトブランチにマージ…", #selector(menuMergeWorktree(_:))))
            menu.addItem(makeItem("worktree を削除…", #selector(menuRemoveWorktree(_:))))
        case .repository:
            menu.addItem(makeItem("新規 worktree…", #selector(menuNewWorktree(_:))))
        case .addSession:
            break
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

/// Selected-row highlight (equivalent to the UI mock's .sess.active: background + 2px accent bar at the left edge)
/// and top border for repository separators (equivalent to .repo-sep).
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
