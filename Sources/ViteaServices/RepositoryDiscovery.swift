import Foundation
import ViteaCore

/// 指定ルートディレクトリ配下の git リポジトリを自動検出する
/// (ccmanager の `CCMANAGER_MULTI_PROJECT_ROOT` 相当)。
///
/// あるディレクトリが「リポジトリ本体」と判定されるのは `<dir>/.git` が **ディレクトリ** の場合のみ。
/// worktree のチェックアウト先は `.git` が `gitdir: …` を指す **ファイル** になっているため、
/// リポジトリとしては検出しない(サイドバーへの登録はリポジトリ本体のみで、その worktree 一覧は
/// `WorktreeStatusScanner` が別途 `git worktree list` から得る)。
///
/// 走査は同期処理(ファイルシステム I/O のみで git コマンドは呼ばない)。ルート配下が大きい場合は
/// 呼び出し側で `Task.detached` 等に包んでメインスレッドをブロックしないようにすること。
public struct RepositoryDiscovery: Sendable {
    /// ルートから何階層下まで走査するか(ルート自身は 0)。
    public var maxDepth: Int
    /// この名前のディレクトリには降りない(大小文字区別)。
    public var excludedDirectoryNames: Set<String>

    public init(
        maxDepth: Int = 4,
        excludedDirectoryNames: Set<String> = RepositoryDiscovery.defaultExcludedDirectoryNames
    ) {
        self.maxDepth = maxDepth
        self.excludedDirectoryNames = excludedDirectoryNames
    }

    public static let defaultExcludedDirectoryNames: Set<String> = [
        "node_modules", "vendor", "Pods", "DerivedData",
        "dist", "build", "target", "__pycache__",
    ]

    /// `rootDirectory` 配下を走査し、見つかったリポジトリを `ViteaCore.Repository` の配列で返す。
    /// リポジトリが見つかったディレクトリの内部はそれ以上降りない
    /// (ネストした vendor 済みリポジトリ等を誤登録しないため)。
    public func discover(rootDirectory: URL) -> [ViteaCore.Repository] {
        var results: [ViteaCore.Repository] = []
        scan(directory: rootDirectory, depth: 0, into: &results)
        return results
    }

    private func scan(directory: URL, depth: Int, into results: inout [ViteaCore.Repository]) {
        switch Self.gitKind(of: directory) {
        case .repository:
            results.append(ViteaCore.Repository(name: directory.lastPathComponent, path: directory.path))
            return
        case .worktreeCheckout, .none:
            break
        }

        guard depth < maxDepth else { return }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard !excludedDirectoryNames.contains(entry.lastPathComponent) else { continue }
            scan(directory: entry, depth: depth + 1, into: &results)
        }
    }

    private enum GitKind {
        /// `.git` がディレクトリ = リポジトリ本体。
        case repository
        /// `.git` がファイル(`gitdir: …`)= worktree のチェックアウト先。
        case worktreeCheckout
        case none
    }

    private static func gitKind(of directory: URL) -> GitKind {
        let gitPath = directory.appendingPathComponent(".git").path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) else { return .none }
        return isDirectory.boolValue ? .repository : .worktreeCheckout
    }
}
