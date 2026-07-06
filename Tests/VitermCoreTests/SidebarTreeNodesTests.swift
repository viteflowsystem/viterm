import Foundation
import Testing
@testable import VitermCore

@Suite("WorktreeNode rollup")
struct WorktreeNodeRollupTests {
    let viterm = Repository(name: "viterm", path: "/repo/viterm")

    func makeNode(states: [AgentSession.State]) -> WorktreeNode {
        let worktree = Worktree(path: "/wt/viterm/feat", repositoryPath: viterm.path, branch: "feat")
        let sessions = states.enumerated().map { index, state in
            SessionNode(
                session: AgentSession(worktreePath: worktree.path, presetName: "claude", displayName: "s\(index)", state: state),
                shortcutNumber: index + 1
            )
        }
        return WorktreeNode(worktree: worktree, sessions: sessions)
    }

    @Test("waitingSessionCountはwaitingInputの件数のみ数える")
    func waitingSessionCountCountsOnlyWaiting() {
        let node = makeNode(states: [.busy, .waitingInput, .idle, .waitingInput])
        #expect(node.waitingSessionCount == 2)
    }

    @Test("waitingSessionCountはセッションが無ければ0")
    func waitingSessionCountIsZeroWhenEmpty() {
        let node = makeNode(states: [])
        #expect(node.waitingSessionCount == 0)
    }

    @Test("stateSummaryはbusy/waitingInput/idleを集計する")
    func stateSummaryAggregates() {
        let node = makeNode(states: [.busy, .busy, .waitingInput, .idle])
        let summary = node.stateSummary
        #expect(summary.busy == 2)
        #expect(summary.waitingInput == 1)
        #expect(summary.idle == 1)
        #expect(summary.total == 4)
    }

    @Test("dominantStateはwaitingInputを最優先する")
    func dominantStatePrefersWaitingInput() {
        let node = makeNode(states: [.busy, .idle, .waitingInput])
        #expect(node.dominantState == .waitingInput)
    }

    @Test("dominantStateはwaitingInputが無ければbusyを優先する")
    func dominantStatePrefersBusyOverIdle() {
        let node = makeNode(states: [.idle, .busy, .idle])
        #expect(node.dominantState == .busy)
    }

    @Test("dominantStateはbusy/waitingInputが無ければidle")
    func dominantStateFallsBackToIdle() {
        let node = makeNode(states: [.idle, .idle])
        #expect(node.dominantState == .idle)
    }

    @Test("dominantStateはセッションが無ければnil")
    func dominantStateIsNilWhenEmpty() {
        let node = makeNode(states: [])
        #expect(node.dominantState == nil)
    }
}
