import Foundation

/// エージェントセッション起動時に使うコマンドプリセット(claude / codex / zsh 等)。
public struct SessionPreset: Codable, Sendable, Hashable, Identifiable {
    /// プリセット名。設定内で一意。`VitermConfig.defaultPreset` などから参照される。
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

    private enum CodingKeys: String, CodingKey {
        case name, command, arguments, environment
    }

    /// `arguments` / `environment` を JSON 側で省略できるようにするためのカスタム実装。
    /// 素の `Codable` 自動合成は非 Optional プロパティに `decodeIfPresent` を使わないため、
    /// 初期化子の既定値([]/[:])はデコード時には効かない(キーが無いと `keyNotFound` になる)。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }
}
