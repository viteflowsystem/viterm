import AppKit
import VitermCore

/// Tab bar: shows the selected worktree's sessions as tabs (equivalent to the UI mock's
/// `.tabbar`). Tab = session, 1:1. The data source is `VitermCore.TabBarViewModel` (a
/// value type), replaced wholesale via `set(viewModel:)` (same convention as
/// SidebarViewController).
final class TabBarView: NSView {
    let paneID: PaneID
    var onSelectTab: ((AgentSession.ID) -> Void)?
    /// From the tab's hover close button, or ⌘W.
    var onCloseTab: ((AgentSession.ID) -> Void)?
    /// From the tab's right-click menu "リネーム…" (rename); argument is the current display name.
    var onRenameTab: ((AgentSession.ID, String) -> Void)?
    /// The ＋ button (new session).
    var onAddTab: (() -> Void)?
    /// Commits an in-pane reorder or cross-pane insertion.
    var onDropTab: ((AgentSession.ID, Int) -> Void)?
    /// Fires whenever the native session drag ends, including cancellation.
    var onSessionDragEnded: (() -> Void)?

    static let height: CGFloat = 34

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let bottomSeparator = NSBox()
    private let insertionCaret: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        view.alphaValue = 0
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 2).isActive = true
        view.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return view
    }()

    private struct SessionDrag {
        let sessionID: AgentSession.ID
        let sourceIndex: Int
        weak var item: TabItemView?
        var insertionSlot: Int
    }

    private var activeSessionDrag: SessionDrag?
    private var foreignDrag: (sessionID: AgentSession.ID, insertionSlot: Int)?
    private var pendingViewModel: TabBarViewModel?
    private var latestViewModel: TabBarViewModel?
    private var displayedTabIDs: [AgentSession.ID] = []

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        bottomSeparator.boxType = .separator

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addSubview(bottomSeparator)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Horizontal scrolling on overflow via NSScrollView + NSStackView (equivalent to
        // the UI mock's overflow-x: auto). By not pinning the documentView's trailing, the
        // stack's width can grow beyond the scroll view with its content.
        scrollView.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
        registerForDraggedTypes([SessionDragPasteboard.type])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replace the whole tab row.
    func set(viewModel: TabBarViewModel) {
        latestViewModel = viewModel
        if activeSessionDrag != nil {
            if viewModel.tabs.map(\.id) == displayedTabIDs {
                pendingViewModel = viewModel
                return
            }
            // Composition changed under the drag, so rebuild the frozen index space.
            activeSessionDrag?.item?.alphaValue = 1
            activeSessionDrag?.item?.isSessionDragSource = false
            activeSessionDrag = nil
            pendingViewModel = nil
        }
        rebuild(viewModel: viewModel)
    }

    private func rebuild(viewModel: TabBarViewModel) {
        displayedTabIDs = viewModel.tabs.map(\.id)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tab in viewModel.tabs {
            let item = TabItemView(
                sessionID: tab.id,
                tab: tab,
                isActive: tab.id == viewModel.activeTabID
            )
            item.onSelect = { [weak self] in self?.onSelectTab?(tab.id) }
            item.onClose = { [weak self] in self?.onCloseTab?(tab.id) }
            item.onRename = { [weak self] in self?.onRenameTab?(tab.id, tab.session.displayName) }
            item.onDragEnded = { [weak self] in self?.endSessionDrag() }
            stack.addArrangedSubview(item)
        }
        insertionCaret.alphaValue = 0
        stack.addArrangedSubview(insertionCaret)
        stack.addArrangedSubview(makeAddButton())
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateSessionDrag(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateSessionDrag(sender)
    }

    private func updateSessionDrag(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let sessionID = SessionDragPasteboard.sessionID(from: sender.draggingPasteboard)
        else { return [] }

        if activeSessionDrag == nil {
            guard let sourceIndex = displayedTabIDs.firstIndex(of: sessionID) else {
                return updateForeignSessionDrag(sessionID, sender: sender)
            }
            guard let item = stack.subviews
                .compactMap({ $0 as? TabItemView })
                .first(where: { $0.sessionID == sessionID }) else { return [] }
            item.isHidden = false
            item.alphaValue = 0
            item.isSessionDragSource = true
            activeSessionDrag = SessionDrag(
                sessionID: sessionID,
                sourceIndex: sourceIndex,
                item: item,
                insertionSlot: sourceIndex
            )
        }
        guard let drag = activeSessionDrag, drag.sessionID == sessionID, let item = drag.item
        else { return [] }

        stack.layoutSubtreeIfNeeded()
        let others = stack.arrangedSubviews
            .compactMap { $0 as? TabItemView }
            .filter { $0 !== item }
        let dragX = stack.convert(sender.draggingLocation, from: nil).x
        let slot = TabReorderMath.insertionSlot(
            forDragX: dragX,
            tabMidXs: others.map(\.frame.midX)
        )
        guard slot != drag.insertionSlot else { return .move }
        activeSessionDrag?.insertionSlot = slot

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            stack.removeArrangedSubview(item)
            stack.insertArrangedSubview(item, at: min(slot, stack.arrangedSubviews.count))
            stack.layoutSubtreeIfNeeded()
        }
        return .move
    }

    private func updateForeignSessionDrag(
        _ sessionID: AgentSession.ID,
        sender: any NSDraggingInfo
    ) -> NSDragOperation {
        stack.layoutSubtreeIfNeeded()
        let tabs = stack.arrangedSubviews.compactMap { $0 as? TabItemView }
        let dragX = stack.convert(sender.draggingLocation, from: nil).x
        let slot = TabReorderMath.insertionSlot(
            forDragX: dragX,
            tabMidXs: tabs.map(\.frame.midX)
        )
        foreignDrag = (sessionID, slot)
        insertionCaret.alphaValue = 1
        stack.removeArrangedSubview(insertionCaret)
        stack.insertArrangedSubview(insertionCaret, at: min(slot, stack.arrangedSubviews.count))
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        activeSessionDrag?.item?.alphaValue = 1
        activeSessionDrag?.item?.isSessionDragSource = false
        activeSessionDrag = nil
        foreignDrag = nil
        insertionCaret.alphaValue = 0
        pendingViewModel = nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let drag = activeSessionDrag {
            guard drag.insertionSlot != drag.sourceIndex else { return false }
            onDropTab?(drag.sessionID, drag.insertionSlot)
            return true
        }
        guard let drag = foreignDrag else { return false }
        onDropTab?(drag.sessionID, drag.insertionSlot)
        return true
    }

    private func endSessionDrag() {
        onSessionDragEnded?()
        activeSessionDrag?.item?.alphaValue = 1
        activeSessionDrag?.item?.isSessionDragSource = false
        activeSessionDrag = nil
        foreignDrag = nil
        insertionCaret.alphaValue = 0
        let viewModel = pendingViewModel ?? latestViewModel
        pendingViewModel = nil
        if let viewModel {
            rebuild(viewModel: viewModel)
        }
    }

    /// The ＋ (new session, ⌘T) button. Equivalent to the UI mock's `.tab.add`.
    private func makeAddButton() -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新規セッション")
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .tertiaryLabelColor
        button.toolTip = "新規セッション(⌘T)"
        button.target = self
        button.action = #selector(didTapAdd)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    @objc private func didTapAdd() { onAddTab?() }
}

