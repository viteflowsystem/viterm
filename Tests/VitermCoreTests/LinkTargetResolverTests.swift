import Foundation
import Testing
@testable import VitermCore

@Suite("LinkTargetResolver")
struct LinkTargetResolverTests {
    let home = "/Users/testuser"

    @Test("URL with a scheme is returned as-is")
    func schemeURL() {
        let url = LinkTargetResolver.resolve("https://example.com/path?q=1", homeDirectory: home)
        #expect(url == URL(string: "https://example.com/path?q=1"))
    }

    @Test("file scheme is returned as-is")
    func fileSchemeURL() {
        let url = LinkTargetResolver.resolve("file:///tmp/a.txt", homeDirectory: home)
        #expect(url == URL(string: "file:///tmp/a.txt"))
    }

    @Test("absolute path becomes a file URL")
    func absolutePath() {
        let url = LinkTargetResolver.resolve("/tmp/dir/file.swift", homeDirectory: home)
        #expect(url?.isFileURL == true)
        #expect(url?.path == "/tmp/dir/file.swift")
    }

    @Test("tilde expands to home directory")
    func tildeExpansion() {
        let url = LinkTargetResolver.resolve("~/Documents/memo.md", homeDirectory: home)
        #expect(url?.isFileURL == true)
        #expect(url?.path == "/Users/testuser/Documents/memo.md")
    }

    @Test("bare tilde is home itself")
    func bareTilde() {
        let url = LinkTargetResolver.resolve("~", homeDirectory: home)
        #expect(url?.path == "/Users/testuser")
    }

    @Test("paths containing `..` are standardized")
    func standardizesPath() {
        let url = LinkTargetResolver.resolve("/tmp/dir/../file.txt", homeDirectory: home)
        #expect(url?.path == "/tmp/file.txt")
    }

    @Test("leading/trailing whitespace and newlines are trimmed")
    func trimsWhitespace() {
        let url = LinkTargetResolver.resolve("  https://example.com \n", homeDirectory: home)
        #expect(url == URL(string: "https://example.com"))
    }

    @Test("empty string resolves to nil")
    func emptyString() {
        #expect(LinkTargetResolver.resolve("", homeDirectory: home) == nil)
        #expect(LinkTargetResolver.resolve("   ", homeDirectory: home) == nil)
    }

    @Test("paths with spaces resolve to a file URL")
    func pathWithSpaces() {
        let url = LinkTargetResolver.resolve("/tmp/My Folder/file.txt", homeDirectory: home)
        #expect(url?.isFileURL == true)
        #expect(url?.path == "/tmp/My Folder/file.txt")
    }
}
