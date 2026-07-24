import AppKit
import VitermCore

/// Renders a pane-owned layout without taking ownership of terminal surfaces.
@MainActor
final class SplitHostView: NSView {
    var onRequestFocusPane: ((PaneID) -> Void)?
    var onDropTab: ((AgentSession.ID, PaneDropTarget) -> Void)?
    var onDividerMoved: ((SplitID, Double) -> Void)?
    var onSelectTab: ((AgentSession.ID) -> Void)?
    var onCloseTab: ((AgentSession.ID) -> Void)?
    var onRenameTab: ((AgentSession.ID, String) -> Void)?
    var onAddTab: ((PaneID) -> Void)?

    static let accentColor = NSColor(name: nil) { appearance in
        let dark = NSColor(red: 0x56 / 255, green: 0xc2 / 255, blue: 0xb6 / 255, alpha: 1)
        let light = NSColor(red: 0x17 / 255, green: 0x8f / 255, blue: 0x83 / 255, alpha: 1)
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    private var paneViews: [PaneID: PaneView] = [:]
    private var splitViews: [SplitID: NSSplitView] = [:]
    private var splitIDsByView: [ObjectIdentifier: SplitID] = [:]
    private var lastTopology: PaneTopology?
    private var rootView: NSView?
    private var lastFocusedPaneID: PaneID?
    private weak var lastFocusedSurface: NSView?
    private var isApplyingDividerPosition = false
    private var pendingDividerFractions: [ObjectIdentifier: Double] = [:]
    private nonisolated(unsafe) var mouseMonitor: Any?

    private let emptyView: NSView = {
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        installMouseMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
    }

    override func layout() {
        super.layout()
        for (identifier, fraction) in Array(pendingDividerFractions) {
            guard let splitView = splitViews.values.first(where: {
                ObjectIdentifier($0) == identifier
            }) else {
                pendingDividerFractions[identifier] = nil
                continue
            }
            let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            guard total > 0 else { continue }
            applyDivider(fraction, in: splitView)
            pendingDividerFractions[identifier] = nil
        }
    }

    func render(
        _ layout: PaneLayout,
        sessions: [AgentSession.ID: AgentSession],
        surface: (AgentSession.ID) -> NSView?
    ) {
        if lastTopology != layout.topology {
            rebuild(layout, sessions: sessions, surface: surface)
        } else {
            patch(layout, sessions: sessions, surface: surface)
        }
        updateFirstResponder(for: layout)
    }

    private func rebuild(
        _ layout: PaneLayout,
        sessions: [AgentSession.ID: AgentSession],
        surface: (AgentSession.ID) -> NSView?
    ) {
        paneViews.values.forEach { $0.releaseSurface() }
        rootView?.removeFromSuperview()
        paneViews.removeAll()
        splitViews.removeAll()
        splitIDsByView.removeAll()

        let multiPane = layout.paneIDs.count > 1
        let renderedRoot = layout.root.map {
            build(
                $0,
                focusedPaneID: layout.focusedPaneID,
                multiPane: multiPane,
                sessions: sessions,
                surface: surface
            )
        } ?? emptyView
        embedRoot(renderedRoot)
        lastTopology = layout.topology
        layoutSubtreeIfNeeded()
        patch(layout, sessions: sessions, surface: surface)
    }

    private func build(
        _ node: PaneLayoutNode,
        focusedPaneID: PaneID?,
        multiPane: Bool,
        sessions: [AgentSession.ID: AgentSession],
        surface: (AgentSession.ID) -> NSView?
    ) -> NSView {
        switch node {
        case .pane(let paneID, let tabs):
            let pane = PaneView(paneID: paneID)
            wire(pane)
            paneViews[paneID] = pane
            pane.patch(
                tabs: tabs,
                sessions: sessions,
                isFocused: paneID == focusedPaneID,
                multiPane: multiPane,
                surface: surface
            )
            return pane
        case .split(let split):
            let splitView = NSSplitView()
            splitView.isVertical = split.orientation == .sideBySide
            splitView.dividerStyle = .thin
            splitView.delegate = self
            splitViews[split.id] = splitView
            splitIDsByView[ObjectIdentifier(splitView)] = split.id
            splitView.addArrangedSubview(build(
                split.first,
                focusedPaneID: focusedPaneID,
                multiPane: multiPane,
                sessions: sessions,
                surface: surface
            ))
            splitView.addArrangedSubview(build(
                split.second,
                focusedPaneID: focusedPaneID,
                multiPane: multiPane,
                sessions: sessions,
                surface: surface
            ))
            return splitView
        }
    }

    private func patch(
        _ layout: PaneLayout,
        sessions: [AgentSession.ID: AgentSession],
        surface: (AgentSession.ID) -> NSView?
    ) {
        let multiPane = layout.paneIDs.count > 1
        for paneID in layout.paneIDs {
            guard let pane = paneViews[paneID], let tabs = layout.tabs(of: paneID) else { continue }
            pane.patch(
                tabs: tabs,
                sessions: sessions,
                isFocused: paneID == layout.focusedPaneID,
                multiPane: multiPane,
                surface: surface
            )
        }
        applyDividerPositions(from: layout)
    }

    private func wire(_ pane: PaneView) {
        let paneID = pane.paneID
        pane.onDropTab = { [weak self] sessionID, target in self?.onDropTab?(sessionID, target) }
        pane.tabBar.onSelectTab = { [weak self] sessionID in self?.onSelectTab?(sessionID) }
        pane.tabBar.onCloseTab = { [weak self] sessionID in self?.onCloseTab?(sessionID) }
        pane.tabBar.onRenameTab = { [weak self] sessionID, name in self?.onRenameTab?(sessionID, name) }
        pane.tabBar.onAddTab = { [weak self] in self?.onAddTab?(paneID) }
        pane.tabBar.onDropTab = { [weak self] sessionID, index in
            self?.onDropTab?(sessionID, .tabBar(paneID: paneID, insertIndex: index))
        }
    }

    private func updateFirstResponder(for layout: PaneLayout) {
        let focusedPaneID = layout.focusedPaneID
        let focusedSurface = focusedPaneID.flatMap { paneViews[$0]?.activeSurface }
        guard focusedPaneID != lastFocusedPaneID || focusedSurface !== lastFocusedSurface else {
            return
        }
        lastFocusedPaneID = focusedPaneID
        lastFocusedSurface = focusedSurface
        if let focusedSurface {
            window?.makeFirstResponder(focusedSurface)
        }
    }

    private func embedRoot(_ view: NSView) {
        rootView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func applyDividerPositions(from layout: PaneLayout) {
        guard let root = layout.root else { return }
        applyDividerPositions(in: root)
    }

    private func applyDividerPositions(in node: PaneLayoutNode) {
        switch node {
        case .pane:
            return
        case .split(let split):
            if let splitView = splitViews[split.id] {
                setDivider(split.dividerPosition, in: splitView)
            }
            applyDividerPositions(in: split.first)
            applyDividerPositions(in: split.second)
        }
    }

    private func setDivider(_ fraction: Double, in splitView: NSSplitView) {
        layoutSubtreeIfNeeded()
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let identifier = ObjectIdentifier(splitView)
        if total > 0 {
            applyDivider(fraction, in: splitView)
            pendingDividerFractions[identifier] = nil
        } else {
            pendingDividerFractions[identifier] = fraction
            needsLayout = true
        }
    }

    private func applyDivider(_ fraction: Double, in splitView: NSSplitView) {
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard total > 0 else { return }
        let desired = total * CGFloat(fraction)
        let current = splitView.isVertical
            ? splitView.arrangedSubviews.first?.frame.maxX
            : splitView.arrangedSubviews.first?.frame.maxY
        guard let current, abs(current - desired) > 0.5 else { return }
        isApplyingDividerPosition = true
        splitView.setPosition(desired, ofDividerAt: 0)
        isApplyingDividerPosition = false
    }

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleLeftMouseDown(event)
            return event
        }
    }

