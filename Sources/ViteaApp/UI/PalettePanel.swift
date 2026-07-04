import AppKit
import ViteaCore

/// コマンドパレット(⌘K)のオーバーレイ。
///
/// `NSPanel` ベースの borderless / 半透明パネルとして、親ウィンドウの中央上部に表示する。
/// 見た目は docs/ui-mock.html の Screen 02 に準拠(固定のダークカラーを用いる。
/// システムのライト/ダークに追従させるのではなく、mock 通りの配色で常に表示する)。
///
/// `AppModel` には依存しない self-contained なコンポーネント。コマンド一覧(`PaletteCommand`)と
/// 確定時のコールバックを外から渡すだけで動作する。MainWindowController からの ⌘K 配線・
/// `PaletteCommandProvider` の呼び出しは呼び出し側の責務。
@MainActor
public final class PalettePanel: NSObject {
    /// 表示中のインスタンスを保持する。パネルを閉じるまで解放されないようにするための参照。
    private static var current: PalettePanel?

    /// コマンドパレットを `window` の中央上部にオーバーレイ表示する。
    ///
    /// - Parameters:
    ///   - window: パレットを重ねる親ウィンドウ。
    ///   - commands: 列挙する全コマンド(表示順は `PaletteCommandProvider` が返した順を初期表示順とする)。
    ///   - onCommit: ユーザーが Enter で確定したときに呼ばれる。呼び出し後、パネルは自動で閉じる。
    public static func show(
        over window: NSWindow,
        commands: [PaletteCommand],
        onCommit: @escaping (PaletteAction) -> Void
    ) {
        current?.close()
        let panel = PalettePanel(commands: commands, onCommit: onCommit)
        current = panel
        panel.present(over: window)
    }

    // MARK: - レイアウト定数

    private static let panelWidth: CGFloat = 460
    private static let inputHeight: CGFloat = 42
    private static let rowHeight: CGFloat = 28
    private static let maxVisibleRows = 8
    private static let topInset: CGFloat = 88

    // MARK: - 配色(docs/ui-mock.html の CSS 変数に合わせた固定値)

    private static let colorPanelBackground = NSColor(red: 0x1b / 255, green: 0x1f / 255, blue: 0x27 / 255, alpha: 1)
    private static let colorBorder = NSColor(red: 0x31 / 255, green: 0x38 / 255, blue: 0x48 / 255, alpha: 1)
    private static let colorLine = NSColor(red: 0x26 / 255, green: 0x2b / 255, blue: 0x36 / 255, alpha: 1)
    private static let colorText = NSColor(red: 0xe8 / 255, green: 0xea / 255, blue: 0xf0 / 255, alpha: 1)
    private static let colorFaint = NSColor(red: 0x56 / 255, green: 0x60 / 255, blue: 0x72 / 255, alpha: 1)
    private static let colorAccent = NSColor(red: 0x56 / 255, green: 0xc2 / 255, blue: 0xb6 / 255, alpha: 1)
    private static let colorDim = NSColor(white: 0, alpha: 0.55)

    // MARK: - 状態

    private let allCommands: [PaletteCommand]
    private var filteredCommands: [PaletteCommand]
    private var selectedIndex: Int = 0
    private let onCommit: (PaletteAction) -> Void

