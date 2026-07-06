import Foundation
import GitKit
import VitermCore

/// Request to create a new worktree.
public struct WorktreeCreationRequest: Sendable {
    public var repository: VitermCore.Repository
    /// One of three patterns: new branch / existing local branch / remote branch (GitKit.WorktreeSource).
    public var source: WorktreeSource
    public var pathTemplate: WorktreePathTemplate
    /// Whether to copy Claude session data (`~/.claude/projects/…`).
    public var copySessionData: Bool
    /// Project path to copy from. If omitted, `repository.path` (the repository root) is used.
    public var copySessionDataFrom: String?
    /// Shell command for the post-creation hook to run after creation. Not run if nil/empty.
    public var postCreationHookCommand: String?

    public init(
        repository: VitermCore.Repository,
        source: WorktreeSource,
        pathTemplate: WorktreePathTemplate,
        copySessionData: Bool = false,
        copySessionDataFrom: String? = nil,
        postCreationHookCommand: String? = nil
    ) {
        self.repository = repository
        self.source = source
        self.pathTemplate = pathTemplate
        self.copySessionData = copySessionData
        self.copySessionDataFrom = copySessionDataFrom
        self.postCreationHookCommand = postCreationHookCommand
    }
}

/// Result of `createWorktree`.
public struct WorktreeCreationResult: Sendable {
    public var worktreePath: String
    public var branch: String
    /// Warnings for steps that failed non-fatally (session data copy, etc.) even though the worktree creation itself succeeded.
    public var warnings: [String]
    /// The Task for the post-creation hook, if one was launched. Callers do not need to await it
    /// (it runs asynchronously and non-blocking), but tests can wait for completion via `await hookTask?.value`.
    public var hookTask: Task<Void, Never>?

    public init(worktreePath: String, branch: String, warnings: [String] = [], hookTask: Task<Void, Never>? = nil) {
        self.worktreePath = worktreePath
        self.branch = branch
        self.warnings = warnings
        self.hookTask = hookTask
    }
}

extension WorktreeSource {
    /// The local branch name that will be checked out in the created worktree (raw form, may contain `/`).
    /// Used for expanding `{branch}` / `{branch_raw}` in path templates.
    public var localBranchName: String {
        switch self {
        case let .newBranch(name, _):
            return name
        case let .existingLocalBranch(name):
            return name
        case let .remoteBranch(_, name, newLocalName):
            return newLocalName ?? name
        }
    }
}

/// Orchestrates worktree creation: path template expansion → `GitService.addWorktree` →
/// Claude session data copy (optional, non-fatal) → post-creation hook execution (optional, async).
public struct WorktreeProvisioner: Sendable {
    public var gitService: GitService
    /// Home directory used for `~` expansion. Injectable for tests.
    public var homeDirectory: String
    /// Root of Claude session data (default `<home>/.claude/projects`). Injectable for tests.
    public var claudeProjectsDirectory: String
    public var fileExists: @Sendable (URL) -> Bool
    public var fileCopier: @Sendable (_ source: URL, _ destination: URL) throws -> Void
    /// The actual post-creation hook executor. Tests can swap this out to avoid launching a real process.
    public var hookRunner: @Sendable (_ command: String, _ environment: [String: String]) async -> Void

    public init(
        gitService: GitService = GitService(),
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        claudeProjectsDirectory: String? = nil,
        fileExists: @escaping @Sendable (URL) -> Bool = WorktreeProvisioner.defaultFileExists,
        fileCopier: @escaping @Sendable (URL, URL) throws -> Void = WorktreeProvisioner.defaultFileCopier,
        hookRunner: @escaping @Sendable (String, [String: String]) async -> Void = WorktreeProvisioner.defaultHookRunner
    ) {
        self.gitService = gitService
        self.homeDirectory = homeDirectory
        self.claudeProjectsDirectory = claudeProjectsDirectory ?? homeDirectory + "/.claude/projects"
        self.fileExists = fileExists
        self.fileCopier = fileCopier
        self.hookRunner = hookRunner
    }

    public func createWorktree(_ request: WorktreeCreationRequest) async throws -> WorktreeCreationResult {
        let branch = request.source.localBranchName
        let context = WorktreePathTemplate.Context(
            projectName: request.repository.name,
            branch: branch,
            repositoryRoot: request.repository.path
        )
        let expandedPath = request.pathTemplate.expand(context: context, homeDirectory: homeDirectory)
        let worktreeURL = URL(fileURLWithPath: expandedPath)
        let repositoryURL = URL(fileURLWithPath: request.repository.path)

        try await gitService.addWorktree(in: repositoryURL, path: worktreeURL, source: request.source)

        var warnings: [String] = []

        if request.copySessionData {
            let sourcePath = request.copySessionDataFrom ?? request.repository.path
            do {
                try copyClaudeSessionData(from: sourcePath, to: expandedPath)
            } catch {
                warnings.append("Claude セッションデータのコピーに失敗しました: \(error)")
            }
        }

        var hookTask: Task<Void, Never>?
        if let command = request.postCreationHookCommand, !command.isEmpty {
            let environment: [String: String] = [
                "VITERM_WORKTREE_PATH": expandedPath,
                "VITERM_BRANCH": branch,
                "VITERM_GIT_ROOT": request.repository.path,
            ]
            let runHook = hookRunner
            hookTask = Task {
                await runHook(command, environment)
            }
        }

        return WorktreeCreationResult(worktreePath: expandedPath, branch: branch, warnings: warnings, hookTask: hookTask)
    }

    /// Copies `~/.claude/projects/<encoded path>` for the new worktree.
    /// If the copy source does not exist (no Claude Code usage history for that project path yet),
    /// does nothing (this is a normal, expected case rather than a failure, so no warning is emitted).
    private func copyClaudeSessionData(from sourcePath: String, to destinationPath: String) throws {
        let root = URL(fileURLWithPath: claudeProjectsDirectory)
        let source = root.appendingPathComponent(Self.encodeProjectPath(sourcePath))
        guard fileExists(source) else { return }
        let destination = root.appendingPathComponent(Self.encodeProjectPath(destinationPath))
        try fileCopier(source, destination)
    }

    /// Claude Code's project directory naming convention: replace `/` in the absolute path with `-`.
    /// Example: `/Users/foo/repo` → `-Users-foo-repo`
    static func encodeProjectPath(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    public static let defaultFileExists: @Sendable (URL) -> Bool = { url in
        FileManager.default.fileExists(atPath: url.path)
    }

    public static let defaultFileCopier: @Sendable (URL, URL) throws -> Void = { source, destination in
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Launches the hook via `/bin/sh -c <command>` with the given env added. Termination is
    /// watched to avoid zombie processes, but the caller (`createWorktree`) does not await this
    /// Task itself, so execution is non-blocking.
    public static let defaultHookRunner: @Sendable (String, [String: String]) async -> Void = { command, environment in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        do {
            try process.run()
        } catch {
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
    }
}
