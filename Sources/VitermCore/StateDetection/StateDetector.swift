import Foundation

/// Signal that a `StateDetector` can read instantaneously from screen text.
/// A pure text-match result with no debouncing or elapsed-time judgment.
/// `.none` only means "no clear evidence of busy/waitingInput"; it does not
/// mean idle has been settled (settling is done by `SessionStateMachine`'s debounce layer).
public enum DetectionSignal: Sendable, Equatable {
    case busy
    case waitingInput
    case none
}

/// Per-tool strategy that detects state signals from an agent session's screen text.
/// Completely independent of the execution environment (PTY / libghostty etc.);
/// takes only strings (the virtual screen's line array) as input.
public protocol StateDetector: Sendable {
    /// Tool name this detector handles (intended to correspond to `SessionPreset.name` etc.).
    var toolName: String { get }

    /// Determines the signal from the current screen content (visible lines only, no scrollback).
    func detect(screenLines: [String]) -> DetectionSignal
}
