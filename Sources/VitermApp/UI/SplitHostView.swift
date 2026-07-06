import AppKit

/// Component hosting multiple panes (terminal surfaces, etc.) as a binary tree of `NSSplitView`s (T12).
///
/// A self-contained view positioned as the split-capable replacement for `TerminalHostView`'s
/// single display. Each leaf holds exactly one arbitrary `NSView` (in practice a `GhosttySurfaceView`).
/// Like `TerminalHostView`, closing a pane only detaches the content view, never destroys it
/// (following the policy of keeping background sessions alive; what to do with the view returned by
/// `closeActivePane()` is the caller's responsibility).
///
/// The split tree is expressed as `PaneNode` (`.leaf` / `.split`); each node directly holds either
/// the arrangedSubview of its containing `NSSplitView` or a `PaneContainerView`. The focused pane
/// switches via click or `focusNextPane()`, and `PaneContainerView` reflects it visually with an
/// accent-colored border.
final class SplitHostView: NSView {
    /// Called on every focus change (click, `focusNextPane()`, split, close).
    /// The argument is the new active pane's content (`nil` if no panes remain).
    var onActivePaneChanged: ((NSView?) -> Void)?

    /// Accent color for the focused pane's border. In dark mode, the accent value from
    /// docs/ui-mock.html; in light mode, a slightly darkened value to keep contrast, following the same policy as `PalettePanel`.
    static let accentColor = NSColor(name: nil) { appearance in
        let dark = NSColor(red: 0x56 / 255, green: 0xc2 / 255, blue: 0xb6 / 255, alpha: 1)
        let light = NSColor(red: 0x17 / 255, green: 0x8f / 255, blue: 0x83 / 255, alpha: 1)
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    private var root: PaneNode?
    private var activeNode: PaneNode?
    /// Reverse lookup `PaneContainerView` -> `PaneNode` for click-based pane switching.
    private var nodesByContainer: [ObjectIdentifier: PaneNode] = [:]
    // Marked unsafe so it can be released from deinit (nonisolated). Writes happen only in init/deinit
    // (same reason as GhosttySurfaceView.surface).
    private nonisolated(unsafe) var mouseMonitor: Any?

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

    // MARK: - Public API

    /// Reset to a single, unsplit display (equivalent to `TerminalHostView.show`). All existing
    /// panes are detached (content views are not destroyed). Passing `nil` leaves no panes at all.
    func showRoot(_ view: NSView?) {
        detachAll()
        guard let view else {
            setActive(nil, notify: true)
            return
        }
        let node = makeLeafNode(content: view)
        root = node
        embedAsRoot(containerView(for: node))
        setActive(node, notify: true)
    }

    /// Split the focused pane and place `newView` as the new pane.
    /// `vertically: true` adds it to the right (left/right split with a vertical divider), `false`
    /// below (top/bottom split with a horizontal divider). With no focused pane, behaves like `showRoot(newView)`.
    func splitActive(_ newView: NSView, vertically: Bool) {
        guard let target = activeNode ?? firstLeaf(of: root) else {
            showRoot(newView)
            return
        }

        let newLeaf = makeLeafNode(content: newView)
        let splitView = NSSplitView()
        splitView.isVertical = vertically
        splitView.dividerStyle = .thin

        let targetView = containerView(for: target)
        let oldParent = target.parent

        let splitNode = PaneNode(kind: .split(splitView, target, newLeaf))
        splitNode.parent = oldParent
        target.parent = splitNode
        newLeaf.parent = splitNode

        if let oldParent, case .split(let parentSplitView, let childA, let childB) = oldParent.kind {
            let replacingA = (childA === target)
            let insertIndex = parentSplitView.arrangedSubviews.firstIndex(of: targetView)
                ?? parentSplitView.arrangedSubviews.count
            targetView.removeFromSuperview()
            oldParent.kind = .split(parentSplitView, replacingA ? splitNode : childA, replacingA ? childB : splitNode)
            parentSplitView.insertArrangedSubview(
                splitView, at: min(insertIndex, parentSplitView.arrangedSubviews.count)
            )
        } else {
            targetView.removeFromSuperview()
            root = splitNode
            embedAsRoot(splitView)
        }

        splitView.addArrangedSubview(targetView)
        splitView.addArrangedSubview(containerView(for: newLeaf))

        setActive(newLeaf, notify: true)
    }

    /// Close the focused pane and detach and return the view it contained (without destroying it).
    /// Whether the caller ties this to session termination etc. is optional. If no panes remain
    /// after closing, `onActivePaneChanged` is notified with `nil`. With no focused pane, does nothing and returns `nil`.
    @discardableResult
    func closeActivePane() -> NSView? {
        guard let target = activeNode, case .leaf(let container) = target.kind else { return nil }
        let removedView = container.releaseContent()
        nodesByContainer[ObjectIdentifier(container)] = nil
        let targetView = containerView(for: target)

        guard let parent = target.parent, case .split(let parentSplitView, let childA, let childB) = parent.kind else {
            // It was the only pane (root itself was a leaf).
            targetView.removeFromSuperview()
            root = nil
            setActive(nil, notify: true)
            return removedView
        }

        let sibling = (childA === target) ? childB : childA
        let siblingView = containerView(for: sibling)
        let grandparent = parent.parent

        // The insertion index in the grandparent must be recorded before removing the parent (the old NSSplitView).
        var grandparentSplitView: NSSplitView?
        var grandparentInsertIndex: Int?
        if let grandparent, case .split(let gSplitView, _, _) = grandparent.kind {
            grandparentSplitView = gSplitView
            grandparentInsertIndex = gSplitView.arrangedSubviews.firstIndex(of: parentSplitView)
        }

        siblingView.removeFromSuperview()
        targetView.removeFromSuperview()
        parentSplitView.removeFromSuperview()

        sibling.parent = grandparent

        if let grandparent, let gSplitView = grandparentSplitView, case .split(_, let gA, let gB) = grandparent.kind {
            let replacingA = (gA === parent)
            grandparent.kind = .split(gSplitView, replacingA ? sibling : gA, replacingA ? gB : sibling)
            gSplitView.insertArrangedSubview(
                siblingView, at: min(grandparentInsertIndex ?? gSplitView.arrangedSubviews.count,
                                      gSplitView.arrangedSubviews.count)
            )
        } else {
            root = sibling
            embedAsRoot(siblingView)
        }

        setActive(firstLeaf(of: sibling), notify: true)
        return removedView
    }

    /// List of currently hosted content views (depth-first order).
    var hostedViews: [NSView] {
        var leaves: [PaneNode] = []
        collectLeaves(root, into: &leaves)
        return leaves.compactMap { node in
            if case .leaf(let container) = node.kind { return container.content }
            return nil
        }
    }

    /// If a pane whose content is `view` exists, focus it and return true.
    @discardableResult
    func focusPane(containing view: NSView) -> Bool {
        var leaves: [PaneNode] = []
        collectLeaves(root, into: &leaves)
        for node in leaves {
            if case .leaf(let container) = node.kind, container.content === view {
                if node !== activeNode {
                    setActive(node, notify: true)
                }
                return true
            }
        }
        return false
    }

    /// Close the pane whose content is `view`, detach the view and return it (without destroying it).
    /// If no such pane exists, does nothing and returns `nil`. For cleaning up sessions whose process exited.
    @discardableResult
    func closePane(containing view: NSView) -> NSView? {
        var leaves: [PaneNode] = []
        collectLeaves(root, into: &leaves)
        guard let node = leaves.first(where: { node in
            if case .leaf(let container) = node.kind { return container.content === view }
            return false
        }) else { return nil }
        let previousActive = activeNode
        activeNode = node
        let removed = closeActivePane()
        // If the closed pane was not the active one, keep the original active pane if possible.
        if let previousActive, previousActive !== node {
            var remaining: [PaneNode] = []
            collectLeaves(root, into: &remaining)
            if remaining.contains(where: { $0 === previousActive }) {
                setActive(previousActive, notify: true)
            }
        }
        return removed
    }

    /// Replace the focused pane's content with `newView` and return the removed view (without destroying it).
    /// With no panes, equivalent to `showRoot(newView)`.
    @discardableResult
    func replaceActive(with newView: NSView) -> NSView? {
        guard let target = activeNode, case .leaf(let container) = target.kind else {
            showRoot(newView)
            return nil
        }
        let removed = container.releaseContent()
        container.setContent(newView)
        window?.makeFirstResponder(newView)
        onActivePaneChanged?(newView)
        return removed
    }

    /// Move focus to the next pane (cycles in depth-first traversal order of the tree, wrapping from last to first).
    /// Does nothing with one pane or fewer.
    func focusNextPane() {
        var leaves: [PaneNode] = []
        collectLeaves(root, into: &leaves)
        guard leaves.count > 1 else { return }
        let currentIndex = activeNode.flatMap { active in leaves.firstIndex(where: { $0 === active }) } ?? -1
        let next = leaves[(currentIndex + 1 + leaves.count) % leaves.count]
        setActive(next, notify: true)
    }

    // MARK: - Split tree operations

    private func makeLeafNode(content: NSView) -> PaneNode {
        let container = PaneContainerView()
        container.setContent(content)
        let node = PaneNode(kind: .leaf(container))
        nodesByContainer[ObjectIdentifier(container)] = node
        return node
    }

    private func containerView(for node: PaneNode) -> NSView {
        switch node.kind {
        case .leaf(let container): return container
        case .split(let splitView, _, _): return splitView
        }
    }

    private func firstLeaf(of node: PaneNode?) -> PaneNode? {
        guard let node else { return nil }
        switch node.kind {
        case .leaf: return node
        case .split(_, let a, _): return firstLeaf(of: a)
        }
    }

    private func collectLeaves(_ node: PaneNode?, into leaves: inout [PaneNode]) {
        guard let node else { return }
        switch node.kind {
        case .leaf: leaves.append(node)
        case .split(_, let a, let b):
            collectLeaves(a, into: &leaves)
            collectLeaves(b, into: &leaves)
        }
    }

    /// Detach the entire current tree (each leaf's content view is also `removeFromSuperview`ed, but not destroyed).
    private func detachAll() {
        if let root {
            releaseAllContent(root)
            containerView(for: root).removeFromSuperview()
        }
        root = nil
        activeNode = nil
        nodesByContainer.removeAll()
    }

    private func releaseAllContent(_ node: PaneNode) {
        switch node.kind {
        case .leaf(let container):
            _ = container.releaseContent()
        case .split(_, let a, let b):
            releaseAllContent(a)
            releaseAllContent(b)
        }
    }

    private func embedAsRoot(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - Focus management

    private func setActive(_ node: PaneNode?, notify: Bool) {
        if let previous = activeNode, case .leaf(let previousContainer) = previous.kind {
            previousContainer.isActive = false
        }
        activeNode = node

        // Show the focus border only when split, where distinguishing "which pane is active" matters
        // (a permanent border on a single pane would just look like decoration).
        var leaves: [PaneNode] = []
        collectLeaves(root, into: &leaves)
        let showsFocusRing = leaves.count > 1

        var contentView: NSView?
        if let node, case .leaf(let container) = node.kind {
            container.isActive = showsFocusRing
            contentView = container.content
            if let contentView {
                window?.makeFirstResponder(contentView)
            }
        }

        if notify {
            onActivePaneChanged?(contentView)
        }
    }

    // MARK: - Pane switching by click

    /// Make the clicked pane active. To have focus follow clicks without touching the leaf content
    /// (`GhosttySurfaceView` etc.), we don't rely on the window's normal responder chain but use a
    /// local mouse monitor to identify the pane from the click location. The event itself is returned unconsumed.
    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleLeftMouseDown(event)
            return event
        }
    }

