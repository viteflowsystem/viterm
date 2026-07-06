import Foundation
import Testing
@testable import GitKit

// MARK: - Parsing (pure logic, no git required)

@Test func parseWorktreeList_parsesMultipleEntriesIncludingDetached() {
    let output = """
    worktree /tmp/repo
    HEAD abc123
    branch refs/heads/main

    worktree /tmp/repo-detached
    HEAD def456
    detached

    """
    let worktrees = GitService.parseWorktreeList(output)
    #expect(worktrees.count == 2)
    #expect(worktrees[0].path.path == "/tmp/repo")
    #expect(worktrees[0].branch == "main")
    #expect(worktrees[0].head == "abc123")
    #expect(worktrees[1].branch == nil)
    #expect(worktrees[1].isDetached == true)
}

@Test func parseShortstat_parsesFilesInsertionsDeletions() {
    let stat = GitService.parseShortstat(" 3 files changed, 10 insertions(+), 5 deletions(-)")
    #expect(stat.files == 3)
    #expect(stat.insertions == 10)
    #expect(stat.deletions == 5)
}

@Test func parseShortstat_emptyOutputReturnsZero() {
    let stat = GitService.parseShortstat("")
    #expect(stat == (0, 0, 0))
}

// MARK: - GitRunner

@Test func gitRunner_commandFailed_carriesStderr() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)

        do {
            try await Fixture.runner.run(["branch", "--this-flag-does-not-exist"], in: repo)
            Issue.record("expected GitError.commandFailed to be thrown")
        } catch let error as GitError {
            guard case let .commandFailed(_, exitCode, _, stderr) = error else {
                Issue.record("expected .commandFailed, got \(error)")
                return
            }
            #expect(exitCode != 0)
            #expect(!stderr.isEmpty)
        }
    }
}

@Test func gitRunner_timesOutOnHangingProcess() async throws {
    try await withTemporaryDirectory { dir in
        let scriptURL = dir.appendingPathComponent("slow-git")
        // Using exec makes sleep a direct child of Process, so terminate() reliably takes effect.
        let script = "#!/bin/sh\nexec sleep 5\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let runner = GitRunner(executableURL: scriptURL)
        do {
            try await runner.run(["status"], in: dir, timeout: 0.2)
            Issue.record("expected GitError.timedOut to be thrown")
        } catch let error as GitError {
            guard case .timedOut = error else {
                Issue.record("expected .timedOut, got \(error)")
                return
            }
        }
    }
}

// MARK: - worktrees(in:)

@Test func worktrees_returnsMainWorktreeWithBranch() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        let worktrees = try await service.worktrees(in: repo)

        #expect(worktrees.count == 1)
        #expect(worktrees[0].branch == "main")
        #expect(worktrees[0].path.resolvingSymlinksInPath() == repo.resolvingSymlinksInPath())
    }
}

// MARK: - addWorktree

@Test func addWorktree_newBranch_createsWorktreeAndLocalBranch() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        // Also covers the case where the path becomes a subdirectory, as with the {branch_raw} template.
        let wtPath = dir.appendingPathComponent("worktrees/feature-x")
        try await service.addWorktree(in: repo, path: wtPath, source: .newBranch(name: "feature-x"))

        let worktrees = try await service.worktrees(in: repo)
        #expect(worktrees.count == 2)
        #expect(worktrees.contains { $0.branch == "feature-x" })

        let branches = try await service.branches(in: repo)
        #expect(branches.contains(Branch(name: "feature-x", kind: .local)))
    }
}

@Test func addWorktree_existingLocalBranch_checksOutWorktree() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        try await service.runner.run(["branch", "existing"], in: repo)

        let wtPath = dir.appendingPathComponent("worktrees/existing")
        try await service.addWorktree(in: repo, path: wtPath, source: .existingLocalBranch(name: "existing"))

        let worktrees = try await service.worktrees(in: repo)
        #expect(worktrees.contains { $0.branch == "existing" })
    }
}

