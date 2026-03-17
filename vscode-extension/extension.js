/**
 * Claude Manager Sidebar Focus Extension
 *
 * Starts a Unix domain socket server. The sidebar connects to it and sends:
 *   {"method":"focusByTTY","tty":"/dev/ttys006","id":"..."}
 *
 * The extension finds the VS Code terminal whose shell process owns that TTY
 * and calls terminal.show() on it.
 *
 * Socket path is written to /tmp/vscode-sidebar.sock so the sidebar can find it.
 */

'use strict';

const vscode = require('vscode');
const net    = require('net');
const fs     = require('fs');
const { exec } = require('child_process');

const INDICATOR = '/tmp/vscode-sidebar.sock';   // sidebar reads this to find our socket
let   server    = null;
let   sockPath  = null;

// ── TTY detection ────────────────────────────────────────────────────────────

/** Return the /dev/ttys... path for a terminal, or null on failure. */
async function ttyForTerminal(terminal) {
    let pid;
    try {
        pid = await Promise.race([
            terminal.processId,
            new Promise((_, r) => setTimeout(() => r(new Error('timeout')), 600))
        ]);
    } catch { return null; }
    if (!pid) return null;

    return new Promise(resolve => {
        exec(`ps -p ${pid} -o tty=`, (err, stdout) => {
            const t = (stdout || '').trim();
            resolve((!err && t && t !== '??') ? '/dev/' + t : null);
        });
    });
}

/** Find the terminal that owns `tty` and show it. */
async function focusByTTY(tty) {
    for (const terminal of vscode.window.terminals) {
        const t = await ttyForTerminal(terminal);
        if (t === tty) {
            terminal.show(false);   // false = terminal gets focus
            return true;
        }
    }
    return false;
}

// ── Socket server ─────────────────────────────────────────────────────────────

function startServer(context) {
    sockPath = `/tmp/vscode-sidebar-focus-${process.pid}.sock`;
    try { fs.unlinkSync(sockPath); } catch (_) {}

    server = net.createServer(conn => {
        let buf = '';
        conn.on('data', data => {
            buf += data.toString();
            const lines = buf.split('\n');
            buf = lines.pop();                  // keep partial last line
            for (const line of lines) {
                const s = line.trim();
                if (!s) continue;
                let msg;
                try { msg = JSON.parse(s); } catch { continue; }

                if (msg.method === 'focusByTTY' && msg.tty) {
                    focusByTTY(msg.tty).then(found => {
                        try {
                            conn.write(JSON.stringify({ ok: found, id: msg.id ?? null }) + '\n');
                        } catch (_) {}
                    });
                }
            }
        });
        conn.on('error', () => {});
    });

    server.on('error', err =>
        console.error('claude-sidebar-focus: server error:', err.message));

    server.listen(sockPath, () => {
        try {
            fs.writeFileSync(INDICATOR, sockPath, { mode: 0o600 });
            console.log('claude-sidebar-focus: listening on', sockPath);
        } catch (err) {
            console.error('claude-sidebar-focus: could not write indicator:', err.message);
        }
    });

    context.subscriptions.push({ dispose: cleanup });
}

function cleanup() {
    if (server) { server.close(); server = null; }
    for (const p of [sockPath, INDICATOR]) {
        if (p) try { fs.unlinkSync(p); } catch (_) {}
    }
    sockPath = null;
}

// ── Entry points ──────────────────────────────────────────────────────────────

function activate(context) {
    startServer(context);
}

function deactivate() {
    cleanup();
}

module.exports = { activate, deactivate };
