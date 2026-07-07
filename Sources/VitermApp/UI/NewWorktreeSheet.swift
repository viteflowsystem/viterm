import AppKit
import GitKit
import VitermCore

/// New-worktree sheet (T10). Per docs/ui-mock.html Screen 03.
/// The brains are in VitermCore.NewWorktreeFormModel; this class is only the mapping onto AppKit.
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

    private enum Layout {
        static let contentWidth: CGFloat = 440
        static let horizontalInset: CGFloat = 24
        static let fieldWidth: CGFloat = contentWidth - horizontalInset * 2
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: Layout.horizontalInset, bottom: 18, right: Layout.horizontalInset)

        let title = NSTextField(labelWithString: "新規 worktree — \(form.repository.name)")
        title.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(title)

        branchField.placeholderString = "feat/palette"
        branchField.font = .systemFont(ofSize: 13)
        branchField.target = self
        branchField.action = #selector(formChanged)
        branchField.delegate = self
        stack.addArrangedSubview(fieldGroup(label: "ブランチ名", control: branchField))

        // Errors (branch name / path collision) sit directly beneath the branch name field.
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        basePopup.addItem(withTitle: "(現在の HEAD)")
        for branch in form.availableBranches {
            let suffix = branch.kind == .remote ? " (remote)" : ""
            basePopup.addItem(withTitle: branch.name + suffix)
        }
        basePopup.target = self
        basePopup.action = #selector(formChanged)
        stack.addArrangedSubview(fieldGroup(label: "ベースブランチ", control: basePopup))

        pathField.stringValue = form.defaultPathTemplate.raw
        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.target = self
        pathField.action = #selector(formChanged)
        pathField.delegate = self
        pathPreviewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathPreviewLabel.textColor = .secondaryLabelColor
        pathPreviewLabel.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(fieldGroup(
            label: "作成先テンプレート(その場上書き可)",
            control: pathField,
            caption: pathPreviewLabel
        ))

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

        // The button row stretches to full width and right-aligns.
        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(didCancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        createButton.title = "作成して起動"
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(didCommit)
        let buttons = NSStackView(views: [NSView(), cancel, createButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.setHuggingPriority(.defaultLow, for: .horizontal)
        buttons.widthAnchor.constraint(equalToConstant: Layout.fieldWidth).isActive = true
        stack.addArrangedSubview(buttons)

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
        ])
        view = container
        syncFromForm()
    }

    /// One fixed-width group stacking label + control (+ optional caption) vertically.
    private func fieldGroup(label text: String, control: NSView, caption: NSView? = nil) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: Layout.fieldWidth).isActive = true

        let views = [label, control] + (caption.map { [$0] } ?? [])
        let group = NSStackView(views: views)
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 5
        return group
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
        pathPreviewLabel.stringValue = form.pathPreview.map { "→ \($0)" } ?? ""

        let error: String?
        if form.branchName.isEmpty {
            error = nil
        } else if let branchError = form.branchNameError {
            error = "ブランチ名: \(branchError)"
        } else if form.hasPathCollision {
            error = "作成先パスが既存の worktree と衝突しています"
        } else {
            error = nil
        }
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = (error == nil)

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
