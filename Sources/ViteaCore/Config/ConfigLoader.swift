import Foundation

/// 設定ファイル読み込みで発生しうるエラー。
public enum ConfigLoaderError: Error, Equatable, CustomStringConvertible {
    /// ファイルは存在するが JSON として不正、またはスキーマに合わない。
    case invalidJSON(path: String, underlying: String)

    public var description: String {
        switch self {
        case let .invalidJSON(path, underlying):
            return "設定ファイルの読み込みに失敗しました: \(path) (\(underlying))"
        }
    }

    public static func == (lhs: ConfigLoaderError, rhs: ConfigLoaderError) -> Bool {
        switch (lhs, rhs) {
        case let (.invalidJSON(lp, lu), .invalidJSON(rp, ru)):
            return lp == rp && lu == ru
        }
    }
}

/// グローバル設定・プロジェクト設定を読み込み、マージ済みの `ViteaConfig` を生成する。
public enum ConfigLoader {
    /// グローバル設定ファイルの既定パス: `~/.config/viterm/config.json`
    public static func defaultGlobalConfigURL(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("viterm", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    /// プロジェクト設定ファイルのパス: `<repositoryRoot>/.vitea.json`
    public static func projectConfigURL(repositoryRoot: URL) -> URL {
        repositoryRoot.appendingPathComponent(".vitea.json", isDirectory: false)
    }

    /// 指定された URL から設定ファイルを読み込む。
    /// ファイルが存在しない場合は `nil` を返す(エラーにしない)。
    /// ファイルは存在するが JSON が不正な場合は `ConfigLoaderError.invalidJSON` を投げる。
    public static func loadFile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> ViteaConfigFile? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigLoaderError.invalidJSON(path: url.path, underlying: "\(error)")
        }
        do {
            return try JSONDecoder().decode(ViteaConfigFile.self, from: data)
        } catch {
            throw ConfigLoaderError.invalidJSON(path: url.path, underlying: "\(error)")
        }
    }

    /// グローバル設定 + プロジェクト設定(あれば)を読み込みマージした `ViteaConfig` を返す。
    /// どちらのファイルも存在しなければ `ViteaConfig.default` を返す。
    ///
    /// - Parameters:
    ///   - globalURL: グローバル設定ファイルの URL。省略時は既定パスを使う。
    ///   - repositoryRoot: プロジェクト設定 `.vitea.json` を探すリポジトリルート。`nil` ならプロジェクト設定は読まない。
    public static func load(
        globalURL: URL? = nil,
        repositoryRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> ViteaConfig {
        let global = try loadFile(
            at: globalURL ?? defaultGlobalConfigURL(fileManager: fileManager),
            fileManager: fileManager
        )
        let project = try repositoryRoot.flatMap {
            try loadFile(at: projectConfigURL(repositoryRoot: $0), fileManager: fileManager)
        }
        return ViteaConfig.merge(global: global, project: project)
    }
}
