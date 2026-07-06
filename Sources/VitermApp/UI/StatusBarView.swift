import AppKit
import VitermCore

/// Status bar at the bottom of the window (T9).
/// Left: the current repo · branch · session; right: state summary across repositories.
final class StatusBarView: NSView {
    private let currentLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        for label in [currentLabel, summaryLabel] {
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            currentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            currentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            summaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            currentLabel.trailingAnchor.constraint(lessThanOrEqualTo: summaryLabel.leadingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(sidebar: SidebarViewModel) {
        if let selected = sidebar.selectedSession {
            let repoName = sidebar.repositories
                .first { $0.worktrees.contains { $0.id == selected.session.worktreePath } }?
                .repository.name
            let branch = sidebar.repositories
                .flatMap(\.worktrees)
                .first { $0.id == selected.session.worktreePath }?
                .worktree.branch
            currentLabel.stringValue = [repoName, branch, selected.session.displayName]
                .compactMap { $0 }
                .joined(separator: " · ")
        } else {
            currentLabel.stringValue = "セッション未選択"
        }

        let s = sidebar.stateSummary
        var parts: [String] = []
        if s.busy > 0 { parts.append("● \(s.busy) busy") }
        if s.waitingInput > 0 { parts.append("◐ \(s.waitingInput) waiting") }
        if s.idle > 0 { parts.append("○ \(s.idle) idle") }
        summaryLabel.stringValue = parts.isEmpty ? "" : parts.joined(separator: "   ") + "   ⌘⇧U 未読へ"
    }
}
