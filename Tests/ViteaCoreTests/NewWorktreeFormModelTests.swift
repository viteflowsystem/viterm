import Foundation
import Testing
@testable import ViteaCore

@Suite("NewWorktreeFormModel")
struct NewWorktreeFormModelTests {
    let repository = Repository(name: "vitea", path: "/repo/vitea")
    let home = "/Users/testuser"

    func makeForm(
        branchName: String = "",
        sourceMode: NewWorktreeFormModel.SourceMode = .newBranch,
        baseBranchName: String? = nil,
        remoteName: String? = nil,
        pathTemplateOverride: String? = nil,
        availableBranches: [AvailableBranch] = [
            AvailableBranch(name: "main", kind: .local),
            AvailableBranch(name: "origin/main", kind: .remote),
        ],
        existingWorktreePaths: [String] = []
    ) -> NewWorktreeFormModel {
        NewWorktreeFormModel(
            repository: repository,
            defaultPathTemplate: WorktreePathTemplate("~/worktrees/{project}/{branch}"),
            availableBranches: availableBranches,
            existingWorktreePaths: existingWorktreePaths,
            homeDirectory: home,
            branchName: branchName,
            sourceMode: sourceMode,
            baseBranchName: baseBranchName,
            remoteName: remoteName,
            pathTemplateOverride: pathTemplateOverride
        )
    }

    @Test("ブランチ名が空ならプレビューはnil")
    func emptyBranchNameHasNoPreview() {
        let form = makeForm(branchName: "")
        #expect(form.pathPreview == nil)
    }

    @Test("パスプレビューは既定テンプレートで展開される")
    func pathPreviewUsesDefaultTemplate() {
        let form = makeForm(branchName: "feat/palette")
        #expect(form.pathPreview == "/Users/testuser/worktrees/vitea/feat-palette")
    }

    @Test("パステンプレートのその場上書きが優先される")
    func pathTemplateOverrideTakesPriority() {
        let form = makeForm(branchName: "feat/palette", pathTemplateOverride: "~/custom/{branch_raw}")
        #expect(form.pathPreview == "/Users/testuser/custom/feat/palette")
    }

    @Test("既存worktreeパスと衝突していればhasPathCollisionがtrue")
    func detectsPathCollision() {
        let form = makeForm(
            branchName: "feat/palette",
            existingWorktreePaths: ["/Users/testuser/worktrees/vitea/feat-palette"]
        )
        #expect(form.hasPathCollision == true)
        #expect(form.isValid == false)
    }

    @Test("衝突が無ければhasPathCollisionはfalse")
    func noPathCollision() {
        let form = makeForm(
            branchName: "feat/palette",
            existingWorktreePaths: ["/Users/testuser/worktrees/vitea/other-branch"]
        )
        #expect(form.hasPathCollision == false)
    }

    @Test("newBranchモードで既存ローカルブランチ名と重複していればisValidはfalse")
    func newBranchDuplicateIsInvalid() {
        let form = makeForm(branchName: "main")
        #expect(form.branchNameError == .duplicatesExistingBranch)
        #expect(form.isValid == false)
        #expect(form.buildRequest() == nil)
    }

    @Test("existingLocalBranchモードでは既存ブランチ名でも重複エラーにならない")
    func existingLocalBranchModeSkipsDuplicateCheck() {
        let form = makeForm(branchName: "main", sourceMode: .existingLocalBranch)
        #expect(form.branchNameError == nil)
        #expect(form.isValid == true)
    }

    @Test("空ブランチ名はisValidがfalseでbuildRequestはnil")
    func emptyBranchNameIsInvalid() {
        let form = makeForm(branchName: "")
        #expect(form.isValid == false)
        #expect(form.buildRequest() == nil)
    }

    @Test("newBranchモードのbuildRequestはbaseBranchNameをstartPointに使う")
    func buildRequestNewBranch() {
        let form = makeForm(branchName: "feat/palette", baseBranchName: "develop")
        let request = form.buildRequest()
        #expect(request?.source == .newBranch(name: "feat/palette", startPoint: "develop"))
        #expect(request?.worktreePath == "/Users/testuser/worktrees/vitea/feat-palette")
        #expect(request?.repository == repository)
    }

    @Test("existingLocalBranchモードのbuildRequestはexistingLocalBranchソースになる")
    func buildRequestExistingLocalBranch() {
        let form = makeForm(branchName: "main", sourceMode: .existingLocalBranch)
        let request = form.buildRequest()
        #expect(request?.source == .existingLocalBranch(name: "main"))
    }

    @Test("remoteBranchモードのbuildRequestはremoteBranchソースになり、remoteNameの既定はorigin")
    func buildRequestRemoteBranchDefaultsToOrigin() {
        let form = makeForm(branchName: "feature", sourceMode: .remoteBranch)
        let request = form.buildRequest()
        #expect(request?.source == .remoteBranch(remote: "origin", name: "feature", newLocalName: nil))
    }

    @Test("remoteBranchモードでremoteNameを指定するとそれが使われる")
    func buildRequestRemoteBranchCustomRemote() {
        let form = makeForm(branchName: "feature", sourceMode: .remoteBranch, remoteName: "upstream")
        let request = form.buildRequest()
        #expect(request?.source == .remoteBranch(remote: "upstream", name: "feature", newLocalName: nil))
    }

    @Test("remoteBranchモードも既存ローカルブランチ名と重複するとinvalid")
    func remoteBranchModeChecksDuplicateToo() {
        let form = makeForm(branchName: "main", sourceMode: .remoteBranch)
        #expect(form.branchNameError == .duplicatesExistingBranch)
    }

    @Test("existingLocalBranchNamesはavailableBranchesからlocalのみ抽出する")
    func existingLocalBranchNamesFiltersLocalOnly() {
        let form = makeForm(branchName: "")
        #expect(form.existingLocalBranchNames == ["main"])
    }

    @Test("buildRequestに渡るpathTemplateはeffectivePathTemplateと一致する")
    func requestCarriesEffectiveTemplate() {
        let form = makeForm(branchName: "feat/x", pathTemplateOverride: "~/custom/{branch}")
        let request = form.buildRequest()
        #expect(request?.pathTemplate == WorktreePathTemplate("~/custom/{branch}"))
    }

    @Test("copySessionData・launchSessionPresetName・runHookCommandがrequestに引き継がれる")
    func requestCarriesOptions() {
        var form = makeForm(branchName: "feat/x")
        form.copySessionData = true
        form.launchSessionPresetName = "claude"
        form.runHookCommand = "npm install"

        let request = form.buildRequest()
        #expect(request?.copySessionData == true)
        #expect(request?.launchSessionPresetName == "claude")
        #expect(request?.runHookCommand == "npm install")
    }
}
