# Claude Sidebar

A macOS floating panel that monitors terminal windows and Claude Code sessions in real time. Supports iTerm2, VS Code, Ghostty, Kitty, Cursor, and cmux.

## Setup

### 1. Build and launch

```bash
git clone git@github.com:GaneshKathar/claude-sidebar.git
cd claude-sidebar
bash build.sh
open ClaudeSidebar.app
```

If macOS blocks it: right-click the app → **Open** → **Open**.

The build script auto-detects installed terminals and installs the VS Code/Cursor extension.

### 2. Configure repositories

On first launch the app auto-detects `sdmain*` repos and opens Settings. Otherwise, hover over the sidebar → click the gear icon in the footer.

Settings are saved to `config.json` next to the app:

```json
{
  "repos": [
    { "num": 1, "path": "~/rubrik/sdmain-1", "label": "S1", "title": "SDMain 1" },
    { "num": 2, "path": "~/rubrik/sdmain-2", "label": "S2" }
  ],
  "pollInterval": 30,
  "branchCacheTTL": 10,
  "staleTimeout": 1800,
  "launchAtLogin": false,
  "fontScale": 1.0,
  "minimalView": false,
  "autoStartClaude": false,
  "showAllTerminalWindows": false
}
```

| Setting | Description | Default |
|---|---|---|
| `repos[].num` | Slot number (used for Opt+Shift+N shortcut) | — |
| `repos[].path` | Repo path (supports `~/`) | — |
| `repos[].label` | Custom badge text (e.g. `"S1"`, emoji) | repo num |
| `repos[].title` | Display name in expanded header | folder name |
| `pollInterval` | Seconds between terminal scans | 30 |
| `branchCacheTTL` | Seconds to cache git branch lookups | 10 |
| `staleTimeout` | Seconds before a session is considered stale | 1800 |
| `fontScale` | UI text scale (0.8 – 1.5) | 1.0 |
| `minimalView` | Compact mode — no hover expand | false |
| `autoStartClaude` | Launch Claude Code when opening a repo window | false |
| `showAllTerminalWindows` | Show all terminal tabs, not just those with Claude/processes | false |
| `launchAtLogin` | Auto-start on login | false |

### 3. Install Claude Code hooks

The sidebar tracks Claude session states via [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks). Add these to `~/.claude/settings.json`:

**Option A** — From the sidebar Settings UI, click **"Copy Install Prompt"** → paste into any Claude Code session.

**Option B** — Manually add to `~/.claude/settings.json`. Each hook event needs an entry pointing to the `sidebar-state.sh` script:

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "command": "/path/to/claude-sidebar/hooks/sidebar-state.sh" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "command": "/path/to/claude-sidebar/hooks/sidebar-state.sh" }] }],
    "Stop": [{ "hooks": [{ "command": "/path/to/claude-sidebar/hooks/sidebar-state.sh" }] }],
    "Notification": [{ "matcher": "permission_prompt|elicitation_dialog", "hooks": [{ "command": "/path/to/claude-sidebar/hooks/sidebar-state.sh" }] }],
    "PermissionRequest": [{ "hooks": [{ "command": "/path/to/claude-sidebar/hooks/sidebar-state.sh" }] }],
    "PostToolUse": [{ "hooks": [{ "command": "/path/to/claude-sidebar/hooks/sidebar-state.sh" }] }],
    "SessionEnd": [{ "hooks": [{ "command": "/path/to/claude-sidebar/hooks/sidebar-state.sh" }] }]
  }
}
```

Replace `/path/to/claude-sidebar` with your actual install directory.

### 4. Terminal-specific setup

**cmux** — Works automatically. The sidebar reads `CMUX_WORKSPACE_ID`, `CMUX_SOCKET_PATH`, and `CMUX_SURFACE_ID` from the hook environment to identify and focus cmux surfaces.

**VS Code / Cursor** — The `build.sh` script auto-installs the focus extension. Restart VS Code after building. The extension runs a socket server so the sidebar can focus specific terminals.

**Kitty** — Add `allow_remote_control yes` to `~/.config/kitty/kitty.conf` for tab focusing support.

**iTerm2 / Ghostty / Terminal** — No extra setup needed.

### 5. Package as DMG (optional)

```bash
bash package.sh
```

Creates `ClaudeSidebar.dmg` for sharing.

## Usage

### Sidebar behavior

- **Collapsed** — Slim bar on the screen edge showing color-coded badges per repo/window
- **Hover expand** — Move mouse over the sidebar to expand and see tab details (CWD, git branch, Claude state, running processes)
- **Click a badge** (collapsed) — Focus the highest-priority tab in that window
- **Click a tab card** (expanded) — Focus that specific terminal session
- **Click a placeholder** — Open a new terminal window at that repo's path
- **Drag** — Move the sidebar; it snaps to left or right screen edge
- **Right-click a badge** — Dump debug info to `/tmp/claude-sidebar/windowbutton-debug.log`

### Status colors

| Color | Meaning |
|---|---|
| Blue | Claude is working (processing a prompt) |
| Teal/Green | Claude is idle (waiting for input) |
| Red | Alert — Claude needs permission or hit an error |
| Slate | Active session, no Claude activity |
| Yellow | Non-Claude process running (make, bazel, etc.) |
| Dim | Inactive placeholder (no open session) |

### Keyboard shortcuts

All shortcuts use **Option + Shift** as the modifier:

| Shortcut | Action |
|---|---|
| `Opt+Shift+1` – `Opt+Shift+9` | Focus the corresponding window slot |
| `Opt+Shift+0` | Toggle sidebar visibility (hide/show) |
| `Opt+Shift+-` | Show only active tabs (hide inactive repo placeholders) |
| `Opt+Shift++` | Show all tabs (restore default view) |

### Settings UI

Hover over sidebar → click the gear icon in the footer to access:
- Add/remove/reorder repos
- Adjust poll interval, stale timeout, font scale
- Toggle minimal view, auto-start Claude, launch at login
- Install Claude Code hooks
