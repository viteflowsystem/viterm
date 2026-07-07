import Foundation

/// Errors that can occur while loading config files.
public enum ConfigLoaderError: Error, Equatable, CustomStringConvertible {
    /// The file exists but is invalid JSON or doesn't match the schema.
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

/// Loads the global and project configs and produces a merged `VitermConfig`.
public enum ConfigLoader {
    /// Default path of the global config file: `~/.config/viterm/config.json`
    public static func defaultGlobalConfigURL(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("viterm", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    /// Path of the project config file: `<repositoryRoot>/.viterm.json`
    public static func projectConfigURL(repositoryRoot: URL) -> URL {
        repositoryRoot.appendingPathComponent(".viterm.json", isDirectory: false)
    }

    /// Load a config file from the given URL.
    /// Returns `nil` if the file doesn't exist (not an error).
    /// Throws `ConfigLoaderError.invalidJSON` if the file exists but the JSON is invalid.
    public static func loadFile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> VitermConfigFile? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigLoaderError.invalidJSON(path: url.path, underlying: "\(error)")
        }
        do {
            return try JSONDecoder().decode(VitermConfigFile.self, from: data)
        } catch {
            throw ConfigLoaderError.invalidJSON(path: url.path, underlying: "\(error)")
        }
    }

    /// Load and merge the global config plus the project config (if any) into a
    /// `VitermConfig`. Returns `VitermConfig.default` when neither file exists.
    ///
    /// - Parameters:
    ///   - globalURL: URL of the global config file. Defaults to the standard path.
    ///   - repositoryRoot: Repository root to look for the project config `.viterm.json` in. If `nil`, no project config is read.
    public static func load(
        globalURL: URL? = nil,
        repositoryRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> VitermConfig {
        let global = try loadFile(
            at: globalURL ?? defaultGlobalConfigURL(fileManager: fileManager),
            fileManager: fileManager
        )
        let project = try repositoryRoot.flatMap {
            try loadFile(at: projectConfigURL(repositoryRoot: $0), fileManager: fileManager)
        }
        return VitermConfig.merge(global: global, project: project)
    }
}
