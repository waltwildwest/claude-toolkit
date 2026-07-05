#!/usr/bin/env node
'use strict';
// vault-harvest — turn a session transcript into a vaulted run (spec Pillar 1
// lazy harvest + /research save|harvest). Light-style: findings digest +
// harvested summary, NO claims — the librarian mines claims later (stage 3).
// Deterministic extraction via transcript-mine; persistence via
// `vault-save.js --light` (child process) so the layered persist, lock,
// views and auto-commit are reused, never re-implemented.
//
//   node vault-harvest.js <transcript.jsonl | session-id> [--vault <dir>]
//        [--topic <slug>] [--title <t>] [--from-inbox]
//   node vault-harvest.js --latest [--cwd <dir>] [--vault <dir>] [--topic <slug>]
//   node vault-harvest.js --inbox [--vault <dir>]
//
// stdout: one JSON line. exit 0 (harvested / already-harvested / drained),
// 1 hard error. Idempotent: a session already present in any run's
// lineage.json is never harvested twice. CLAUDE_PROJECTS_DIR overrides
// ~/.claude/projects (the CI seam).

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');
const lib = require('./vault-lib');
const { mine } = require('./transcript-mine');

function getFlag(name) { const i = process.argv.indexOf(name); return i !== -1 ? process.argv[i + 1] : null; }
function die(msg) { process.stderr.write('vault-harvest: ' + msg + '\n'); process.exit(1); }
function projectsDir() { return process.env.CLAUDE_PROJECTS_DIR || path.join(os.homedir(), '.claude', 'projects'); }
// Claude Code maps EVERY non-alphanumeric char to '-' in project dir names
// (verified: real dirs show '--' runs from spaces/underscores, not just /.)
function cwdSlug(cwd) { return String(cwd).replace(/[^a-zA-Z0-9]/g, '-'); }

// Subagent transcripts (stage-2 measured layout): sibling dir named after the
// transcript stem, agent-*.jsonl inside. Mining is best-effort — a broken
// subagent file never fails the harvest.
function mineSubagents(transcript) {
  const dir = path.join(path.dirname(transcript), path.basename(transcript, '.jsonl'), 'subagents');
  if (!fs.existsSync(dir)) return [];
  const out = [];
  let names;
  try { names = fs.readdirSync(dir).sort(); }
  catch (_e) { return out; } // unreadable subagents dir — main mining stands
  for (const f of names) {
    if (!/^agent-.*\.jsonl$/.test(f)) continue;
    const p = path.join(dir, f);
    try {
      const m = mine(p);
      if (m.messages) out.push({ file: f, path: p, mined: m });
    } catch (_e) { /* unreadable subagent transcript — main mining stands */ }
  }
  return out;
}

function resolveTranscript(arg) {
  if (process.argv.includes('--latest')) {
    const dir = path.join(projectsDir(), cwdSlug(getFlag('--cwd') || process.cwd()));
    if (!fs.existsSync(dir)) die('no transcripts dir for this project: ' + dir);
    const files = fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl'))
      .map((f) => ({ f, m: fs.statSync(path.join(dir, f)).mtimeMs }))
      .sort((a, b) => b.m - a.m);
    if (!files.length) die('no transcripts found under ' + dir);
    return path.join(dir, files[0].f);
  }
  if (!arg) die('usage: vault-harvest.js <transcript.jsonl | session-id> [--latest] [--inbox] [--vault <dir>] [--topic <slug>] [--from-inbox]');
  if (fs.existsSync(arg)) return path.resolve(arg);
  const root = projectsDir();
  if (fs.existsSync(root)) {
    for (const d of fs.readdirSync(root)) {
      const p = path.join(root, d, arg + '.jsonl');
      if (fs.existsSync(p)) return p;
    }
  }
  die('transcript not found: ' + arg + ' (looked for a file, then <projects>/*/' + arg + '.jsonl)');
}

