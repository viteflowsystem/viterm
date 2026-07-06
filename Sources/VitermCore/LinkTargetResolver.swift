import Foundation

/// Resolves a link string that was cmd+clicked in the terminal (a URL or a
/// file path) into a URL that NSWorkspace etc. can open.
///
/// The string passed by libghostty's `GHOSTTY_ACTION_OPEN_URL` is either text
/// matched by the URL regex or the href of an OSC 8 hyperlink, so it is not
/// guaranteed to be a URL with a scheme (reference: Ghostty.App.swift openURL).
public enum LinkTargetResolver {
    /// - Returns: The URL as-is when it has a scheme; otherwise the string is
    ///   interpreted as a file path and returned as a file URL (`~` expands to
    ///   home). Empty strings resolve to nil.
    public static func resolve(
        _ raw: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Passing a scheme-less string (e.g. a plain file path) to URL(string:)
        // would produce a scheme-less URL that cannot be opened properly, so
        // treat it as a file path instead.
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
