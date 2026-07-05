import Foundation
import GitKit
import Testing
import VitermCore
@testable import VitermServices

/// hookRunner / fileCopier のような @Sendable クロージャからの呼び出しを記録するためのアクター。
actor CallRecorder {
    private(set) var hookInvocations: [(command: String, environment: [String: String])] = []
    private(set) var copyInvocations: [(source: URL, destination: URL)] = []

    func recordHook(command: String, environment: [String: String]) {
        hookInvocations.append((command: command, environment: environment))
    }

    func recordCopy(source: URL, destination: URL) {
        copyInvocations.append((source: source, destination: destination))
    }
}

struct StubError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - WorktreeProvisioner

@Test func createWorktree_newBranch_expandsTemplateAndCreatesWorktree() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)

        let provisioner = WorktreeProvisioner(homeDirectory: dir.path)
        let request = WorktreeCreationRequest(
            repository: Repository(name: "demo", path: repo.path),
            source: .newBranch(name: "feature-x"),
            pathTemplate: WorktreePathTemplate("worktrees/{branch}")
        )

        let result = try await provisioner.createWorktree(request)

        #expect(result.branch == "feature-x")
        #expect(result.worktreePath == repo.path + "/worktrees/feature-x")
        #expect(result.warnings.isEmpty)
        #expect(result.hookTask == nil)

        let worktrees = try await GitService().worktrees(in: repo)
        #expect(worktrees.contains { $0.branch == "feature-x" })
    }
}

@Test func createWorktree_branchRawTemplate_createsNestedDirectoryForSlashBranch() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)

        let provisioner = WorktreeProvisioner(homeDirectory: dir.path)
        let request = WorktreeCreationRequest(
            repository: Repository(name: "demo", path: repo.path),
            source: .newBranch(name: "feat/nested"),
            pathTemplate: WorktreePathTemplate("worktrees/{branch_raw}")
        )

        let result = try await provisioner.createWorktree(request)

        #expect(result.worktreePath == repo.path + "/worktrees/feat/nested")
        #expect(FileManager.default.fileExists(atPath: result.worktreePath))

        let worktrees = try await GitService().worktrees(in: repo)
        #expect(worktrees.contains { $0.branch == "feat/nested" })
    }
}

@Test func createWorktree_copySessionData_copiesWhenSourceProjectExists() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)

        let claudeProjects = dir.appendingPathComponent("claude-projects")
        let encodedSource = repo.path.replacingOccurrences(of: "/", with: "-")
        let sourceProjectDir = claudeProjects.appendingPathComponent(encodedSource)
        try FileManager.default.createDirectory(at: sourceProjectDir, withIntermediateDirectories: true)
        try "session data".write(
            to: sourceProjectDir.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let provisioner = WorktreeProvisioner(homeDirectory: dir.path, claudeProjectsDirectory: claudeProjects.path)
        let request = WorktreeCreationRequest(
            repository: Repository(name: "demo", path: repo.path),
            source: .newBranch(name: "feature-x"),
            pathTemplate: WorktreePathTemplate("worktrees/{branch}"),
            copySessionData: true
        )

        let result = try await provisioner.createWorktree(request)

        #expect(result.warnings.isEmpty)
        let encodedDestination = result.worktreePath.replacingOccurrences(of: "/", with: "-")
        let copiedFile = claudeProjects
            .appendingPathComponent(encodedDestination)
            .appendingPathComponent("session.jsonl")
        #expect(FileManager.default.fileExists(atPath: copiedFile.path))
    }
}

@Test func createWorktree_copySessionData_missingSourceIsSkippedWithoutWarning() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)

        let claudeProjects = dir.appendingPathComponent("claude-projects-empty")

        let provisioner = WorktreeProvisioner(homeDirectory: dir.path, claudeProjectsDirectory: claudeProjects.path)
        let request = WorktreeCreationRequest(
            repository: Repository(name: "demo", path: repo.path),
            source: .newBranch(name: "feature-x"),
            pathTemplate: WorktreePathTemplate("worktrees/{branch}"),
            copySessionData: true
        )

        let result = try await provisioner.createWorktree(request)

        #expect(result.warnings.isEmpty)
    }
}

