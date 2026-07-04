import Foundation

/// detector 実装間で共有する、テキストパターンマッチの小さなヘルパー集。
enum TextSignals {
    /// Claude Code / Codex 等のCLIが「作業中」の表現に使うスピナー・装飾記号。
    static let spinnerCharacters: Set<Character> = Set("⠋⠙⠸⠼⠴⠦⠧⠇⠏⠹✻✽✶✳✢")

    /// 大小文字を無視して、いずれかの部分文字列を含むか。
    static func containsAny(_ line: String, of needles: [String]) -> Bool {
        let lower = line.lowercased()
        return needles.contains { lower.contains($0) }
    }

    /// 正規表現(ICU)でのマッチ判定。
    static func matchesRegex(_ line: String, pattern: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    /// 行頭(前後の空白を無視)がスピナー文字で始まっているか。
    static func startsWithSpinner(_ line: String) -> Bool {
        guard let first = line.trimmingCharacters(in: .whitespaces).first else { return false }
        return spinnerCharacters.contains(first)
    }
}