    private func handleLeftMouseDown(_ event: NSEvent) {
        guard event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = hitTest(point) else { return }
        var candidate: NSView? = hit
        while let view = candidate {
            if let pane = view as? PaneView {
                onRequestFocusPane?(pane.paneID)
                return
            }
            candidate = view.superview
        }
    }
}

extension SplitHostView: NSSplitViewDelegate {
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isApplyingDividerPosition,
              let splitView = notification.object as? NSSplitView,
              pendingDividerFractions[ObjectIdentifier(splitView)] == nil,
              let splitID = splitIDsByView[ObjectIdentifier(splitView)] else { return }
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard total > 0 else { return }
        guard let first = splitView.arrangedSubviews.first else { return }
        let position = splitView.isVertical ? first.frame.maxX : first.frame.maxY
        onDividerMoved?(splitID, Double(position / total))
    }
}

/// A pane leaf containing its own tab bar, active terminal surface, and drop hint.
@MainActor
private final class PaneView: NSView {
    let paneID: PaneID
    let tabBar: TabBarView
    var onDropTab: ((AgentSession.ID, PaneDropTarget) -> Void)?

    private let contentView = NSView()
    private let dropHint = PaneDropHintOverlayView()
    private weak var hostedSurface: NSView?
    private var currentDropZone: PaneDropMath.DropZone?

