import Foundation

/// エージェントセッション起動時に使うコマンドプリセット(claude / codex / zsh 等)。
public struct SessionPreset: Codable, Sendable, Hashable, Identifiable {
    /// プリセット名。設定内で一意。`ViteaConfig.defaultPreset` などから参照される。
    public var name: String
    /// 実行するコマンド(絶対パス、または `PATH` から解決される名前)。
    public var command: String
    /// コマンド引数。
    public var arguments: [String]
    /// 追加で設定する環境変数。
    public var environment: [String: String]

    public init(name: String, command: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }

    public var id: String { name }
}
