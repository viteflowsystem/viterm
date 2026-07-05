import AppKit

/// 複数ペイン(ターミナルサーフェス等)を `NSSplitView` の二分木でホストするコンポーネント(T12)。
///
/// `TerminalHostView` の単一表示に代わる分割対応版という位置づけの self-contained なビュー。
/// リーフには任意の `NSView`(実運用では `GhosttySurfaceView`)を1枚だけ保持する。
/// `TerminalHostView` 同様、ペインを閉じても中身の View 自体は破棄せず取り外すだけ
/// (バックグラウンドセッションの生存方針を踏襲。`closeActivePane()` が返す View の扱いは
/// 呼び出し側の責務)。
///
/// 分割木は `PaneNode`(`.leaf` / `.split`)で表現し、各ノードは自身を含む `NSSplitView` の
/// arrangedSubview もしくは `PaneContainerView` を直接保持する。フォーカス中ペインはクリックまたは
/// `focusNextPane()` で切り替わり、`PaneContainerView` がアクセント色の枠で見た目に反映する。
final class SplitHostView: NSView {
    /// フォーカス移動(クリック・`focusNextPane()`・分割・クローズ)のたびに呼ばれる。
    /// 引数は新しいアクティブペインの中身(ペインが1つも無くなった場合は `nil`)。
    var onActivePaneChanged: ((NSView?) -> Void)?