    init(paneID: PaneID) {
        self.paneID = paneID
        tabBar = TabBarView(paneID: paneID)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        dropHint.translatesAutoresizingMaskIntoConstraints = true
        dropHint.alphaValue = 0
        addSubview(tabBar)
        addSubview(contentView)
        contentView.addSubview(dropHint)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            contentView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes([SessionDragPasteboard.type])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var activeSurface: NSView? { hostedSurface }

    func patch(
        tabs: PaneTabs,
        sessions: [AgentSession.ID: AgentSession],
        isFocused: Bool,
        multiPane: Bool,
        surface: (AgentSession.ID) -> NSView?
    ) {
        tabBar.set(viewModel: TabBarViewModel(paneTabs: tabs, sessions: Array(sessions.values)))
        tabBar.alphaValue = (isFocused || !multiPane) ? 1.0 : 0.55
        let nextSurface = tabs.activeTabID.flatMap(surface)
        guard hostedSurface !== nextSurface else { return }
        hostedSurface?.removeFromSuperview()
        hostedSurface = nextSurface
        guard let nextSurface else { return }
        nextSurface.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nextSurface, positioned: .below, relativeTo: dropHint)
        NSLayoutConstraint.activate([
            nextSurface.topAnchor.constraint(equalTo: contentView.topAnchor),
            nextSurface.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            nextSurface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nextSurface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    func releaseSurface() {
        hostedSurface?.removeFromSuperview()
        hostedSurface = nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDropHint(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDropHint(sender)
    }

    private func updateDropHint(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard SessionDragPasteboard.sessionID(from: sender.draggingPasteboard) != nil else {
            clearDropHint()
            return []
        }
        let point = contentView.convert(sender.draggingLocation, from: nil)
        guard let zone = PaneDropMath.zone(
            for: point,
            in: contentView.bounds,
            current: currentDropZone
        ) else {
            clearDropHint()
            return []
        }
        currentDropZone = zone
        dropHint.frame = switch zone {
        case .center: contentView.bounds
        case .edge(let edge): PaneDropMath.halfRect(for: edge, in: contentView.bounds)
        }
        dropHint.alphaValue = 1
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearDropHint()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { clearDropHint() }
        guard let sessionID = SessionDragPasteboard.sessionID(from: sender.draggingPasteboard) else {
            return false
        }
        let point = contentView.convert(sender.draggingLocation, from: nil)
        guard let zone = PaneDropMath.zone(
            for: point,
            in: contentView.bounds,
            current: currentDropZone
        ) else { return false }
        onDropTab?(sessionID, .paneBody(paneID: paneID, zone: zone))
        return true
    }

    private func clearDropHint() {
        currentDropZone = nil
        dropHint.alphaValue = 0
    }
}

private final class PaneDropHintOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        SplitHostView.accentColor.withAlphaComponent(0.25).setFill()
        bounds.fill()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        SplitHostView.accentColor.setStroke()
        path.stroke()
    }
}
