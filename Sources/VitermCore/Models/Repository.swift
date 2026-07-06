import Foundation

/// A repository registered with the app (top level of the sidebar hierarchy).
/// Pure reference information; the on-disk repository itself is never modified.
public struct Repository: Codable, Sendable, Hashable, Identifiable {
    /// Sidebar display name. Also used for the `{project}` placeholder of `WorktreePathTemplate`.
    public var name: String
    /// Absolute path of the repository root.
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    public var id: String { path }
}
