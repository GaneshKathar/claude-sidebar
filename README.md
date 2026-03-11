# Claude Sidebar

A macOS floating panel that monitors iTerm2 windows and Claude Code sessions in real time. Sits as a slim sidebar on the right edge of your screen, auto-expanding on hover to show window details, tab status, git branches, and running processes.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![Architecture](https://img.shields.io/badge/arch-arm64-lightgrey)

## Features

- **Floating sidebar** — always-on-top panel that auto-expands on hover, collapses when you move away
- **Minimal mode** — compact, collapsed-only view (no hover expand); toggle via Settings
- **Window-centric view** — shows all iTerm2 windows with their tabs, not just configured repos
- **Real-time Claude status** via Claude Code hooks (working / idle / needs attention)
- **Process monitoring** — detects running commands (make, bazel, etc.) with duration and exit status
- **Color-coded indicators** — blue (working), green (idle), red (alert/error), yellow (process running)
- **Git branch display** — shows current branch for each tab
- **Stable window labels** — repo windows show custom labels (S1, S2...), non-repo windows get sequential numbers (1, 2, 3...)
- **Keyboard shortcuts** — Opt+Shift+1-9 to focus windows, Opt+Shift+0 to hide/show sidebar
- **Left/right dock snapping** — drag the sidebar to either screen edge
- **Auto-start Claude** — optionally launch Claude Code when opening a repo window
- **iTerm2 integration** — click a tab card to focus its terminal session
- **Configurable font scale** — adjust UI text size from 80% to 150%
- **Settings UI** — manage repos, poll intervals, timeouts, and font size
- **First-time setup** — auto-detects sdmain repos and shows settings on first launch
- **Hook installer** — one-click prompt generation to configure Claude Code hooks
- **Launch at login** — optional auto-start on login
- **DMG packaging** — share with teammates via a single `.dmg` file

## Requirements

- macOS 13.0+ (Apple Silicon / arm64)
- Xcode Command Line Tools (`xcode-select --install`)
- iTerm2
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI (optional, for Claude session tracking)

## Build

```bash
git clone git@github.com:GaneshKathar/claude-sidebar.git
cd claude-sidebar
bash build.sh
```

This compiles `main.swift` + `Sources/*.swift` into `ClaudeSidebar.app`.

## Install

### Option A: Run from source

```bash
open ClaudeSidebar.app
```

If macOS blocks it: right-click the app → **Open** → **Open**.

### Option B: Package as DMG

```bash
bash package.sh
```

This builds and creates `ClaudeSidebar.dmg`. Share it with others — they just drag the `claude-sidebar` folder wherever they like and open the app.

## Setup

### 1. Configure repositories

On first launch the app auto-detects `sdmain*` repos and opens Settings. Otherwise, hover over the sidebar → click **Settings** in the footer.

- Add your repo paths (e.g. `~/rubrik/sdmain-1`)
- Optionally set a custom `label` per repo (e.g. `"S1"`) — defaults to the repo number
- Repo windows show their label; non-repo iTerm windows get sequential numbers (1, 2, 3...)
- Enable **Minimal View** for a compact, collapsed-only sidebar
- Enable **Auto-start Claude** to launch Claude Code when opening a missing repo window

Settings are saved to `config.json` next to the app.

### 2. Install Claude Code hooks

The sidebar receives Claude status updates via [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks). These must be added to your `~/.claude/settings.json`.

From **Settings** → **Claude Hooks** section:

1. Click **"Copy Install Prompt"**
2. Click **"Copy to Clipboard"**
3. Paste the prompt into any Claude Code session — it will merge the hooks into your settings

This installs hooks for these events:
| Event | Sidebar state |
|---|---|
| `SessionStart` | working |
| `UserPromptSubmit` | working |
| `Stop` | idle |
| `Notification` | alert |
| `PermissionRequest` | alert |
| `SessionEnd` | removes session |

### 3. Verify

Start a Claude Code session in one of your configured repos. The sidebar should light up with the session's status.

## Keyboard Shortcuts

All shortcuts use **Option + Shift** as the modifier:

| Shortcut | Action |
|---|---|
| `Opt+Shift+1` – `Opt+Shift+9` | Focus the corresponding window slot (repos first, then non-repo windows) |
| `Opt+Shift+0` | Toggle sidebar visibility (hide / show) |

Hotkeys on placeholder tiles (repos with no open iTerm window) do nothing — they are for navigation only.

## Configuration

`config.json` (next to the app):

```json
{
  "repos": [
    { "num": 1, "path": "~/rubrik/sdmain-1", "label": "S1" },
    { "num": 2, "path": "~/rubrik/sdmain-2", "label": "S2" }
  ],
  "pollInterval": 30,
  "branchCacheTTL": 10,
  "staleTimeout": 1800,
  "launchAtLogin": false,
  "fontScale": 1.0,
  "minimalView": false,
  "autoStartClaude": false
}
```

| Setting | Description | Default |
|---|---|---|
| `repos` | List of repos to monitor (num + path + optional label) | sdmain 1-4 |
| `repos[].label` | Custom display label for the repo tile (e.g. `"S1"`) | repo num |
| `pollInterval` | Seconds between full iTerm scans | 30 |
| `branchCacheTTL` | Seconds to cache git branch lookups | 10 |
| `staleTimeout` | Seconds before a session is considered stale | 1800 (30 min) |
| `launchAtLogin` | Start app on login | false |
| `fontScale` | UI text scale factor (0.8 – 1.5) | 1.0 |
| `minimalView` | Compact mode — sidebar stays collapsed, no hover expand | false |
| `autoStartClaude` | Run `claude` automatically when opening a repo window | false |

## How it works

1. **iTerm scanning** — AppleScript queries iTerm2 for all windows, tabs, session names, and TTYs
2. **Claude hooks** — Claude Code hooks fire `sidebar-state.sh` on session events, writing JSON state files to `/tmp/claude-sidebar/`
3. **Event-driven updates** — Darwin notifications trigger instant UI updates on hook events; a background timer handles process and branch polling
4. **Process monitoring** — `ps` scans detect running commands (make, bazel, etc.) attached to terminal TTYs, with `kqueue` watching for exit
5. **Repo matching** — tabs are matched to configured repos by CWD path; matched windows get custom labels, others get sequential numbers
6. **Keyboard shortcuts** — Carbon hotkeys (no Accessibility permission needed) for window focus and sidebar toggle

## Project structure

```
claude-sidebar/
├── main.swift                  # Entry point
├── Sources/
│   ├── App.swift               # AppDelegate, status bar menu
│   ├── SidebarController.swift # Main sidebar window, layout, hover expand/collapse
│   ├── WindowButton.swift      # Per-window UI (collapsed badge + expanded header)
│   ├── TabCard.swift           # Per-tab card (CWD, branch, Claude/process status)
│   ├── Models.swift            # AppConfig, data models, state enums
│   ├── Theme.swift             # Colors, scaled font helpers
│   ├── ITermScanner.swift      # AppleScript iTerm2 queries, repo matching
│   ├── StateReader.swift       # Reads hook state files from /tmp
│   ├── ProcessMonitor.swift    # Process discovery and kqueue exit watching
│   ├── HookInstaller.swift     # Hook install prompt generator
│   ├── StatusBarManager.swift  # Menu bar status item
│   └── SettingsWindowController.swift  # Settings window UI
├── sidebar-state.sh            # Claude Code hook script
├── build.sh                    # Compile script
├── package.sh                  # Build + create DMG
├── config.json                 # Runtime configuration
└── ClaudeSidebar.app/          # App bundle
    └── Contents/
        ├── Info.plist
        ├── MacOS/
        └── Resources/
```
