import Foundation
import VitermCore

/// The settings window's write gateway. Updates the global config
/// `~/.config/viterm/config.json` by reading the existing JSON, replacing only the target
/// keys, and writing it back (keys this screen doesn't handle are preserved). Changes
/// save immediately (macOS settings convention).
@MainActor
final class SettingsStore {
    /// Called after each successful save (for the app-side config reload).
    let onChanged: () -> Void

    static var globalConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/viterm/config.json")
    }

    init(onChanged: @escaping () -> Void) {
        self.onChanged = onChanged
    }

    /// The current resolved config (after merging with built-in defaults). Used for panes' initial values.
    func currentConfig() -> VitermConfig {
        (try? ConfigLoader.load(globalURL: Self.globalConfigURL, repositoryRoot: nil)) ?? .default
    }

    /// The raw JSON (only keys written in the file). Used for list editing (repositories, etc.).
    func rawJSON() -> [String: Any] {
        guard let data = try? Data(contentsOf: Self.globalConfigURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    /// Replace only the target key in the JSON and save. Passing `nil` deletes the key.
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

    /// Open config.json in the default editor (creating an empty JSON first if missing).
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
