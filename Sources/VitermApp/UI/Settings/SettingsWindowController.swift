import AppKit

/// Settings window (Cmd+,). Uses the standard macOS toolbar-switching style
/// (NSTabViewController .toolbar); panes are added as SettingsPane subclasses
/// (extensibility-focused; see SettingsPanes.swift).
/// Changes are saved to config.json immediately and trigger the app-side config reload.
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(store: SettingsStore) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        // Pane list. To add a pane, add one line here.
        let panes: [(pane: SettingsPane, icon: String)] = [
            (GeneralSettingsPane(title: L("General"), store: store), "gearshape"),
            (WorktreeSettingsPane(title: "Worktree", store: store), "arrow.triangle.branch"),
            (RepositoriesSettingsPane(title: L("Repositories"), store: store), "folder"),
            (HooksSettingsPane(title: L("Notification Hooks"), store: store), "bolt"),
        ]
        for (pane, icon) in panes {
            let item = NSTabViewItem(viewController: pane)
            item.label = pane.title ?? ""
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = L("viterm Settings")
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        // Match the selected pane's content size from the initial display
        // (subsequent resizes on tab switches are done by NSTabViewController via preferredContentSize).
        if let first = panes.first?.pane {
            first.loadViewIfNeeded()
            window.setContentSize(first.preferredContentSize)
        }
        self.init(window: window)
        window.center()
    }
}
