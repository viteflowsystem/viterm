import Foundation

/// ブランチ名として不正な理由。`git check-ref-format --branch` 相当のルールのサブセット。
public enum BranchNameValidationError: Sendable, Equatable, CustomStringConvertible {
    case empty
    case containsWhitespace
    case startsWithHyphen
    case endsWithSlash
    case endsWithDot
    case endsWithDotLock
    case containsDoubleDot
    case containsConsecutiveSlashes
    /// `/` で始まる、`/` で終わる、または `//` を含む結果として空になる階層があるか、
    /// いずれかの階層が `.` から始まっている。
    case containsEmptyOrDotPathComponent
    case containsInvalidCharacter(Character)
    case containsAtBrace
    case isSingleAt
    /// 既に同名のローカルブランチが存在する(新規ブランチ作成時のみチェック)。
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

/// `git check-ref-format --branch` が課すルールのサブセットでブランチ名を検証する。
public enum BranchNameValidator {
    /// ASCII 制御文字に加え、git が ref 名に許さない記号。
    private static let invalidCharacters: Set<Character> = ["~", "^", ":", "?", "*", "[", "\\"]

    /// `name` を検証する。問題が無ければ `nil`。
    /// - Parameters:
    ///   - existingLocalBranchNames: 重複チェックに使う既存のローカルブランチ名一覧。
    ///   - checkDuplicate: 重複チェックを行うかどうか(新規にローカルブランチを作らないモードでは `false` にする)。
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
