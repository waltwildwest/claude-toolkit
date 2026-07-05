#!/usr/bin/env node
'use strict';
// vault-lib — shared core for the re-searcher vault scripts (module only).
// Deliberately boring: vault resolution that fails loud, atomic writes,
// skip-don't-abort JSONL, ONE advisory mkdir lock for all mutation, git
// auto-commit, and the event fold that turns the append-only claims file
// into effective statuses. Scripts import this; nothing re-implements it.
//
// Module API:
//   resolveVault(cliVal, {mustExist}) atomicWrite(file, data)
//   readJsonl(file) appendJsonl(file, obj) parseFrontmatter(text)
//   slugify(s) sha8(s) newId(prefix, seed, taken) today() allocateRun(vault, topicRaw, sessionRaw) msleep(ms)
//   withLock(vault, fn) gitCommit(vault, message)
//   foldClaims(records) resolveTerminal(claimsMap, id)

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

function resolveVault(cliVal, opts) {
  const o = opts || {};
  const vault = cliVal || process.env.RESEARCH_VAULT_DIR || null;
  if (!vault) {
    process.stderr.write('vault not configured — pass --vault or set RESEARCH_VAULT_DIR (suggestion: ~/research-vault)\n');
    process.exit(1);
  }
  const abs = path.resolve(vault);
  if (o.mustExist !== false && !fs.existsSync(abs)) {
    process.stderr.write('vault missing at ' + abs + ' — run vault-init.js or set RESEARCH_VAULT_DIR (a missing vault must never look like an empty one)\n');
    process.exit(1);
  }
  return abs;
}

function atomicWrite(file, data) {
  const tmp = file + '.tmp' + process.pid;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}

function readJsonl(file) {
  if (!fs.existsSync(file)) return { records: [], skipped: 0, missing: true };
  const records = [];
  let skipped = 0;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try { records.push(JSON.parse(line)); } catch (_e) { skipped++; }
  }
  if (skipped) process.stderr.write('vault-lib: skipped ' + skipped + ' unparseable line(s) in ' + path.basename(file) + '\n');
  return { records, skipped, missing: false };
}

function appendJsonl(file, obj) {
  fs.appendFileSync(file, JSON.stringify(obj) + '\n');
}

// Minimal frontmatter: --- delimited key: value lines; values that parse as
// JSON (arrays, numbers, booleans) are parsed, everything else is a string.
function parseFrontmatter(text) {
  const m = String(text).match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return { fields: {}, body: String(text) };
  const fields = {};
  for (const line of m[1].split('\n')) {
    const km = line.trim().match(/^([A-Za-z_][\w-]*):\s*(.*)$/);
    if (!km) continue;
    const raw = km[2].trim();
    let val = raw;
    if (raw !== '') { try { val = JSON.parse(raw); } catch (_e) { val = raw; } }
    fields[km[1]] = val;
  }
  return { fields, body: m[2] };
}

function slugify(s) {
  return String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'topic';
}

function sha8(s) { return crypto.createHash('sha256').update(String(s), 'utf8').digest('hex').slice(0, 10); }

// Containment guard for any CLI-supplied id/slug that becomes a path segment.
// Vault ids are alnum plus - _ . (source ids carry '--', claim ids 'clm_',
// topic slugs [a-z0-9-]); anything with a separator or '..' is a traversal
// attempt and must never reach path.join. Callers die() loud on false.
function isSafeName(s) {
  return typeof s === 'string' && s.length > 0 && s.length <= 200
    && /^[A-Za-z0-9._-]+$/.test(s) && !s.includes('..');
}

function newId(prefix, seed, taken) {
  let id = prefix + '_' + sha8(seed);
  let n = 2;
  while (taken && taken.has(id)) { id = prefix + '_' + sha8(seed) + '-' + n; n++; }
  return id;
}

function today() {
  const d = new Date();
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
}

// Atomic run-folder allocation (spec Pillar 1): parents may be created
// recursively, but the LEAF run dir is a bare mkdir — same-day collisions
// bump the letter, they never race. Throws (never exits) — CLI callers die().
function allocateRun(vault, topicRaw, sessionRaw) {
  const topic = slugify(topicRaw);
  const sess = String(sessionRaw || 'anon').replace(/[^a-z0-9]/gi, '').slice(0, 4).toLowerCase() || 'anon';
  const runsDir = path.join(vault, 'topics', topic, 'runs');
  fs.mkdirSync(runsDir, { recursive: true });
  for (const letter of 'abcdefghijklmnopqrstuvwxyz') {
    const id = today() + letter + '-' + sess;
    const dir = path.join(runsDir, id);
    try { fs.mkdirSync(dir); } catch (e) { if (e.code === 'EEXIST') continue; throw e; }
    fs.mkdirSync(path.join(dir, 'findings'));
    return { runId: id, runDir: dir, topic };
  }
  throw new Error('could not allocate a run folder (26 same-day runs with the same session suffix)');
}

function msleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

const LOCK_STALE_MS = 5 * 60 * 1000;
const LOCK_WAIT_MS = 10 * 1000;

