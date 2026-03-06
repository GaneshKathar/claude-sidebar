# Claude Sidebar

A macOS floating panel that monitors multiple Claude Code sessions in real time. Sits as a slim sidebar on screen showing which repos have active Claude sessions, their status (working / idle / needs attention), and details like branch, session ID, and TTY.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![Architecture](https://img.shields.io/badge/arch-arm64-lightgrey)

## Features

- **Floating sidebar** — always-on-top panel showing repo status at a glance
- **Real-time status** via Claude Code hooks (working / idle / alert)
- **Color-coded indicators** — green (working), blue (idle), orange/red (needs attention)
- **Sub-panel details** — click a repo to see branch, session ID, CWD, and TTY
- **iTerm2 integration** — click a session to focus its terminal tab
- **Menu bar icon** — quick access to toggle sidebar, settings, and hook installer
- **Configurable** — add/remove repos, adjust poll intervals, stale timeouts, and more
- **DMG packaging** — share with teammates via a single `.dmg` file

## Requirements

- macOS 13.0+ (Apple Silicon / arm64)
- Xcode Command Line Tools (`xcode-select --install`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI

## Build

```bash
git clone git@github.com:GaneshKathar/claude-sidebar.git
cd claude-sidebar
bash build.sh
```

This compiles `main.swift` into `ClaudeSidebar.app/Contents/MacOS/ClaudeSidebar`.

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

Open the app → click the menu bar icon → **Settings...**

- Add your repo paths (e.g. `~/rubrik/sdmain-1`)
- Each repo gets a numbered slot in the sidebar

Settings are saved to `config.json` next to the app.

### 2. Install Claude Code hooks

The sidebar receives status updates via [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks). These must be added to your `~/.claude/settings.json`.

From **Settings** → **Claude Hooks** section:

1. Click **"Install Hooks"**
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

Start a Claude Code session in one of your configured repos. The sidebar should light up with the repo's status.

## Configuration

`config.json` (next to the app):

```json
{
  "repos": [
    { "num": 1, "path": "~/rubrik/sdmain-1" },
    { "num": 2, "path": "~/rubrik/sdmain-2" }
  ],
  "pollInterval": 30,
  "branchCacheTTL": 10,
  "staleTimeout": 1800,
  "launchAtLogin": false
}
```

| Setting | Description | Default |
|---|---|---|
| `repos` | List of repos to monitor (num + path) | sdmain 1-4 |
| `pollInterval` | Seconds between state file polls | 30 |
| `branchCacheTTL` | Seconds to cache git branch lookups | 10 |
| `staleTimeout` | Seconds before a session is considered stale | 1800 (30 min) |
| `launchAtLogin` | Start app on login | false |

## How it works

1. Claude Code hooks fire a shell script (`hooks/sidebar-state.sh`) on session events
2. The script writes JSON state files to `/tmp/claude-sidebar/<session_id>.json`
3. The app polls that directory (every 500ms) and updates the sidebar in real time
4. Repo detection uses the CWD path — either `sdmain-N` pattern matching or config lookup

## Project structure

```
claude-sidebar/
├── main.swift              # Single-file macOS app (AppKit, no storyboards)
├── build.sh                # Compile script
├── package.sh              # Build + create DMG
├── config.json             # Runtime configuration
├── hooks/
│   └── sidebar-state.sh    # Claude Code hook script
└── ClaudeSidebar.app/      # App bundle (pre-built structure)
    └── Contents/
        ├── Info.plist
        ├── MacOS/
        └── Resources/
```
