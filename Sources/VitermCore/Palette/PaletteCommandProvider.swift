import Foundation

/// Dynamically generates the `PaletteCommand`s listed in the command palette from the
/// current app state (the tree equivalent to `SidebarViewModel.repositories`).
/// Follows Screen 02 of docs/ui-mock.html: Worktree (create/switch/merge/remove),
/// Session (launch preset), Repo (add).
public enum PaletteCommandProvider {
    /// - Parameters:
    ///   - repositories: The sidebar tree (`SidebarViewModel.repositories`).
    ///   - presets: Currently available session presets (`VitermConfig.presets`).
    ///   - defaultPresetName: The default preset name (`VitermConfig.defaultPreset`).
    ///     Only this preset's session-launch command gets the `⌘T` keyboard hint
    ///     (same treatment as docs/ui-mock.html, where only claude has ⌘T).
    ///   - currentWorktreeID: ID of the currently active worktree (= the one shown in the
    ///     terminal pane). Merge, remove, and session launch operate on "this worktree",
    ///     so if this is `nil` or absent from the tree, those commands are not generated.
    ///   - mergeTargetBranch: Display name of the merge target branch (e.g. `"main"`).
    ///     The current `Worktree` model doesn't track the actual base branch, so the
    ///     caller passes a shared default as a stopgap. When per-worktree base-branch
    ///     tracking becomes necessary, consider extending `Worktree`.
    public static func commands(
        repositories: [RepositoryNode],
        presets: [SessionPreset],
        defaultPresetName: String?,
        currentWorktreeID: String?,
        mergeTargetBranch: String = "main"
    ) -> [PaletteCommand] {
        var commands: [PaletteCommand] = [
            PaletteCommand(
                id: "worktree.create",
                category: .worktree,
                title: "新規作成…",
                keyboardHint: "⌘N",
                action: .createWorktree
            ),
        ]

        for repositoryNode in repositories {
            for worktreeNode in repositoryNode.worktrees {
                let worktree = worktreeNode.worktree
                commands.append(PaletteCommand(
                    id: "worktree.switch.\(worktree.id)",
                    category: .worktree,
                    title: "\(worktree.branch) に切替",
                    subtitle: aheadBehindLabel(worktree),
                    action: .switchToWorktree(worktreeID: worktree.id)
                ))
            }
        }

        if let currentWorktreeID, containsWorktree(currentWorktreeID, in: repositories) {
            commands.append(PaletteCommand(
                id: "worktree.merge.\(currentWorktreeID)",
                category: .worktree,
                title: "\(mergeTargetBranch) にマージ…(merge / rebase)",
                action: .mergeWorktree(worktreeID: currentWorktreeID)
            ))
            commands.append(PaletteCommand(
                id: "worktree.remove.\(currentWorktreeID)",
                category: .worktree,
                title: "削除…",
                action: .removeWorktree(worktreeID: currentWorktreeID)
            ))
            for preset in presets {
                commands.append(PaletteCommand(
                    id: "session.start.\(currentWorktreeID).\(preset.name)",
                    category: .session,
                    title: "\(preset.name) を起動(この worktree)",
                    keyboardHint: preset.name == defaultPresetName ? "⌘T" : nil,
                    action: .startSession(worktreeID: currentWorktreeID, presetName: preset.name)
                ))
            }
        }

        commands.append(PaletteCommand(
            id: "repo.add",
            category: .repository,
            title: "リポジトリを追加…(ディレクトリ選択)",
            action: .addRepository
        ))

        return commands
    }

    private static func containsWorktree(_ id: String, in repositories: [RepositoryNode]) -> Bool {
        repositories.contains { $0.worktrees.contains { $0.worktree.id == id } }
    }

    /// Ahead/behind display like `↑3 ↓1`. A zero side is omitted. `nil` when both are zero.
    private static func aheadBehindLabel(_ worktree: Worktree) -> String? {
        var parts: [String] = []
        if worktree.ahead > 0 { parts.append("↑\(worktree.ahead)") }
        if worktree.behind > 0 { parts.append("↓\(worktree.behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