// Steal a stale lock SAFELY. A blind rmdir+mkdir race lets two stealers each
// remove a lock a third process legitimately re-created between their stat and
// their rmdir — two holders, a lost update. Fix: serialize stealers behind a
// steal-mutex dir, then RE-VERIFY the lock is still the same stale instance
// (old mtime) immediately before removing it. A fresh lock has a current
// mtime, so a stealer that lost the race sees "not stale" and backs off.
function stealStaleLock(lockDir) {
  const steal = lockDir + '.steal';
  try { fs.mkdirSync(steal); }
  catch (e) {
    if (e.code === 'EEXIST') {
      // a concurrent (or crashed) stealer holds it — clear only if itself stale
      let sAge = null;
      try { sAge = Date.now() - fs.statSync(steal).mtimeMs; } catch (_e2) { return; }
      if (sAge > LOCK_STALE_MS) { try { fs.rmdirSync(steal); } catch (_e2) {} }
    }
    return; // let the caller loop and retry
  }
  try {
    let age = null;
    try { age = Date.now() - fs.statSync(lockDir).mtimeMs; } catch (_e) { return; } // already gone
    if (age > LOCK_STALE_MS) {
      process.stderr.write('vault-lib: stealing stale lock (' + Math.round(age / 1000) + 's old) at ' + lockDir + '\n');
      try { fs.rmdirSync(lockDir); } catch (_e) {}
    }
  } finally { try { fs.rmdirSync(steal); } catch (_e) {} }
}

function withLock(vault, fn) {
  const lockDir = path.join(vault, '.lock');
  const deadline = Date.now() + LOCK_WAIT_MS;
  for (;;) {
    try { fs.mkdirSync(lockDir); break; }
    catch (e) {
      if (e.code !== 'EEXIST') throw e;
      let age = null;
      try { age = Date.now() - fs.statSync(lockDir).mtimeMs; } catch (_e) { continue; } // vanished — retry now
      if (age > LOCK_STALE_MS) {
        stealStaleLock(lockDir); // serialized + re-verified; may or may not free the dir
        if (Date.now() > deadline) {
          throw new Error('vault is locked (' + lockDir + ', ' + Math.round(age / 1000) + 's old) — another process is writing; retry, or remove the dir if you know it is dead');
        }
        msleep(5);
        continue;
      }
      if (Date.now() > deadline) {
        throw new Error('vault is locked (' + lockDir + ', ' + Math.round(age / 1000) + 's old) — another process is writing; retry, or remove the dir if you know it is dead');
      }
      msleep(200);
    }
  }
  try { return fn(); }
  finally { try { fs.rmdirSync(lockDir); } catch (_e) {} }
}

function gitCommit(vault, message) {
  try { execFileSync('git', ['-C', vault, 'rev-parse', '--git-dir'], { stdio: 'pipe' }); }
  catch (_e) { return { committed: false, warning: 'vault is not a git repo — run vault-init.js to enable auto-commits' }; }
  try {
    execFileSync('git', ['-C', vault, 'add', '-A'], { stdio: 'pipe' });
    execFileSync('git', ['-C', vault, 'commit', '-q', '-m', message], { stdio: 'pipe' });
    return { committed: true, warning: null };
  } catch (e) {
    const out = ((e.stdout || '') + (e.stderr || '')).toString();
    if (/nothing to commit|nothing added/.test(out)) return { committed: false, warning: null };
    return { committed: false, warning: 'git auto-commit failed: ' + (out.trim().split('\n')[0] || e.message) };
  }
}

// Fold the append-only claims file: claim records (id, no op) get a derived
// status; event records (op) mutate ONLY the folded view, never the file.
// Verify promotes provenance; downgrade (script-only, written by vault-redact) lowers it.
function foldClaims(records) {
  const claims = new Map();
  let skippedEvents = 0;
  for (const r of records) {
    if (r && r.id && !r.op) {
      claims.set(r.id, Object.assign({}, r, { status: 'active', supersededBy: [], contradictedBy: [], events: [] }));
    }
  }
  for (const r of records) {
    if (!r || !r.op) continue;
    const c = claims.get(r.claim);
    if (!c) { skippedEvents++; continue; }
    c.events.push(r);
    if (r.op === 'retract') c.status = 'retracted';
    else if (r.op === 'supersede') {
      if (c.status !== 'retracted') c.status = 'superseded';
      if (r.by) c.supersededBy.push(r.by);
    } else if (r.op === 'contradict') {
      if (r.by) {
        c.contradictedBy.push(r.by);
        const other = claims.get(r.by);
        if (other) other.contradictedBy.push(r.claim);
      }
    } else if (r.op === 'verify') c.provenance = 'externally-verified';
    else if (r.op === 'downgrade') c.provenance = (typeof r.to === 'string' && r.to) || 'model-asserted';
  }
  return { claims, skippedEvents };
}

function resolveTerminal(claims, id, seen) {
  const s = seen || new Set();
  if (s.has(id)) return [];
  s.add(id);
  const c = claims.get(id);
  if (!c) return [];
  if (c.status === 'active') return [c];
  if (c.status === 'superseded' && c.supersededBy.length) {
    const out = [];
    for (const nxt of c.supersededBy) {
      for (const t of resolveTerminal(claims, nxt, s)) if (!out.includes(t)) out.push(t);
    }
    return out;
  }
  return [];
}

module.exports = { resolveVault, atomicWrite, readJsonl, appendJsonl, parseFrontmatter, slugify, sha8, isSafeName, newId, today, allocateRun, msleep, withLock, gitCommit, foldClaims, resolveTerminal };
