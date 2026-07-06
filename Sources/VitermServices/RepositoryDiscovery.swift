import Foundation
import VitermCore

/// Auto-discovers git repositories under a given root directory
/// (equivalent to ccmanager's `CCMANAGER_MULTI_PROJECT_ROOT`).
///
/// A directory is judged to be a "main repository" only when `<dir>/.git` is a **directory**.
/// Worktree checkouts have a `.git` **file** pointing at `gitdir: …`, so they are not detected
/// as repositories (only main repositories are registered in the sidebar; their worktree lists
/// are obtained separately by `WorktreeStatusScanner` from `git worktree list`).
///
/// The scan is synchronous (filesystem I/O only; no git commands are invoked). If the tree under
/// the root is large, the caller should wrap it in `Task.detached` or similar so the main thread
/// is not blocked.
public struct RepositoryDiscovery: Sendable {
    /// How many levels below the root to scan (the root itself is 0).
    public var maxDepth: Int
    /// Directories with these names are not descended into (case-sensitive).
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

    /// Scans under `rootDirectory` and returns the repositories found as an array of `VitermCore.Repository`.
    /// Does not descend further inside a directory where a repository was found
    /// (to avoid mistakenly registering nested vendored repositories, etc.).
    public func discover(rootDirectory: URL) -> [VitermCore.Repository] {
        var results: [VitermCore.Repository] = []
        scan(directory: rootDirectory, depth: 0, into: &results)
        return results
    }

    private func scan(directory: URL, depth: Int, into results: inout [VitermCore.Repository]) {
        switch Self.gitKind(of: directory) {
        case .repository:
            results.append(VitermCore.Repository(name: directory.lastPathComponent, path: directory.path))
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
        /// `.git` is a directory = main repository.
        case repository
        /// `.git` is a file (`gitdir: …`) = a worktree checkout.
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
