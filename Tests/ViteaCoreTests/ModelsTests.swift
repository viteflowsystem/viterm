import Foundation
import Testing
@testable import ViteaCore

@Suite("Domain models")
struct ModelsTests {
    @Test("Repository は Codable で往復できる")
    func repositoryRoundTrip() throws {
        let original = Repository(name: "vitea", path: "/repo/vitea")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Repository.self, from: data)
        #expect(decoded == original)
        #expect(decoded.id == "/repo/vitea")
    }

    @Test("Worktree は Codable で往復でき、既定値は0/非dirty")
    func worktreeRoundTripAndDefaults() throws {
        let worktree = Worktree(path: "/repo/vitea/wt/feat-foo", branch: "feat/foo")
        #expect(worktree.ahead == 0)
        #expect(worktree.behind == 0)
        #expect(worktree.diffStat == Worktree.DiffStat(added: 0, removed: 0))
        #expect(worktree.isDirty == false)
        #expect(worktree.id == worktree.path)

        let full = Worktree(
            path: "/repo/vitea/wt/feat-foo",
            branch: "feat/foo",
            ahead: 3,
            behind: 1,
            diffStat: Worktree.DiffStat(added: 10, removed: 5),
            isDirty: true
        )
        let data = try JSONEncoder().encode(full)
        let decoded = try JSONDecoder().decode(Worktree.self, from: data)
        #expect(decoded == full)
    }

    @Test("SessionPreset の既定引数・環境変数は空")
    func sessionPresetDefaults() throws {
        let preset = SessionPreset(name: "claude", command: "claude")
        #expect(preset.arguments.isEmpty)
        #expect(preset.environment.isEmpty)
        #expect(preset.id == "claude")

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(SessionPreset.self, from: data)
        #expect(decoded == preset)
    }

    @Test("AgentSession は既定で idle 状態、Codable で往復できる")
    func agentSessionDefaultsAndRoundTrip() throws {
        let session = AgentSession(
            worktreePath: "/repo/vitea/wt/feat-foo",
            presetName: "claude",
            displayName: "claude #1"
        )
        #expect(session.state == .idle)

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        #expect(decoded == session)
    }

    @Test("AgentSession.State の全ケースが Codable")
    func agentSessionStateCodable() throws {
        for state: AgentSession.State in [.busy, .waitingInput, .idle] {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(AgentSession.State.self, from: data)
            #expect(decoded == state)
        }
    }
}
