import AppKit

/// 設定ウィンドウ(⌘,)。macOS 標準のツールバー切替式(NSTabViewController .toolbar)で、
/// ペインは SettingsPane サブクラスとして追加する(拡張性重視。SettingsPanes.swift 参照)。
/// 変更は即時に config.json へ保存され、アプリ側の設定リロードが走る。
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(store: SettingsStore) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        // ペイン一覧。追加するときはここに1行足す。
        let panes: [(pane: SettingsPane, icon: String)] = [
            (GeneralSettingsPane(title: "一般", store: store), "gearshape"),
            (WorktreeSettingsPane(title: "Worktree", store: store), "arrow.triangle.branch"),
            (RepositoriesSettingsPane(title: "リポジトリ", store: store), "folder"),
            (HooksSettingsPane(title: "通知フック", store: store), "bolt"),
        ]
        for (pane, icon) in panes {
            let item = NSTabViewItem(viewController: pane)
            item.label = pane.title ?? ""
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "vitea 設定"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        self.init(window: window)
        window.center()
    }
}
