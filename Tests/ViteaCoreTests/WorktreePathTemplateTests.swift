import Testing
@testable import ViteaCore

@Suite("WorktreePathTemplate")
struct WorktreePathTemplateTests {
    let home = "/Users/testuser"
    let repoRoot = "/Users/testuser/dev/vitea"

    func context(branch: String, project: String = "vitea") -> WorktreePathTemplate.Context {
        WorktreePathTemplate.Context(projectName: project, branch: branch, repositoryRoot: repoRoot)
    }

    @Test("branch のスラッシュはハイフンに正規化される")
    func normalizesBranchSlashes() {
        let template = WorktreePathTemplate("~/worktrees/{project}/{branch}")
        let result = template.expand(context: context(branch: "feat/foo"), homeDirectory: home)
        #expect(result == "/Users/testuser/worktrees/vitea/feat-foo")
    }

    @Test("ネストしたブランチ名も全スラッシュがハイフンになる")
    func normalizesNestedBranchSlashes() {
        let template = WorktreePathTemplate("~/worktrees/{project}/{branch}")
        let result = template.expand(context: context(branch: "feat/sub/foo"), homeDirectory: home)
        #expect(result == "/Users/testuser/worktrees/vitea/feat-sub-foo")
    }

    @Test("branch_raw はスラッシュを正規化せずサブディレクトリになる")
    func branchRawPreservesSlashes() {
        let template = WorktreePathTemplate("~/worktrees/{project}/{branch_raw}")
        let result = template.expand(context: context(branch: "feat/foo"), homeDirectory: home)
        #expect(result == "/Users/testuser/worktrees/vitea/feat/foo")
    }

    @Test("プレースホルダとリテラルの混在")
    func literalSuffixMixedWithPlaceholder() {
        let template = WorktreePathTemplate("~/worktrees/{project}/{branch}_hogehoge")
        let result = template.expand(context: context(branch: "feat/foo"), homeDirectory: home)
        #expect(result == "/Users/testuser/worktrees/vitea/feat-foo_hogehoge")
    }

    @Test("~ 単体はホームディレクトリそのものに展開される")
    func tildeAloneExpandsToHome() {
        let template = WorktreePathTemplate("~")
        let result = template.expand(context: context(branch: "main"), homeDirectory: home)
        #expect(result == "/Users/testuser")
    }

    @Test("絶対パステンプレートはそのまま使われ、~・相対解決の対象にならない")
    func absolutePathPassesThrough() {
        let template = WorktreePathTemplate("/tmp/wt/{project}/{branch}")
        let result = template.expand(context: context(branch: "feat/foo"), homeDirectory: home)
        #expect(result == "/tmp/wt/vitea/feat-foo")
    }

    @Test("相対パステンプレートはリポジトリルート基準で解決される")
    func relativePathResolvesAgainstRepositoryRoot() {
        let template = WorktreePathTemplate("../worktrees/{branch}")
        let result = template.expand(context: context(branch: "feat/foo"), homeDirectory: home)
        #expect(result == "/Users/testuser/dev/vitea/../worktrees/feat-foo")
    }

    @Test("リポジトリルートの末尾スラッシュは二重スラッシュを生まない")
    func relativePathHandlesTrailingSlashInRoot() {
        let template = WorktreePathTemplate("wt/{branch}")
        let context = WorktreePathTemplate.Context(
            projectName: "vitea",
            branch: "feat/foo",
            repositoryRoot: "/Users/testuser/dev/vitea/"
        )
        let result = template.expand(context: context, homeDirectory: home)
        #expect(result == "/Users/testuser/dev/vitea/wt/feat-foo")
    }

    @Test("{project} プレースホルダの展開")
    func projectPlaceholderExpansion() {
        let template = WorktreePathTemplate("~/worktrees/{project}-checkout/{branch}")
        let result = template.expand(context: context(branch: "main", project: "my-repo"), homeDirectory: home)
        #expect(result == "/Users/testuser/worktrees/my-repo-checkout/main")
    }

    @Test("全プレースホルダを1つのテンプレートで組み合わせる")
    func allPlaceholdersCombined() {
        let template = WorktreePathTemplate("{project}/{branch}/{branch_raw}")
        let context = WorktreePathTemplate.Context(
            projectName: "vitea",
            branch: "feat/foo",
            repositoryRoot: "/repo"
        )
        let result = template.expand(context: context, homeDirectory: home)
        #expect(result == "/repo/vitea/feat-foo/feat/foo")
    }

    @Test("プレースホルダを含まないリテラルテンプレートも動作する")
    func literalOnlyTemplate() {
        let template = WorktreePathTemplate("~/worktrees/fixed-dir")
        let result = template.expand(context: context(branch: "main"), homeDirectory: home)
        #expect(result == "/Users/testuser/worktrees/fixed-dir")
    }
}
