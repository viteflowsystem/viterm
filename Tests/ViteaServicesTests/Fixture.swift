import Foundation
import GitKit
@testable import ViteaServices

/// テスト用の一時ディレクトリを作り、`body` 実行後に必ず削除する。
/// 実 git を使う fixture リポジトリはすべてこの配下に作る。カレントの vitea リポジトリには一切触れない。
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vitea-ViteaServicesTests-\(UUID().uuidString)", isDirectory: true)
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
}