    private var dimWindow: NSWindow?
    private var panelWindow: NSPanel?
    private let containerView = NSView()
    private let inputRow = NSView()
    private let scrollView = NSScrollView()
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "見つかりません")

    private var observers: [NSObjectProtocol] = []

    private init(commands: [PaletteCommand], onCommit: @escaping (PaletteAction) -> Void) {
        self.allCommands = commands
        self.filteredCommands = commands
        self.onCommit = onCommit
        super.init()
    }

    // MARK: - 表示

    private func present(over window: NSWindow) {
        let dim = makeDimWindow(covering: window)
        let panel = makePanelWindow()

        window.addChildWindow(dim, ordered: .above)
        window.addChildWindow(panel, ordered: .above)

        dim.orderFront(nil)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        dimWindow = dim
        panelWindow = panel

        let resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.close()
            }
        }
        observers.append(resignObserver)

        reload()
    }

    /// パネルを閉じる(ウィンドウの破棄・オブザーバの解除を行う)。確定・Esc・フォーカス外れのいずれからも呼ばれる。
    private func close() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        if let panelWindow, let parent = panelWindow.parent {
            parent.removeChildWindow(panelWindow)
        }
        if let dimWindow, let parent = dimWindow.parent {
            parent.removeChildWindow(dimWindow)
        }
        panelWindow?.orderOut(nil)
        dimWindow?.orderOut(nil)
        panelWindow = nil
        dimWindow = nil

        if PalettePanel.current === self {
            PalettePanel.current = nil
        }
    }

    // MARK: - ウィンドウ構築

    private func makeDimWindow(covering window: NSWindow) -> NSWindow {
        let dim = PaletteDimWindow(
            contentRect: window.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        dim.isOpaque = false
        dim.backgroundColor = PalettePanel.colorDim
        dim.hasShadow = false
        dim.ignoresMouseEvents = false
        dim.onMouseDown = { [weak self] in self?.close() }
        dim.level = window.level
        return dim
    }

    private func makePanelWindow() -> NSPanel {
        let height = contentHeight()
        let panel = PaletteWindow(
            contentRect: NSRect(x: 0, y: 0, width: PalettePanel.panelWidth, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        setUpContainerViewIfNeeded()
        panel.contentView = containerView
        layoutContainer(height: height)

        return panel
    }

    /// 検索欄・テーブル一式を一度だけ構築する。フィルタ結果に応じた再表示は `layoutContainer`
    /// によるフレーム調整のみで行い、サブビューを作り直さない(作り直すと `searchField` が
    /// 毎回別ウィンドウに付け替わり、入力中に first responder が失われてしまう)。
    private func setUpContainerViewIfNeeded() {
        guard containerView.subviews.isEmpty else { return }

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = PalettePanel.colorPanelBackground.cgColor
        containerView.layer?.cornerRadius = 10
        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = PalettePanel.colorBorder.cgColor
        containerView.layer?.masksToBounds = true

        // 入力欄
        let bottomLine = NSBox()
        bottomLine.boxType = .custom
        bottomLine.fillColor = PalettePanel.colorLine
        bottomLine.borderWidth = 0
        bottomLine.frame = NSRect(x: 0, y: 0, width: PalettePanel.panelWidth, height: 1)
        inputRow.addSubview(bottomLine)

        let caret = NSTextField(labelWithString: "❯")
        caret.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        caret.textColor = PalettePanel.colorAccent
        caret.frame = NSRect(x: 14, y: 11, width: 16, height: 20)
        inputRow.addSubview(caret)

        searchField.frame = NSRect(x: 32, y: 8, width: PalettePanel.panelWidth - 32 - 14, height: 24)
        searchField.font = .systemFont(ofSize: 13)
        searchField.textColor = PalettePanel.colorText
        searchField.backgroundColor = .clear
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.placeholderString = "コマンドを検索…"
        searchField.delegate = self
        inputRow.addSubview(searchField)
        containerView.addSubview(inputRow)

        // 候補リスト
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = PalettePanel.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = []
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(commitSelection)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.width = PalettePanel.panelWidth
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        containerView.addSubview(scrollView)

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = PalettePanel.colorFaint
        emptyLabel.isHidden = true
        containerView.addSubview(emptyLabel)
    }

    /// `height` に合わせてコンテナ内の各フレームだけを再配置する(ビューは作り直さない)。
    private func layoutContainer(height: CGFloat) {
        containerView.frame = NSRect(x: 0, y: 0, width: PalettePanel.panelWidth, height: height)
        inputRow.frame = NSRect(
            x: 0, y: height - PalettePanel.inputHeight,
            width: PalettePanel.panelWidth, height: PalettePanel.inputHeight
        )
        let listHeight = height - PalettePanel.inputHeight
        scrollView.frame = NSRect(x: 0, y: 0, width: PalettePanel.panelWidth, height: listHeight)
        emptyLabel.frame = NSRect(x: 0, y: listHeight / 2 - 10, width: PalettePanel.panelWidth, height: 20)
    }

    private func contentHeight() -> CGFloat {
        let visibleRows = min(max(filteredCommands.count, 1), PalettePanel.maxVisibleRows)
        return PalettePanel.inputHeight + CGFloat(visibleRows) * PalettePanel.rowHeight
    }

    private func repositionPanel(over window: NSWindow) {
        guard let panelWindow else { return }
        let height = contentHeight()
        let origin = NSPoint(
            x: window.frame.midX - PalettePanel.panelWidth / 2,
            y: window.frame.maxY - PalettePanel.topInset - height
        )
        // `layoutContainer` を先に呼び、サブビューを新しい `height` に合わせておく。
        // `setFrame(display: true)` は呼び出した瞬間に同期的に再描画するため、逆順だと
        // 古い(絞り込み前の大きい)フレームのまま新しい(小さい)コンテナ境界で
        // クリップされた状態が一瞬描画されてしまう(候補が1件のときの半端な切れ方の原因)。
        layoutContainer(height: height)
        panelWindow.setFrame(NSRect(origin: origin, size: NSSize(width: PalettePanel.panelWidth, height: height)), display: true)
    }

    // MARK: - フィルタリング・選択

    private func reload() {
        tableView.reloadData()
        emptyLabel.isHidden = !filteredCommands.isEmpty
        if let parent = panelWindow?.parent {
            repositionPanel(over: parent)
        }
        updateSelection()
    }

    private func updateSelection() {
        guard !filteredCommands.isEmpty else {
            tableView.deselectAll(nil)
            return
        }
        selectedIndex = min(max(selectedIndex, 0), filteredCommands.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
    }

    private func moveSelection(by delta: Int) {
        guard !filteredCommands.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + filteredCommands.count) % filteredCommands.count
        updateSelection()
    }

    @objc private func commitSelection() {
        guard filteredCommands.indices.contains(selectedIndex) else { return }
        let action = filteredCommands[selectedIndex].action
        close()
        onCommit(action)
    }
}

// MARK: - NSTextFieldDelegate(検索クエリの変化・矢印キー/Enter/Esc の横取り)

extension PalettePanel: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue
        filteredCommands = PaletteSearch.search(allCommands, query: query)
        selectedIndex = 0
        reload()
    }

    // 検索フィールドはフィールドエディタ(共有 NSTextView)経由でキー入力を処理するため、
    // 矢印キー・Enter・Esc は通常の `keyDown` では受け取れない。AppKit が field editor の
    // コマンドをこのデリゲートメソッドにも転送してくるので、ここで横取りする。
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension PalettePanel: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        filteredCommands.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = filteredCommands[row]
        let isSelected = row == selectedIndex

        let identifier = NSUserInterfaceItemIdentifier("paletteRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? PaletteRowCellView) ?? PaletteRowCellView()
        cell.identifier = identifier
        cell.configure(
            category: command.category.displayName,
            title: command.title,
            trailing: trailingText(for: command),
            isSelected: isSelected
        )
        return cell
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = PaletteRowView()
        return rowView
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // 選択はキーボード操作(↑↓)側で管理する。マウスクリックのみここで反映する。
        selectedIndex = row
        return true
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        // マウスクリックによる選択も見た目に反映するため、選択行のセルだけ再描画する。
        tableView.reloadData()
    }

    private func trailingText(for command: PaletteCommand) -> String? {
        switch (command.subtitle, command.keyboardHint) {
        case let (subtitle?, hint?):
            return "\(subtitle) \(hint)"
        case let (subtitle?, nil):
            return subtitle
        case let (nil, hint?):
            return hint
        case (nil, nil):
            return nil
        }
    }
}

