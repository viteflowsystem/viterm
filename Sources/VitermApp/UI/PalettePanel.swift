import AppKit
import VitermCore

/// Command palette (Cmd-K) overlay.
///
/// Shown as an `NSPanel`-based borderless / translucent panel at the top center of the parent
/// window. Its look follows Screen 02 of docs/ui-mock.html (dark mode uses the mock's fixed colors
/// as-is). Light mode reconstructs colors with the same roles on the light side, and dynamic colors
/// via `NSColor(name:dynamicProvider:)` automatically track `effectiveAppearance` changes.
///
/// A self-contained component with no dependency on `AppModel`. It works given only the command
/// list (`PaletteCommand`) and a commit callback from outside. Wiring Cmd-K from
/// MainWindowController and calling `PaletteCommandProvider` are the caller's responsibility.
@MainActor
public final class PalettePanel: NSObject {
    /// Holds the instance being shown. This reference keeps it from being deallocated until the panel closes.
    private static var current: PalettePanel?

    /// Show the command palette as an overlay at the top center of `window`.
    ///
    /// - Parameters:
    ///   - window: Parent window to overlay the palette on.
    ///   - commands: All commands to list (initial display order is the order returned by `PaletteCommandProvider`).
    ///   - onCommit: Called when the user confirms with Enter. The panel closes automatically after the call.
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

    // MARK: - Layout constants

    private static let panelWidth: CGFloat = 460
    private static let inputHeight: CGFloat = 42
    private static let rowHeight: CGFloat = 28
    private static let maxVisibleRows = 8
    private static let topInset: CGFloat = 88

    // MARK: - Colors (dynamic colors based on the CSS variables in docs/ui-mock.html)
    //
    // Dark mode values are the mock's fixed colors verbatim. Light mode values reconstruct the same
    // roles (panel background, border, separator line, body/auxiliary text, accent, selected row)
    // on the light side. Colors made with `dynamicColor(dark:light:)` automatically track
    // `effectiveAppearance` changes.

    private static func dynamicColor(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static let colorPanelBackground = dynamicColor(
        dark: NSColor(red: 0x1b / 255, green: 0x1f / 255, blue: 0x27 / 255, alpha: 1),
        light: NSColor(red: 0xf3 / 255, green: 0xf4 / 255, blue: 0xf6 / 255, alpha: 1)
    )
    private static let colorBorder = dynamicColor(
        dark: NSColor(red: 0x31 / 255, green: 0x38 / 255, blue: 0x48 / 255, alpha: 1),
        light: NSColor(red: 0xdc / 255, green: 0xdf / 255, blue: 0xe4 / 255, alpha: 1)
    )
    private static let colorLine = dynamicColor(
        dark: NSColor(red: 0x26 / 255, green: 0x2b / 255, blue: 0x36 / 255, alpha: 1),
        light: NSColor(red: 0xe8 / 255, green: 0xea / 255, blue: 0xed / 255, alpha: 1)
    )
    // The following 4 colors are fileprivate because `PaletteRowView` / `PaletteRowCellView` in this file also reference them.
    fileprivate static let colorText = dynamicColor(
        dark: NSColor(red: 0xe8 / 255, green: 0xea / 255, blue: 0xf0 / 255, alpha: 1),
        light: NSColor(red: 0x1c / 255, green: 0x1f / 255, blue: 0x26 / 255, alpha: 1)
    )
    fileprivate static let colorFaint = dynamicColor(
        dark: NSColor(red: 0x56 / 255, green: 0x60 / 255, blue: 0x72 / 255, alpha: 1),
        light: NSColor(red: 0x6b / 255, green: 0x72 / 255, blue: 0x80 / 255, alpha: 1)
    )
    fileprivate static let colorMuted = dynamicColor(
        dark: NSColor(red: 0x8b / 255, green: 0x93 / 255, blue: 0xa5 / 255, alpha: 1),
        light: NSColor(red: 0x52 / 255, green: 0x59 / 255, blue: 0x66 / 255, alpha: 1)
    )
    fileprivate static let colorAccent = dynamicColor(
        dark: NSColor(red: 0x56 / 255, green: 0xc2 / 255, blue: 0xb6 / 255, alpha: 1),
        light: NSColor(red: 0x17 / 255, green: 0x8f / 255, blue: 0x83 / 255, alpha: 1)
    )
    fileprivate static let colorSelectionRow = dynamicColor(
        dark: NSColor(red: 0x23 / 255, green: 0x2a / 255, blue: 0x36 / 255, alpha: 1),
        light: NSColor(red: 0xe1 / 255, green: 0xf3 / 255, blue: 0xf0 / 255, alpha: 1)
    )
    private static let colorDim = NSColor(white: 0, alpha: 0.55)

    // MARK: - State

    private let allCommands: [PaletteCommand]
    private var filteredCommands: [PaletteCommand]
    private var selectedIndex: Int = 0
    private let onCommit: (PaletteAction) -> Void

    private var dimWindow: NSWindow?
    private var panelWindow: NSPanel?
    private let containerView = PaletteContainerView()
    private let inputRow = NSView()
    private let scrollView = NSScrollView()
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: L("No Results"))

    private var observers: [NSObjectProtocol] = []

