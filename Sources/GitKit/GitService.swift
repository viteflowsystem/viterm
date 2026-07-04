import Foundation

/// git worktree / branch 操作をまとめた高レベル API。
///
/// すべてのメソッドは `GitRunner` 経由で実 `git` プロセスを起動する(libgit2 は使わない)。
/// UI 非依存。呼び出し側(ViteaApp)がスレッド/エラーハンドリングを扱う。
public struct GitService: Sendable {
    public let runner: GitRunner

    public init(runner: GitRunner = GitRunner()) {
        self.runner = runner
    }

    // MARK: - Worktree

    /// `git worktree list --porcelain` を実行してパースする。
    public func worktrees(in repository: URL) async throws -> [Worktree] {
        let output = try await runner.run(["worktree", "list", "--porcelain"], in: repository)
        return Self.parseWorktreeList(output)
    }

    /// worktree を新規追加する。`source` に応じて新規ブランチ/既存ローカルブランチ/リモートブランチ追跡の
    /// 3パターンを切り替える。親ディレクトリが存在しない場合は作成する
    /// (`{branch_raw}` テンプレートでサブディレクトリになるケースに対応するため)。
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

    /// worktree を削除する。`force == false` の場合は事前に `status --porcelain` で dirty チェックを行い、
    /// 変更が残っていれば `GitServiceError.worktreeDirty` を投げて git コマンドを実行しない。
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

    /// ローカル/リモートのブランチ一覧を返す(`origin/HEAD` のようなシンボリック参照は除く)。
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

    /// `branch` の `upstream` に対する ahead/behind を返す。
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

    /// 作業ツリーの diff 統計を返す。`ref` を渡すと `git diff --shortstat <ref>` を実行し
    /// (例: 親ブランチとの差分行数)、省略すると作業ツリー vs インデックスの差分になる。
    /// dirty 判定は常に `status --porcelain`(未追跡ファイルも検出)で行う。
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

    /// `git status --porcelain` が非空かどうか(未コミットの変更 = 未追跡ファイルも含む)。
    public func isDirty(at worktreePath: URL) async throws -> Bool {
        let output = try await runner.run(["status", "--porcelain"], in: worktreePath)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Merge

    /// worktree 間のマージ/リベースを行う。
    ///
    /// worktree では各ブランチが既にそれぞれの worktree でチェックアウト済みのため、
    /// 「別ブランチへの checkout」は行わず、対象の worktree ディレクトリで直接 `merge`/`rebase` を実行する
    /// (同一ブランチが他 worktree でチェックアウト中だと `git checkout` は失敗するため)。
    ///
    /// - `.merge`: `targetWorktree` で `git merge <arguments> <source>` を実行する。
    /// - `.rebase`: `sourceWorktree` で `git rebase <target>` した後、`targetWorktree` で
    ///   `git merge --ff-only <source>` を実行する。
    public func merge(
        source: String,
        target: String,
        sourceWorktree: URL,
        targetWorktree: URL,
        strategy: MergeStrategy = .merge()
    ) async throws {
        switch strategy {
        case let .merge(arguments):
            // --no-edit: マージコミットメッセージ入力のためのエディタ起動を防ぐ(ヘッドレス実行前提のため)。
            try await runner.run(["merge"] + arguments + ["--no-edit", source], in: targetWorktree)
        case .rebase:
            try await runner.run(["rebase", target], in: sourceWorktree)
            try await runner.run(["merge", "--ff-only", source], in: targetWorktree)
        }
    }

    // MARK: - Default branch

    /// デフォルトブランチを検出する。優先順位:
    /// 1. `git symbolic-ref --short refs/remotes/origin/HEAD`(clone 時や `git remote set-head` で設定される)
    /// 2. ローカルに `main` または `master` が存在すればそれ
    /// 3. 現在の HEAD が指すブランチ
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
