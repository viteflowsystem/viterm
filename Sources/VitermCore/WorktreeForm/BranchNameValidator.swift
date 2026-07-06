import Foundation

/// Reason a branch name is invalid. A subset of the rules equivalent to `git check-ref-format --branch`.
public enum BranchNameValidationError: Sendable, Equatable, CustomStringConvertible {
    case empty
    case containsWhitespace
    case startsWithHyphen
    case endsWithSlash
    case endsWithDot
    case endsWithDotLock
    case containsDoubleDot
    case containsConsecutiveSlashes
    /// A path component is empty (as a result of starting with `/`, ending with `/`,
    /// or containing `//`), or some component starts with `.`.
    case containsEmptyOrDotPathComponent
    case containsInvalidCharacter(Character)
    case containsAtBrace
    case isSingleAt
    /// A local branch with the same name already exists (checked only when creating a new branch).
    case duplicatesExistingBranch

    public var description: String {
        switch self {
        case .empty:
            return L("Branch name is required")
        case .containsWhitespace:
            return L("Branch names can't contain whitespace")
        case .startsWithHyphen:
            return L("Branch names can't start with \"-\"")
        case .endsWithSlash:
            return L("Branch names can't end with \"/\"")
        case .endsWithDot:
            return L("Branch names can't end with \".\"")
        case .endsWithDotLock:
            return L("Branch names can't end with \".lock\"")
        case .containsDoubleDot:
            return L("Branch names can't contain \"..\"")
        case .containsConsecutiveSlashes:
            return L("Branch names can't contain consecutive slashes")
        case .containsEmptyOrDotPathComponent:
            return L("Path components separated by \"/\" can't be empty or start with \".\"")
        case let .containsInvalidCharacter(character):
            return L("Branch name contains an invalid character: \(String(character))")
        case .containsAtBrace:
            return L("Branch names can't contain \"@{\"")
        case .isSingleAt:
            return L("Branch name can't be just \"@\"")
        case .duplicatesExistingBranch:
            return L("A local branch with this name already exists")
        }
    }
}

/// Validates a branch name against a subset of the rules imposed by `git check-ref-format --branch`.
public enum BranchNameValidator {
    /// Symbols git does not allow in ref names, in addition to ASCII control characters.
    private static let invalidCharacters: Set<Character> = ["~", "^", ":", "?", "*", "[", "\\"]

    /// Validates `name`. Returns `nil` if there is no problem.
    /// - Parameters:
    ///   - existingLocalBranchNames: Names of existing local branches used for the duplicate check.
    ///   - checkDuplicate: Whether to perform the duplicate check (set to `false` in modes that do not create a new local branch).
    public static func validate(
        _ name: String,
        existingLocalBranchNames: [String] = [],
        checkDuplicate: Bool = true
    ) -> BranchNameValidationError? {
        if name.isEmpty { return .empty }
        if name.contains(where: \.isWhitespace) { return .containsWhitespace }
        if name.hasPrefix("-") { return .startsWithHyphen }
        if name.hasSuffix("/") { return .endsWithSlash }
        if name.hasSuffix(".lock") { return .endsWithDotLock }
        if name.hasSuffix(".") { return .endsWithDot }
        if name.contains("..") { return .containsDoubleDot }
        if name.contains("//") { return .containsConsecutiveSlashes }
        if name == "@" { return .isSingleAt }
        if name.contains("@{") { return .containsAtBrace }
        if let invalid = name.first(where: { isInvalidCharacter($0) }) {
            return .containsInvalidCharacter(invalid)
        }

        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0.isEmpty || $0.hasPrefix(".") }) {
            return .containsEmptyOrDotPathComponent
        }

        if checkDuplicate, existingLocalBranchNames.contains(name) {
            return .duplicatesExistingBranch
        }

        return nil
    }

    private static func isInvalidCharacter(_ character: Character) -> Bool {
        if invalidCharacters.contains(character) { return true }
        return character.asciiValue.map { $0 < 0x20 } ?? false
    }
}
