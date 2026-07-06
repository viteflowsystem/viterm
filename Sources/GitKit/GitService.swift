import Foundation

/// High-level API bundling git worktree / branch operations.
///
/// Every method launches a real `git` process via `GitRunner` (libgit2 is not used).
/// UI-independent. The caller (VitermApp) handles threading and error handling.
public struct GitService: Sendable {
    public let runner: GitRunner

    public init(runner: GitRunner = GitRunner()) {
        self.runner = runner
    }

    // MARK: - Worktree

    /// Runs and parses `git worktree list --porcelain`.
    public func worktrees(in repository: URL) async throws -> [Worktree] {
        let output = try await runner.run(["worktree", "list", "--porcelain"], in: repository)
        return Self.parseWorktreeList(output)
    }

    /// Adds a new worktree. Depending on `source`, switches between three patterns:
    /// new branch / existing local branch / tracking a remote branch. Creates the parent
    /// directory if it does not exist (to handle cases where the `{branch_raw}` template
    /// produces a subdirectory).
    public func addWorktree(
        in repository: URL,
        path: URL,
        source: WorktreeSource,
        timeout: TimeInterval? = nil
    ) async throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var args = ["worktree", "add"]
        switch source {
        case let .newBranch(name, startPoint):
            args += ["-b", name, path.path]
            if let startPoint {
                args.append(startPoint)
            }
        case let .existingLocalBranch(name):
            args += [path.path, name]
        case let .remoteBranch(remote, name, newLocalName):
            let localName = newLocalName ?? name
            args += ["--track", "-b", localName, path.path, "\(remote)/\(name)"]
        }

