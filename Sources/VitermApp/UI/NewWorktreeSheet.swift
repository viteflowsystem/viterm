import AppKit
import GitKit
import VitermCore

/// worktree 新規作成シート(T10)。docs/ui-mock.html Screen 03 準拠。
/// 頭脳は VitermCore.NewWorktreeFormModel、このクラスは AppKit への写像のみ。
@MainActor
final class NewWorktreeSheet: NSViewController {
    private var form: NewWorktreeFormModel
    private let onCommit: (NewWorktreeRequest) -> Void

    private let branchField = NSTextField(string: "")
    private let basePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pathField = NSTextField(string: "")
    private let pathPreviewLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let copyCheckbox = NSButton(checkboxWithTitle: "Claude セッションデータをコピー(~/.claude/projects)", target: nil, action: nil)
    private let launchCheckbox = NSButton(checkboxWithTitle: "作成後にセッションを起動", target: nil, action: nil)
    private let createButton = NSButton(title: "作成して起動", target: nil, action: nil)
    private let launchPresetName: String

    init(
        form: NewWorktreeFormModel,
        launchPresetName: String,
        onCommit: @escaping (NewWorktreeRequest) -> Void
    ) {
        self.form = form
        self.launchPresetName = launchPresetName
        self.onCommit = onCommit
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

        let title = NSTextField(labelWithString: "新規 worktree — \(form.repository.name)")
        title.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(title)

        stack.addArrangedSubview(fieldLabel("ブランチ名"))
        branchField.placeholderString = "feat/palette"
        branchField.target = self
        branchField.action = #selector(formChanged)
        // 入力のたびにプレビューを更新するため delegate も使う。
        branchField.delegate = self
        stack.addArrangedSubview(branchField)

        stack.addArrangedSubview(fieldLabel("ベースブランチ"))
        basePopup.addItem(withTitle: "(現在の HEAD)")
        for branch in form.availableBranches {
            let suffix = branch.kind == .remote ? " (remote)" : ""
            basePopup.addItem(withTitle: branch.name + suffix)
        }
        basePopup.target = self
        basePopup.action = #selector(formChanged)
        stack.addArrangedSubview(basePopup)

        stack.addArrangedSubview(fieldLabel("作成先テンプレート(その場上書き可)"))
        pathField.stringValue = form.defaultPathTemplate.raw
        pathField.target = self
        pathField.action = #selector(formChanged)
        pathField.delegate = self
        stack.addArrangedSubview(pathField)

        pathPreviewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathPreviewLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(pathPreviewLabel)

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        stack.addArrangedSubview(errorLabel)

        copyCheckbox.state = form.copySessionData ? .on : .off
        copyCheckbox.target = self
        copyCheckbox.action = #selector(formChanged)
        stack.addArrangedSubview(copyCheckbox)

        launchCheckbox.state = .on
        launchCheckbox.title = "作成後にセッションを起動: \(launchPresetName)"
        launchCheckbox.target = self
        launchCheckbox.action = #selector(formChanged)
        stack.addArrangedSubview(launchCheckbox)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(didCancel))
        cancel.keyEquivalent = "\u{1b}"
        createButton.target = self
        createButton.action = #selector(didCommit)
        createButton.keyEquivalent = "\r"
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(createButton)
        stack.addArrangedSubview(buttons)

        for field in [branchField, pathField] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        }

        view = stack
        syncFromForm()
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - Form sync

    @objc private func formChanged() {
        readIntoForm()
        syncFromForm()
    }

    private func readIntoForm() {
        form.branchName = branchField.stringValue
        let baseIndex = basePopup.indexOfSelectedItem
        if baseIndex > 0, form.availableBranches.indices.contains(baseIndex - 1) {
            let branch = form.availableBranches[baseIndex - 1]
            form.baseBranchName = branch.name
            form.sourceMode = .newBranch
        } else {
            form.baseBranchName = nil
        }
        let template = pathField.stringValue
        form.pathTemplateOverride = template == form.defaultPathTemplate.raw ? nil : template
        form.copySessionData = copyCheckbox.state == .on
        form.launchSessionPresetName = launchCheckbox.state == .on ? launchPresetName : nil
    }

    private func syncFromForm() {
        if let preview = form.pathPreview {
            pathPreviewLabel.stringValue = "→ \(preview)"
        } else {
            pathPreviewLabel.stringValue = ""
        }
        if form.branchName.isEmpty {
            errorLabel.stringValue = ""
        } else if let error = form.branchNameError {
            errorLabel.stringValue = "ブランチ名: \(error)"
        } else if form.hasPathCollision {
            errorLabel.stringValue = "作成先パスが既存の worktree と衝突しています"
        } else {
            errorLabel.stringValue = ""
        }
        createButton.isEnabled = form.isValid
    }

    // MARK: - Actions

    @objc private func didCancel() {
        dismissSheet()
    }

    @objc private func didCommit() {
        readIntoForm()
        guard let request = form.buildRequest() else {
            NSSound.beep()
            return
        }
        dismissSheet()
        onCommit(request)
    }

    private func dismissSheet() {
        if let sheetWindow = view.window, let parent = sheetWindow.sheetParent {
            parent.endSheet(sheetWindow)
        }
    }
}

extension NewWorktreeSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        formChanged()
    }
}
