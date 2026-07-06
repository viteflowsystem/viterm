import AppKit
import VitermCore

// The individual panes of the settings window. The shared SettingsPane base class provides
// form-building helpers (adding grid rows, immediate saving of changes), so each pane can
// focus on its field definitions. To add a pane, write a SettingsPane subclass and add a
// single line to SettingsWindowController.panes.

// MARK: - Base

@MainActor
class SettingsPane: NSViewController, NSTextFieldDelegate {
    let store: SettingsStore

    /// Form layout constants (shared by all panes; consistency is guaranteed here alone).
    private enum Layout {
        static let labelColumnWidth: CGFloat = 168
        static let fieldWidth: CGFloat = 380
        static let contentWidth: CGFloat = 24 + labelColumnWidth + 12 + fieldWidth + 24
    }

    private let grid = NSGridView()
    private let footnote = NSTextField(wrappingLabelWithString: "")

    init(title: String, store: SettingsStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline

        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .tertiaryLabelColor
        footnote.isHidden = true
        footnote.preferredMaxLayoutWidth = Layout.fieldWidth

        let stack = NSStackView(views: [grid, footnote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        // Align the footnote with the start of the field column.
        footnote.leadingAnchor.constraint(
            equalTo: stack.leadingAnchor,
            constant: 24 + Layout.labelColumnWidth + 12
        ).isActive = true

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // The window height is determined by fittingSize, so pin bottom with equal
            // (with lessThanOrEqual the height collapses to 0 and the window becomes invisible).
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
        ])
        view = container
        buildForm()
        // Columns are created when rows are added, so configuring them before buildForm
        // raises an out-of-range exception.
        if grid.numberOfColumns > 0 {
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = Layout.labelColumnWidth
        }
        // NSTabViewController (.toolbar) resizes the window per pane using this value.
        // If unset, the window keeps its initial size and a huge blank margin appears.
        preferredContentSize = container.fittingSize
    }

    /// Subclasses add their form rows here.
    func buildForm() {}

    // MARK: Form-building helpers