@Test func createWorktree_copySessionData_copyFailureBecomesWarningNotFatal() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)

        let provisioner = WorktreeProvisioner(
            homeDirectory: dir.path,
            claudeProjectsDirectory: dir.appendingPathComponent("claude-projects").path,
            fileExists: { _ in true },
            fileCopier: { _, _ in throw StubError(description: "copy failed") }
        )
        let request = WorktreeCreationRequest(
            repository: Repository(name: "demo", path: repo.path),
            source: .newBranch(name: "feature-x"),
            pathTemplate: WorktreePathTemplate("worktrees/{branch}"),
            copySessionData: true
        )

        // コピーに失敗しても worktree 作成自体は成功として扱われる(throw しない)。
        let result = try await provisioner.createWorktree(request)

        #expect(result.warnings.count == 1)
        #expect(result.worktreePath == repo.path + "/worktrees/feature-x")

        let worktrees = try await GitService().worktrees(in: repo)
        #expect(worktrees.contains { $0.branch == "feature-x" })
    }
}

@Test func createWorktree_postCreationHook_runsAsynchronouslyWithExpectedEnvironment() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)

        let recorder = CallRecorder()
        let provisioner = WorktreeProvisioner(
            homeDirectory: dir.path,
            hookRunner: { command, environment in
                await recorder.recordHook(command: command, environment: environment)
            }
        )
        let request = WorktreeCreationRequest(
            repository: Repository(name: "demo", path: repo.path),
            source: .newBranch(name: "feature-x"),
            pathTemplate: WorktreePathTemplate("worktrees/{branch}"),
            postCreationHookCommand: "echo hello"
        )

        let result = try await provisioner.createWorktree(request)
        #expect(result.hookTask != nil)
        await result.hookTask?.value

        let invocations = await recorder.hookInvocations
        #expect(invocations.count == 1)
        #expect(invocations[0].command == "echo hello")
        #expect(invocations[0].environment["VITERM_WORKTREE_PATH"] == result.worktreePath)
        #expect(invocations[0].environment["VITERM_BRANCH"] == "feature-x")
        #expect(invocations[0].environment["VITERM_GIT_ROOT"] == repo.path)
    }
}

@Test func createWorktree_noHookCommand_hookTaskIsNil() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)

        let provisioner = WorktreeProvisioner(homeDirectory: dir.path)
        let request = WorktreeCreationRequest(
            repository: Repository(name: "demo", path: repo.path),
            source: .newBranch(name: "feature-x"),
            pathTemplate: WorktreePathTemplate("worktrees/{branch}")
        )

        let result = try await provisioner.createWorktree(request)
        #expect(result.hookTask == nil)
    }
}

// MARK: - WorktreeStatusScanner

@Test func scan_singleMainWorktree_reportsCleanWithZeroAheadBehind() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)

        let scanner = WorktreeStatusScanner()
        let repository = Repository(name: "demo", path: repo.path)
        let worktrees = try await scanner.scan(repository: repository)

        #expect(worktrees.count == 1)
        #expect(worktrees[0].branch == "main")
        #expect(worktrees[0].ahead == 0)
        #expect(worktrees[0].behind == 0)
        #expect(worktrees[0].isDirty == false)
        #expect(worktrees[0].hasStagedChanges == false)
        #expect(worktrees[0].hasUnstagedChanges == false)
        #expect(worktrees[0].repositoryPath == repo.path)
    }
}

@Test func scan_reportsAheadBehindAndDiffStatForFeatureWorktree() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        let featurePath = dir.appendingPathComponent("worktrees/feature")
        try await service.addWorktree(in: repo, path: featurePath, source: .newBranch(name: "feature"))
        try await Fixture.commitFile(named: "a.txt", content: "a\n", message: "add a", in: featurePath)
        try await Fixture.commitFile(named: "b.txt", content: "b\n", message: "add b", in: featurePath)
        try await Fixture.commitFile(named: "c.txt", content: "c\n", message: "advance main", in: repo)

        let scanner = WorktreeStatusScanner(gitService: service)
        let repository = Repository(name: "demo", path: repo.path)
        let worktrees = try await scanner.scan(repository: repository)

        #expect(worktrees.count == 2)
        guard let feature = worktrees.first(where: { $0.branch == "feature" }) else {
            Issue.record("feature worktree not found")
            return
        }
        #expect(feature.ahead == 2)
        #expect(feature.behind == 1)
        #expect(feature.isDirty == false)
        #expect(feature.hasStagedChanges == false)
        #expect(feature.hasUnstagedChanges == false)

        guard let main = worktrees.first(where: { $0.branch == "main" }) else {
            Issue.record("main worktree not found")
            return
        }
        #expect(main.ahead == 0)
        #expect(main.behind == 0)
    }
}

