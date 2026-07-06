import Foundation

/// ターミナル上で cmd+クリックされたリンク文字列(URL またはファイルパス)を、
/// NSWorkspace 等で開ける URL に解決する。
///
/// libghostty の `GHOSTTY_ACTION_OPEN_URL` が渡す文字列は、URL 正規表現にマッチした
/// テキストか OSC 8 ハイパーリンクの href で、スキーム付き URL とは限らない
/// (実装リファレンス: Ghostty.App.swift の openURL)。
public enum LinkTargetResolver {
    /// - Returns: スキーム付きならその URL、それ以外はファイルパスとして解釈した
    ///   file URL(`~` はホームへ展開)。空文字列は nil。
    public static func resolve(
        _ raw: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // スキームの無い文字列(例: プレーンなファイルパス)を URL(string:) に渡すと
        // スキームレス URL ができてしまい正しく開けないため、ファイルパスとして扱う。
        if let candidate = URL(string: trimmed), candidate.scheme != nil {
            return candidate
        }

        var path = trimmed
        if path == "~" {
            path = homeDirectory
        } else if path.hasPrefix("~/") {
            path = homeDirectory + String(path.dropFirst(1))
        }
        return URL(filePath: NSString(string: path).standardizingPath)
    }
}
