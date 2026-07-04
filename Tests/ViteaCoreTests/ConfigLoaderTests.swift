import Foundation
import Testing
@testable import ViteaCore

@Suite("ConfigLoader")
struct ConfigLoaderTests {
    /// テストごとに独立した一時ディレクトリを用意する。
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitea-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("両方のファイルが存在しない場合は既定値になる")
    func missingFilesUseDefault() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let globalURL = dir.appendingPathComponent("config.json")
        let repoRoot = dir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)

        let config = try ConfigLoader.load(globalURL: globalURL, repositoryRoot: repoRoot)
        #expect(config == ViteaConfig.default)
    }

    @Test("グローバル設定ファイルのみ存在する場合はその内容が反映される")
    func globalFileOnly() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let globalURL = dir.appendingPathComponent("config.json")
        let json = """
        {"worktreePathTemplate": "~/g/{project}/{branch}", "defaultPreset": "codex"}
        """
        try json.write(to: globalURL, atomically: true, encoding: .utf8)

        let config = try ConfigLoader.load(globalURL: globalURL, repositoryRoot: nil)
        #expect(config.worktreePathTemplate == "~/g/{project}/{branch}")
        #expect(config.defaultPreset == "codex")
    }

    @Test("プロジェクト設定 .vitea.json がグローバル設定を上書きする")
    func projectFileOverridesGlobal() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let globalURL = dir.appendingPathComponent("config.json")
        try """
        {"worktreePathTemplate": "~/g/{project}/{branch}"}
        """.write(to: globalURL, atomically: true, encoding: .utf8)

        let repoRoot = dir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        let projectURL = ConfigLoader.projectConfigURL(repositoryRoot: repoRoot)
        try """
        {"worktreePathTemplate": "~/p/{project}/{branch}"}
        """.write(to: projectURL, atomically: true, encoding: .utf8)

        let config = try ConfigLoader.load(globalURL: globalURL, repositoryRoot: repoRoot)
        #expect(config.worktreePathTemplate == "~/p/{project}/{branch}")
    }

    @Test("不正な JSON はエラーを投げる")
    func malformedJSONThrows() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let globalURL = dir.appendingPathComponent("config.json")
        try "{ not valid json".write(to: globalURL, atomically: true, encoding: .utf8)

        #expect(throws: ConfigLoaderError.self) {
            try ConfigLoader.load(globalURL: globalURL, repositoryRoot: nil)
        }
    }

    @Test("登録リポジトリ一覧はグローバル設定から読み込まれる")
    func repositoriesLoadedFromGlobal() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let globalURL = dir.appendingPathComponent("config.json")
        try """
        {"repositories": [{"name": "vitea", "path": "/repo/vitea"}]}
        """.write(to: globalURL, atomically: true, encoding: .utf8)

        let config = try ConfigLoader.load(globalURL: globalURL, repositoryRoot: nil)
        #expect(config.repositories == [Repository(name: "vitea", path: "/repo/vitea")])
    }

    @Test("postCreationHook/statusHooks/discoveryRoots を含む設定ファイルを読み込める")
    func loadsHookAndDiscoveryKeys() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let globalURL = dir.appendingPathComponent("config.json")
        try """
        {
          "postCreationHook": "echo created",
          "statusHooks": { "onBusy": "notify-busy", "onIdle": "notify-idle" },
          "discoveryRoots": ["~/dev", "~/work"]
        }
        """.write(to: globalURL, atomically: true, encoding: .utf8)

        let config = try ConfigLoader.load(globalURL: globalURL, repositoryRoot: nil)
        #expect(config.postCreationHook == "echo created")
        #expect(config.statusHooks.onBusy == "notify-busy")
        #expect(config.statusHooks.onIdle == "notify-idle")
        #expect(config.statusHooks.onWaitingInput == nil)
        #expect(config.discoveryRoots == ["~/dev", "~/work"])
    }

    @Test("presets に arguments/environment を省略した config ファイルも読み込める")
    func loadsPresetsWithMissingOptionalFields() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let globalURL = dir.appendingPathComponent("config.json")
        try """
        {"presets": [{"name": "gemini", "command": "gemini"}]}
        """.write(to: globalURL, atomically: true, encoding: .utf8)

        let config = try ConfigLoader.load(globalURL: globalURL, repositoryRoot: nil)
        // 組み込み既定(claude/codex/shell)は残ったまま、gemini が末尾に追加される。
        #expect(config.presets.map(\.name) == ["claude", "codex", "shell", "gemini"])
        #expect(config.presets.first { $0.name == "gemini" } == SessionPreset(name: "gemini", command: "gemini"))
    }
}