        try await runner.run(args, in: repository, timeout: timeout)
    }

    /// Removes a worktree. When `force == false`, first runs a dirty check via `status --porcelain`,
    /// and if changes remain, throws `GitServiceError.worktreeDirty` without running the git command.
    public func removeWorktree(at path: URL, in repository: URL, force: Bool = false) async throws {
        if !force {
            let dirty = try await isDirty(at: path)
            if dirty {
                throw GitServiceError.worktreeDirty(path: path)
            }
        }

        var args = ["worktree", "remove"]
        if force {
            args.append("--force")
        }
        args.append(path.path)
        try await runner.run(args, in: repository)
    }

    // MARK: - Branch

    /// Returns the list of local/remote branches (excluding symbolic refs like `origin/HEAD`).
    public func branches(in repository: URL) async throws -> [Branch] {
        let output = try await runner.run(
            ["for-each-ref", "--format=%(refname)", "refs/heads/", "refs/remotes/"],
            in: repository
        )
        return output
            .split(separator: "\n")
            .compactMap { line -> Branch? in
                let ref = String(line)
                if ref.hasPrefix("refs/heads/") {
                    return Branch(name: String(ref.dropFirst("refs/heads/".count)), kind: .local)
                }
                if ref.hasPrefix("refs/remotes/") {
                    let name = String(ref.dropFirst("refs/remotes/".count))
                    guard !name.hasSuffix("/HEAD") else { return nil }
                    return Branch(name: name, kind: .remote)
                }
                return nil
            }
    }

    /// Returns ahead/behind of `branch` relative to `upstream`.
    public func aheadBehind(branch: String, upstream: String, in repository: URL) async throws -> AheadBehind {
        let command = "rev-list --left-right --count \(upstream)...\(branch)"
        let output = try await runner.run(
            ["rev-list", "--left-right", "--count", "\(upstream)...\(branch)"],
            in: repository
        )
        let parts = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2, let behindCount = Int(parts[0]), let aheadCount = Int(parts[1]) else {
            throw GitServiceError.unexpectedOutput(command: command, output: output)
        }
        return AheadBehind(ahead: aheadCount, behind: behindCount)
    }

    /// Returns diff statistics for the working tree. If `ref` is given, runs `git diff --shortstat <ref>`
    /// (e.g. line counts of the diff against the parent branch); if omitted, it is the diff of the
    /// working tree vs the index. The dirty check is always done via `status --porcelain`
    /// (which also detects untracked files).
    public func diffStat(at worktreePath: URL, comparedTo ref: String? = nil) async throws -> DiffStat {
        var args = ["diff", "--shortstat"]
        if let ref {
            args.append(ref)
        }
        let output = try await runner.run(args, in: worktreePath)
        let stat = Self.parseShortstat(output)
        let dirty = try await isDirty(at: worktreePath)
        return DiffStat(
            filesChanged: stat.files,
            insertions: stat.insertions,
            deletions: stat.deletions,
            isDirty: dirty
        )
    }

    /// Whether `git status --porcelain` is non-empty (uncommitted changes, including untracked files).
    public func isDirty(at worktreePath: URL) async throws -> Bool {
        let output = try await runner.run(["status", "--porcelain"], in: worktreePath)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Determines whether staged / unstaged changes exist from the XY columns of `git status --porcelain`.
    /// Untracked (`??`) counts as unstaged.
    public func workingState(at worktreePath: URL) async throws -> WorkingState {
        let output = try await runner.run(["status", "--porcelain"], in: worktreePath)
        return Self.parseWorkingState(output)
    }

    static func parseWorkingState(_ porcelainOutput: String) -> WorkingState {
        var staged = false
        var unstaged = false
        for line in porcelainOutput.split(separator: "\n") where line.count >= 2 {
            let x = line[line.startIndex]
            let y = line[line.index(after: line.startIndex)]
            if x == "?" {
                unstaged = true
                continue
            }
            if x != " " { staged = true }
            if y != " " { unstaged = true }
        }
        return WorkingState(hasStagedChanges: staged, hasUnstagedChanges: unstaged)
    }

    // MARK: - Merge

    /// Performs a merge/rebase between worktrees.
    ///
    /// With worktrees, each branch is already checked out in its own worktree, so no
    /// "checkout of another branch" is done — `merge`/`rebase` runs directly in the relevant
    /// worktree directory (`git checkout` would fail if the same branch is checked out in
    /// another worktree).
    ///
    /// - `.merge`: runs `git merge <arguments> <source>` in `targetWorktree`.
    /// - `.rebase`: runs `git rebase <target>` in `sourceWorktree`, then
    ///   `git merge --ff-only <source>` in `targetWorktree`.
    public func merge(
        source: String,
        target: String,
        sourceWorktree: URL,
        targetWorktree: URL,
        strategy: MergeStrategy = .merge()
    ) async throws {
        switch strategy {
        case let .merge(arguments):
            // --no-edit: prevents launching an editor for the merge commit message (headless execution is assumed).
            try await runner.run(["merge"] + arguments + ["--no-edit", source], in: targetWorktree)
        case .rebase:
            try await runner.run(["rebase", target], in: sourceWorktree)
            try await runner.run(["merge", "--ff-only", source], in: targetWorktree)
        }
    }

    // MARK: - Default branch

    /// Detects the default branch. Priority:
    /// 1. `git symbolic-ref --short refs/remotes/origin/HEAD` (set at clone time or via `git remote set-head`)
    /// 2. `main` or `master` if it exists locally
    /// 3. The branch the current HEAD points to
    public func defaultBranch(in repository: URL) async throws -> String {
        if let output = try? await runner.run(
            ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            in: repository
        ) {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("origin/") {
                return String(trimmed.dropFirst("origin/".count))
            }
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        for candidate in ["main", "master"] {
            if (try? await runner.run(["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"], in: repository)) != nil {
                return candidate
            }
        }

        let head = try await runner.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repository)
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parsing

    static func parseWorktreeList(_ output: String) -> [Worktree] {
        var result: [Worktree] = []

        var path: URL?
        var head = ""
        var branchRef: String?
        var isBare = false
        var isDetached = false
        var isLocked = false
        var isPrunable = false

        func flush() {
            guard let currentPath = path else { return }
            result.append(
                Worktree(
                    path: currentPath,
                    branch: branchRef.map(shortBranchName),
                    head: head,
                    isBare: isBare,
                    isDetached: isDetached,
                    isLocked: isLocked,
                    isPrunable: isPrunable
                )
            )
            path = nil
            head = ""
            branchRef = nil
            isBare = false
            isDetached = false
            isLocked = false
            isPrunable = false
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("worktree ") {
                flush()
                path = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                branchRef = String(line.dropFirst("branch ".count))
            } else if line == "bare" {
                isBare = true
            } else if line == "detached" {
                isDetached = true
            } else if line.hasPrefix("locked") {
                isLocked = true
            } else if line.hasPrefix("prunable") {
                isPrunable = true
            }
        }
        flush()

        return result
    }

    private static func shortBranchName(_ ref: String) -> String {
        guard ref.hasPrefix("refs/heads/") else { return ref }
        return String(ref.dropFirst("refs/heads/".count))
    }

    static func parseShortstat(_ output: String) -> (files: Int, insertions: Int, deletions: Int) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (0, 0, 0) }

        var files = 0
        var insertions = 0
        var deletions = 0

        for part in trimmed.split(separator: ",") {
            let tokens = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard let first = tokens.first, let number = Int(first) else { continue }
            if part.contains("file") {
                files = number
            } else if part.contains("insertion") {
                insertions = number
            } else if part.contains("deletion") {
                deletions = number
            }
        }

        return (files, insertions, deletions)
    }
}