@Test func scan_reportsDirtyWhenUntrackedFilePresent() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        try "untracked\n".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let scanner = WorktreeStatusScanner()
        let worktrees = try await scanner.scan(repository: Repository(name: "demo", path: repo.path))

        #expect(worktrees.count == 1)
        #expect(worktrees[0].isDirty == true)
    }
}

@Test func scan_repositories_skipsFailingRepositoryWithoutThrowing() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let bogus = dir.appendingPathComponent("does-not-exist")

        let scanner = WorktreeStatusScanner()
        let worktrees = await scanner.scan(repositories: [
            Repository(name: "bogus", path: bogus.path),
            Repository(name: "demo", path: repo.path),
        ])

        #expect(worktrees.count == 1)
        #expect(worktrees[0].repositoryPath == repo.path)
    }
}

// MARK: - MergeCleanupCoordinator

@Test func mergeAndCleanUp_success_allStepsSucceedAndCleanUp() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        let featurePath = dir.appendingPathComponent("worktrees/feature")
        try await service.addWorktree(in: repo, path: featurePath, source: .newBranch(name: "feature"))
        try await Fixture.commitFile(named: "feature.txt", content: "feature\n", message: "add feature", in: featurePath)

        let coordinator = MergeCleanupCoordinator(gitService: service)
        let result = await coordinator.mergeAndCleanUp(
            MergeCleanupRequest(
                source: "feature",
                target: "main",
                sourceWorktree: featurePath,
                targetWorktree: repo
            )
        )

        #expect(result.isFullySuccessful)
        #expect(result.steps.map(\.step) == [.merge, .removeWorktree, .deleteBranch])

        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("feature.txt").path) == true)
        #expect(FileManager.default.fileExists(atPath: featurePath.path) == false)

        let branches = try await service.branches(in: repo)
        #expect(!branches.contains { $0.name == "feature" })
    }
}

@Test func mergeAndCleanUp_mergeConflict_stopsAndReportsOnlyMergeStep() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo, initialFile: "shared.txt")
        let service = GitService()

        let featurePath = dir.appendingPathComponent("worktrees/feature")
        try await service.addWorktree(in: repo, path: featurePath, source: .newBranch(name: "feature"))
        try await Fixture.commitFile(
            named: "shared.txt",
            content: "hello\nfeature\n",
            message: "feature change",
            in: featurePath
        )
        try await Fixture.commitFile(
            named: "shared.txt",
            content: "hello\nmain\n",
            message: "main change",
            in: repo
        )

        let coordinator = MergeCleanupCoordinator(gitService: service)
        let result = await coordinator.mergeAndCleanUp(
            MergeCleanupRequest(
                source: "feature",
                target: "main",
                sourceWorktree: featurePath,
                targetWorktree: repo
            )
        )

        #expect(result.isFullySuccessful == false)
        #expect(result.steps.map(\.step) == [.merge])
        #expect(result.result(for: .merge)?.error != nil)

        // 後始末は行われず、feature worktree はまだ残っている(コンフリクト解消は人手に委ねる)。
        #expect(FileManager.default.fileExists(atPath: featurePath.path) == true)

        // conflict 状態のままだと後続テストに影響しうるため abort しておく。
        _ = try? await service.runner.run(["merge", "--abort"], in: repo)
    }
}

@Test func mergeAndCleanUp_dirtySourceWorktree_removeStepFailsAndSkipsBranchDelete() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        let featurePath = dir.appendingPathComponent("worktrees/feature")
        try await service.addWorktree(in: repo, path: featurePath, source: .newBranch(name: "feature"))
        try await Fixture.commitFile(named: "feature.txt", content: "feature\n", message: "add feature", in: featurePath)

        // マージ後に source worktree を dirty にしておく(force 未指定なので削除は失敗するはず)。
        try "dirty\n".write(to: featurePath.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let coordinator = MergeCleanupCoordinator(gitService: service)
        let result = await coordinator.mergeAndCleanUp(
            MergeCleanupRequest(
                source: "feature",
                target: "main",
                sourceWorktree: featurePath,
                targetWorktree: repo
            )
        )

        #expect(result.isFullySuccessful == false)
        #expect(result.steps.map(\.step) == [.merge, .removeWorktree])
        #expect(result.result(for: .merge)?.isSuccess == true)
        #expect(result.result(for: .removeWorktree)?.isSuccess == false)

        // worktree もブランチもまだ残っている。
        #expect(FileManager.default.fileExists(atPath: featurePath.path) == true)
        let branches = try await service.branches(in: repo)
        #expect(branches.contains { $0.name == "feature" })
    }
}

