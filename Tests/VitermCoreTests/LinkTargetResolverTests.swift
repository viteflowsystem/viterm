import Foundation
import Testing
@testable import VitermCore

@Suite("LinkTargetResolver")
struct LinkTargetResolverTests {
    let home = "/Users/testuser"

    @Test("スキーム付き URL はそのまま返す")
    func schemeURL() {
        let url = LinkTargetResolver.resolve("https://example.com/path?q=1", homeDirectory: home)
        #expect(url == URL(string: "https://example.com/path?q=1"))
    }

    @Test("file スキームもそのまま返す")
    func fileSchemeURL() {
        let url = LinkTargetResolver.resolve("file:///tmp/a.txt", homeDirectory: home)
        #expect(url == URL(string: "file:///tmp/a.txt"))
    }

    @Test("絶対パスは file URL になる")
    func absolutePath() {
        let url = LinkTargetResolver.resolve("/tmp/dir/file.swift", homeDirectory: home)
        #expect(url?.isFileURL == true)
        #expect(url?.path == "/tmp/dir/file.swift")
    }

    @Test("チルダはホームに展開される")
    func tildeExpansion() {
        let url = LinkTargetResolver.resolve("~/Documents/memo.md", homeDirectory: home)
        #expect(url?.isFileURL == true)
        #expect(url?.path == "/Users/testuser/Documents/memo.md")
    }

    @Test("チルダ単体はホームそのもの")
    func bareTilde() {
        let url = LinkTargetResolver.resolve("~", homeDirectory: home)
        #expect(url?.path == "/Users/testuser")
    }

    @Test("`..` を含むパスは正規化される")
    func standardizesPath() {
        let url = LinkTargetResolver.resolve("/tmp/dir/../file.txt", homeDirectory: home)
        #expect(url?.path == "/tmp/file.txt")
    }

    @Test("前後の空白・改行はトリムされる")
    func trimsWhitespace() {
        let url = LinkTargetResolver.resolve("  https://example.com \n", homeDirectory: home)
        #expect(url == URL(string: "https://example.com"))
    }

    @Test("空文字列は nil")
    func emptyString() {
        #expect(LinkTargetResolver.resolve("", homeDirectory: home) == nil)
        #expect(LinkTargetResolver.resolve("   ", homeDirectory: home) == nil)
    }

    @Test("スペースを含むパスも file URL として解決できる")
    func pathWithSpaces() {
        let url = LinkTargetResolver.resolve("/tmp/My Folder/file.txt", homeDirectory: home)
        #expect(url?.isFileURL == true)
        #expect(url?.path == "/tmp/My Folder/file.txt")
    }
}
