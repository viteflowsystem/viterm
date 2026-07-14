import Foundation

/// One command listed in the command palette (⌘K).
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
    /// Keyboard hint shown at the far right (e.g. `⌘N`). `nil` if none.
    public var keyboardHint: String?
    /// The action the UI switches over to execute.
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

    /// Text targeted by fuzzy search. Including the category name at the front lets a
    /// query against the category name (e.g. "wt") surface that category's commands first.
    public var searchableText: String {
        "\(category.displayName) \(title)"
    }
}

/// The operation a `PaletteCommand` performs. The UI switches over this to dispatch the
/// actual work (GitService calls, showing dialogs, launching SessionManager, etc.).
/// No execution logic lives here.
public enum PaletteAction: Sendable, Equatable, Hashable {
    /// Open the new-worktree dialog.
    case createWorktree
    /// Switch to the given worktree.
    case switchToWorktree(worktreeID: String)
    /// Jump directly to the given session (used by ⌘P quick-open).
    case switchToSession(sessionID: AgentSession.ID)
    /// Merge the given worktree's branch (the merge/rebase choice is up to the UI).
    case mergeWorktree(worktreeID: String)
    /// Remove the given worktree (the confirmation dialog is up to the UI).
    case removeWorktree(worktreeID: String)
    /// Launch a session with the given preset in the given worktree.
    case startSession(worktreeID: String, presetName: String)
    /// Open the add-repository dialog (directory picker).
    case addRepository
}
