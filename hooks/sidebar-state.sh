#!/bin/bash
# Claude Code hook — writes session state to /tmp/claude-sidebar/
# Pure bash builtins only (no grep/cut/sed/tr) for speed
INPUT=$(cat)

# Parse JSON with bash parameter expansion (no subprocesses)
extract() { local t="${INPUT#*"\"$1\":\""}"; echo "${t%%\"*}"; }
EVENT=$(extract hook_event_name)
SESSION_ID=$(extract session_id)
CWD=$(extract cwd)

[ -z "$SESSION_ID" ] && exit 0

# Log each hook invocation
LOG_DIR="/tmp/claude-sidebar"
LOG_FILE="$LOG_DIR/hook.log"
LOG_TS=$(date '+%H:%M:%S')
echo "$LOG_TS [$SESSION_ID] event=$EVENT cwd=$CWD input=$INPUT" >> "$LOG_FILE" 2>/dev/null

# TTY from parent (Claude) — macOS only
TTY=""
TTY=$(ps -p $PPID -o tty= 2>/dev/null)
TTY="${TTY// /}"
[ -n "$TTY" ] && [ "$TTY" != "??" ] && TTY="/dev/$TTY" || TTY=""

STATE_DIR="/tmp/claude-sidebar"
[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || exit 1
# Restrict file permissions to owner-only
umask 0077

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Use SESSION_ID + TTY hash for unique state files (avoid collision)
if [ -n "$TTY" ]; then
    SAFE_TTY="${TTY//\//_}"
    STATE_FILE="$STATE_DIR/${SESSION_ID}-${SAFE_TTY}.json"
else
    STATE_FILE="$STATE_DIR/$SESSION_ID.json"
fi

# Detect repo from CWD — try sdmain-N pattern first (fastest, no config read)
REPO_NUM=""
case "$CWD" in
    *"/sdmain-"[0-9]/*)  REPO_NUM="${CWD#*sdmain-}"; REPO_NUM="${REPO_NUM%%/*}" ;;
    *"/sdmain-"[0-9])    REPO_NUM="${CWD##*sdmain-}" ;;
esac

# Fallback: read config (only if pattern didn't match)
if [ -z "$REPO_NUM" ]; then
    SCRIPT_DIR="${0%/*}/.."; SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
    CONFIG="$SCRIPT_DIR/config.json"
    if [ -f "$CONFIG" ]; then
        while IFS= read -r line; do
            case "$line" in
                *'"num"'*) n="${line#*: }"; n="${n%%[, ]*}" ;;
                *'"path"'*) p="${line#*\"}"; p="${p#*\"}"; p="${p%%\"*}"
                    p="${p//\\//\/}"; [[ "$p" == "~/"* ]] && p="$HOME/${p:2}"
                    if [ -n "$p" ] && { [ "$CWD" = "$p" ] || [[ "$CWD" == "$p"/* ]]; }; then
                        REPO_NUM="$n"; break
                    fi ;;
            esac
        done < "$CONFIG"
    fi
fi

[ -z "$REPO_NUM" ] && REPO_NUM=0

# Map event → state
case "$EVENT" in
    SessionStart)                  STATE="active" ;;
    UserPromptSubmit)              STATE="working" ;;
    Stop)                          STATE="idle" ;;
    Notification|PermissionRequest) STATE="alert" ;;
    PostToolUse)
        # Only transition alert→working; skip write if already working/idle
        if [ -f "$STATE_FILE" ]; then
            case "$(cat "$STATE_FILE")" in
                *'"state":"alert"'*) STATE="working" ;;
                *) exit 0 ;;
            esac
        else
            exit 0
        fi
        ;;
    SessionEnd)                    rm -f "$STATE_FILE"; /usr/bin/notifyutil -p com.claudesidebar.update 2>/dev/null; exit 0 ;;
    *)                             exit 0 ;;
esac

# Write focus file — terminal identity data for window focusing.
# Written at SessionStart, and re-created on any event if missing (e.g. after /tmp cleanup).
FOCUS_FILE=""
if [ -n "$TTY" ] && [ -n "$SAFE_TTY" ]; then
    FOCUS_FILE="$STATE_DIR/focus${SAFE_TTY}.json"
fi
if [ -n "$TTY" ] && { [ "$EVENT" = "SessionStart" ] || { [ -n "$FOCUS_FILE" ] && [ ! -f "$FOCUS_FILE" ]; }; }; then
    # Extract iTerm2 session UUID from ITERM_SESSION_ID (format: "wNtNpUUID")
    ITERM_UUID=""
    if [ -n "$ITERM_SESSION_ID" ]; then
        ITERM_UUID="${ITERM_SESSION_ID##*p}"
    fi
    # Capture Kitty IPC env vars (set by kitty when allow_remote_control is enabled)
    KITTY_WID="${KITTY_WINDOW_ID:-}"
    KITTY_SOCK="${KITTY_LISTEN_ON:-}"
    TMP_FOCUS=$(mktemp)
    printf '{"tty":"%s","term_program":"%s","iterm_session_id":"%s","cmux_workspace_id":"%s","cmux_socket_path":"%s","cmux_surface_id":"%s","kitty_window_id":"%s","kitty_listen_on":"%s","timestamp":%d}' \
        "$(json_escape "$TTY")" \
        "$(json_escape "${TERM_PROGRAM:-}")" \
        "$(json_escape "$ITERM_UUID")" \
        "$(json_escape "${CMUX_WORKSPACE_ID:-}")" \
        "$(json_escape "${CMUX_SOCKET_PATH:-}")" \
        "$(json_escape "${CMUX_SURFACE_ID:-}")" \
        "$(json_escape "$KITTY_WID")" \
        "$(json_escape "$KITTY_SOCK")" \
        "$(date +%s)" > "$TMP_FOCUS" && mv -f "$TMP_FOCUS" "$FOCUS_FILE"
fi

# Atomic write: temp file OUTSIDE watched dir, then mv in — only the mv triggers kqueue
TMP_FILE=$(mktemp)
printf '{"repo":%d,"state":"%s","session_id":"%s","cwd":"%s","tty":"%s","timestamp":%d}' \
    "$REPO_NUM" "$STATE" "$(json_escape "$SESSION_ID")" "$(json_escape "$CWD")" "$(json_escape "$TTY")" "$(date +%s)" > "$TMP_FILE"
mv -f "$TMP_FILE" "$STATE_FILE"
/usr/bin/notifyutil -p com.claudesidebar.update 2>/dev/null