/// One tab: state dot + name + waitingInput badge + ⌘ number, with a close button on
/// hover (equivalent to the UI mock's `.tab`). The active tab is emphasized with a
/// background + a 2px accent bar at the top edge.
private final class TabItemView: NSView, NSDraggingSource {
    let sessionID: AgentSession.ID
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var isSessionDragSource = false

    private let closeButton: NSButton = {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "タブを閉じる")
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.isHidden = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }()

    private var trackingArea: NSTrackingArea?
    private var mouseDownLocation: NSPoint?
    private var draggingSession: NSDraggingSession?

    init(sessionID: AgentSession.ID, tab: SessionNode, isActive: Bool) {
        self.sessionID = sessionID
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.backgroundColor = isActive
            ? NSColor.controlBackgroundColor.cgColor
            : NSColor.clear.cgColor

        let dot = Self.stateDot(for: tab.session.state)
        let label = NSTextField(labelWithString: tab.session.displayName)
        label.font = .systemFont(ofSize: 11, weight: isActive ? .semibold : .regular)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let contentStack = NSStackView(views: [dot, label])
        contentStack.orientation = .horizontal
        contentStack.spacing = 6
        contentStack.alignment = .centerY

        if tab.session.state == .waitingInput {
            contentStack.addArrangedSubview(Self.badge("1"))
        }
        if let number = tab.shortcutNumber {
            let key = NSTextField(labelWithString: "⌘\(number)")
            key.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
            key.textColor = .tertiaryLabelColor
            contentStack.addArrangedSubview(key)
        }
        contentStack.addArrangedSubview(closeButton)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        if isActive {
            let accent = NSView()
            accent.wantsLayer = true
            accent.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            accent.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accent)
            NSLayoutConstraint.activate([
                accent.topAnchor.constraint(equalTo: topAnchor),
                accent.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                accent.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                accent.heightAnchor.constraint(equalToConstant: 2),
            ])
        }

        closeButton.target = self
        closeButton.action = #selector(didTapClose)

        let contextMenu = NSMenu()
        let rename = NSMenuItem(title: "リネーム…", action: #selector(didSelectRename), keyEquivalent: "")
        rename.target = self
        contextMenu.addItem(rename)
        contextMenu.addItem(.separator())
        let close = NSMenuItem(title: "セッションを終了", action: #selector(didTapClose), keyEquivalent: "")
        close.target = self
        contextMenu.addItem(close)
        menu = contextMenu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }
    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        draggingSession = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingSession == nil, let mouseDownLocation else { return }
        let location = convert(event.locationInWindow, from: nil)
        let distance = hypot(location.x - mouseDownLocation.x, location.y - mouseDownLocation.y)
        guard distance > 4 else { return }

        let pasteboardItem = NSPasteboardItem()
        SessionDragPasteboard.write(sessionID, to: pasteboardItem)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: snapshot())
        draggingSession = beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        // Defer selection so dragging a tab does not replace the pane under its drop.
        if draggingSession == nil {
            onSelect?()
        }
        mouseDownLocation = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isSessionDragSource ? nil : super.hitTest(point)
    }

    private func snapshot() -> NSImage {
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isHidden = false
        draggingSession = nil
        mouseDownLocation = nil
        onDragEnded?()
    }

    @objc private func didTapClose() { onClose?() }
    @objc private func didSelectRename() { onRename?() }

    /// State dot (same spec as SidebarViewController.stateDot).
    private static func stateDot(for state: AgentSession.State) -> NSView {
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

    /// waitingInput badge (same spec as SidebarViewController.badge).
    private static func badge(_ text: String) -> NSView {
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
}