@Test func mergeAndCleanUp_rebaseStrategy_succeeds() async throws {
    try await withTemporaryDirectory { dir in
        let repo = dir.appendingPathComponent("repo")
        try await Fixture.makeRepository(at: repo)
        let service = GitService()

        let featurePath = dir.appendingPathComponent("worktrees/feature")
        try await service.addWorktree(in: repo, path: featurePath, source: .newBranch(name: "feature"))
        try await Fixture.commitFile(named: "feature.txt", content: "feature\n", message: "add feature", in: featurePath)
        try await Fixture.commitFile(named: "main-only.txt", content: "main\n", message: "advance main", in: repo)

        let coordinator = MergeCleanupCoordinator(gitService: service)
        let result = await coordinator.mergeAndCleanUp(
            MergeCleanupRequest(
                source: "feature",
                target: "main",
                sourceWorktree: featurePath,
                targetWorktree: repo,
                strategy: .rebase
            )
        )

        #expect(result.isFullySuccessful)
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("feature.txt").path) == true)
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("main-only.txt").path) == true)
        #expect(FileManager.default.fileExists(atPath: featurePath.path) == false)
    }
}

// MARK: - RepositoryDiscovery

/// `<directory>/.git` をディレクトリとして作る(= 本物のリポジトリを模す)。実 git は不要。
private func makeFakeRepositoryMarker(at directory: URL) throws {
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent(".git"),
        withIntermediateDirectories: true
    )
}

/// `<directory>/.git` をファイルとして作る(= worktree チェックアウト先を模す)。
private func makeFakeWorktreeCheckoutMarker(at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "gitdir: /somewhere/.git/worktrees/x\n".write(
        to: directory.appendingPathComponent(".git"),
        atomically: true,
        encoding: .utf8
    )
}

