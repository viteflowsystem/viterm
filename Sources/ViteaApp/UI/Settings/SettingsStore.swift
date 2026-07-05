import Foundation
import ViteaCore

/// 設定ウィンドウの書き込み窓口。グローバル設定 `~/.config/vitea/config.json` を
/// 「既存 JSON を読み、対象キーだけ差し替えて書き戻す」方式で更新する
/// (この画面で扱わないキーは保全される)。変更は即時保存(macOS 設定の流儀)。
@MainActor
final class SettingsStore {
    /// 保存が成功するたびに呼ばれる(アプリ側の設定リロード用)。
    let onChanged: () -> Void

    static var globalConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vitea/config.json")
    }

    init(onChanged: @escaping () -> Void) {
        self.onChanged = onChanged
    }

    /// 現在の解決済み設定(組み込み既定値とのマージ後)。ペインの初期値表示に使う。
    func currentConfig() -> ViteaConfig {
        (try? ConfigLoader.load(globalURL: Self.globalConfigURL, repositoryRoot: nil)) ?? .default
    }

    /// 生の JSON(ファイルに書かれているキーのみ)。リスト編集(repositories 等)に使う。
    func rawJSON() -> [String: Any] {
        guard let data = try? Data(contentsOf: Self.globalConfigURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    /// JSON の対象キーだけを差し替えて保存する。値に `nil` を渡すとキーを削除する。
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
            NSLog("vitea: 設定の保存に失敗: \(error)")
        }
    }

    /// config.json を既定のエディタで開く(無ければ空の JSON を作ってから)。
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
