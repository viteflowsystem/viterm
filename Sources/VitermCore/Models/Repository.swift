import Foundation

/// A repository registered in the app (the top level of the sidebar).
/// Pure reference info — the repository on disk is never touched.
public struct Repository: Codable, Sendable, Hashable, Identifiable {
    /// Sidebar display name. Also used for `WorktreePathTemplate`'s `{project}` placeholder.
    public var name: String
    /// Absolute path of the repository root.
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    public var id: String { path }
}
