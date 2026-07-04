import AppKit
import ViteaCore

/// 設定シート(⌘,)。グローバル設定 `~/.config/vitea/config.json` の主要キーを編集する。
///
/// 書き戻しは「既存 JSON を読み、編集対象キーだけ差し替える」方式で、
/// presets や repositories などこの画面で扱わないキーを保全する。
@MainActor
final class SettingsSheet: NSViewController {
    private let config: ViteaConfig
    private let onSaved: () -> Void

    private let templateField = NSTextField(string: "")
    private let templatePreview = NSTextField(labelWithString: "")
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let copyCheckbox = NSButton(checkboxWithTitle: "worktree 作成時に Claude セッションデータをコピー(既定値)", target: nil, action: nil)
    private let discoveryField = NSTextField(string: "")
    private let errorLabel = NSTextField(labelWithString: "")

    static var globalConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vitea/config.json")
    }

    init(config: ViteaConfig, onSaved: @escaping () -> Void) {
        self.config = config
        self.onSaved = onSaved
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)

        let title = NSTextField(labelWithString: "設定 — ~/.config/vitea/config.json")
        title.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(title)

        stack.addArrangedSubview(fieldLabel("worktree 作成先テンプレート({project} / {branch} / {branch_raw})"))
        templateField.stringValue = config.worktreePathTemplate
        templateField.delegate = self
        stack.addArrangedSubview(templateField)
        templatePreview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        templatePreview.textColor = .secondaryLabelColor
        stack.addArrangedSubview(templatePreview)

        stack.addArrangedSubview(fieldLabel("既定プリセット(⌘T / worktree 作成時に起動)"))
        for preset in config.presets {
            presetPopup.addItem(withTitle: preset.name)
        }
        if let defaultPreset = config.defaultPreset {
            presetPopup.selectItem(withTitle: defaultPreset)
        }
        stack.addArrangedSubview(presetPopup)

        copyCheckbox.state = (config.copySessionDataByDefault ?? false) ? .on : .off
        stack.addArrangedSubview(copyCheckbox)

        stack.addArrangedSubview(fieldLabel("リポジトリ自動検出ルート(カンマ区切り、空で無効。例: ~/repo)"))
        discoveryField.stringValue = config.discoveryRoots.joined(separator: ", ")
        stack.addArrangedSubview(discoveryField)

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        stack.addArrangedSubview(errorLabel)

        let note = NSTextField(labelWithString: "プリセット定義や status hooks などは config.json を直接編集(docs/configuration.md 参照)")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(note)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let openInEditor = NSButton(title: "config.json を開く", target: self, action: #selector(didOpenInEditor))
        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(didCancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "保存", target: self, action: #selector(didSave))
        save.keyEquivalent = "\r"
        buttons.addArrangedSubview(openInEditor)
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(save)
        stack.addArrangedSubview(buttons)

        for field in [templateField, discoveryField] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        }

        view = stack
        updatePreview()
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func updatePreview() {
        let template = WorktreePathTemplate(templateField.stringValue)
        let preview = template.expand(context: .init(
            projectName: "myapp",
            branch: "feat/x",
            repositoryRoot: "/path/to/myapp"
        ))
        templatePreview.stringValue = "例: myapp の feat/x → \(preview)"
    }

    // MARK: - Actions

    @objc private func didOpenInEditor() {
        let url = Self.globalConfigURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "{\n}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func didCancel() {
        dismissSheet()
    }

    @objc private func didSave() {
        do {
            try save()
            dismissSheet()
            onSaved()
        } catch {
            errorLabel.stringValue = "保存に失敗: \(error.localizedDescription)"
        }
    }

    /// 既存 JSON の未編集キーを保全しながら編集対象キーだけを差し替えて書き戻す。
    private func save() throws {
        let url = Self.globalConfigURL
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        json["worktreePathTemplate"] = templateField.stringValue
        if let selected = presetPopup.titleOfSelectedItem {
            json["defaultPreset"] = selected
        }
        json["copySessionDataByDefault"] = copyCheckbox.state == .on
        let roots = discoveryField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if roots.isEmpty {
            json.removeValue(forKey: "discoveryRoots")
        } else {
            json["discoveryRoots"] = roots
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func dismissSheet() {
        if let sheetWindow = view.window, let parent = sheetWindow.sheetParent {
            parent.endSheet(sheetWindow)
        }
    }
}

extension SettingsSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updatePreview()
    }
}