@Test func discover_findsRepositoriesAtVariousDepths() async throws {
    try await withTemporaryDirectory { dir in
        let root = dir.appendingPathComponent("root")
        try makeFakeRepositoryMarker(at: root.appendingPathComponent("project-a"))
        try makeFakeRepositoryMarker(at: root.appendingPathComponent("group/project-b"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("group/not-a-repo"),
            withIntermediateDirectories: true
        )

        let discovery = RepositoryDiscovery()
        let repositories = discovery.discover(rootDirectory: root)
        let names = Set(repositories.map(\.name))

        #expect(names == ["project-a", "project-b"])
        let expectedPath = root.appendingPathComponent("project-a").resolvingSymlinksInPath().path
        #expect(repositories.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == expectedPath })
    }
}

@Test func discover_excludesWorktreeCheckoutDirectories() async throws {
    try await withTemporaryDirectory { dir in
        let root = dir.appendingPathComponent("root")
        try makeFakeRepositoryMarker(at: root.appendingPathComponent("project-a"))
        try makeFakeWorktreeCheckoutMarker(at: root.appendingPathComponent("project-a-worktree"))

        let discovery = RepositoryDiscovery()
        let repositories = discovery.discover(rootDirectory: root)

        #expect(repositories.map(\.name) == ["project-a"])
    }
}

@Test func discover_excludesConfiguredDirectoryNames() async throws {
    try await withTemporaryDirectory { dir in
        let root = dir.appendingPathComponent("root")
        try makeFakeRepositoryMarker(at: root.appendingPathComponent("node_modules/nested-repo"))
        try makeFakeRepositoryMarker(at: root.appendingPathComponent("real-project"))

        let discovery = RepositoryDiscovery()
        let repositories = discovery.discover(rootDirectory: root)

        #expect(repositories.map(\.name) == ["real-project"])
    }
}

@Test func discover_respectsMaxDepth() async throws {
    try await withTemporaryDirectory { dir in
        let root = dir.appendingPathComponent("root")
        // root/a/b/c/d/e/deep-project は root から見て depth 6。
        try makeFakeRepositoryMarker(at: root.appendingPathComponent("a/b/c/d/e/deep-project"))

        let shallow = RepositoryDiscovery(maxDepth: 4)
        #expect(shallow.discover(rootDirectory: root).isEmpty)

        let deep = RepositoryDiscovery(maxDepth: 6)
        #expect(deep.discover(rootDirectory: root).map(\.name) == ["deep-project"])
    }
}

@Test func discover_doesNotDescendIntoFoundRepository() async throws {
    try await withTemporaryDirectory { dir in
        let root = dir.appendingPathComponent("root")
        try makeFakeRepositoryMarker(at: root.appendingPathComponent("project-a"))
        // project-a の内部にネストしたリポジトリ(vendor 済み等)があっても二重登録しない。
        try makeFakeRepositoryMarker(at: root.appendingPathComponent("project-a/vendor/nested-repo"))

        let discovery = RepositoryDiscovery()
        let repositories = discovery.discover(rootDirectory: root)

        #expect(repositories.map(\.name) == ["project-a"])
    }
}

@Test func discover_emptyRootReturnsEmpty() async throws {
    try await withTemporaryDirectory { dir in
        let root = dir.appendingPathComponent("empty-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let discovery = RepositoryDiscovery()
        #expect(discovery.discover(rootDirectory: root).isEmpty)
    }
}

// MARK: - StatusChangeHookRunner

@Test func notify_configuredState_invokesHookWithExpectedEnvironment() async throws {
    let recorder = CallRecorder()
    let runner = StatusChangeHookRunner(
        config: StatusChangeHookConfig(onWaitingInput: "notify-waiting"),
        hookRunner: { command, environment in
            await recorder.recordHook(command: command, environment: environment)
        }
    )

    let task = runner.notify(
        sessionName: "claude-1",
        worktreePath: "/repo/worktrees/feature",
        oldState: .busy,
        newState: .waitingInput
    )
    #expect(task != nil)
    await task?.value

    let invocations = await recorder.hookInvocations
    #expect(invocations.count == 1)
    #expect(invocations[0].command == "notify-waiting")
    #expect(invocations[0].environment["VITERM_SESSION_NAME"] == "claude-1")
    #expect(invocations[0].environment["VITERM_WORKTREE_PATH"] == "/repo/worktrees/feature")
    #expect(invocations[0].environment["VITERM_OLD_STATE"] == "busy")
    #expect(invocations[0].environment["VITERM_NEW_STATE"] == "waitingInput")
}

@Test func notify_oldStateNil_setsEmptyStringForOldState() async throws {
    let recorder = CallRecorder()
    let runner = StatusChangeHookRunner(
        config: StatusChangeHookConfig(onIdle: "notify-idle"),
        hookRunner: { command, environment in
            await recorder.recordHook(command: command, environment: environment)
        }
    )

    let task = runner.notify(sessionName: "s", worktreePath: "/p", oldState: nil, newState: .idle)
    await task?.value

    let invocations = await recorder.hookInvocations
    #expect(invocations[0].environment["VITERM_OLD_STATE"] == "")
}

@Test func notify_unconfiguredState_returnsNilAndDoesNotInvoke() async throws {
    let recorder = CallRecorder()
    let runner = StatusChangeHookRunner(
        config: StatusChangeHookConfig(onBusy: "notify-busy"),
        hookRunner: { command, environment in
            await recorder.recordHook(command: command, environment: environment)
        }
    )

    // onWaitingInput / onIdle は未設定なので busy 以外では何も起きない。
    let task = runner.notify(sessionName: "s", worktreePath: "/p", oldState: .busy, newState: .idle)
    #expect(task == nil)

    let invocations = await recorder.hookInvocations
    #expect(invocations.isEmpty)
}

@Test func notify_defaultHookRunner_actuallyExecutesCommand() async throws {
    try await withTemporaryDirectory { dir in
        let marker = dir.appendingPathComponent("hook-ran")
        let runner = StatusChangeHookRunner(config: StatusChangeHookConfig(onBusy: "touch '\(marker.path)'"))

        let task = runner.notify(sessionName: "s", worktreePath: "/p", oldState: nil, newState: .busy)
        await task?.value

        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}
