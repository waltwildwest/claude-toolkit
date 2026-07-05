#!/usr/bin/env node
'use strict';
// vault-doctor — the librarian's deterministic half (spec Pillar 5).
// Property-checker, not vibes-reviewer: NEVER calls an LLM. Three phases:
//   1. SWEEP  (read-only, no lock)   doctor-sweeps property checks + work items
//   2. PROBE  (read-only network)    wayback-queue availability/save retries
//   3. FIX    (ONE withLock)         drop dead inbox pointers, compact
//      index.jsonl, materialize claims-current.jsonl, learn aliases from
//      recall misses, apply wayback outcomes, write profiles/source-quality.md,
//      regenerate DASHBOARD.md, append the doctor hwm record, auto-commit.
// Emits ONE JSON line {status, fixed, report, work, dropped, hwm} — the work
// report the skill's doctor flow (references/doctor.md) consumes to dispatch
// LLM passes. Agent output re-enters ONLY through vault-save (staged runs or
// --events --doctor); this script grants nothing by itself.
//
//   node vault-doctor.js [--vault <dir>] [--stale-days <n=30>]
//                        [--max-pairs <n=40>] [--max-drain <n=10>] [--no-network]
//   node vault-doctor.js --schedule-snippet
//
// exit 0 ran (findings included) / 1 hard error.

const fs = require('fs');
const path = require('path');
const lib = require('./vault-lib');
const sweeps = require('./doctor-sweeps');
const quality = require('./doctor-quality');
const views = require('./vault-views');

const CAPS = { promote: 50, freshnessTopics: 10, mine: 10 };
const MAX_ATTEMPTS = 5;
const STOP = new Set(['this', 'that', 'with', 'from', 'have', 'will', 'been', 'were', 'they', 'their',
  'which', 'about', 'into', 'than', 'then', 'when', 'where', 'only', 'also', 'more', 'most', 'some', 'such']);

const WB_BASE = process.env.WAYBACK_API || null;
const WB_AVAIL = (WB_BASE || 'https://archive.org') + '/wayback/available?url=';
const WB_SAVE = (WB_BASE || 'https://web.archive.org') + '/save/';
const WB_TIMEOUT = Number(process.env.WAYBACK_TIMEOUT_MS || 3000);

const SNIPPET = 'Run the librarian on a schedule (the deterministic half is also fine on demand via /research doctor):\n'
  + '\n'
  + '# cron — weekly, Monday 08:00, deterministic half only (no LLM passes):\n'
  + '0 8 * * 1  RESEARCH_VAULT_DIR="$HOME/research-vault" node "' + __dirname + '/vault-doctor.js"\n'
  + '\n'
  + '# Claude Code scheduled agent — deterministic half + the LLM passes:\n'
  + '#   create a weekly scheduled task / routine whose prompt is:  /research doctor\n'
  + '\n'
  + 'Plain cron re-derives the promotion/freshness/mining work each run, but\n'
  + 'contradiction candidates are emitted ONCE per run (the high-water mark advances\n'
  + 'even if stdout is discarded) — capture stdout under cron, or prefer the\n'
  + 'scheduled-agent path so pairs are judged in the same session.\n';

function strFlag(name) { const i = process.argv.indexOf(name); return i !== -1 ? process.argv[i + 1] : null; }
function numFlag(name, dflt) {
  const i = process.argv.indexOf(name);
  if (i === -1) return dflt;
  const n = Number(process.argv[i + 1]);
  return Number.isFinite(n) && n >= 0 ? n : dflt;
}