    private func handleLeftMouseDown(_ event: NSEvent) {
        guard event.window === window else { return }
        let pointInSelf = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pointInSelf), let hitView = hitTest(pointInSelf) else { return }

        var view: NSView? = hitView
        while let current = view {
            if let container = current as? PaneContainerView,
               let node = nodesByContainer[ObjectIdentifier(container)] {
                if node !== activeNode {
                    setActive(node, notify: true)
                }
                return
            }
            view = current.superview
        }
    }
}

// MARK: - Split tree

/// Node of `SplitHostView`'s split tree. `.leaf` holds one `PaneContainerView`; `.split` holds an
/// `NSSplitView` and its two child nodes. `parent` is used to restructure the tree on close/split.
private final class PaneNode {
    enum Kind {
        case leaf(PaneContainerView)
        case split(NSSplitView, PaneNode, PaneNode)
    }

    var kind: Kind
    weak var parent: PaneNode?

    init(kind: Kind) {
        self.kind = kind
    }
}

// MARK: - Leaf container

/// Container holding one content view as a leaf of the split tree. Depending on `isActive`, draws
/// an accent-colored border via a frontmost overlay (`PaneBorderOverlayView`). Because the content
/// fills the entire bounds, the border must be layered on top by a separate view or it gets hidden
/// behind the content (the container's own background drawing is always composited below its subviews).
private final class PaneContainerView: NSView {
    private(set) var content: NSView?
    private let borderOverlay = PaneBorderOverlayView()

