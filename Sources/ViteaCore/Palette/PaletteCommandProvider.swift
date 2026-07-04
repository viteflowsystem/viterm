import Foundation

/// 現在のアプリ状態(`SidebarViewModel.repositories` 相当のツリー)から、
/// コマンドパレットに列挙する `PaletteCommand` を動的に生成する。
/// docs/ui-mock.html の Screen 02 に準拠: Worktree(新規作成/切替/マージ/削除)、
/// Session(プリセット起動)、Repo(追加)。
public enum PaletteCommandProvider {
    /// - Parameters:
    ///   - repositories: サイドバーのツリー(`SidebarViewModel.repositories`)。
    ///   - presets: 現在利用可能なセッションプリセット一覧(`ViteaConfig.presets`)。
    ///   - defaultPresetName: 既定プリセット名(`ViteaConfig.defaultPreset`)。
    ///     このプリセットのセッション起動コマンドにのみ `⌘T` のキーボードヒントを付ける
    ///     (docs/ui-mock.html で claude だけに ⌘T が付いているのと同じ扱い)。
    ///   - currentWorktreeID: 現在アクティブな worktree(= ターミナルペインで表示中の worktree)の ID。
    ///     マージ・削除・セッション起動は「この worktree」に対する操作なので、
    ///     これが `nil` またはツリー内に存在しない場合はそれらのコマンドを生成しない。
    ///   - mergeTargetBranch: マージ先ブランチの表示名(例: `"main"`)。
    ///     現在の `Worktree` モデルは実際のベースブランチを保持していないため、
    ///     呼び出し側が共通の既定値を渡す暫定対応。worktree ごとの実ベースブランチ追跡が
    ///     必要になった時点で `Worktree` 側の拡張を検討する。
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

    /// `↑3 ↓1` のような ahead/behind 表示。0 の側は表示しない。両方0なら `nil`。
    private static func aheadBehindLabel(_ worktree: Worktree) -> String? {
        var parts: [String] = []
        if worktree.ahead > 0 { parts.append("↑\(worktree.ahead)") }
        if worktree.behind > 0 { parts.append("↓\(worktree.behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
