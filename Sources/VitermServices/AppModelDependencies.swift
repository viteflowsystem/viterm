import Foundation
import GitKit
import VitermCore

// MARK: - Abstractions over the external effects AppModel uses.
//
// `AppModel` itself only performs side effects (running git, file I/O, config read/write)
// through these protocols. Each protocol corresponds 1:1 to the methods of an existing
// concrete type (WorktreeStatusScanner, etc.), and the concrete types conform unchanged
// via the extensions below. Tests inject fakes conforming to the same protocols.

/// Abstraction over config loading (wrapper for `ConfigLoader.load`).
public protocol ConfigProviding: Sendable {
    func loadConfig(repositoryRoot: URL?) throws -> VitermConfig
}

/// Abstraction over persisting the registered repository list to the global config.
public protocol RepositoryConfigPersisting: Sendable {
    func persist(repositories: [Repository]) throws
}

/// Abstraction over auto-discovering git repositories under a given root (wrapper for `RepositoryDiscovery`).
public protocol RepositoryDiscovering: Sendable {
    func discover(rootDirectory: URL) -> [Repository]
}

/// Abstraction over collecting worktree status for the registered repositories (wrapper for `WorktreeStatusScanner`).
public protocol WorktreeStatusScanning: Sendable {
    func scan(repositories: [Repository]) async -> [VitermCore.Worktree]
}

/// Abstraction over worktree creation (wrapper for `WorktreeProvisioner`).
public protocol WorktreeProvisioning: Sendable {
    func createWorktree(_ request: WorktreeCreationRequest) async throws -> WorktreeCreationResult
}

/// Abstraction over standalone worktree removal (`git worktree remove` without a merge; wrapper for `GitService`).
public protocol WorktreeRemoving: Sendable {
    func removeWorktree(at path: URL, in repository: URL, force: Bool) async throws
}

/// Abstraction over merge/rebase + cleanup (wrapper for `MergeCleanupCoordinator`).
public protocol MergeCleaningUp: Sendable {
    func mergeAndCleanUp(_ request: MergeCleanupRequest) async -> MergeCleanupResult
}

/// Abstraction over firing session state-change hooks (wrapper for `StatusChangeHookRunner`).
public protocol StatusChangeNotifying: Sendable {
    @discardableResult
    func notify(
        sessionName: String,
        worktreePath: String,
        oldState: AgentSession.State?,
        newState: AgentSession.State
    ) -> Task<Void, Never>?

    /// Refreshes the hook command config on every config reload (`AppModel.refresh()`).
    mutating func updateConfig(_ config: StatusChangeHookConfig)
}

/// Abstraction over launching and switching sessions. The `SessionManager` implemented in T6
/// is expected to conform to this (for now, only the protocol definition and a test fake exist).
public protocol SessionLaunching: Sendable {
    /// Launches the preset in the given worktree and returns the created `AgentSession`.
    func startSession(worktreePath: String, presetName: String) async throws -> AgentSession
    /// Switches the currently displayed worktree (the actual surface switch is the UI's responsibility; this is notification only).
    func switchToWorktree(_ worktreePath: String) async
}

// MARK: - Conform the existing concrete types to the protocols as-is (signatures match exactly).

extension RepositoryDiscovery: RepositoryDiscovering {}
extension WorktreeStatusScanner: WorktreeStatusScanning {}
extension WorktreeProvisioner: WorktreeProvisioning {}
extension MergeCleanupCoordinator: MergeCleaningUp {}
extension StatusChangeHookRunner: StatusChangeNotifying {}
extension GitService: WorktreeRemoving {}

// MARK: - Live implementations

/// Default implementation that simply calls `ConfigLoader.load`.
public struct LiveConfigProvider: ConfigProviding {
    public var globalURL: URL?

    public init(globalURL: URL? = nil) {
        self.globalURL = globalURL
    }

    public func loadConfig(repositoryRoot: URL?) throws -> VitermConfig {
        try ConfigLoader.load(globalURL: globalURL, repositoryRoot: repositoryRoot)
    }
}

/// Default implementation that re-reads the global config file (`~/.config/viterm/config.json`)
/// and overwrites only its `repositories` field. Other fields (templates, presets, etc.) are preserved.
public struct LiveRepositoryConfigPersister: RepositoryConfigPersisting {
    public var globalConfigURL: URL

    public init(globalConfigURL: URL = ConfigLoader.defaultGlobalConfigURL()) {
        self.globalConfigURL = globalConfigURL
    }

    public func persist(repositories: [Repository]) throws {
        try FileManager.default.createDirectory(
            at: globalConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var file = (try? ConfigLoader.loadFile(at: globalConfigURL)) ?? VitermConfigFile()
        file.repositories = repositories

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: globalConfigURL, options: .atomic)
    }
}
