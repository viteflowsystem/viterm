import Foundation

/// Resolves the default `StateDetector` for a tool name.
public enum StateDetectorRegistry {
    /// Return a detector for a tool name such as `SessionPreset.name`.
    /// Unknown names fall back to the generic shell detector (keeping that name).
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
