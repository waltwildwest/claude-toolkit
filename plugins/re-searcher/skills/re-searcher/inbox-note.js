#!/usr/bin/env node
'use strict';
// inbox-note — Stop-hook safety net (spec Pillar 1): append a harvest POINTER
// for this session to the vault inbox. Pointers only: no extraction, no
// dialog, no stdout — mining happens lazily, when recall has a paying
// customer. A Stop hook must never crash or stall a session close, so this
// exits 0 on every path and appends are single-line O_APPEND writes
// (lock-free by design, same precedent as sources/fetch-log.jsonl — the hook
// can never block on the vault's advisory lock).
//
//   <hook stdin JSON> | node inbox-note.js
//
// Guards: no vault (or not vault-init'd) -> silent no-op, never create one;
// RESEARCH_INBOX=off -> no-op; session already in inbox -> no-op;
// unreadable stdin -> no-op. TTL via RESEARCH_TRANSCRIPT_TTL_DAYS (default 30).

const fs = require('fs');
const path = require('path');
const os = require('os');

function main() {
  if ((process.env.RESEARCH_INBOX || '').toLowerCase() === 'off') return;
  const vault = process.env.RESEARCH_VAULT_DIR || path.join(os.homedir(), 'research-vault');
  const inboxFile = path.join(vault, 'inbox.jsonl');
  if (!fs.existsSync(inboxFile)) return; // no vault: stay silent, never create

  let hook;
  try { hook = JSON.parse(fs.readFileSync(0, 'utf8')); } catch (_e) { return; }
  const session = hook.session_id || hook.sessionId || null;
  const transcript = hook.transcript_path || hook.transcriptPath || null;
  if (!session || !transcript) return;

  try {
    for (const line of fs.readFileSync(inboxFile, 'utf8').split('\n')) {
      if (!line.trim()) continue;
      try { if (JSON.parse(line).session === session) return; } catch (_e) {}
    }
  } catch (_e) { return; }

  // clamp: a garbage TTL env var must degrade to the default, not NaN the
  // date and silently drop this session's pointer
  const rawTtl = Number(process.env.RESEARCH_TRANSCRIPT_TTL_DAYS || 30);
  const ttlDays = Number.isFinite(rawTtl) ? rawTtl : 30;
  const cwd = String(hook.cwd || process.cwd());
  fs.appendFileSync(inboxFile, JSON.stringify({
    v: 1, kind: 'pointer', session: String(session), transcript: String(transcript),
    subagents: String(transcript).replace(/\.jsonl$/, '') + '/subagents',
    cwd, topicGuess: path.basename(cwd),
    ts: new Date().toISOString(),
    transcript_dies: new Date(Date.now() + ttlDays * 86400000).toISOString().slice(0, 10),
  }) + '\n');
}

try { main(); } catch (_e) { /* a Stop hook must never crash the session */ }