function httpGet(url, timeoutMs, redirects) {
  return new Promise((resolve, reject) => {
    let mod;
    try { mod = new URL(url).protocol === 'http:' ? require('http') : require('https'); }
    catch (e) { return reject(e); }
    const req = mod.get(url, { headers: { 'user-agent': 're-searcher-vault-doctor/0.3' } }, (res) => {
      const loc = res.headers.location;
      if (res.statusCode >= 300 && res.statusCode < 400 && loc) {
        res.resume();
        if ((redirects || 0) >= 5) return reject(new Error('too many redirects'));
        return httpGet(new URL(loc, url).toString(), timeoutMs, (redirects || 0) + 1).then(resolve, reject);
      }
      if (res.statusCode !== 200) { res.resume(); return reject(new Error('http ' + res.statusCode)); }
      const chunks = [];
      res.on('data', (c) => { if (chunks.length < 64) chunks.push(c); });
      res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
      res.on('error', reject);
    });
    req.setTimeout(timeoutMs, () => req.destroy(new Error('timeout')));
    req.on('error', reject);
  });
}

// PROBE phase — network OUTSIDE the lock (withLock takes a sync fn). Returns
// per-entry outcomes; the FIX phase rewrites the queue from them. "Drained
// slowly": at most maxDrain probes per run.
async function probeWayback(vault, maxDrain, noNetwork) {
  const queue = lib.readJsonl(path.join(vault, 'wayback-queue.jsonl')).records;
  const outcomes = [];
  let probed = 0;
  for (const entry of queue) {
    if (!entry || !entry.url) { outcomes.push({ entry, action: 'drop-failed' }); continue; }
    if (noNetwork || probed >= maxDrain) { outcomes.push({ entry, action: 'keep' }); continue; }
    probed++;
    let action = null, snap = null;
    try {
      const j = JSON.parse(await httpGet(WB_AVAIL + encodeURIComponent(entry.url), WB_TIMEOUT, 0));
      const c = j && j.archived_snapshots && j.archived_snapshots.closest;
      if (c && c.available && c.url) { action = 'exists'; snap = String(c.url); }
    } catch (_e) { /* availability failed — try the save */ }
    if (!action) {
      try { await httpGet(WB_SAVE + entry.url, WB_TIMEOUT, 0); action = 'requested'; }
      catch (_e) { action = ((entry.attempts || 0) + 1) >= MAX_ATTEMPTS ? 'drop-failed' : 'retry'; }
    }
    outcomes.push({ entry, action, snap });
  }
  return outcomes;
}

function updateSourceWayback(vault, sourceId, status, snapshot) {
  if (!sourceId) return;
  const p = path.join(vault, 'sources', String(sourceId) + '.md');
  if (!fs.existsSync(p)) return;
  const text = fs.readFileSync(p, 'utf8');
  let updated = text.replace(/^wayback: .*$/m, 'wayback: ' + status);
  if (snapshot && !/^wayback_url: /m.test(updated)) {
    updated = updated.replace(/^wayback: .*$/m, 'wayback: ' + status + '\nwayback_url: ' + snapshot);
  }
  if (updated !== text) lib.atomicWrite(p, updated);
}

// Alias enrichment (spec Pillar 5): a near-miss whose exact probe LATER hit a
// topic means the vocabulary gap healed via a slower path — make it a direct
// alias. Incremental from the metrics hwm.
function mineAliases(metricsRecords, fromIdx, indexMap) {
  const learned = [];
  const seen = new Set();
  for (let i = fromIdx; i < metricsRecords.length; i++) {
    const nm = metricsRecords[i];
    if (!nm || nm.kind !== 'near-miss' || !Array.isArray(nm.terms) || !nm.terms.length) continue;
    const probe = nm.terms.join(' ').toLowerCase();
    for (let j = i + 1; j < metricsRecords.length; j++) {
      const rc = metricsRecords[j];
      if (!rc || rc.kind !== 'recall' || !Array.isArray(rc.hits) || !rc.hits.length) continue;
      if ((rc.terms || []).join(' ').toLowerCase() !== probe) continue;
      const slug = rc.hits[0];
      const rec = indexMap.get(slug);
      if (rec) {
        const hay = (slug + ' ' + (rec.title || '') + ' ' + (rec.aliases || []).join(' ')).toLowerCase();
        const key = slug + '|' + probe;
        if (!hay.includes(probe) && !seen.has(key)) { learned.push({ slug, alias: probe }); seen.add(key); }
      }
      break;
    }
  }
  return learned;
}