function alreadyHarvested(vault, session) {
  if (!session) return null;
  const topics = path.join(vault, 'topics');
  if (!fs.existsSync(topics)) return null;
  for (const t of fs.readdirSync(topics)) {
    const runs = path.join(topics, t, 'runs');
    if (!fs.existsSync(runs)) continue;
    for (const r of fs.readdirSync(runs)) {
      const lin = path.join(runs, r, 'lineage.json');
      if (!fs.existsSync(lin)) continue;
      try { if (JSON.parse(fs.readFileSync(lin, 'utf8')).session === session) return t + '/' + r; } catch (_e) {}
    }
  }
  return null;
}

function digest(mined, transcript, subs) {
  const L = ['## Summary', '', mined.summary ? mined.summary.trim() : '_No final assistant text found._', ''];
  L.push('## Files written during the session', '');
  if (!mined.writes.length) L.push('_None captured._');
  for (const w of mined.writes) {
    L.push('- `' + w.file + '` (' + w.bytes + 'B · transcript:' + w.line + ')');
    if (w.content && /\.md$/i.test(w.file)) {
      L.push('', '````', w.content + (w.truncated ? '\n… [truncated]' : ''), '````', '');
    }
  }
  L.push('', '## Source events', '');
  if (!mined.sources.length) L.push('_None captured._');
  for (const s of mined.sources) L.push('- ' + s.tool + ' — ' + (s.detail || '(no detail)') + ' (transcript:' + s.line + ')');
  if (subs && subs.length) {
    L.push('', '## Subagents (' + subs.length + ' mined)', '');
    for (const s of subs) {
      L.push('### ' + s.file, '');
      if (s.mined.summary) L.push(s.mined.summary.trim().slice(0, 2000), '');
      for (const w of s.mined.writes) L.push('- Write `' + w.file + '` (' + w.bytes + 'B · ' + s.file + ':' + w.line + ')');
      for (const src of s.mined.sources) L.push('- ' + src.tool + ' — ' + (src.detail || '(no detail)') + ' (' + s.file + ':' + src.line + ')');
      L.push('');
    }
  }
  L.push('', '## Provenance', '',
    '- transcript: ' + transcript,
    '- extraction: deterministic (transcript-mine); everything above is model output from that session — treat as model-asserted until the librarian verifies it (stage 3)');
  return L.join('\n');
}

function harvestOne(vault, transcript, opts) {
  const mined = mine(transcript);
  if (!mined.messages) return { status: 'error', error: 'no Messages-shaped records in ' + transcript };
  const session = mined.sessionId || path.basename(transcript, '.jsonl');
  const existing = alreadyHarvested(vault, session);
  if (existing) return { status: 'already-harvested', existing, session };
  const subs = mineSubagents(transcript);

  const topic = lib.slugify(opts.topic || path.basename(mined.cwd || '') || 'harvested-session');
  const title = opts.title || 'Harvest: ' + topic;
  const run = lib.allocateRun(vault, topic, session);
  const date = lib.today();

  lib.atomicWrite(path.join(run.runDir, 'plan.md'), [
    '---', 'topic: ' + run.topic, 'title: ' + title, 'scope: general',
    'classification: harvest', 'session: ' + session,
    'aliases: ' + JSON.stringify([opts.topicGuess || path.basename(mined.cwd || '')].filter(Boolean)),
    'questions: []', 'date: ' + date, '---', '',
    '# Plan — harvested session', '', '## Question', '',
    '(lazy harvest of session ' + session + ' — no explicit research question)', '',
    '```manifest', '[{"role": "harvest", "file": "findings/harvest.md"}]', '```', '',
  ].join('\n'));
  lib.atomicWrite(path.join(run.runDir, 'findings', 'harvest.md'), [
    '---', 'role: harvest', 'run: ' + run.runId, 'task: deterministic transcript harvest',
    'date: ' + date, '---', '', '# Findings — harvest', '', digest(mined, transcript, subs), '',
  ].join('\n'));
  lib.atomicWrite(path.join(run.runDir, 'synthesis.md'),
    '# Synthesis (harvested)\n\n' + (mined.summary ? mined.summary.trim() : '_No final assistant text — digest only._') + '\n');

  let saved;
  try {
    const saveArgs = [path.join(__dirname, 'vault-save.js'), run.runDir,
      '--light', '--vault', vault, '--session', session, '--transcript', transcript];
    for (const s of subs) saveArgs.push('--transcript', s.path);
    const save = execFileSync('node', saveArgs, { encoding: 'utf8' });
    saved = JSON.parse(save.trim().split('\n').pop());
  } catch (e) {
    // persist failed: the staged run has no lineage.json, so a retry will
    // allocate a fresh dir — report the orphan loudly instead of hiding it
    return { status: 'error', session,
      error: 'vault-save failed: ' + String((e && (e.stderr || e.message)) || e).split('\n')[0],
      orphanedRun: run.runDir };
  }
  return { status: 'harvested', session, runId: run.runId, topic: run.topic,
    writes: mined.writes.length, sources: mined.sources.length, subagents: subs.length,
    versionWarning: mined.versionWarning, provenanceLine: saved.provenanceLine };
}

