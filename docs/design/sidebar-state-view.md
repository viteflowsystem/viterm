# Design: Sidebar Filter (A) + State Lane View (E)

Status: reviewed (adversarial review applied 2026-07-12; see the implementation note)
Related issues: #2 (sidebar tree filter/search), new issue for the state lane view
Design exploration: https://claude.ai/code/artifact/83ddb620-188e-45a4-879b-6ec7746179ca

## Problem

As registered repositories grow, the sidebar (repository → worktree tree; sessions
roll up into worktree rows as state dots) becomes long and hard to scan. Two
distinct needs emerge:

1. **Reachability** — finding a specific repo/worktree costs a long scroll (issue #2).
2. **Situational awareness** — with many parallel agent sessions, "which session
   is waiting for my input?" matters more than "where is repo X".

## Approach

Two features sharing one filter:

- **A. Incremental filter + state badges** — a filter field above the tree narrows
  repo/worktree rows by name; collapsed rows aggregate session-state counts.
- **E. State lane view** — a toggle switches the sidebar body from the tree to a
  flat list of *sessions* grouped into three lanes: waiting-input / busy / idle.
  Tree = "map" (where things are); lanes = "situation board" (what needs me now).

The tree view, its careful diff-reload policy, and its collapse handling are left
untouched; the lane view is an independent sibling subview toggled by `isHidden`.

## Non-goals

- ⌘P quick-open palette (issue #1) — separate feature; the existing PalettePanel
  already covers command access. This design must not preclude it.
- Pinned/favorite worktrees, "recent" section (proposals B/D) — not now.
- Reordering or grouping changes inside the tree view.

---

## 1. Core layer (VitermCore)

### 1.1 New value type: `SidebarDisplayMode`

```swift
public enum SidebarDisplayMode: String, Sendable, Codable, Equatable {
    case tree
    case state
}
```

### 1.2 `SidebarViewModel` additions

Follow the `activeSessionByWorktree` precedent: state lives in the value type and
`AppModel.rebuildSidebar()` carries it over explicitly on every rebuild.

```swift
public private(set) var filterText: String            // default ""
public private(set) var displayMode: SidebarDisplayMode  // default .tree
```

Both are `init` parameters with defaults, so existing call sites keep compiling.

**Derived, not stored** (computed properties; the stored tree stays complete):

- `filteredRepositories: [RepositoryNode]` — case-insensitive substring match of
  `filterText` against repository name, worktree branch name, and session name.
  Matching rules:
  - A repository matches → keep it with **all** its worktrees.
  - A worktree matches → keep its repository (ancestor) and that worktree with all sessions.
  - A session matches → keep its worktree and repository (session names are
    filterable even though the tree shows no session rows; the match keeps the
    worktree row visible).
  - Empty `filterText` → identical to `repositories` (fast path, no allocation churn).
- `stateLanes: SidebarStateLanes` — sessions from `filteredRepositories` (the
  filter applies in both modes) grouped by state:

```swift
public struct SidebarStateLanes: Sendable, Equatable {
    public var waiting: [StateLaneCard]
    public var busy: [StateLaneCard]
    public var idle: [StateLaneCard]
}

public struct StateLaneCard: Sendable, Equatable, Identifiable {
    public var id: AgentSession.ID       // session id
    public var sessionName: String
    public var state: AgentSession.State // existing nested enum (busy/waitingInput/idle)
    public var repositoryName: String    // denormalized for flat rendering
    public var branch: String
    public var worktreePath: String
    public var stateChangedAt: Date?
}
```

Lane grouping reads each session's `AgentSession.State` directly. The existing
`WorktreeNode.dominantState` (SidebarTreeNodes.swift:31, worktree-level rollup)
is *not* applicable here — lanes are per-session, not per-worktree. Reuse
`SessionStateSummary` for counts; do not reimplement the tally.

Ordering inside each lane: newest `stateChangedAt` first (consistent with the
⌘⇧U "latest waiting" semantics in `jumpToLatestWaiting()`); `nil` sorts last;
ties keep display order.

Mutations:

```swift
public mutating func setFilterText(_ text: String)
public mutating func setDisplayMode(_ mode: SidebarDisplayMode)
```

**Selection semantics with an active filter:** filtering only affects the derived
trees/lanes; `selectedSessionID` / `selectedWorktreePath` are *not* cleared when
the selection is filtered out. The selected terminal stays open; the sidebar
simply doesn't highlight a hidden row. Clearing the filter restores the highlight.
Keyboard navigation (`selectNextWorktree()` etc.) keeps operating on the full
tree — changing nav to respect the filter is a possible follow-up, noted in Open
questions.

### 1.3 Badge aggregation

`RepositoryNode` gains `stateSummary: SessionStateSummary` (same rollup that
`WorktreeNode` already has). The repository row badge shows, when the row is
collapsed (or always — see Open questions): `N待` (waiting count, blue) and
`N作` (busy count, orange), hidden at zero. Rendering reuses the existing
generic pill helper `badge(_:)` (SidebarViewController.swift:422, takes a
`String`); the waiting-only logic lives at its call sites and is what gets
extended, not the helper itself.

**Note on Equatable:** `filterText` / `displayMode` participate in
`SidebarViewModel`'s synthesized `==`. That is correct for the UI reload gate
(§3.2 compares *filtered* trees separately), but any future use of whole-struct
equality must be aware that typing changes equality without changing the tree.

## 2. Services layer (VitermServices)

### 2.1 Carry-over in `rebuildSidebar()`

`AppModel.rebuildSidebar()` (AppModel.swift:208) additionally carries over
`filterText` and `displayMode` — same pattern as the three existing carried
fields. **This is the known-pitfall spot**: forgetting a carry-over compiles
fine (init defaults) and silently resets state. Structural mitigation: add
`SidebarViewModel.rebuilt(repositories:worktrees:sessions:)` — an instance
method that re-inits while carrying over *all* UI state fields in one place —
and make `rebuildSidebar()` call it instead of `init` directly. New carried
fields then have exactly one place to be added. A unit test still asserts the
full carry-over contract.

### 2.2 New AppModel API

```swift
func setSidebarFilter(_ text: String)
func setSidebarDisplayMode(_ mode: SidebarDisplayMode)   // also persists
```

Both mutate `sidebar` and trigger the same UI-refresh path the existing
mutations use (synchronous re-render by the caller, per current convention).

### 2.3 Persistence (display mode only)

Filter text is ephemeral (never persisted). Display mode persists across
launches via the JSON config, following the `RepositoryConfigPersisting`
precedent (no UserDefaults in this codebase):

- `VitermConfigFile` gains optional `sidebarDisplayMode: String?`.
- New protocol `SidebarPreferencePersisting` in `AppModelDependencies` with a
  `LiveSidebarPreferencePersister` writing to `~/.config/viterm/config.json`.
- On launch, `AppModel` seeds `displayMode` from config; unknown values fall
  back to `.tree`.

**Write-back strategy (required):** `config.json` is a user-edited file.
The persister must do read-modify-write at write time — re-decode the file,
set only `sidebarDisplayMode`, re-encode — never serialize a stale in-memory
snapshot that would clobber concurrent user edits to other fields
(`presets`, `discoveryRoots`, …). `VitermConfigFile` is plain Codable with no
comment preservation; that limitation already exists for
`RepositoryConfigPersisting` and is accepted. This also stays compatible with
config hot-reload (GitHub issue #14, not yet implemented): mode changes write
promptly, so a later reload reads back the same value.

## 3. App layer (VitermApp)

### 3.1 Sidebar header (filter field + mode toggle)

Inserted into `SidebarViewController.loadView()`'s container stack directly
before the scroll view (SidebarViewController.swift:~100), with an explicit
width anchor (container alignment is `.leading`).

- `NSSearchField` (compact style) + `NSSegmentedControl` (2 segments: tree icon
  / state icon, `selectedSegment` bound to display mode) in a horizontal stack.
  Narrow-width behavior: the search field has the lower content compression
  resistance and truncates first; the segmented control keeps its fixed size.
- Filter events: `NSSearchField` continuous change → `appModel.setSidebarFilter(_)`.
- **Write-back contract:** `set(viewModel:)` must never clobber live editing.
  Sync `filterField.stringValue` from the model only when (a) the value
  actually differs, and (b) the field is not being edited with IME marked text
  (`currentEditor()?.hasMarkedText() != true`). Without this guard, the 30-second
  auto-refresh (AppModel's timer) would destroy in-progress Japanese input and
  caret position.
- Esc inside the field clears it (`cancelOperation` via `NSTextFieldDelegate`
  `control(_:textView:doCommandBy:)` — same pattern as PalettePanel.swift:374-391).
  No conflict with PalettePanel's own Esc handling: the palette floats above as
  key window and consumes its events first.
- `/` to focus the filter: `performKeyEquivalent` override on the sidebar
  container view. AppKit offers `performKeyEquivalent` to all subviews of the
  window regardless of first responder (see the ⌘V interception in
  Sources/VitermApp/Ghostty/GhosttySurfaceView.swift:354-366), so the guard must
  be: first responder is inside the sidebar **and is not the search field's
  field editor** — otherwise typing `/` *into* the field (branch names like
  `feature/foo`) would be swallowed and re-focus the field instead of inserting
  the character. `/` while the terminal has focus goes to the terminal, unchanged.

### 3.2 Tree view filtering

`SidebarViewController.set(viewModel:)` renders `filteredRepositories` instead
of `repositories`. **Two lines must switch together** (a half-done change fails
silently): the equality gate (`treeUnchanged`, SidebarViewController.swift:156)
and the `rootNodes` mapping (L171) both currently read `repositories`; both
move to `filteredRepositories`. Gate-only → typing changes nothing on screen;
map-only → changes render without reload. With both switched, typing re-renders
only when visible content changes.

Collapse snapshot/restore (L183-199) is keyed by repository ID and is
unaffected by filtering. Scroll position is *not* explicitly preserved across
filter-triggered reloads — accepted: a filtered tree is short and the user's
context is the filter itself. When the filter yields zero rows, reuse the
existing empty-state overlay with a "no match" message (「該当なし」).

### 3.3 Lane view (new subview)

New `SidebarStateListView` (NSStackView-based scrollable list, *not* an
NSOutlineView extension), sibling of the tree's scroll view inside the same
container; mode toggle flips `isHidden` on the two. (Nearest in-repo pattern
is single-view `isHidden` toggling, `toggleSidebar2`,
MainWindowController.swift:474 — the exclusive two-view swap itself is new
code. Standard NSStackView-in-NSScrollView caveats apply: flipped document
view, width pinned to the clip view.)

- Three sections with mono uppercase lane headers (待機中 / 作業中 / アイドル)
  and a count; **empty lanes are omitted entirely**.
- **Idle lane is collapsed by default** (header row with count; click to
  expand). Expansion state is session-volatile, like tree collapse state.
- Card: state dot + `repoName · sessionName` primary, branch secondary
  (mono, faint). Card click → `appModel` session selection — reuses
  `SidebarViewModel.select(sessionID:)`, which already selects the owning
  worktree; the terminal and tab bar follow exactly as tree clicks do.
- Selected card gets the accent treatment consistent with `AccentBarRowView`.
- Re-render policy: rebuild the stack only when `stateLanes` changed
  (Equatable gate, mirroring the tree's reload gate). Lane counts are small
  (= session count), full rebuild of the stack is acceptable; no diffing.
- **Known issue — cards move under the cursor:** every state transition
  re-groups and re-sorts, so a card can jump lanes the moment the user tries
  to click it, causing misclicks. Accepted for v1 (state transitions are
  debounced upstream by `SessionStateMachine`'s ~1.5s idle debounce, which
  bounds the churn); if it proves annoying, the planned mitigation is a short
  re-sort suppression window (~500ms) after mouse-down inside the lane view.
  Tracked in Open questions.
- Empty state: when waiting and busy lanes are both empty (only collapsed idle
  remains, or no sessions at all), show a one-line placeholder
  (「待機中・作業中のセッションはありません」) so the view never looks broken.
- The lane view shows sessions; the tree shows no session rows. This is
  intentional: lanes answer "which session needs me", the tree answers
  "where do I work".
- Filter indication: the shared filter also narrows lanes (§1.2). Because a
  filtered lane view can otherwise be mistaken for "sessions disappeared",
  the search field keeps the active filter text visible at all times (header
  is present in both modes), and the empty-state line switches to 「該当なし」
  when a non-empty filter is active.

### 3.4 View menu + shortcut

Menu item under 表示 (View): 「サイドバーを状態別に表示」, toggling
tree ⇄ state. Shortcut **⌘⌥V**, plus a required guard fix:
`GhosttySurfaceView.performKeyEquivalent` (GhosttySurfaceView.swift:354-365)
currently intercepts ⌘V checking only `.command`; add
`!event.modifierFlags.contains(.option)` so ⌘⌥V is not swallowed as a terminal
paste. (This guard is a correctness fix independent of this feature.)
Fallback if real-device testing still shows interference (libghostty core
keybindings): ⌘⇧O.

### 3.5 Status bar interaction

`StatusBarView` already shows the global `stateSummary`. Clicking the waiting
segment could jump to the state view — noted as a follow-up, not in scope.

## 4. Testing (unit, per repo convention)

`VitermCore` (SidebarViewModelTests style: Swift Testing, Japanese names,
`makeFixture() -> (repos:, worktrees:, sessions:)` tuple fixture):

- Filter: repo-name match keeps whole repo; worktree match keeps ancestors;
  session-name match keeps its worktree; case-insensitivity; empty filter
  returns identical tree; zero-match yields empty array.
- Selection under filter: filtered-out selection is retained, not cleared.
- Lanes: grouping by state; per-lane ordering (stateChangedAt desc, nil last,
  tie → display order); lanes derive from the *filtered* tree; card
  denormalization (repo name / branch correctness).
- `RepositoryNode.stateSummary` rollup.
- Mode/filter round-trip through re-`init` (the carry-over contract, mirroring
  what `rebuildSidebar()` must do).

`VitermServices`:

- `rebuildSidebar()` carries over `filterText` + `displayMode` (regression
  guard for the known pitfall).
- `setSidebarDisplayMode` persists via a fake `SidebarPreferencePersisting`;
  launch seeding from config incl. unknown-string fallback to `.tree`.

UI layer has no unit-test harness (per repo convention); manual verification
via `scripts/make-app.sh` + `VITERM_AUTOSTART_SESSION=1`.

## 5. Implementation plan (suggested issue split)

1. **Core: filter + badges (issue #2)** — `filterText`, `filteredRepositories`,
   `RepositoryNode.stateSummary`, carry-over, tests. Then UI: header field,
   tree renders filtered nodes, generalized badges, `/` & Esc handling.
2. **Core: lanes + mode** — `SidebarDisplayMode`, `stateLanes`, carry-over,
   tests; config persistence.
3. **UI: `SidebarStateListView`** + toggle segment + View menu + ⌘⌥V (with the
   GhosttySurfaceView option-guard fix) + mode persistence wiring.

Each step lands independently; 1 ships value alone.

## 6. Open questions (tentative answers chosen; not blocking)

| Question | Tentative | Notes |
| --- | --- | --- |
| Toggle shortcut | ⌘⌥V + Ghostty guard fix | fallback ⌘⇧O; needs real-device check |
| Idle lane default | collapsed | user preference pending |
| Repo badges when expanded | show only when collapsed | waiting badge stays always-on as today |
| Keyboard nav under filter | operates on full tree | follow-up: constrain to filtered nodes |
| Filter also matches paths? | names only (repo/branch/session) | paths add noise; revisit on demand |
| Lane re-sort churn mitigation | none in v1 (upstream debounce bounds it) | option: ~500ms re-sort suppression after mouse-down |
| Scroll position across filter reloads | not preserved | filtered trees are short; revisit if it hurts |