function tokensOf(s) {
  return new Set(String(s).toLowerCase().split(/[^a-z0-9.]+/).filter((w) => w.length >= 4 && !STOP.has(w)));
}

// Work items for the LLM passes. All caps report a dropped count.
function buildWork(vault, claims, indexMap, claimRecords, hwmClaims, staleDays, maxPairs) {
  const work = { promote: [], freshness: [], mine: [], contradictions: [] };
  const dropped = { promote: 0, freshness: 0, mine: 0, contradictions: 0 };

  for (const c of claims.values()) {
    if (c.status !== 'active' || c.provenance !== 'verbatim-grounded') continue;
    if (work.promote.length >= CAPS.promote) { dropped.promote++; continue; }
    work.promote.push({ claim: c.id, topic: c.topic || null, statement: c.statement, quote: c.quote || null, source: c.source || null });
  }

  const cutoff = Date.now() - staleDays * 86400000;
  const byTopic = new Map();
  for (const c of claims.values()) {
    if (c.status !== 'active' || !c.topic) continue;
    const rec = indexMap.get(c.topic);
    if (!rec || (rec.volatility || 'moving') !== 'moving') continue;
    const t = Date.parse(String(c.date || ''));
    if (Number.isNaN(t) || t > cutoff) continue;
    const list = byTopic.get(c.topic) || [];
    list.push({ claim: c.id, statement: c.statement, date: c.date });
    byTopic.set(c.topic, list);
  }
  for (const [topic, list] of byTopic) {
    if (work.freshness.length >= CAPS.freshnessTopics) { dropped.freshness++; continue; }
    work.freshness.push({ topic, claims: list });
  }

  const runsWithClaims = new Set(Array.from(claims.values()).map((c) => c.run));
  for (const e of sweeps.listRunDirs(vault)) {
    const lin = path.join(e.dir, 'lineage.json');
    if (!fs.existsSync(lin)) continue;
    let l;
    try { l = JSON.parse(fs.readFileSync(lin, 'utf8')); } catch (_e) { continue; }
    if (!l.light || runsWithClaims.has(e.run)) continue;
    if (work.mine.length >= CAPS.mine) { dropped.mine++; continue; }
    work.mine.push({ topic: e.topic, run: e.run });
  }

  // contradictions: only claims REGISTERED since the hwm, within topic +
  // alias-shared topics, token-overlap prefiltered — incremental by design.
  const aliasTopics = new Map();
  for (const rec of indexMap.values()) {
    for (const a of rec.aliases || []) {
      const k = String(a).toLowerCase();
      const s = aliasTopics.get(k) || new Set();
      s.add(rec.slug);
      aliasTopics.set(k, s);
    }
  }
  const newClaims = claimRecords.slice(hwmClaims).filter((r) => r && r.id && !r.op);
  const seenPairs = new Set();
  for (const nc of newClaims) {
    const a = claims.get(nc.id);
    if (!a || a.status !== 'active' || !a.topic) continue;
    const candidateTopics = new Set([a.topic]);
    const rec = indexMap.get(a.topic);
    for (const al of (rec && rec.aliases) || []) {
      for (const s of aliasTopics.get(String(al).toLowerCase()) || []) candidateTopics.add(s);
    }
    const ta = tokensOf(a.statement);
    for (const b of claims.values()) {
      if (b.id === a.id || b.status !== 'active' || !candidateTopics.has(b.topic)) continue;
      if (a.contradictedBy.includes(b.id)) continue;
      const key = [a.id, b.id].sort().join('|');
      if (seenPairs.has(key)) continue;
      let overlap = 0;
      for (const w of tokensOf(b.statement)) if (ta.has(w)) overlap++;
      if (!overlap) continue;
      seenPairs.add(key);
      if (work.contradictions.length >= maxPairs) { dropped.contradictions++; continue; }
      work.contradictions.push({ a: a.id, b: b.id, topic: a.topic, aStatement: a.statement, bStatement: b.statement });
    }
  }
  return { work, dropped };
}