// MARK: - 補助クラス

/// borderless / nonactivating でもキーウィンドウになれる `NSPanel`。
/// テキストフィールドにキー入力を届けるために必要。
private final class PaletteWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// パレット背後を薄暗くするだけの borderless ウィンドウ。クリックでパレットを閉じる。
private final class PaletteDimWindow: NSWindow {
    var onMouseDown: (() -> Void)?

    override var canBecomeKey: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }
}

/// 選択行のハイライトを mock の配色(`#232a36`)に合わせてカスタム描画する行ビュー。
private final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let selectionRect = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6)
        NSColor(red: 0x23 / 255, green: 0x2a / 255, blue: 0x36 / 255, alpha: 1).setFill()
        path.fill()
    }
}

/// 1行分のセル(カテゴリ・タイトル・右端のキーヒント/補助情報)。
private final class PaletteRowCellView: NSTableCellView {
    private let categoryLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        for label in [categoryLabel, titleLabel, trailingLabel] {
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        categoryLabel.font = .systemFont(ofSize: 11)
        titleLabel.font = .systemFont(ofSize: 12.5)
        trailingLabel.font = .systemFont(ofSize: 11)
        trailingLabel.alignment = .right
    }

    func configure(category: String, title: String, trailing: String?, isSelected: Bool) {
        categoryLabel.stringValue = category
        titleLabel.stringValue = title
        trailingLabel.stringValue = trailing ?? ""

        let accent = NSColor(red: 0x56 / 255, green: 0xc2 / 255, blue: 0xb6 / 255, alpha: 1)
        let text = NSColor(red: 0xe8 / 255, green: 0xea / 255, blue: 0xf0 / 255, alpha: 1)
        let muted = NSColor(red: 0x8b / 255, green: 0x93 / 255, blue: 0xa5 / 255, alpha: 1)
        let faint = NSColor(red: 0x56 / 255, green: 0x60 / 255, blue: 0x72 / 255, alpha: 1)

        categoryLabel.textColor = isSelected ? accent : faint
        titleLabel.textColor = isSelected ? text : muted
        trailingLabel.textColor = faint
    }

    override func layout() {
        super.layout()
        let categoryWidth: CGFloat = 64
        let trailingWidth: CGFloat = 90
        let padding: CGFloat = 14
        let height = bounds.height

        categoryLabel.frame = NSRect(x: padding, y: (height - 14) / 2, width: categoryWidth, height: 14)
        trailingLabel.frame = NSRect(
            x: bounds.width - trailingWidth - padding, y: (height - 14) / 2,
            width: trailingWidth, height: 14
        )
        let titleX = padding + categoryWidth + 10
        titleLabel.frame = NSRect(
            x: titleX, y: (height - 16) / 2,
            width: max(0, bounds.width - trailingWidth - padding - titleX - 6), height: 16
        )
    }
}
