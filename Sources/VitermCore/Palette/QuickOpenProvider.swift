import Foundation

/// Builds the jump-target list for ⌘P quick-open: every session and every worktree across
/// all repositories, flattened into `PaletteCommand`s so the existing palette UI and fuzzy
/// search can be reused as-is. Unlike `PaletteCommandProvider` (which offers *operations*
/// on the current worktree), this offers *navigation* to anything.
public enum QuickOpenProvider {
    /// - Parameter repositories: the sidebar tree (`SidebarViewModel.repositories`).
    ///
    /// Emits, in display order per repository: each worktree's sessions
    /// (`repo · branch · session`), then the worktree itself (`repo · branch`). Selecting a
    /// session jumps to it; selecting a worktree jumps to it (the UI launches a default
    /// session when the worktree has none). Sessions come first so the common "jump to a
    /// session" case ranks ahead on an empty query.
    public static func commands(repositories: [RepositoryNode]) -> [PaletteCommand] {
        var sessionCommands: [PaletteCommand] = []
        var worktreeCommands: [PaletteCommand] = []

        for repositoryNode in repositories {
            let repositoryName = repositoryNode.repository.name
            for worktreeNode in repositoryNode.worktrees {
                let worktree = worktreeNode.worktree
                for sessionNode in worktreeNode.sessions {
                    let session = sessionNode.session
                    sessionCommands.append(PaletteCommand(
                        id: "quickopen.session.\(session.id.uuidString)",
                        category: .session,
                        title: "\(repositoryName) · \(worktree.branch) · \(session.displayName)",
                        action: .switchToSession(sessionID: session.id)
                    ))
                }
                worktreeCommands.append(PaletteCommand(
                    id: "quickopen.worktree.\(worktree.id)",
                    category: .worktree,
                    title: "\(repositoryName) · \(worktree.branch)",
                    action: .switchToWorktree(worktreeID: worktree.id)
                ))
            }
        }

        return sessionCommands + worktreeCommands
    }
}
