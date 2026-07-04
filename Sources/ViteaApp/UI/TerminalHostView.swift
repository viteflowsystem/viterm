import AppKit

/// 選択中セッションのサーフェスを表示するホストビュー(T8)。
///
/// サーフェスビューは破棄せず付け替える(removeFromSuperview のみ)ことで、
/// 非表示セッションのプロセスとスクロールバックを維持する。
final class TerminalHostView: NSView {
    private(set) var currentSurface: GhosttySurfaceView?
    private let placeholder = NSTextField(labelWithString: "⌘T でセッションを起動 / ⌘N で worktree を作成")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 表示するサーフェスを切り替える。nil でプレースホルダ表示。
    func show(_ surface: GhosttySurfaceView?) {
        guard surface !== currentSurface else { return }
        currentSurface?.removeFromSuperview()
        currentSurface = surface

        if let surface {
            surface.translatesAutoresizingMaskIntoConstraints = false
            addSubview(surface)
            NSLayoutConstraint.activate([
                surface.topAnchor.constraint(equalTo: topAnchor),
                surface.bottomAnchor.constraint(equalTo: bottomAnchor),
                surface.leadingAnchor.constraint(equalTo: leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            placeholder.isHidden = true
            window?.makeFirstResponder(surface)
        } else {
            placeholder.isHidden = false
        }
    }
}
