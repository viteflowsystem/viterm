import Foundation

/// Command preset used when launching an agent session (claude / codex / zsh etc.).
public struct SessionPreset: Codable, Sendable, Hashable, Identifiable {
    /// Preset name. Unique within the config. Referenced by `VitermConfig.defaultPreset` and others.
    public var name: String
    /// Command to run (absolute path, or a name resolved via `PATH`).
    public var command: String
    /// Command arguments.
    public var arguments: [String]
    /// Additional environment variables to set.
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

    /// Custom implementation so `arguments` / `environment` can be omitted in the JSON.
    /// Plain `Codable` auto-synthesis does not use `decodeIfPresent` for non-Optional
    /// properties, so the initializer defaults ([]/[:]) do not apply during decoding
    /// (a missing key would produce `keyNotFound`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }
}
