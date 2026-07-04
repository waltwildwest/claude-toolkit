#!/usr/bin/env node
// handoff-spawn.js — spawn a fresh `claude` session that MIRRORS the current
// session's model, effort, and permission mode, and picks up a handoff file.
// Standalone: needs only node + the `claude` CLI. Uses tmux if present; otherwise
// prints the exact command to paste into a new terminal. Never touches ~/.claude.
//
//   node handoff-spawn.js --dir <projectDir> --handoff <handoffFile> [--dry-run]
//
// Detection:
//   effort         <- $CLAUDE_EFFORT
//   model, permMode <- last values in the current session transcript
//                      (~/.claude/projects/<enc-cwd>/$CLAUDE_CODE_SESSION_ID.jsonl)
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const argv = process.argv.slice(2);
const arg = (name) => { const i = argv.indexOf(`--${name}`); return i > -1 ? (argv[i + 1] ?? null) : null; };
const has = (name) => argv.includes(`--${name}`);

const dir = arg('dir');
const handoffFile = arg('handoff');
const dryRun = has('dry-run');

// The handoff path gets typed onto a shell line via tmux send-keys, so keep it inert.
const SAFE_PATH = /^[A-Za-z0-9/._-]+$/;
if (handoffFile && !SAFE_PATH.test(handoffFile)) { console.error('handoff-spawn: unsafe handoff path (no spaces/quotes).'); process.exit(1); }
if (dir && !fs.existsSync(dir)) { console.error(`handoff-spawn: dir not found: ${dir}`); process.exit(1); }
if (handoffFile && !fs.existsSync(handoffFile)) { console.error(`handoff-spawn: handoff file not found: ${handoffFile}`); process.exit(1); }

// ---- detect the current session's settings ----
const effort = process.env.CLAUDE_EFFORT || null;
const sessionId = process.env.CLAUDE_CODE_SESSION_ID || null;

function findTranscript(sid) {
  if (!sid) return null;
  const base = path.join(os.homedir(), '.claude', 'projects');
  if (!fs.existsSync(base)) return null;
  for (const proj of fs.readdirSync(base)) {
    const f = path.join(base, proj, `${sid}.jsonl`);
    if (fs.existsSync(f)) return f;
  }
  return null;
}

function lastSettings(txPath) {
  let model = null, permMode = null;
  if (!txPath) return { model, permMode };
  for (const line of fs.readFileSync(txPath, 'utf8').split('\n')) {
    if (!line) continue;
    let d; try { d = JSON.parse(line); } catch { continue; }
    const msg = (d.message && typeof d.message === 'object') ? d.message : {};
    const m = msg.model || d.model;
    if (m) model = m;
    const pm = d.permissionMode ?? msg.permissionMode ?? d.mode;
    if (pm) permMode = pm;
  }
  return { model, permMode };
}

const { model, permMode } = lastSettings(findTranscript(sessionId));
// `claude --permission-mode` only accepts these; anything else (e.g. "default") is omitted
// so the new session falls back to the user's own default rather than erroring on launch.
const CLI_MODES = new Set(['acceptEdits', 'auto', 'bypassPermissions', 'manual', 'dontAsk', 'plan']);
const usePerm = (permMode && CLI_MODES.has(permMode)) ? permMode : null;

// ---- build the mirrored `claude` command ----
const HANDOFF_PROMPT = handoffFile
  ? `A previous session handed this task off to you. Read the handoff file at ${handoffFile}, state the task in one line, then execute it.`
  : null;

const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`; // single-quote for a POSIX shell line
const flags = [];
if (model) flags.push('--model', shq(model));
if (effort) flags.push('--effort', shq(effort));
if (usePerm) flags.push('--permission-mode', shq(usePerm));
const claudeCmd = ['claude', ...flags, ...(HANDOFF_PROMPT ? [shq(HANDOFF_PROMPT)] : [])].join(' ');

const mirror = `model=${model || '(default)'}  effort=${effort || '(default)'}  permission=${usePerm || '(default)'}`;

if (dryRun) {
  console.log('handoff-spawn DRY RUN');
  console.log('  mirrored:', mirror);
  console.log('  dir:     ', dir || process.cwd(), '| tmux:', Boolean(process.env.TMUX));
  console.log('  command: ', claudeCmd);
  process.exit(0);
}

// ---- spawn ----
const fullCmd = `${dir ? `cd ${shq(dir)} && ` : ''}${claudeCmd}`;
function printFallback() {
  console.log(`Paste this into a new terminal to continue with the same setup (${mirror}):\n`);
  console.log(fullCmd);
}

if (process.env.TMUX) {
  // Seamless: a new background window in the current tmux session.
  const r = spawnSync('tmux', ['new-window', '-d', '-P', '-F', '#{pane_id}', ...(dir ? ['-c', dir] : [])], { encoding: 'utf8' });
  const pane = (r.stdout || '').trim();
  if (r.status !== 0 || !pane) { console.error('handoff-spawn: tmux new-window failed.'); process.exit(1); }
  if (spawnSync('tmux', ['send-keys', '-t', pane, claudeCmd, 'C-m']).status !== 0) { console.error('handoff-spawn: tmux send-keys failed.'); process.exit(1); }
  console.log(`Handoff spawned in a new tmux window (${mirror}).`);
  console.log('Switch to it with your tmux window keys. Safe to /clear here and move on.');
} else if (process.platform === 'darwin') {
  // No tmux, on a Mac: open a new Terminal.app window running the mirrored command.
  const as = '"' + fullCmd.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  const r = spawnSync('osascript', ['-e', `tell application "Terminal" to do script ${as}`, '-e', 'tell application "Terminal" to activate']);
  if (r.status === 0) {
    console.log(`Handoff opened in a new Terminal window (${mirror}). Safe to /clear here and move on.`);
  } else {
    printFallback();
  }
} else {
  // Any other terminal (Linux, no tmux): hand back the exact command to run.
  printFallback();
}
