import AppKit
import ViteaCore

/// サイドバー: リポジトリ → worktree → セッション の3階層ツリー(T7b)。
/// データソースは ViteaCore.SidebarViewModel(値型)。set(viewModel:) で丸ごと差し替える。
@MainActor
final class SidebarViewController: NSViewController {
    var onSelectSession: ((AgentSession.ID) -> Void)?
    /// worktree 行の選択(セッションが無い worktree でも ⌘T のターゲットにするため)。
    var onSelectWorktree: ((String) -> Void)?
    var onAddRepository: (() -> Void)?
    var onNewWorktree: (() -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let emptyState = NSStackView()
    private var viewModel = SidebarViewModel(repositories: [], worktrees: [], sessions: [])

    // NSOutlineView の item は参照同一性で管理されるため、ツリーを class ノードに変換して保持する。
    private final class Node {
        enum Kind {
            case repository(RepositoryNode)
            case worktree(WorktreeNode)
            case session(SessionNode)
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

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        // 空状態(リポジトリ未登録)のガイド。
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

        // 下部アクションバー(UIモックの sb-actions 相当)。
        let actionBar = NSStackView()
        actionBar.orientation = .horizontal
        actionBar.spacing = 6
        actionBar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)
        let addRepoButton = sidebarActionButton("＋ リポジトリ", action: #selector(didTapAddRepository))
        let addWorktreeButton = sidebarActionButton("＋ worktree  ⌘N", action: #selector(didTapNewWorktree))
        actionBar.addArrangedSubview(addRepoButton)
        actionBar.addArrangedSubview(addWorktreeButton)

        let separator = NSBox()
        separator.boxType = .separator

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 0
        container.addArrangedSubview(scrollView)
        container.addArrangedSubview(separator)
        container.addArrangedSubview(actionBar)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        view = container
    }

    private func sidebarActionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.font = .systemFont(ofSize: 11)
        return button
    }

    @objc private func didTapAddRepository() { onAddRepository?() }
    @objc private func didTapNewWorktree() { onNewWorktree?() }

    func set(viewModel: SidebarViewModel) {
        self.viewModel = viewModel
        emptyState.isHidden = !viewModel.repositories.isEmpty
        rootNodes = viewModel.repositories.map { repo in
            Node(kind: .repository(repo), children: repo.worktrees.map { wt in
                Node(kind: .worktree(wt), children: wt.sessions.map { s in
                    Node(kind: .session(s))
                })
            })
        }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        syncSelection()
    }

    /// プログラムからの選択反映中は selectionDidChange をコールバックに再入させない
    /// (render → syncSelection → didChange → render… の無限再帰防止)。
    private var isSyncingSelection = false

    private func syncSelection() {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        guard let selected = viewModel.selectedSessionID else {
            outlineView.deselectAll(nil)
            return
        }
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? Node,
               case let .session(s) = node.kind, s.id == selected {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
                return
            }
        }
    }

    @objc private func didClickRow() {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node else { return }
        switch node.kind {
        case let .session(s):
            onSelectSession?(s.id)
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

        // 行 = [先頭アクセサリ?] タイトル …スペーサ… [右寄せ情報群](UIモック準拠)
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
            stack.addArrangedSubview(label("\(repo.worktrees.count) wt", size: 10, color: .tertiaryLabelColor))

        case let .worktree(wt):
            stack.addArrangedSubview(label(wt.worktree.branch, size: 11, weight: .semibold))
            stack.addArrangedSubview(spacer())
            var git: [String] = []
            if wt.worktree.ahead > 0 { git.append("↑\(wt.worktree.ahead)") }
            if wt.worktree.behind > 0 { git.append("↓\(wt.worktree.behind)") }
            let added = wt.worktree.diffStat.added
            let removed = wt.worktree.diffStat.removed
            if added > 0 { git.append("+\(added)") }
            if removed > 0 { git.append("−\(removed)") }
            if git.isEmpty && !wt.worktree.isDirty { git.append("clean") }
            if wt.worktree.isDirty { git.append("●") }
            stack.addArrangedSubview(label(git.joined(separator: " "), size: 10, color: .tertiaryLabelColor, mono: true))

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
        }

        let cell = NSTableCellView()
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

    /// 状態ドット(busy=オレンジ ● / waiting=青 ◐ / idle=枠のみ ○)。UIモックの .st 相当。
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

    /// waiting 数のバッジ(青いピル)。UIモックの .badge 相当。
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
        case .repository: return false
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        didClickRow()
    }
}
