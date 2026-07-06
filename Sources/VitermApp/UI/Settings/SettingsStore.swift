import Foundation
import VitermCore

/// Write gateway for the settings window. Updates the global config
/// `~/.config/viterm/config.json` by reading the existing JSON, replacing only the target
/// keys, and writing it back (keys not handled by this screen are preserved). Changes are
/// saved immediately (the macOS settings convention).
@MainActor
final class SettingsStore {
    /// Called every time a save succeeds (for the app-side config reload).
    let onChanged: () -> Void

    static var globalConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/viterm/config.json")
    }

    init(onChanged: @escaping () -> Void) {
        self.onChanged = onChanged
    }

    /// The currently resolved config (after merging with built-in defaults). Used for panes' initial values.
    func currentConfig() -> VitermConfig {
        (try? ConfigLoader.load(globalURL: Self.globalConfigURL, repositoryRoot: nil)) ?? .default
    }

    /// The raw JSON (only the keys written in the file). Used for list editing (repositories, etc.).
    func rawJSON() -> [String: Any] {
        guard let data = try? Data(contentsOf: Self.globalConfigURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    /// Save the JSON, replacing only the target keys. Passing `nil` as a value deletes the key.
    func set(_ values: [String: Any?]) {
        var json = rawJSON()
        for (key, value) in values {
            if let value {
                json[key] = value
            } else {
                json.removeValue(forKey: key)
            }
        }
        do {
            let url = Self.globalConfigURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            onChanged()
        } catch {
            NSLog("viterm: 設定の保存に失敗: \(error)")
        }
    }

    /// Open config.json in the default editor (creating an empty JSON file first if absent).
    func openInEditor() {
        let url = Self.globalConfigURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "{\n}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}

import AppKit
