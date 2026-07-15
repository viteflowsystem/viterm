import Foundation
import GitKit
import VitermCore

// MARK: - Abstractions over the external effects AppModel uses.
//
// `AppModel` itself only causes side effects (running git, file I/O, config reads/writes)
// through these protocols. Each protocol corresponds 1:1 to methods on an existing concrete
// type (WorktreeStatusScanner, etc.), and the concrete types conform unchanged via the
// extensions below. Tests inject fakes conforming to the same protocols.

/// Abstraction over config loading (wrapper around `ConfigLoader.load`).
public protocol ConfigProviding: Sendable {
    func loadConfig(repositoryRoot: URL?) throws -> VitermConfig
}

/// Abstraction over persisting the registered-repository list to the global config.
public protocol RepositoryConfigPersisting: Sendable {
    func persist(repositories: [Repository]) throws
}

/// Abstraction over persisting sidebar UI preferences (display mode) to the global config.
public protocol SidebarPreferencePersisting: Sendable {
    func persist(sidebarDisplayMode: SidebarDisplayMode) throws
}

/// Abstraction over auto-discovering git repositories under a root (wrapper around `RepositoryDiscovery`).
public protocol RepositoryDiscovering: Sendable {
    func discover(rootDirectory: URL) -> [Repository]
}

/// Abstraction over collecting worktree status for registered repositories (wrapper around `WorktreeStatusScanner`).
public protocol WorktreeStatusScanning: Sendable {
    func scan(repositories: [Repository]) async -> [VitermCore.Worktree]
}

/// Abstraction over worktree creation (wrapper around `WorktreeProvisioner`).
public protocol WorktreeProvisioning: Sendable {
    func createWorktree(_ request: WorktreeCreationRequest) async throws -> WorktreeCreationResult
}

/// Abstraction over standalone worktree removal (`git worktree remove` without merging; wrapper around `GitService`).
public protocol WorktreeRemoving: Sendable {
    func removeWorktree(at path: URL, in repository: URL, force: Bool) async throws
    func deleteBranch(_ name: String, in repository: URL, force: Bool) async throws
}

/// Abstraction over merge/rebase + cleanup (wrapper around `MergeCleanupCoordinator`).
public protocol MergeCleaningUp: Sendable {
    func mergeAndCleanUp(_ request: MergeCleanupRequest) async -> MergeCleanupResult
}

/// Abstraction over firing session-state-change hooks (wrapper around `StatusChangeHookRunner`).
public protocol StatusChangeNotifying: Sendable {
    @discardableResult
    func notify(
        sessionName: String,
        worktreePath: String,
        oldState: AgentSession.State?,
        newState: AgentSession.State
    ) -> Task<Void, Never>?

    /// Refresh the hook command config on every config reload (`AppModel.refresh()`).
    mutating func updateConfig(_ config: StatusChangeHookConfig)
}

/// Abstraction over launching/switching sessions. The `SessionManager` implemented in T6
/// is expected to conform (for now, only the protocol definition and a test fake exist).
public protocol SessionLaunching: Sendable {
    /// Launch the preset in the given worktree and return the created `AgentSession`.
    func startSession(worktreePath: String, presetName: String) async throws -> AgentSession
    /// Switch the displayed worktree (the actual surface switch is the UI's responsibility; this only notifies).
    func switchToWorktree(_ worktreePath: String) async
}

// MARK: - Conform the existing concrete types as-is (signatures match exactly).

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

/// Default implementation that re-reads the global config file
/// (`~/.config/viterm/config.json`) and overwrites only its `repositories` field.
/// Other fields (templates, presets, etc.) are preserved.
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

/// Default implementation that re-reads the global config file and overwrites only its
/// `sidebarDisplayMode` field (read-modify-write; other fields, including ones the user
/// edited by hand since the app launched, are preserved).
public struct LiveSidebarPreferencePersister: SidebarPreferencePersisting {
    public var globalConfigURL: URL

    public init(globalConfigURL: URL = ConfigLoader.defaultGlobalConfigURL()) {
        self.globalConfigURL = globalConfigURL
    }

    public func persist(sidebarDisplayMode: SidebarDisplayMode) throws {
        try FileManager.default.createDirectory(
            at: globalConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var file = (try? ConfigLoader.loadFile(at: globalConfigURL)) ?? VitermConfigFile()
        file.sidebarDisplayMode = sidebarDisplayMode.rawValue

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: globalConfigURL, options: .atomic)
    }
}