    var isActive: Bool = false {
        didSet {
            guard oldValue != isActive else { return }
            borderOverlay.isActive = isActive
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(borderOverlay)
        NSLayoutConstraint.activate([
            borderOverlay.topAnchor.constraint(equalTo: topAnchor),
            borderOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            borderOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            borderOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lay out the content view to fill the bounds. Any existing content is `removeFromSuperview`ed
    /// (not destroyed).
    func setContent(_ view: NSView) {
        content?.removeFromSuperview()
        content = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: borderOverlay)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// Detach and return the content view (without destroying it). The container is empty afterwards.
    @discardableResult
    func releaseContent() -> NSView? {
        let view = content
        content?.removeFromSuperview()
        content = nil
        return view
    }
}

/// Click-through view layered on top of `PaneContainerView` that draws the accent border only when active.
/// `hitTest` is pinned to `nil` so mouse/click events always reach the content below.
private final class PaneBorderOverlayView: NSView {
    private static let borderWidth: CGFloat = 2

    var isActive: Bool = false {
        didSet {
            guard oldValue != isActive else { return }
            needsDisplay = true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard isActive else { return }
        let inset = Self.borderWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = Self.borderWidth
        SplitHostView.accentColor.setStroke()
        path.stroke()
    }

    // Unlike standard AppKit controls, a custom drawRect is not guaranteed to be redrawn on
    // appearance changes, so invalidate explicitly (same reason as `PalettePanel`'s `PaletteRowView`).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isActive { needsDisplay = true }
    }
}
