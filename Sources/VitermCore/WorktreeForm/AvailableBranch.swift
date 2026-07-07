import Foundation

/// One option for the worktree creation form's "base branch" and similar dropdowns.
/// The local/remote branch lists are expected to be injected by the caller (queried via
/// GitKit); `VitermCore` itself performs no git operations.
public struct AvailableBranch: Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case local
        case remote
    }

    /// For local: the short branch name (e.g. `main`); for remote: `<remote>/<branch>` form (e.g. `origin/main`).
    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    public var id: String { "\(kind.rawValue):\(name)" }
}
