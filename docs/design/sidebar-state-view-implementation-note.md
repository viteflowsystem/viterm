# Implementation Note: Sidebar Filter (A) + State Lane View (E)

Working log for the design phase. Updated as work progresses.
Design reference: https://claude.ai/code/artifact/83ddb620-188e-45a4-879b-6ec7746179ca

## Status

- [x] Kickoff (2026-07-12)
- [x] Codebase research (parallel agents)
- [x] Design document draft (`docs/design/sidebar-state-view.md`)
- [x] Adversarial review (multi-perspective) + revisions
- [x] Final design ready for implementation issues

## Decisions (tentative — flagged for user confirmation, not blocking)

| Topic | Tentative decision | Confidence |
| --- | --- | --- |
| View toggle shortcut | **decided**: Cmd+B = tree⇄state, Cmd+Shift+B = show/hide (user, 2026-07-12) | done |
| Idle lane default | collapsed (not hidden) | needs user confirmation |
| State view granularity | per-session | high |
| Repo headers inside lanes | none (flat; repo shown inside card) | high |
| Filter scope | shared across both view modes | high |
| Empty lanes | removed entirely | high |
| Lane order within lane | most recent stateChangedAt first | high |

## Implementation status

- [x] Step 1 core (issue #2): filterText / filteredRepositories / RepositoryNode.stateSummary / rebuilt() carry-over + tests (commit fe92730)
- [x] Step 1 UI: search field header, filtered rendering, collapsed busy badge, "/" & Esc, IME-safe write-back (commit 6b6035b). Verified on device: narrowing, 該当なし, Esc clear, selection retention, collapsed badge, slash focus. Note: clicking a worktree row moves focus to the terminal, so "/" is mainly useful right after Esc or when the tree has focus — as designed, but worth watching.
- [x] Step 2 (issue #21): SidebarDisplayMode + stateLanes + config persistence (read-modify-write), launch seeding, carry-over + tests (commit 69b6947)
- [x] Step 3 (issue #22): SidebarStateListView (lanes UI), header segmented control, Cmd+B mode toggle (reveals hidden sidebar first), Cmd+Shift+B show/hide with divider-collapse fix, Ghostty plain-⌘V-only paste guard (commit 7f9b018)
- [x] Sidebar collapse rework: hand-rolled collapse variants of the plain NSSplitView failed differently — divider-to-0 ghosted the header (frames correct, stale pixels, healed on deactivate; confirmed via AX geometry + zero constraint logs), setPosition-while-hidden wedged the divider. Web research (Apple Forums thread 74369, NSVisualEffectView backdrop caching) confirmed zero-width collapse is a known minefield. An NSSplitViewController migration (833084f) placed the sidebar on the wrong side and was reverted (5fca354). **Final implementation (379fb5f): detach/re-insert of the sidebar pane** + priority-999 full-width constraints + compressible segmented control. Known issue: one report of a hang under very rapid Cmd+Shift+B spam, not reproducible under automation (10–30x toggles fine); needs a `sample` of a hung process.
- [ ] On-device verification by the user (checklist below)

### On-device verification checklist (user)

1. Cmd+B → サイドバーが状態レーン(待機中/作業中/アイドル)に切り替わる。もう一度で戻る
2. ヘッダ右のセグメントでも同じ切替ができ、Cmd+B と同期する
3. アイドルレーンは既定で折りたたみ。ヘッダクリックで展開/折りたたみ
4. レーンのカードをクリック → そのセッションにフォーカス移動(タブ・ターミナル追従)
5. フィルタ文字列が状態ビューにも効く(絞った状態でモード切替しても維持)
6. 待機中・作業中が空のとき「待機中・作業中のセッションはありません」の1行が出る
7. モードが config.json に保存され、再起動後も維持される(`sidebarDisplayMode: "state"`)
8. config.json の他フィールド(presets等の手編集)が切替後も消えていない
9. Cmd+Shift+B → サイドバーが領域ごと消える(以前の「空領域が残る」が直っている)。再度で元の幅に復元
10. ターミナルで ⌘⌥V を押してもペーストされない(⌘V は従来どおりペースト)

## Progress log

- 2026-07-12: Note created. Launching research agents (sidebar UI, AppModel/state flow, keyboard shortcuts/persistence).
- 2026-07-12: Sidebar UI research done. Key findings:
  - **The sidebar has NO session rows** — sessions were removed in the tab redesign; worktree rows roll up session states as dots (`stateDot(for:)`, SidebarViewController.swift:379). The artifact's mocks showing session rows in the tree are outdated. Impacts E: lane cards at session granularity are *new* UI, not a rearrangement; also A's filter targets are repo/worktree names (+ maybe session names without visible rows — needs a decision).
  - Reload policy: `set(viewModel:)` skips `reloadData()` when `repositories` unchanged (Equatable, L156); collapse state snapshot/restore is session-volatile, no persistence.
  - Insertion point for filter field + view toggle: `loadView()` container stack, just before scrollView (L100); needs explicit width anchor (container alignment is .leading).
  - E recommendation from research: do NOT extend NSOutlineView; add an independent lane subview (NSStackView or sectioned NSTableView) toggled via `isHidden`, fed from existing `flattenedSessions`. Selection propagation can reuse `select(sessionID:)` (worktree follows session).
  - waiting badge (`badge()`, L422) and StatusBarView's `stateSummary` usage already cover much of A's badge aggregation.
- 2026-07-12: AppModel + shortcuts research done. Key findings:
  - `rebuildSidebar()` (AppModel.swift:208) is the single rebuild point; carried-over state is exactly `selectedSessionID` / `selectedWorktreePath` / `activeSessionByWorktree`. Filter text & view mode should follow the same carry-over pattern; known pitfall = forgetting to carry over on init.
  - No UserDefaults anywhere; persistence is JSON config (`~/.config/viterm/config.json`, `RepositoryConfigPersisting` as the protocol precedent). View mode persistence → new config field + persister protocol.
  - **⌘⌥V conflict**: `GhosttySurfaceView.performKeyEquivalent` (L354) intercepts ⌘V checking only `.command`, ignoring `.option` — ⌘⌥V would paste into the terminal instead. Either guard `.option` there (correct fix regardless) or pick alternative (⌘⇧O / ⌘.). Tentative: fix the guard AND use ⌘⌥V.
  - Focus-scoped key precedent: PalettePanel's NSSearchField + `doCommandBy` (moveUp/moveDown/cancelOperation). Sidebar has no keyDown override today; `/`-to-focus needs a container-level performKeyEquivalent scoped to sidebar focus — new pattern.
  - `SessionStateSummary` + `WorktreeNode.dominantState` already exist and cover badge/lane math. Tests: Swift Testing, Japanese test names, `makeFixture()` style.
- 2026-07-12: All research complete → drafting `docs/design/sidebar-state-view.md`.
- 2026-07-12: Draft complete. Adversarial review started (2 parallel: correctness-vs-code / AppKit+UX).
- 2026-07-12: AppKit+UX review returned. Findings to fold in (pending correctness review):
  - **C1** Model→field write-back unspecified; naive `stringValue` sync during 30s auto-refresh destroys IME marked text. Fix: spec a "set(viewModel:) must not clobber live editing" contract (skip when `hasMarkedText`, skip when equal).
  - **C2** `/`-focus override would swallow "/" typed *into* the search field (performKeyEquivalent is offered to all subviews regardless of first responder — confirmed via GhosttySurfaceView precedent). Branch names like `feature/foo` hit this constantly. Fix: guard must exclude the search field itself being first responder.
  - **M1** The reload gate (L156) and `rootNodes` mapping (L171) must switch to `filteredRepositories` *together*; spec as an explicit pair.
  - **M2** Lane re-sort on every state change → cards jump under the cursor; add known-issue note + mitigation option (short re-sort suppression after interaction), or explicitly defer as P2.
  - **M3** Narrow-sidebar header layout: search field compresses first; segmented control keeps fixed size. Specify priorities.
  - **m1** Esc: note PalettePanel modality assumption. **m2** All-idle case renders a nearly empty list; add empty-state line (e.g. 「待機中・作業中のセッションはありません」).
- 2026-07-12: Correctness review (vs. actual code) returned. Verified findings applied:
  - **C1** `AgentSessionState` doesn't exist → `AgentSession.State` (nested enum). Fixed in §1.2.
  - **C2** `SessionStateSummary` / `dominantState` are existing helpers; lanes read per-session state directly, counts reuse the summary. Clarified.
  - **C3** "AccentBarRowView doesn't exist" — **false positive**; verified by grep: SidebarViewController.swift:575. Rejected, no change.
  - **C4** `toggleSidebar2` is single-view isHidden only; two-view exclusive swap is new code. Wording fixed.
  - **C5** Config write-back must be read-modify-write (re-decode → set one field → re-encode), never a stale snapshot. Added to §2.3.
  - **C6** "issue #14 doesn't exist" — reviewer searched code only; it exists on GitHub (config hot-reload). Reworded as future-feature compatibility.
  - **M1** Scroll position across filter reloads: explicitly accepted as not preserved (open question). **M2** Structural carry-over protection: added `rebuilt(...)` helper so carried fields have one home. **M3** `badge(_:)` is a generic pill helper; call sites extended. **M4** Synthesized `==` includes filterText — noted. Minor line-number corrections applied.
- 2026-07-12: Shortcut decided with the user: **Cmd+B = tree⇄state toggle** (reveals sidebar if hidden), **Cmd+Shift+B = sidebar show/hide** (reassigned). User also reported the existing hide is broken — `toggleSidebar2` flips `isHidden` only, leaving the NSSplitView pane area; verified in code (MainWindowController.swift:474, sidebar is an arrangedSubview at L218). Collapse fix bundled into the design (§3.4).
- 2026-07-12: All UX findings (C1 IME write-back contract, C2 `/`-swallow guard, M1 paired-line switch, M2 lane-churn known issue, M3 narrow-header priorities, m1/m2) folded into §3.1–3.3. **Design finalized.** Next: implementation issues (plan in §5), user confirmations still pending: toggle shortcut ⌘⌥V (needs real-device check vs libghostty), idle-lane default (collapsed).