async function run() {
  if (process.argv.includes('--schedule-snippet')) { process.stdout.write(SNIPPET); return; }
  const vault = lib.resolveVault(strFlag('--vault'));
  const staleDays = numFlag('--stale-days', 30);
  const maxPairs = numFlag('--max-pairs', 40);
  const maxDrain = numFlag('--max-drain', 10);
  const noNetwork = process.argv.includes('--no-network');

  // ---- phase 1: read-only sweeps + work items ----
  const claimRecords = lib.readJsonl(path.join(vault, 'claims.jsonl')).records;
  const { claims } = lib.foldClaims(claimRecords);
  const metricsRecords = lib.readJsonl(path.join(vault, 'metrics.jsonl')).records;
  const indexMap = new Map();
  for (const r of lib.readJsonl(path.join(vault, 'index.jsonl')).records) if (r && r.slug) indexMap.set(r.slug, r);
  const lastDoctor = metricsRecords.filter((m) => m && m.kind === 'doctor').pop() || null;
  const hwm = (lastDoctor && lastDoctor.hwm) || { claims: 0, metrics: 0 };

  const report = {
    orphanRuns: sweeps.sweepOrphanRuns(vault),
    duplicateSessions: sweeps.sweepDuplicateSessions(vault),
    sourceRefs: sweeps.sweepSourceRefs(vault, claims),
    quotes: sweeps.sweepQuotes(vault, claims),
    secrets: sweeps.sweepSecrets(vault),
    census: sweeps.schemaCensus(vault),
    deadPointers: sweeps.deadInboxPointers(vault),
  };
  const { work, dropped } = buildWork(vault, claims, indexMap, claimRecords, hwm.claims || 0, staleDays, maxPairs);

  // ---- phase 2: network probes (outside the lock) ----
  const outcomes = await probeWayback(vault, maxDrain, noNetwork);

  // ---- phase 3: fixes under ONE lock ----
  const fixed = lib.withLock(vault, () => {
    const f = { deadPointersDropped: 0, indexCompacted: null, claimsCurrent: 0, aliasesLearned: [],
      wayback: { exists: 0, requested: 0, retried: 0, droppedFailed: 0, kept: 0 } };

    if (report.deadPointers.length) {
      const deadSet = new Set(report.deadPointers.map((p) => p.session));
      const inboxFile = path.join(vault, 'inbox.jsonl');
      const keep = lib.readJsonl(inboxFile).records.filter((r) => !(r && r.kind === 'pointer' && deadSet.has(r.session)));
      lib.atomicWrite(inboxFile, keep.map((r) => JSON.stringify(r)).join('\n') + (keep.length ? '\n' : ''));
      f.deadPointersDropped = report.deadPointers.length;
    }

    // index compaction + alias learning in ONE write (last-record-per-slug;
    // learned aliases merge into the map BEFORE the write, so a re-run finds
    // nothing to compact — the idempotence the contract test asserts)
    const idxFile = path.join(vault, 'index.jsonl');
    const idxRecords = lib.readJsonl(idxFile).records;
    const lastBySlug = new Map();
    for (const r of idxRecords) if (r && r.slug) lastBySlug.set(r.slug, r);
    for (const { slug, alias } of mineAliases(metricsRecords, hwm.metrics || 0, lastBySlug)) {
      const prev = lastBySlug.get(slug);
      if (!prev || (prev.aliases && prev.aliases.includes(alias))) continue;
      lastBySlug.set(slug, Object.assign({}, prev, { aliases: Array.from(new Set([].concat(prev.aliases || [], [alias]))) }));
      f.aliasesLearned.push({ slug, alias });
    }
    if (lastBySlug.size < idxRecords.length || f.aliasesLearned.length) {
      lib.atomicWrite(idxFile, Array.from(lastBySlug.values()).map((r) => JSON.stringify(r)).join('\n') + (lastBySlug.size ? '\n' : ''));
    }
    f.indexCompacted = { before: idxRecords.length, after: lastBySlug.size };

    // claims-current: the materialized view for cheap greps (active only,
    // effective provenance; events dropped — JSON.stringify skips undefined)
    const current = Array.from(claims.values()).filter((c) => c.status === 'active')
      .map((c) => Object.assign({}, c, { events: undefined }));
    lib.atomicWrite(path.join(vault, 'claims-current.jsonl'),
      current.map((c) => JSON.stringify(c)).join('\n') + (current.length ? '\n' : ''));
    f.claimsCurrent = current.length;

    const keepQ = [];
    for (const o of outcomes) {
      if (o.action === 'exists') { f.wayback.exists++; updateSourceWayback(vault, o.entry.source_id, 'exists', o.snap); }
      else if (o.action === 'requested') { f.wayback.requested++; updateSourceWayback(vault, o.entry.source_id, 'requested', null); }
      else if (o.action === 'retry') { f.wayback.retried++; keepQ.push(Object.assign({}, o.entry, { attempts: (o.entry.attempts || 0) + 1 })); }
      else if (o.action === 'drop-failed') { f.wayback.droppedFailed++; if (o.entry) updateSourceWayback(vault, o.entry.source_id, 'failed', null); }
      else { f.wayback.kept++; keepQ.push(o.entry); }
    }
    lib.atomicWrite(path.join(vault, 'wayback-queue.jsonl'),
      keepQ.map((r) => JSON.stringify(r)).join('\n') + (keepQ.length ? '\n' : ''));

    fs.mkdirSync(path.join(vault, 'profiles'), { recursive: true });
    lib.atomicWrite(path.join(vault, 'profiles', 'source-quality.md'),
      quality.renderProfile(quality.scoreQuality(claims), lib.today()));
    // hwm record BEFORE the dashboard regen so DASHBOARD's "Doctor: last run"
    // line reflects THIS run, not the previous one
    lib.appendJsonl(path.join(vault, 'metrics.jsonl'), {
      v: 1, kind: 'doctor', ts: new Date().toISOString(),
      hwm: { claims: claimRecords.length, metrics: metricsRecords.length },
      fixed: { deadPointersDropped: f.deadPointersDropped, aliasesLearned: f.aliasesLearned.length, wayback: f.wayback },
      work: { promote: work.promote.length, freshness: work.freshness.length, mine: work.mine.length, contradictions: work.contradictions.length },
      report: { orphanRuns: report.orphanRuns.length, duplicateSessions: report.duplicateSessions.length,
        brokenRefs: report.sourceRefs.broken.length, quoteFails: report.quotes.failed.length, secrets: report.secrets.length },
    });
    views.regenDashboard(vault, { work });
    const c = lib.gitCommit(vault, 'research: doctor sweep');
    if (c.warning) f.commitWarning = c.warning;
    return f;
  });

  process.stdout.write(JSON.stringify({ status: 'ok', vault, fixed, report, work, dropped,
    hwm: { claims: claimRecords.length, metrics: metricsRecords.length } }) + '\n');
  process.stderr.write('doctor: ' + report.orphanRuns.length + ' orphan run(s) · '
    + report.duplicateSessions.length + ' duplicate session(s) · ' + report.sourceRefs.broken.length + ' broken ref(s) · '
    + report.quotes.failed.length + ' quote fail(s) · ' + report.secrets.length + ' secret hit(s) — work: '
    + work.promote.length + ' promote, ' + work.freshness.length + ' freshness, '
    + work.mine.length + ' mine, ' + work.contradictions.length + ' pair(s)\n');
}

run().catch((e) => {
  process.stdout.write(JSON.stringify({ status: 'error', error: String((e && e.message) || e) }) + '\n');
  process.stderr.write('vault-doctor: failed: ' + ((e && e.stack) || e) + '\n');
  process.exit(1);
});
