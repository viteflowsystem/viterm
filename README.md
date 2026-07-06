<img src="docs/brand/icon.svg" width="96" alt="viterm">

# viterm

A native macOS terminal for running AI coding agents in parallel.

Spin up any number of agent sessions (Claude Code, Codex, plain shells) per git
worktree, and see every session's state — busy / waiting for input / idle — at a
glance in the sidebar. Terminal rendering is handled natively by
[libghostty](https://ghostty.org), so nothing garbles on resize. Not Electron.

[日本語 README](README.ja.md)

## Install

```sh
brew tap viteflowsystem/tap
brew install --cask viterm
```

Or grab the DMG from the
[releases](https://github.com/viteflowsystem/homebrew-tap/releases)
(Developer ID signed and notarized). Requires macOS 15+ on Apple Silicon.

## Highlights

- **1 worktree : N sessions** — run multiple agents and shells side by side on the same branch
- **Worktree lifecycle** — create from any branch with a configurable path template
  (`~/worktrees/{project}/{branch}`), launch an agent on creation, merge/rebase back, delete from the sidebar
- **State & notifications** — per-session busy/waiting/idle dots; macOS notification when an
  agent asks for input (OSC 9/777 first, screen-text detection as fallback); `⌘⇧U` jumps to the latest one waiting
- **Pane splits** — `⌘D` / `⌘⇧D`; closing a pane keeps the session alive
- **Multi-repo sidebar** with auto-discovery (`discoveryRoots`), session layout restore across
  launches, and terminal appearance inherited from your `~/.config/ghostty/config`

## Keymap

| Key | Action |
|---|---|
| `⌘K` | Command palette |
| `⌘N` | New worktree |
| `⌘T` | New session in the selected worktree |
| `⌘1`–`⌘9` | Switch session |
| `⌘⇧U` | Jump to latest waiting session |
| `⌘D` / `⌘⇧D` | Split pane right / down |
| `⌘⇧W` | Close pane (session survives) |
| `⌘]` | Focus next pane |
| `⌘B` | Toggle sidebar |
| `⌘,` | Settings |

## Configuration

Global config lives at `~/.config/viterm/config.json`, merged with per-project
`.viterm.json`. Common keys are editable from the settings window (`⌘,`).

```json
{
  "worktreePathTemplate": "~/worktrees/{project}/{branch}",
  "defaultPreset": "claude",
  "discoveryRoots": ["~/dev"]
}
```

See [docs/configuration.md](docs/configuration.md) for the full reference
(presets, status hooks, merge rules). Everything works with zero config too.

## Building from source

Requires macOS (arm64) and full Xcode (with the Metal Toolchain — Command Line
Tools alone can't compile the Metal shaders).

```sh
scripts/setup-zig.sh     # pinned Zig toolchain into vendor/zig/
scripts/fetch-ghostty.sh # ghostty at a pinned commit + viterm patches
scripts/build-ghostty.sh # produces GhosttyKit.xcframework
swift build
swift test
scripts/make-app.sh      # assemble .build/viterm.app
```

Known libghostty build issues and workarounds are documented in
[docs/ghostty-integration.md](docs/ghostty-integration.md).

### Architecture

| Target | Role |
|---|---|
| `VitermCore` | Domain models, config, path templates, state detection, view models. UI-independent |
| `GitKit` | `git` CLI wrapper (worktree / branch / merge). UI-independent |
| `VitermServices` | Orchestration layer (`AppModel`); all dependencies injected via protocols |
| `VitermApp` | The AppKit app: sidebar, libghostty surfaces, dialogs, palette |
| `vendor/` | ghostty sources and build artifacts (not tracked; fetched by scripts) |

Release process (signing, notarization, DMG): [docs/RELEASE.md](docs/RELEASE.md).

## License

MIT — see [LICENSE](LICENSE). Bug reports and feature requests welcome in
[Issues](https://github.com/viteflowsystem/viterm/issues).
