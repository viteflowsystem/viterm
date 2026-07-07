import Foundation

/// Reasons a branch name is invalid. A subset of the rules equivalent to `git check-ref-format --branch`.
public enum BranchNameValidationError: Sendable, Equatable, CustomStringConvertible {
    case empty
    case containsWhitespace
    case startsWithHyphen
    case endsWithSlash
    case endsWithDot
    case endsWithDotLock
    case containsDoubleDot
    case containsConsecutiveSlashes
    /// A path component ends up empty (leading `/`, trailing `/`, or a `//`), or some
    /// component starts with `.`.
    case containsEmptyOrDotPathComponent
    case containsInvalidCharacter(Character)
    case containsAtBrace
    case isSingleAt
    /// A local branch with the same name already exists (checked only when creating a new branch).
    case duplicatesExistingBranch

    public var description: String {
        switch self {
        case .empty:
            return "ブランチ名を入力してください"
        case .containsWhitespace:
            return "ブランチ名に空白は使えません"
        case .startsWithHyphen:
            return "ブランチ名を \"-\" で始めることはできません"
        case .endsWithSlash:
            return "ブランチ名を \"/\" で終えることはできません"
        case .endsWithDot:
            return "ブランチ名を \".\" で終えることはできません"
        case .endsWithDotLock:
            return "ブランチ名を \".lock\" で終えることはできません"
        case .containsDoubleDot:
            return "ブランチ名に \"..\" は使えません"
        case .containsConsecutiveSlashes:
            return "ブランチ名に連続した \"/\" は使えません"
        case .containsEmptyOrDotPathComponent:
            return "\"/\" 区切りの各階層を空や \".\" 始まりにすることはできません"
        case let .containsInvalidCharacter(character):
            return "ブランチ名に使えない文字が含まれています: \(character)"
        case .containsAtBrace:
            return "ブランチ名に \"@{\" は使えません"
        case .isSingleAt:
            return "ブランチ名を \"@\" だけにすることはできません"
        case .duplicatesExistingBranch:
            return "同名のローカルブランチが既に存在します"
        }
    }
}

/// Validates branch names against a subset of the rules imposed by `git check-ref-format --branch`.
public enum BranchNameValidator {
    /// Symbols git disallows in ref names, in addition to ASCII control characters.
    private static let invalidCharacters: Set<Character> = ["~", "^", ":", "?", "*", "[", "\\"]

    /// Validate `name`. Returns `nil` if there is no problem.
    /// - Parameters:
    ///   - existingLocalBranchNames: Existing local branch names used for the duplicate check.
    ///   - checkDuplicate: Whether to run the duplicate check (set `false` in modes that don't create a new local branch).
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