@Test func addWorktree_remoteBranch_createsTrackingLocalBranch() async throws {
    try await withTemporaryDirectory { dir in
        let (repo, _) = try await Fixture.makeRepositoryWithRemote(in: dir)
        let service = GitService()

        let wtPath = dir.appendingPathComponent("worktrees/feature")
        try await service.addWorktree(
            in: repo,
            path: wtPath,
            source: .remoteBranch(remote: "origin", name: "feature", newLocalName: nil)
        )

        let worktrees = try await service.worktrees(in: repo)
        #expect(worktrees.contains { $0.branch == "feature" })

        let upstream = try await service.runner.run(
            ["rev-parse", "--abbrev-ref", "feature@{upstream}"],
            in: wtPath
        )
        #expect(upstream.trimmingCharacters(in: .whitespacesAndNewlines) == "origin/feature")
    }
}

// MARK: - removeWorktree

@Test func removeWorktree_clean_succeeds() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        let wtPath = dir.appendingPathComponent("worktrees/feature-x")
        try await service.addWorktree(in: repo, path: wtPath, source: .newBranch(name: "feature-x"))

        try await service.removeWorktree(at: wtPath, in: repo)

        let worktrees = try await service.worktrees(in: repo)
        #expect(worktrees.count == 1)
    }
}

@Test func removeWorktree_dirty_throwsWithoutForce() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        let wtPath = dir.appendingPathComponent("worktrees/feature-x")
        try await service.addWorktree(in: repo, path: wtPath, source: .newBranch(name: "feature-x"))
        try "dirty\n".write(to: wtPath.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        do {
            try await service.removeWorktree(at: wtPath, in: repo)
            Issue.record("expected GitServiceError.worktreeDirty to be thrown")
        } catch let error as GitServiceError {
            guard case .worktreeDirty = error else {
                Issue.record("expected .worktreeDirty, got \(error)")
                return
            }
        }

        // Since force was not used, the worktree still remains.
        let worktrees = try await service.worktrees(in: repo)
        #expect(worktrees.count == 2)
    }
}

@Test func removeWorktree_dirty_succeedsWithForce() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        let wtPath = dir.appendingPathComponent("worktrees/feature-x")
        try await service.addWorktree(in: repo, path: wtPath, source: .newBranch(name: "feature-x"))
        try "dirty\n".write(to: wtPath.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        try await service.removeWorktree(at: wtPath, in: repo, force: true)

        let worktrees = try await service.worktrees(in: repo)
        #expect(worktrees.count == 1)
    }
}

// MARK: - branches(in:)

@Test func branches_listsLocalAndRemoteExcludingSymbolicHead() async throws {
    try await withTemporaryDirectory { dir in
        let (repo, _) = try await Fixture.makeRepositoryWithRemote(in: dir)
        let service = GitService()

        let branches = try await service.branches(in: repo)
        let names = Set(branches.map(\.name))

        #expect(names.contains("main"))
        #expect(branches.contains(Branch(name: "origin/main", kind: .remote)))
        #expect(branches.contains(Branch(name: "origin/feature", kind: .remote)))
        #expect(!names.contains("origin/HEAD"))
    }
}

// MARK: - aheadBehind

@Test func aheadBehind_reportsAheadAndBehindCounts() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        try await service.runner.run(["checkout", "-b", "feature"], in: repo)
        try await Fixture.commitFile(named: "a.txt", content: "a\n", message: "add a", in: repo)
        try await Fixture.commitFile(named: "b.txt", content: "b\n", message: "add b", in: repo)

        try await service.runner.run(["checkout", "main"], in: repo)
        try await Fixture.commitFile(named: "c.txt", content: "c\n", message: "advance main", in: repo)

        let result = try await service.aheadBehind(branch: "feature", upstream: "main", in: repo)
        #expect(result.ahead == 2)
        #expect(result.behind == 1)
    }
}

// MARK: - diffStat / isDirty

