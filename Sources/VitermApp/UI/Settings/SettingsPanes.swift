import AppKit
import VitermCore

// 設定ウィンドウの各ペイン。共通の SettingsPane 基底がフォーム構築ヘルパー
// (grid 行の追加、変更の即時保存)を提供し、各ペインはフィールド定義に集中する。
// ペインを増やす場合は SettingsPane サブクラスを書いて
// SettingsWindowController.panes に1行追加するだけでよい。

// MARK: - 基底

@MainActor
class SettingsPane: NSViewController, NSTextFieldDelegate {
    let store: SettingsStore

    /// フォームのレイアウト定数(全ペイン共通。ここだけで一貫性を担保する)。
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
        // 注釈はフィールド列の開始位置に揃える。
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
            // fittingSize でウィンドウ高さが決まるため、bottom は equal で固定する
            // (lessThanOrEqual だと高さが 0 に潰れてウィンドウが見えなくなる)。
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
        ])
        view = container
        buildForm()
        // 列は行追加時に生成されるため、設定は buildForm 後でないと範囲外例外になる。
        if grid.numberOfColumns > 0 {
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = Layout.labelColumnWidth
        }
        // NSTabViewController(.toolbar)はこの値でウィンドウをペインごとにリサイズする。
        // 未設定だと初期ウィンドウサイズのまま巨大な余白ができる。
        preferredContentSize = container.fittingSize
    }

    /// サブクラスがフォーム行を追加する。
    func buildForm() {}

    // MARK: フォーム構築ヘルパー

    func addRow(label: String, field: NSView) {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13)
        labelField.textColor = .labelColor
        labelField.lineBreakMode = .byClipping
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)
        grid.addRow(with: [labelField, field])
    }

    /// ラベル無しで右カラムだけに置く(チェックボックスや補足)。
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
        // 全ペインで同一のフィールド幅(伸縮させない。一貫性のため equal 固定)。
        field.widthAnchor.constraint(equalToConstant: Layout.fieldWidth).isActive = true
        return field
    }

    /// フィールドの直下に補足(プレビュー等)を沿わせる縦スタック。行のフィールドとして使う。
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

    /// ポップアップ等の固定幅(テキストフィールドと開始位置・見た目を揃える)。
    func fixWidth(_ view: NSView, _ width: CGFloat = 200) {
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
}

/// フォーカスが外れる/Enter で確定したときだけ onCommit を呼ぶテキストフィールド。
final class CommitTextField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    /// 変更の都度(確定前)呼ばれる。プレビュー更新用。
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

// MARK: - 一般

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
        addRow(label: "既定プリセット:", field: presetPopup)

        let copyCheckbox = NSButton(
            checkboxWithTitle: "worktree 作成時に Claude セッションデータをコピー",
            target: self,
            action: #selector(copyChanged(_:))
        )
        copyCheckbox.state = (config.copySessionDataByDefault ?? false) ? .on : .off
        addTrailingRow(copyCheckbox)

        let openButton = NSButton(title: "config.json を開く…", target: self, action: #selector(openConfig))
        openButton.bezelStyle = .rounded
        addTrailingRow(openButton)

        setFootnote("既定プリセットは ⌘T・「＋ セッションを追加」・worktree 作成時のセッション起動に使われます。プリセットの定義自体は config.json の presets で編集します。")
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
        addRow(label: "作成先テンプレート:", field: fieldWithCaption(templateField, caption: previewLabel))
        updatePreview(template: config.worktreePathTemplate)

        let hookField = makeTextField(
            value: config.postCreationHook ?? "",
            placeholder: "npm install など(空で無効)"
        ) { [weak self] value in
            self?.store.set(["postCreationHook": value.isEmpty ? nil : value])
        }
        addRow(label: "作成後フック:", field: hookField)

        setFootnote("プレースホルダ: {project}(リポジトリ名)、{branch}(/ は - に正規化)、{branch_raw}(そのまま)。フックには VITERM_WORKTREE_PATH / VITERM_BRANCH / VITERM_GIT_ROOT が渡されます。")
    }

    private func updatePreview(template: String) {
        let preview = WorktreePathTemplate(template).expand(context: .init(
            projectName: "myapp",
            branch: "feat/x",
            repositoryRoot: "/path/to/myapp"
        ))
        previewLabel.stringValue = "例: myapp の feat/x → \(preview)"
    }
}

// MARK: - 通知フック

final class HooksSettingsPane: SettingsPane {
    override func buildForm() {
        let hooks = store.currentConfig().statusHooks

        addRow(label: "busy になったとき:", field: hookField(hooks.onBusy, key: "onBusy"))
        addRow(label: "入力待ちになったとき:", field: hookField(hooks.onWaitingInput, key: "onWaitingInput"))
        addRow(label: "idle になったとき:", field: hookField(hooks.onIdle, key: "onIdle"))

        setFootnote("セッション状態の変化時に /bin/sh -c で実行されます(空で無効)。環境変数: VITERM_SESSION_NAME / VITERM_WORKTREE_PATH / VITERM_OLD_STATE / VITERM_NEW_STATE。例: 入力待ちで音を鳴らす → afplay /System/Library/Sounds/Glass.aiff")
    }

    private func hookField(_ value: String?, key: String) -> NSTextField {
        makeTextField(value: value ?? "", placeholder: "コマンド(空で無効)") { [weak self] newValue in
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

// MARK: - リポジトリ

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
        addRow(label: "登録リポジトリ:", field: scroll)

        let addButton = NSButton(title: "追加…", target: self, action: #selector(addRepository))
        let removeButton = NSButton(title: "削除", target: self, action: #selector(removeRepository))
        for button in [addButton, removeButton] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        addTrailingRow(buttons)

        let config = store.currentConfig()
        let discoveryField = makeTextField(
            value: config.discoveryRoots.joined(separator: ", "),
            placeholder: "~/repo, ~/work(カンマ区切り、空で無効)"
        ) { [weak self] value in
            let roots = value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            self?.store.set(["discoveryRoots": roots.isEmpty ? nil : roots])
        }
        addRow(label: "自動検出ルート:", field: discoveryField)

        setFootnote("自動検出ルート配下の git リポジトリ(深さ4まで、node_modules 等は除外)は起動時・更新時に自動でサイドバーに追加されます。登録リポジトリはそれとは別に常に表示されます。")
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
        panel.message = "git リポジトリのルートディレクトリを選択"
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
