import AppKit
import VitermCore

/// The sidebar's "state view" body: all sessions flattened into three lanes
/// (waiting-input / busy / idle), answering "which session needs me now" — the tree
/// answers "where do I work". Fed from `SidebarViewModel.stateLanes` (already filtered
/// by the shared filter). Design: docs/design/sidebar-state-view.md §3.3.
@MainActor
final class SidebarStateListView: NSView {
    /// Card click; argument is the session ID. Selection propagation (worktree follows
    /// session) is the model's job (`SidebarViewModel.select(sessionID:)`).
    var onSelectSession: ((AgentSession.ID) -> Void)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var lanes = SidebarStateLanes()
    private var selectedSessionID: AgentSession.ID?
    /// The idle lane is collapsed by default (its contents are not actionable);
    /// session-volatile like the tree's collapse state.
    private var isIdleLaneExpanded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 10, right: 10)

        // NSStackView inside NSScrollView: the document view must be flipped so content
        // grows downward from the top.
        let documentView = FlippedStackContainer()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Re-render only when the lanes or the selection actually changed (mirrors the
    /// tree's reload gate). Lane counts are small, so a full stack rebuild is fine.
    func set(lanes: SidebarStateLanes, selectedSessionID: AgentSession.ID?) {
        guard lanes != self.lanes || selectedSessionID != self.selectedSessionID else { return }
        self.lanes = lanes
        self.selectedSessionID = selectedSessionID
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Empty lanes are omitted entirely; when nothing actionable remains, show a
        // one-line placeholder so the view never looks broken.
        if lanes.waiting.isEmpty, lanes.busy.isEmpty {
            let message = lanes.idle.isEmpty
                ? "セッションがありません"
                : "待機中・作業中のセッションはありません"
            stack.addArrangedSubview(placeholderRow(message))
        }

        addLane(title: "待機中", cards: lanes.waiting, color: .systemBlue, collapsible: false)
        addLane(title: "作業中", cards: lanes.busy, color: .systemOrange, collapsible: false)
        addLane(title: "アイドル", cards: lanes.idle, color: .tertiaryLabelColor, collapsible: true)
    }

    private func addLane(title: String, cards: [StateLaneCard], color: NSColor, collapsible: Bool) {
        guard !cards.isEmpty else { return }

        let header = laneHeader(title: title, count: cards.count, color: color, collapsible: collapsible)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true

        if collapsible, !isIdleLaneExpanded { return }
        for card in cards {
            let row = cardRow(card)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
    }

    /// Lane header: uppercase-style mono label + count. The idle lane's header doubles
    /// as its expand/collapse toggle.
    private func laneHeader(title: String, count: Int, color: NSColor, collapsible: Bool) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = color

        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 8, left: 2, bottom: 2, right: 2)

        if collapsible {
            let chevron = NSTextField(labelWithString: isIdleLaneExpanded ? "▾" : "▸")
            chevron.font = .systemFont(ofSize: 8)
            chevron.textColor = .tertiaryLabelColor
            row.addArrangedSubview(chevron)
        }
        row.addArrangedSubview(label)
        row.addArrangedSubview(countLabel)
        row.addArrangedSubview(NSView()) // spacer

        if collapsible {
            let button = HitButton()
            button.onClick = { [weak self] in
                guard let self else { return }
                self.isIdleLaneExpanded.toggle()
                self.rebuild()
            }
            button.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: row.topAnchor),
                button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            ])
        }
        return row
    }

    /// One session card: state dot + "repo · session" primary, branch secondary.
    private func cardRow(_ card: StateLaneCard) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        dot.layer?.cornerRadius = 3.5
        switch card.state {
        case .busy: dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        case .waitingInput: dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        case .idle:
            dot.layer?.backgroundColor = NSColor.clear.cgColor
            dot.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
            dot.layer?.borderWidth = 1.5
        }

        let title = NSTextField(labelWithString: "\(card.repositoryName) · \(card.sessionName)")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let branch = NSTextField(labelWithString: card.branch)
        branch.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        branch.textColor = .tertiaryLabelColor
        branch.lineBreakMode = .byTruncatingHead

        let content = NSStackView(views: [dot, title, NSView(), branch])
        content.orientation = .horizontal
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        let cardView = CardBackgroundView()
        cardView.isSelected = card.id == selectedSessionID
        cardView.isDimmed = card.state == .idle
        content.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: cardView.topAnchor),
            content.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
        ])

        let sessionID = card.id
        let button = HitButton()
        button.onClick = { [weak self] in self?.onSelectSession?(sessionID) }
        button.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: cardView.topAnchor),
            button.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            button.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
        ])
        return cardView
    }

    private func placeholderRow(_ message: String) -> NSView {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label])
        row.edgeInsets = NSEdgeInsets(top: 12, left: 4, bottom: 4, right: 4)
        return row
    }
}

/// Flipped container so the stacked content is pinned to the scroll view's top.
private final class FlippedStackContainer: NSView {
    override var isFlipped: Bool { true }
}

/// Card chrome: rounded background with selection accent / idle dimming.
/// Colors are applied directly on state change (not via `updateLayer()`, which AppKit
/// only calls when `wantsUpdateLayer` is overridden — same pattern as PalettePanel).
private final class CardBackgroundView: NSView {
    var isSelected = false { didSet { updateColors() } }
    var isDimmed = false { didSet { alphaValue = isDimmed ? 0.6 : 1.0 } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateColors() {
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// Transparent full-area click target (borderless NSButton overlay).
private final class HitButton: NSButton {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        target = self
        action = #selector(didClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func didClick() { onClick?() }
}