    func addRow(label: String, field: NSView) {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13)
        labelField.textColor = .labelColor
        labelField.lineBreakMode = .byClipping
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)
        grid.addRow(with: [labelField, field])
    }

    /// Place a view in the right column only, without a label (checkboxes, supplementary text).
    func addTrailingRow(_ view: NSView) {
        grid.addRow(with: [NSGridCell.emptyContentView, view])
    }

    func setFootnote(_ text: String) {
        footnote.stringValue = text
        footnote.isHidden = text.isEmpty
    }

    func makeTextField(value: String, placeholder: String = "", onCommit: @escaping (String) -> Void) -> NSTextField {
        let field = CommitTextField()
        field.stringValue = value
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.onCommit = onCommit
        field.delegate = field
        // Same field width across all panes (no stretching; pinned equal for consistency).
        field.widthAnchor.constraint(equalToConstant: Layout.fieldWidth).isActive = true
        return field
    }

    /// Vertical stack that places a caption (preview, etc.) directly under a field. Use as a row's field.
    func fieldWithCaption(_ field: NSView, caption: NSTextField) -> NSView {
        caption.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingMiddle
        caption.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.fieldWidth).isActive = true
        let stack = NSStackView(views: [field, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    /// Fixed width for popups etc. (aligns start position and appearance with text fields).
    func fixWidth(_ view: NSView, _ width: CGFloat = 200) {
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
}

/// Text field that calls onCommit only when focus leaves or Enter commits the value.
final class CommitTextField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    /// Called on every change (before commit). For preview updates.
    var onLiveChange: ((String) -> Void)?
    private var lastCommitted: String?

    func controlTextDidChange(_ obj: Notification) {
        onLiveChange?(stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commit()
    }

    private func commit() {
        guard stringValue != lastCommitted else { return }
        lastCommitted = stringValue
        onCommit?(stringValue)
    }
}

// MARK: - General

final class GeneralSettingsPane: SettingsPane {
    override func buildForm() {
        let config = store.currentConfig()

        let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for preset in config.presets {
            presetPopup.addItem(withTitle: preset.name)
        }
        if let defaultPreset = config.defaultPreset {
            presetPopup.selectItem(withTitle: defaultPreset)
        }
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))
        fixWidth(presetPopup)
        addRow(label: L("Default Preset:"), field: presetPopup)

        let copyCheckbox = NSButton(
            checkboxWithTitle: L("Copy Claude session data when creating a worktree"),
            target: self,
            action: #selector(copyChanged(_:))
        )
        copyCheckbox.state = (config.copySessionDataByDefault ?? false) ? .on : .off
        addTrailingRow(copyCheckbox)

        let openButton = NSButton(title: L("Open config.json…"), target: self, action: #selector(openConfig))
        openButton.bezelStyle = .rounded
        addTrailingRow(openButton)

        setFootnote(L("The default preset is used for ⌘T, “＋ Add Session”, and the session launched when creating a worktree. Presets themselves are edited in the presets section of config.json."))
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        store.set(["defaultPreset": title])
    }

    @objc private func copyChanged(_ sender: NSButton) {
        store.set(["copySessionDataByDefault": sender.state == .on])
    }

    @objc private func openConfig() {
        store.openInEditor()
    }
}

// MARK: - Worktree

final class WorktreeSettingsPane: SettingsPane {
    private let previewLabel = NSTextField(labelWithString: "")

    override func buildForm() {
        let config = store.currentConfig()

        let templateField = makeTextField(
            value: config.worktreePathTemplate,
            placeholder: "~/worktrees/{project}/{branch}"
        ) { [weak self] value in
            self?.store.set(["worktreePathTemplate": value])
        }
        (templateField as? CommitTextField)?.onLiveChange = { [weak self] value in
            self?.updatePreview(template: value)
        }
        addRow(label: L("Destination Template:"), field: fieldWithCaption(templateField, caption: previewLabel))
        updatePreview(template: config.worktreePathTemplate)

        let hookField = makeTextField(
            value: config.postCreationHook ?? "",
            placeholder: L("e.g. npm install (leave empty to disable)")
        ) { [weak self] value in
            self?.store.set(["postCreationHook": value.isEmpty ? nil : value])
        }
        addRow(label: L("Post-Creation Hook:"), field: hookField)

        setFootnote(L("Placeholders: {project} (repository name), {branch} (/ normalized to -), {branch_raw} (as is). The hook receives VITERM_WORKTREE_PATH / VITERM_BRANCH / VITERM_GIT_ROOT."))
    }

    private func updatePreview(template: String) {
        let preview = WorktreePathTemplate(template).expand(context: .init(
            projectName: "myapp",
            branch: "feat/x",
            repositoryRoot: "/path/to/myapp"
        ))
        previewLabel.stringValue = L("Example: feat/x in myapp → \(preview)")
    }
}

// MARK: - Notification hooks

final class HooksSettingsPane: SettingsPane {
    override func buildForm() {
        let hooks = store.currentConfig().statusHooks

        addRow(label: L("When busy:"), field: hookField(hooks.onBusy, key: "onBusy"))
        addRow(label: L("When waiting for input:"), field: hookField(hooks.onWaitingInput, key: "onWaitingInput"))
        addRow(label: L("When idle:"), field: hookField(hooks.onIdle, key: "onIdle"))

        setFootnote(L("Runs via /bin/sh -c when a session state changes (leave empty to disable). Environment variables: VITERM_SESSION_NAME / VITERM_WORKTREE_PATH / VITERM_OLD_STATE / VITERM_NEW_STATE. Example: play a sound on waiting for input → afplay /System/Library/Sounds/Glass.aiff"))
    }

    private func hookField(_ value: String?, key: String) -> NSTextField {
        makeTextField(value: value ?? "", placeholder: L("Command (leave empty to disable)")) { [weak self] newValue in
            guard let self else { return }
            var statusHooks = (self.store.rawJSON()["statusHooks"] as? [String: Any]) ?? [:]
            if newValue.isEmpty {
                statusHooks.removeValue(forKey: key)
            } else {
                statusHooks[key] = newValue
            }
            self.store.set(["statusHooks": statusHooks.isEmpty ? nil : statusHooks])
        }
    }
}

// MARK: - Repositories

final class RepositoriesSettingsPane: SettingsPane, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private var repositories: [[String: String]] = []

    override func buildForm() {
        reloadRepositories()

        let column = NSTableColumn(identifier: .init("repo"))
        column.isEditable = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
        addRow(label: L("Registered Repositories:"), field: scroll)

        let addButton = NSButton(title: L("Add…"), target: self, action: #selector(addRepository))
        let removeButton = NSButton(title: L("Remove"), target: self, action: #selector(removeRepository))
        for button in [addButton, removeButton] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        addTrailingRow(buttons)

        let config = store.currentConfig()
        let discoveryField = makeTextField(
            value: config.discoveryRoots.joined(separator: ", "),
            placeholder: L("~/repo, ~/work (comma-separated, leave empty to disable)")
        ) { [weak self] value in
            let roots = value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            self?.store.set(["discoveryRoots": roots.isEmpty ? nil : roots])
        }
        addRow(label: L("Discovery Roots:"), field: discoveryField)

        setFootnote(L("Git repositories under the discovery roots (up to depth 4, excluding node_modules and the like) are added to the sidebar automatically at launch and on refresh. Registered repositories are always shown in addition to those."))
    }

    private func reloadRepositories() {
        repositories = (store.rawJSON()["repositories"] as? [[String: Any]])?.compactMap { entry in
            guard let name = entry["name"] as? String, let path = entry["path"] as? String else { return nil }
            return ["name": name, "path": path]
        } ?? []
        tableView.reloadData()
    }

    private func persistRepositories() {
        store.set(["repositories": repositories.isEmpty ? nil : repositories])
        reloadRepositories()
    }

    @objc private func addRepository() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L("Select the root directory of a git repository")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if let index = self.repositories.firstIndex(where: { $0["path"] == url.path }) {
                self.repositories[index]["name"] = url.lastPathComponent
            } else {
                self.repositories.append(["name": url.lastPathComponent, "path": url.path])
            }
            self.persistRepositories()
        }
    }

    @objc private func removeRepository() {
        let row = tableView.selectedRow
        guard repositories.indices.contains(row) else {
            NSSound.beep()
            return
        }
        repositories.remove(at: row)
        persistRepositories()
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { repositories.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = repositories[row]
        let text = NSTextField(labelWithString: "\(entry["name"] ?? "")  —  \(entry["path"] ?? "")")
        text.font = .systemFont(ofSize: 12)
        text.lineBreakMode = .byTruncatingMiddle
        let cell = NSTableCellView()
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
