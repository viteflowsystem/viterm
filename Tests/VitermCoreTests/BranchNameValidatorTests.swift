import Testing
@testable import VitermCore

@Suite("BranchNameValidator")
struct BranchNameValidatorTests {
    @Test("有効なブランチ名はnilを返す")
    func validNames() {
        #expect(BranchNameValidator.validate("main") == nil)
        #expect(BranchNameValidator.validate("feat/palette") == nil)
        #expect(BranchNameValidator.validate("fix-123") == nil)
    }

    @Test("空文字はempty")
    func empty() {
        #expect(BranchNameValidator.validate("") == .empty)
    }

    @Test("空白を含むとcontainsWhitespace")
    func whitespace() {
        #expect(BranchNameValidator.validate("feat sidebar") == .containsWhitespace)
        #expect(BranchNameValidator.validate("feat\tsidebar") == .containsWhitespace)
    }

    @Test("先頭がハイフンだとstartsWithHyphen")
    func startsWithHyphen() {
        #expect(BranchNameValidator.validate("-feat") == .startsWithHyphen)
    }

    @Test("末尾が/だとendsWithSlash")
    func endsWithSlash() {
        #expect(BranchNameValidator.validate("feat/") == .endsWithSlash)
    }

    @Test("末尾が.lockだとendsWithDotLock")
    func endsWithDotLock() {
        #expect(BranchNameValidator.validate("feat.lock") == .endsWithDotLock)
    }

    @Test("末尾が.だとendsWithDot")
    func endsWithDot() {
        #expect(BranchNameValidator.validate("feat.") == .endsWithDot)
    }

    @Test("..を含むとcontainsDoubleDot")
    func doubleDot() {
        #expect(BranchNameValidator.validate("feat..sidebar") == .containsDoubleDot)
    }

    @Test("連続する/はcontainsConsecutiveSlashes")
    func consecutiveSlashes() {
        #expect(BranchNameValidator.validate("feat//sidebar") == .containsConsecutiveSlashes)
    }

    @Test("先頭が/、または階層が.始まりだとcontainsEmptyOrDotPathComponent")
    func emptyOrDotPathComponent() {
        #expect(BranchNameValidator.validate("/feat") == .containsEmptyOrDotPathComponent)
        #expect(BranchNameValidator.validate("feat/.hidden") == .containsEmptyOrDotPathComponent)
    }

    @Test("不正な記号はcontainsInvalidCharacter")
    func invalidCharacters() {
        #expect(BranchNameValidator.validate("feat~1") == .containsInvalidCharacter("~"))
        #expect(BranchNameValidator.validate("feat^1") == .containsInvalidCharacter("^"))
        #expect(BranchNameValidator.validate("feat:1") == .containsInvalidCharacter(":"))
        #expect(BranchNameValidator.validate("feat?1") == .containsInvalidCharacter("?"))
        #expect(BranchNameValidator.validate("feat*1") == .containsInvalidCharacter("*"))
        #expect(BranchNameValidator.validate("feat[1") == .containsInvalidCharacter("["))
        #expect(BranchNameValidator.validate("feat\\1") == .containsInvalidCharacter("\\"))
    }

    @Test("制御文字もcontainsInvalidCharacter")
    func controlCharacters() {
        #expect(BranchNameValidator.validate("feat\u{0007}sidebar") == .containsInvalidCharacter("\u{0007}"))
    }

    @Test("@{を含むとcontainsAtBrace")
    func atBrace() {
        #expect(BranchNameValidator.validate("feat@{upstream}") == .containsAtBrace)
    }

    @Test("@単体はisSingleAt")
    func singleAt() {
        #expect(BranchNameValidator.validate("@") == .isSingleAt)
    }

    @Test("既存ローカルブランチと重複していればduplicatesExistingBranch")
    func duplicate() {
        let error = BranchNameValidator.validate("main", existingLocalBranchNames: ["main", "develop"])
        #expect(error == .duplicatesExistingBranch)
    }

    @Test("checkDuplicateがfalseなら重複チェックをスキップする")
    func duplicateCheckCanBeDisabled() {
        let error = BranchNameValidator.validate(
            "main", existingLocalBranchNames: ["main"], checkDuplicate: false
        )
        #expect(error == nil)
    }

    @Test("リモートブランチ名(重複チェック対象外)との一致はduplicateにならない")
    func remoteNamesDoNotCountAsDuplicates() {
        // existingLocalBranchNames is assumed to receive locals only, so passing a
        // remote-style string doesn't count as a duplicate.
        let error = BranchNameValidator.validate("origin/main", existingLocalBranchNames: ["main"])
        #expect(error == nil)
    }
}
