import AppKit

/// Settings window (⌘,). Standard macOS toolbar-switching style (NSTabViewController
/// .toolbar); panes are added as SettingsPane subclasses (extensibility first; see
/// SettingsPanes.swift). Changes save to config.json immediately and trigger the
/// app-side config reload.
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(store: SettingsStore) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        // Pane list. To add one, append a line here.
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
        window.title = "viterm 設定"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        // Match the selected pane's content size from the initial display (subsequent
        // resize on tab switches is done by NSTabViewController via preferredContentSize).
        if let first = panes.first?.pane {
            first.loadViewIfNeeded()
            window.setContentSize(first.preferredContentSize)
        }
        self.init(window: window)
        window.center()
    }
}