function removePointers(vault, sessions) {
  lib.withLock(vault, () => {
    const inboxFile = path.join(vault, 'inbox.jsonl');
    const keep = lib.readJsonl(inboxFile).records.filter((r) => !(r && sessions.includes(r.session)));
    lib.atomicWrite(inboxFile, keep.map((r) => JSON.stringify(r)).join('\n') + (keep.length ? '\n' : ''));
    lib.gitCommit(vault, 'research: drain inbox (' + sessions.length + ' pointer' + (sessions.length === 1 ? '' : 's') + ')');
  });
}

function drainInbox(vault) {
  const pointers = lib.readJsonl(path.join(vault, 'inbox.jsonl')).records.filter((r) => r && r.kind === 'pointer');
  const results = [];
  const done = [];
  let harvested = 0, already = 0, missing = 0, errors = 0;
  for (const p of pointers) {
    if (!p.transcript || !fs.existsSync(p.transcript)) {
      missing++; done.push(p.session); results.push({ session: p.session, status: 'transcript-missing' });
      continue;
    }
    const r = harvestOne(vault, p.transcript, { topic: p.topicGuess, topicGuess: p.topicGuess });
    results.push(r);
    if (r.status === 'harvested') { harvested++; done.push(p.session); }
    else if (r.status === 'already-harvested') { already++; done.push(p.session); }
    else if (r.status === 'error') errors++; // pointer KEPT — retried next drain, now visibly counted
  }
  if (done.length) removePointers(vault, done);
  process.stdout.write(JSON.stringify({ drained: done.length, harvested, alreadyHarvested: already, missing, errors, results }) + '\n');
}

function main() {
  const vault = lib.resolveVault(getFlag('--vault'));
  if (process.argv.includes('--inbox')) return drainInbox(vault);
  const posArg = process.argv[2] && !process.argv[2].startsWith('--') ? process.argv[2] : null;
  const transcript = resolveTranscript(posArg);
  const res = harvestOne(vault, transcript, { topic: getFlag('--topic'), title: getFlag('--title') });
  if (res.status === 'error') {
    process.stdout.write(JSON.stringify(res) + '\n');
    process.stderr.write('vault-harvest: ' + res.error
      + (res.orphanedRun ? ' (staged run left at ' + res.orphanedRun + ' — no lineage, safe to inspect or delete)' : '') + '\n');
    process.exit(1);
  }
  if (process.argv.includes('--from-inbox') && res.session) removePointers(vault, [res.session]);
  process.stdout.write(JSON.stringify(res) + '\n');
}

function emitFatal(e) {
  process.stdout.write(JSON.stringify({ status: 'error', error: String((e && e.message) || e) }) + '\n');
  process.stderr.write('vault-harvest: failed: ' + ((e && e.stack) || e) + '\n');
  process.exit(1);
}

try { main(); } catch (e) { emitFatal(e); }