    /// フォーカス中ペインの枠に使うアクセント色。ダーク時は docs/ui-mock.html のアクセント値、
    /// ライト時は `PalettePanel` と同じ方針でコントラストを保つよう少し暗くした値を使う。
    static let accentColor = NSColor(name: nil) { appearance in
        let dark = NSColor(red: 0x56 / 255, green: 0xc2 / 255, blue: 0xb6 / 255, alpha: 1)
        let light = NSColor(red: 0x17 / 255, green: 0x8f / 255, blue: 0x83 / 255, alpha: 1)
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    private var root: PaneNode?
    private var activeNode: PaneNode?
    /// クリックでのペイン切り替え用に `PaneContainerView` → `PaneNode` を逆引きする。
    private var nodesByContainer: [ObjectIdentifier: PaneNode] = [:]
    // deinit(nonisolated)から解放するため unsafe 指定。書き込みは init/deinit のみ
    // (GhosttySurfaceView.surface と同じ理由)。
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

    // MARK: - 公開 API

    /// 分割なしの単一表示にリセットする(`TerminalHostView.show` 相当)。既存のペインはすべて
    /// 取り外す(中身の View は破棄しない)。`nil` を渡すとペインが1つも無い状態になる。
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

    /// フォーカス中のペインを分割し、新しいペインとして `newView` を配置する。
    /// `vertically: true` は右側に(縦の仕切り線で左右分割)、`false` は下側に(横の仕切り線で
    /// 上下分割)追加する。フォーカス中のペインが無い場合は `showRoot(newView)` と同じ挙動になる。
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

    /// フォーカス中のペインを閉じ、そこに入っていた View を取り外して返す(破棄はしない)。
    /// 呼び出し側がセッション終了などと紐付けるかは任意。閉じた結果ペインが1つも残らなければ
    /// `onActivePaneChanged` に `nil` が通知される。フォーカス中のペインが無ければ何もせず `nil`。
    @discardableResult
    func closeActivePane() -> NSView? {
        guard let target = activeNode, case .leaf(let container) = target.kind else { return nil }
        let removedView = container.releaseContent()
        nodesByContainer[ObjectIdentifier(container)] = nil
        let targetView = containerView(for: target)

        guard let parent = target.parent, case .split(let parentSplitView, let childA, let childB) = parent.kind else {
            // 唯一のペイン(root がそのまま leaf)だった。
            targetView.removeFromSuperview()
            root = nil
            setActive(nil, notify: true)
            return removedView
        }

        let sibling = (childA === target) ? childB : childA
        let siblingView = containerView(for: sibling)
        let grandparent = parent.parent

        // 祖父ノードでの挿入位置は、親(古い NSSplitView)を取り除く前に記録しておく必要がある。
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

    /// 現在ホストしている中身の View 一覧(深さ優先順)。
    var hostedViews: [NSView] {
        var leaves: [PaneNode] = []
        collectLeaves(root, into: &leaves)
        return leaves.compactMap { node in
            if case .leaf(let container) = node.kind { return container.content }
            return nil
        }
    }

    /// `view` を中身に持つペインがあればフォーカスして true を返す。
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

    /// `view` を中身に持つペインを閉じ、View を取り外して返す(破棄はしない)。
    /// 該当ペインが無ければ何もせず `nil`。プロセス終了したセッションの後始末用。
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
        // 閉じたのが非アクティブペインだった場合、可能なら元のアクティブを維持する。
        if let previousActive, previousActive !== node {
            var remaining: [PaneNode] = []
            collectLeaves(root, into: &remaining)
            if remaining.contains(where: { $0 === previousActive }) {
                setActive(previousActive, notify: true)
            }
        }
        return removed
    }

    /// フォーカス中ペインの中身を `newView` に差し替え、外した View を返す(破棄はしない)。
    /// ペインが無い場合は `showRoot(newView)` 相当。
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

    /// ペイン間でフォーカスを次に移す(木を深さ優先で辿った順で巡回し、末尾からは先頭に戻る)。
    /// ペインが1つ以下なら何もしない。
    func focusNextPane() {
        var leaves: [PaneNode] = []
        collectLeaves(root, into: &leaves)
        guard leaves.count > 1 else { return }
        let currentIndex = activeNode.flatMap { active in leaves.firstIndex(where: { $0 === active }) } ?? -1
        let next = leaves[(currentIndex + 1 + leaves.count) % leaves.count]
        setActive(next, notify: true)
    }

    // MARK: - 分割木の操作

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

    /// 現在の木をすべて取り外す(各リーフの中身の View も `removeFromSuperview` する。破棄はしない)。
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

    // MARK: - フォーカス管理

    private func setActive(_ node: PaneNode?, notify: Bool) {
        if let previous = activeNode, case .leaf(let previousContainer) = previous.kind {
            previousContainer.isActive = false
        }
        activeNode = node

        // フォーカス枠は「どのペインがアクティブか」の区別が必要な分割時のみ表示する
        // (単一ペインで常時枠が出ると、ただの飾り枠に見えてしまう)。
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

    // MARK: - クリックによるペイン切り替え

    /// クリックされたペインをアクティブにする。`GhosttySurfaceView` 等リーフの中身側に手を入れず
    /// フォーカス追従させるため、ウィンドウの通常応答チェーンには頼らずローカルの mouse monitor で
    /// クリック位置から該当ペインを特定する。イベント自体は消費せずそのまま返す。
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

// MARK: - 分割木

/// `SplitHostView` の分割木のノード。`.leaf` は1枚の `PaneContainerView`、`.split` は
/// `NSSplitView` とその2つの子ノードを持つ。`parent` はクローズ/分割時の木の組み替えに使う。
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

// MARK: - リーフのコンテナ

/// 分割木の葉として、中身の View を1枚保持するコンテナ。`isActive` に応じてアクセント色の枠を
/// 最前面のオーバーレイ(`PaneBorderOverlayView`)で描画する。中身は bounds いっぱいに敷き詰める
/// ため、枠は別 View で最前面から重ねないと中身に隠れてしまう(コンテナ自身の背景描画は
/// 常に subview より下に合成されるため)。
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

    /// 中身の View を bounds いっぱいに配置する。既存の中身があれば `removeFromSuperview` する
    /// (破棄はしない)。
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

    /// 中身の View を取り外して返す(破棄はしない)。以後このコンテナは空になる。
    @discardableResult
    func releaseContent() -> NSView? {
        let view = content
        content?.removeFromSuperview()
        content = nil
        return view
    }
}

/// `PaneContainerView` の最前面に重ね、アクティブ時のみアクセント枠を描画するクリックスルー View。
/// `hitTest` を `nil` 固定にしてマウス/クリックイベントは常に下の中身に届くようにする。
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

    // カスタム drawRect は AppKit 標準コントロールと違い外観変化時の再描画が保証されないため、
    // 明示的に invalidate する(`PalettePanel` の `PaletteRowView` と同じ理由)。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isActive { needsDisplay = true }
    }
}
