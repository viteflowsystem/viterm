import Foundation

/// Template expansion for the worktree destination path.
///
/// Example: `~/worktrees/{project}/{branch}_suffix`
/// Placeholders:
/// - `{project}`: repository name
/// - `{branch}`: branch name (`/` normalized to `-`, e.g. `feat/x` → `feat-x`)
/// - `{branch_raw}`: branch name as-is (`feat/x` becomes a subdirectory)
///
/// A leading `~` resolves relative to the home directory, a leading `/` is taken as an
/// absolute path as-is, and anything else resolves as a path relative to `repositoryRoot`.
public struct WorktreePathTemplate: Sendable, Equatable {
    public var raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    /// Context needed for expansion.
    public struct Context: Sendable, Equatable {
        /// Repository name substituted into `{project}`.
        public var projectName: String
        /// Branch name substituted into `{branch}` / `{branch_raw}` (raw form, may contain `/`).
        public var branch: String
        /// Absolute path of the repository root that relative path templates resolve against.
        public var repositoryRoot: String

        public init(projectName: String, branch: String, repositoryRoot: String) {
            self.projectName = projectName
            self.branch = branch
            self.repositoryRoot = repositoryRoot
        }
    }

    /// Expand the template into an actual path string.
    /// - Parameters:
    ///   - context: Info used for placeholder and relative-path resolution.
    ///   - homeDirectory: Home directory used for `~` expansion (injectable for tests; defaults to the real home).
    public func expand(
        context: Context,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let normalizedBranch = context.branch.replacingOccurrences(of: "/", with: "-")
        let substituted = raw
            .replacingOccurrences(of: "{branch_raw}", with: context.branch)
            .replacingOccurrences(of: "{branch}", with: normalizedBranch)
            .replacingOccurrences(of: "{project}", with: context.projectName)

        if substituted == "~" {
            return homeDirectory
        }
        if substituted.hasPrefix("~/") {
            return homeDirectory + substituted.dropFirst(1)
        }
        if substituted.hasPrefix("/") {
            return substituted
        }
        // Relative path: resolve against the repository root.
        let trimmedRoot = context.repositoryRoot.hasSuffix("/")
            ? String(context.repositoryRoot.dropLast())
            : context.repositoryRoot
        return trimmedRoot + "/" + substituted
    }
}
