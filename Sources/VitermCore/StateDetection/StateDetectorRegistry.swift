import Foundation

/// ツール名から既定の `StateDetector` を解決する。
public enum StateDetectorRegistry {
    /// `SessionPreset.name` などのツール名から detector を返す。
    /// 未知の名前は汎用シェル detector にフォールバックする(その名前を保持する)。
    public static func detector(forToolName toolName: String) -> any StateDetector {
        switch toolName.lowercased() {
        case "claude":
            return ClaudeStateDetector()
        case "codex":
            return CodexStateDetector()
        default:
            return GenericShellStateDetector(toolName: toolName)
        }
    }
}
