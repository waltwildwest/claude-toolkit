#!/usr/bin/env node
'use strict';
// vault-redact — the deletion path that keeps epistemics honest (spec Vault
// lifecycle). Redacting a SOURCE deletes its files, writes a tombstone,
// drops its fetch-log records (a refetch must never dedupe into a deleted
// file), and DOWNGRADES dependent grounded claims via the script-only
// 'downgrade' event. Redacting a CLAIM appends a retract event. The registry
// stays append-only: corrections are events, never edits. Raw bytes remain
// in the vault's git history — a true purge is `git filter-repo`, documented
// and manual, never automatic.
//
//   node vault-redact.js <source-id | claim-id> [--vault <dir>] [--reason "<r>"]
//
// stdout: one JSON line. exit 0 done (incl. already-redacted) / 1 unknown id.

const fs = require('fs');
const path = require('path');
const lib = require('./vault-lib');
const views = require('./vault-views');

const GROUNDED = ['verbatim-grounded', 'externally-verified'];

function strFlag(name) { const i = process.argv.indexOf(name); return i !== -1 ? process.argv[i + 1] : null; }
function die(msg) { process.stderr.write('vault-redact: ' + msg + '\n'); process.exit(1); }

function redactClaim(vault, id, reason) {
  return lib.withLock(vault, () => {
    const claimsFile = path.join(vault, 'claims.jsonl');
    const { claims } = lib.foldClaims(lib.readJsonl(claimsFile).records);
    const c = claims.get(id);
    if (!c) return null;
    const alreadyRetracted = c.status === 'retracted';
    if (!alreadyRetracted) {
      lib.appendJsonl(claimsFile, { v: 1, op: 'retract', claim: id, by: 'human', date: lib.today(), reason: reason || 'redacted' });
    }
    if (c.topic) views.regenTopic(vault, c.topic);
    views.regenIndex(vault);
    lib.gitCommit(vault, 'research: redact claim ' + id);
    return { status: 'redacted', kind: 'claim', id, alreadyRetracted };
  });
}

function redactSource(vault, id, reason) {
  const srcMd = path.join(vault, 'sources', id + '.md');
  const tomb = path.join(vault, 'sources', id + '.tombstone.json');
  if (!fs.existsSync(srcMd)) {
    return fs.existsSync(tomb) ? { status: 'already-redacted', kind: 'source', id } : null;
  }
  return lib.withLock(vault, () => {
    // re-check INSIDE the lock: a concurrent redact of the same id must
    // become a no-op here, never rewrite the tombstone with new provenance
    if (!fs.existsSync(srcMd)) {
      return fs.existsSync(tomb) ? { status: 'already-redacted', kind: 'source', id } : null;
    }
    const removed = [];
    fs.rmSync(srcMd, { force: true });
    removed.push('sources/' + id + '.md');
    const hash8 = id.split('--')[0];
    const rawPath = path.join(vault, 'sources', 'raw', hash8 + '.html');
    if (fs.existsSync(rawPath)) { fs.rmSync(rawPath, { force: true }); removed.push('sources/raw/' + hash8 + '.html'); }
    lib.atomicWrite(tomb, JSON.stringify({ v: 1, source: id, reason: reason || 'redacted', date: lib.today(), removed }, null, 2) + '\n');

    const logFile = path.join(vault, 'sources', 'fetch-log.jsonl');
    if (fs.existsSync(logFile)) {
      const keep = lib.readJsonl(logFile).records.filter((r) => !(r && r.source_id === id));
      lib.atomicWrite(logFile, keep.map((r) => JSON.stringify(r)).join('\n') + (keep.length ? '\n' : ''));
    }

    const claimsFile = path.join(vault, 'claims.jsonl');
    const { claims } = lib.foldClaims(lib.readJsonl(claimsFile).records);
    const downgraded = [];
    const touched = new Set();
    for (const c of claims.values()) {
      if (c.source !== id || c.status === 'retracted' || !GROUNDED.includes(c.provenance)) continue;
      lib.appendJsonl(claimsFile, { v: 1, op: 'downgrade', claim: c.id, by: 'redaction', to: 'model-asserted',
        date: lib.today(), reason: 'source redacted: ' + (reason || 'unspecified') });
      downgraded.push(c.id);
      if (c.topic) touched.add(c.topic);
    }
    for (const t of touched) views.regenTopic(vault, t);
    views.regenIndex(vault);
    lib.gitCommit(vault, 'research: redact source ' + id);
    return { status: 'redacted', kind: 'source', id, removed, downgraded,
      note: 'raw bytes remain in the vault git history — run git filter-repo for a true purge' };
  });
}

function main() {
  const id = process.argv[2];
  if (!id || id.startsWith('--')) die('usage: vault-redact.js <source-id | claim-id> [--vault <dir>] [--reason "<r>"]');
  const vault = lib.resolveVault(strFlag('--vault'));
  const reason = strFlag('--reason');
  const out = id.startsWith('clm_') ? redactClaim(vault, id, reason) : redactSource(vault, id, reason);
  if (!out) die('unknown id: ' + id + ' — not a registered claim, not a stored source');
  process.stdout.write(JSON.stringify(out) + '\n');
}

main();
