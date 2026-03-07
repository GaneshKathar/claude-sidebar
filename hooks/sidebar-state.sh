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

# TTY from parent (Claude) — macOS only
TTY=""
TTY=$(ps -p $PPID -o tty= 2>/dev/null)
TTY="${TTY// /}"
[ -n "$TTY" ] && [ "$TTY" != "??" ] && TTY="/dev/$TTY" || TTY=""

STATE_DIR="/tmp/claude-sidebar"
[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null
# Restrict file permissions to owner-only
umask 0077

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
    SessionStart|UserPromptSubmit) STATE="working" ;;
    Stop)                          STATE="idle" ;;
    Notification|PermissionRequest) STATE="alert" ;;
    SessionEnd)                    rm -f "$STATE_FILE"; /usr/bin/notifyutil -p com.claudesidebar.update 2>/dev/null; exit 0 ;;
    *)                             exit 0 ;;
esac

# Atomic write: temp file OUTSIDE watched dir, then mv in — only the mv triggers kqueue
TMP_FILE="/tmp/.claude-sidebar-tmp.$$"
printf '{"repo":%d,"state":"%s","session_id":"%s","cwd":"%s","tty":"%s","timestamp":%d}' \
    "$REPO_NUM" "$STATE" "$SESSION_ID" "$CWD" "$TTY" "$(date +%s)" > "$TMP_FILE"
mv -f "$TMP_FILE" "$STATE_FILE"
/usr/bin/notifyutil -p com.claudesidebar.update 2>/dev/null
