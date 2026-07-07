import Foundation

/// A signal `StateDetector` can read immediately from screen text.
/// A pure text-match result with no debouncing or elapsed-time judgment.
/// `.none` only means "no clear evidence of busy/waitingInput" — it does not mean idle
/// has been confirmed (confirmation is done by `SessionStateMachine`'s debounce layer).
public enum DetectionSignal: Sendable, Equatable {
    case busy
    case waitingInput
    case none
}

/// Per-tool strategy for detecting state signals from an agent session's screen text.
/// Depends on no runtime environment (PTY / libghostty / etc.); its only input is strings
/// (an array of virtual-screen lines).
public protocol StateDetector: Sendable {
    /// The tool name this detector handles (intended to correspond to `SessionPreset.name`, etc.).
    var toolName: String { get }

    /// Determine the signal from the current screen content (visible lines only, no scrollback).
    func detect(screenLines: [String]) -> DetectionSignal
}
