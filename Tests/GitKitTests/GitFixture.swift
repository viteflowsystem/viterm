import Foundation
@testable import GitKit

/// テスト用の一時ディレクトリを作り、`body` 実行後に必ず削除する。
/// 実 git を使う fixture リポジトリはすべてこの配下に作る。カレントの vitea リポジトリには一切触れない。
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vitea-GitKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

enum Fixture {
    static let runner = GitRunner()

    /// 指定ブランチ(既定 `main`)に初期コミットが1つある単純なリポジトリを作る。
    @discardableResult
    static func makeRepository(at repoURL: URL, branch: String = "main", initialFile: String = "README.md") async throws -> String {
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try await runner.run(["init", "-b", branch], in: repoURL)
        try await runner.run(["config", "user.email", "vitea-test@example.com"], in: repoURL)
        try await runner.run(["config", "user.name", "Vitea Test"], in: repoURL)
        return try await commitFile(named: initialFile, content: "hello\n", message: "initial commit", in: repoURL)
    }

    @discardableResult
    static func commitFile(
        named name: String,
        content: String,
        message: String,
        in directory: URL
    ) async throws -> String {
        let fileURL = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        try await runner.run(["add", name], in: directory)
        try await runner.run(["commit", "-m", message], in: directory)
        let sha = try await runner.run(["rev-parse", "HEAD"], in: directory)
        return sha.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// bare リモート("origin")を持つリポジトリ一式を作る。`repo` が origin/HEAD = main を持つ
    /// clone になっており、`feature` ブランチも origin に push 済みで `repo` から fetch 済み。
    /// - Returns: (repo: 作業用 clone, bare: bare リモートのパス)
    static func makeRepositoryWithRemote(in directory: URL) async throws -> (repo: URL, bare: URL) {
        let bare = directory.appendingPathComponent("origin.git", isDirectory: true)
        let seed = directory.appendingPathComponent("seed", isDirectory: true)
        let repo = directory.appendingPathComponent("repo", isDirectory: true)

        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try await runner.run(["init", "--bare", "-b", "main"], in: bare)

        try await runner.run(["clone", bare.path, seed.path], in: directory)
        try await runner.run(["config", "user.email", "vitea-test@example.com"], in: seed)
        try await runner.run(["config", "user.name", "Vitea Test"], in: seed)
        try await commitFile(named: "README.md", content: "hello\n", message: "initial commit", in: seed)
        try await runner.run(["push", "origin", "main"], in: seed)

        try await runner.run(["checkout", "-b", "feature"], in: seed)
        try await commitFile(named: "feature.txt", content: "feature\n", message: "add feature", in: seed)
        try await runner.run(["push", "origin", "feature"], in: seed)

        try await runner.run(["clone", bare.path, repo.path], in: directory)
        try await runner.run(["config", "user.email", "vitea-test@example.com"], in: repo)
        try await runner.run(["config", "user.name", "Vitea Test"], in: repo)
        try await runner.run(["fetch", "origin"], in: repo)

        return (repo, bare)
    }
}