@Test func diffStat_reportsInsertionsAgainstBaseBranch() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        try await service.runner.run(["checkout", "-b", "feature"], in: repo)
        try await Fixture.commitFile(named: "a.txt", content: "line1\nline2\nline3\n", message: "add a", in: repo)

        let stat = try await service.diffStat(at: repo, comparedTo: "main")
        #expect(stat.filesChanged == 1)
        #expect(stat.insertions == 3)
        #expect(stat.deletions == 0)
        #expect(stat.isDirty == false)
    }
}

@Test func isDirty_detectsUntrackedFile() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        #expect(try await service.isDirty(at: repo) == false)

        try "new\n".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        #expect(try await service.isDirty(at: repo) == true)
    }
}

// MARK: - merge

@Test func merge_noFF_createsMergeCommitInTargetWorktree() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        let featurePath = dir.appendingPathComponent("worktrees/feature")
        try await service.addWorktree(in: repo, path: featurePath, source: .newBranch(name: "feature"))
        try await Fixture.commitFile(named: "feature.txt", content: "feature\n", message: "add feature", in: featurePath)

        try await service.merge(
            source: "feature",
            target: "main",
            sourceWorktree: featurePath,
            targetWorktree: repo,
            strategy: .merge()
        )

        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("feature.txt").path))

        let log = try await service.runner.run(["log", "--merges", "-1", "--pretty=%s"], in: repo)
        #expect(log.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Merge branch"))
    }
}

@Test func merge_rebase_thenFastForwardsTarget() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        let featurePath = dir.appendingPathComponent("worktrees/feature")
        try await service.addWorktree(in: repo, path: featurePath, source: .newBranch(name: "feature"))
        try await Fixture.commitFile(named: "feature.txt", content: "feature\n", message: "add feature", in: featurePath)

        // Advance only main so that feature stays based on the old main.
        try await Fixture.commitFile(named: "main-only.txt", content: "main\n", message: "advance main", in: repo)

        try await service.merge(
            source: "feature",
            target: "main",
            sourceWorktree: featurePath,
            targetWorktree: repo,
            strategy: .rebase
        )

        let mainLog = try await service.runner.run(["log", "--pretty=%H"], in: repo)
        let featureLog = try await service.runner.run(["log", "--pretty=%H"], in: featurePath)
        #expect(mainLog == featureLog)

        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("main-only.txt").path))
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("feature.txt").path))
    }
}

// MARK: - defaultBranch

@Test func defaultBranch_usesOriginHEADWhenRemotePresent() async throws {
    try await withTemporaryDirectory { dir in
        let (repo, _) = try await Fixture.makeRepositoryWithRemote(in: dir)
        let service = GitService()

        let branch = try await service.defaultBranch(in: repo)
        #expect(branch == "main")
    }
}

@Test func defaultBranch_fallsBackToLocalMainWithoutRemote() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        let branch = try await service.defaultBranch(in: repo)
        #expect(branch == "main")
    }
}

@Test func defaultBranch_fallsBackToCurrentHEADWhenNoConventionalName() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo, branch: "trunk")
        let service = GitService()

        let branch = try await service.defaultBranch(in: repo)
        #expect(branch == "trunk")
    }
}

// MARK: - parseWorkingState (pure logic, no git required)

@Test func parseWorkingState_stagedAndUnstagedColumns() {
    // X=staged, Y=unstaged, ??=untracked (treated as unstaged)
    #expect(GitService.parseWorkingState("") == WorkingState(hasStagedChanges: false, hasUnstagedChanges: false))
    #expect(GitService.parseWorkingState("M  a.txt\n") == WorkingState(hasStagedChanges: true, hasUnstagedChanges: false))
    #expect(GitService.parseWorkingState(" M a.txt\n") == WorkingState(hasStagedChanges: false, hasUnstagedChanges: true))
    #expect(GitService.parseWorkingState("MM a.txt\n") == WorkingState(hasStagedChanges: true, hasUnstagedChanges: true))
    #expect(GitService.parseWorkingState("?? new.txt\n") == WorkingState(hasStagedChanges: false, hasUnstagedChanges: true))
    #expect(GitService.parseWorkingState("A  new.txt\n?? junk\n") == WorkingState(hasStagedChanges: true, hasUnstagedChanges: true))
}
