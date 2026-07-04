import AppKit
import ViteaCore

/// サイドバー: リポジトリ → worktree → セッション の3階層ツリー(T7b)。
/// データソースは ViteaCore.SidebarViewModel(値型)。set(viewModel:) で丸ごと差し替える。
@MainActor
final class SidebarViewController: NSViewController {
    var onSelectSession: ((AgentSession.ID) -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
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
        view = scrollView
    }

    func set(viewModel: SidebarViewModel) {
        self.viewModel = viewModel
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

    private func syncSelection() {
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
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node,
              case let .session(s) = node.kind else { return }
        onSelectSession?(s.id)
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
        let cell = NSTableCellView()
        let text: NSTextField

        switch node.kind {
        case let .repository(repo):
            var title = repo.repository.name
            let waiting = repo.waitingSessionCount
            if waiting > 0 { title += "  ●\(waiting)" }
            text = NSTextField(labelWithString: title)
            text.font = .boldSystemFont(ofSize: NSFont.systemFontSize(for: .small))

        case let .worktree(wt):
            var parts = [wt.worktree.branch]
            let ahead = wt.worktree.ahead, behind = wt.worktree.behind
            if ahead > 0 { parts.append("↑\(ahead)") }
            if behind > 0 { parts.append("↓\(behind)") }
            if wt.worktree.isDirty { parts.append("●") }
            text = NSTextField(labelWithString: parts.joined(separator: " "))
            text.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))

        case let .session(s):
            let dot: String
            switch s.session.state {
            case .busy: dot = "●"
            case .waitingInput: dot = "◐"
            case .idle: dot = "○"
            }
            var title = "\(dot) \(s.session.displayName)"
            if let n = s.shortcutNumber { title += "   ⌘\(n)" }
            text = NSTextField(labelWithString: title)
            text.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            switch s.session.state {
            case .busy: text.textColor = .systemOrange
            case .waitingInput: text.textColor = .systemBlue
            case .idle: text.textColor = .labelColor
            }
        }

        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        if case .session = node.kind { return true }
        return false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        didClickRow()
    }
}