    private init(commands: [PaletteCommand], onCommit: @escaping (PaletteAction) -> Void) {
        self.allCommands = commands
        self.filteredCommands = commands
        self.onCommit = onCommit
        super.init()
    }

    // MARK: - Presentation

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

    /// Close the panel (tears down the windows and removes observers). Called from commit, Esc, and losing focus alike.
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

    // MARK: - Window construction

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

    /// Build the search field and table set exactly once. Re-display for filter results is done
    /// only by frame adjustment via `layoutContainer`, never by recreating subviews (recreating
    /// would reattach `searchField` to a different window each time, losing first responder while typing).
    private func setUpContainerViewIfNeeded() {
        guard containerView.subviews.isEmpty else { return }

        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 10
        containerView.layer?.borderWidth = 1
        containerView.layer?.masksToBounds = true
        containerView.backgroundDynamicColor = PalettePanel.colorPanelBackground
        containerView.borderDynamicColor = PalettePanel.colorBorder

        // Input field
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
        searchField.placeholderString = L("Search commands…")
        searchField.delegate = self
        inputRow.addSubview(searchField)
        containerView.addSubview(inputRow)

        // Candidate list
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

    /// Re-position only the frames inside the container to match `height` (views are not recreated).
    /// The container is flipped (y=0 at the top), so "input field at the top, list below it" can be
    /// written naturally. All height changes are absorbed at the bottom edge, so even mid-shrink
    /// while filtering, the input field and the list's top edge never move (the definitive fix for
    /// rows appearing clipped at the bottom edge).
    private func layoutContainer(height: CGFloat) {
        inputRow.frame = NSRect(
            x: 0, y: 0,
            width: PalettePanel.panelWidth, height: PalettePanel.inputHeight
        )
        let listHeight = max(0, height - PalettePanel.inputHeight)
        scrollView.frame = NSRect(
            x: 0, y: PalettePanel.inputHeight,
            width: PalettePanel.panelWidth, height: listHeight
        )
        emptyLabel.frame = NSRect(
            x: 0, y: PalettePanel.inputHeight + listHeight / 2 - 10,
            width: PalettePanel.panelWidth, height: 20
        )
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
        // Call `layoutContainer` first so subviews match the new `height`.
        // `setFrame(display: true)` redraws synchronously the moment it is called, so in the
        // reverse order a frame that is still old (large, pre-filter) would briefly render clipped
        // by the new (small) container bounds (the cause of the odd truncation with a single candidate).
        layoutContainer(height: height)
        panelWindow.setFrame(NSRect(origin: origin, size: NSSize(width: PalettePanel.panelWidth, height: height)), display: true)
    }

    // MARK: - Filtering and selection

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

// MARK: - NSTextFieldDelegate (search query changes; intercepting arrow keys/Enter/Esc)

extension PalettePanel: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue
        filteredCommands = PaletteSearch.search(allCommands, query: query)
        selectedIndex = 0
        reload()
    }

    // The search field processes key input via the field editor (a shared NSTextView), so arrow
    // keys, Enter, and Esc cannot be received through a normal `keyDown`. AppKit also forwards the
    // field editor's commands to this delegate method, so intercept them here.
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
        // Selection is managed by keyboard navigation (up/down arrows). Only mouse clicks are applied here.
        selectedIndex = row
        return true
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        // Redraw the selected row's cell so that mouse-click selection is also reflected visually.
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

// MARK: - Helper classes

/// An `NSPanel` that can become key even while borderless / nonactivating.
/// Required to deliver key input to the text field.
private final class PaletteWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Borderless window that only dims the area behind the palette. Clicking it closes the palette.
private final class PaletteDimWindow: NSWindow {
    var onMouseDown: (() -> Void)?

    override var canBecomeKey: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }
}

/// Row view that custom-draws the selected-row highlight to match `PalettePanel.colorSelectionRow`.
private final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let selectionRect = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6)
        PalettePanel.colorSelectionRow.setFill()
        path.fill()
    }

    // `drawSelection` is custom drawing (a dynamic color resolved via `setFill` each time, not
    // through a raw CGColor), so it would track automatically in principle — but there is no
    // guarantee a redraw is scheduled when the system appearance switches, so invalidate explicitly.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Container view of the palette panel itself. The layer's background and border colors become
/// fixed `CGColor` snapshots, so `NSColor(name:dynamicProvider:)`'s automatic tracking does not
/// apply; re-resolve them explicitly with `performAsCurrentDrawingAppearance` on appearance changes.
private final class PaletteContainerView: NSView {
    // Flipped for the top-down stacking layout (layoutContainer).
    override var isFlipped: Bool { true }

    var backgroundDynamicColor: NSColor? {
        didSet { updateLayerColors() }
    }
    var borderDynamicColor: NSColor? {
        didSet { updateLayerColors() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            guard let self else { return }
            layer?.backgroundColor = backgroundDynamicColor?.cgColor
            layer?.borderColor = borderDynamicColor?.cgColor
        }
    }
}

/// Cell for one row (category, title, and key hint / auxiliary info at the right edge).
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

        categoryLabel.textColor = isSelected ? PalettePanel.colorAccent : PalettePanel.colorFaint
        titleLabel.textColor = isSelected ? PalettePanel.colorText : PalettePanel.colorMuted
        trailingLabel.textColor = PalettePanel.colorFaint
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
