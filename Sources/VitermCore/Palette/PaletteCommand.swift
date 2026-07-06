import Foundation

/// A single command listed in the command palette (⌘K).
/// Screen 02 (command palette) of docs/ui-mock.html is the display spec.
public struct PaletteCommand: Sendable, Equatable, Hashable, Identifiable {
    /// Category heading in the palette.
    public enum Category: Sendable, Equatable, Hashable, CaseIterable {
        case worktree
        case session
        case repository

        /// Category heading string shown in the palette (per docs/ui-mock.html).
        public var displayName: String {
            switch self {
            case .worktree: return "Worktree"
            case .session: return "Session"
            case .repository: return "Repo"
            }
        }
    }

    /// Unique, stable command ID (unchanged across regeneration given the same context).
    public var id: String
    public var category: Category
    public var title: String
    /// Auxiliary info shown on the right (e.g. ahead/behind `↑3 ↓1`). `nil` if none.
    public var subtitle: String?
    /// Keyboard hint shown at the right edge (e.g. `⌘N`). `nil` if none.
    public var keyboardHint: String?
    /// Action that the UI switches over and executes.
    public var action: PaletteAction

    public init(
        id: String,
        category: Category,
        title: String,
        subtitle: String? = nil,
        keyboardHint: String? = nil,
        action: PaletteAction
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.keyboardHint = keyboardHint
        self.action = action
    }

    /// Text targeted by fuzzy search. Prepending the category name lets a query for
    /// the category name (e.g. "wt") surface that category's commands preferentially.
    public var searchableText: String {
        "\(category.displayName) \(title)"
    }
}

/// Operation executed by a `PaletteCommand`. The UI switches over this and dispatches
/// to the actual work (GitService calls, dialog display, SessionManager launch, etc.).
/// No execution logic lives here.
public enum PaletteAction: Sendable, Equatable, Hashable {
    /// Open the new-worktree dialog.
    case createWorktree
    /// Switch to the specified worktree.
    case switchToWorktree(worktreeID: String)
    /// Merge the specified worktree's branch (merge vs. rebase choice is on the UI side).
    case mergeWorktree(worktreeID: String)
    /// Remove the specified worktree (confirmation dialog is on the UI side).
    case removeWorktree(worktreeID: String)
    /// Start a session with the specified preset in the specified worktree.
    case startSession(worktreeID: String, presetName: String)
    /// Open the add-repository dialog (directory picker).
    case addRepository
}
