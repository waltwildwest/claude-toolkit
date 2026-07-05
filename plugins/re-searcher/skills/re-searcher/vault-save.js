#!/usr/bin/env node
'use strict';
// vault-save — the persist gate. Layered so bookkeeping can never hold a run
// hostage: tier 1 (plan/findings/synthesis registration, lineage, transcript
// copies, index append, view regen) always lands; tier 2 validates claims
// PER RECORD and quarantines rejects to the run's claims-rejected.jsonl.
// All mutation happens under the advisory vault lock; every save auto-commits.
//
//   node vault-save.js <run-dir> [--vault <dir>] [--session <id>]
//                      [--transcript <path>]... [--light] [--fresh]
//   node vault-save.js --new-run --topic <slug> [--session <id>] [--vault <dir>]
//   node vault-save.js --check-staging <run-dir>
//   node vault-save.js --events <file.jsonl> [--doctor] [--vault <dir>]
//
// stdout: one JSON line always. exit 0 ok (complete or partial claims),
// 2 staging incomplete (--check-staging), 1 hard error.

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const lib = require('./vault-lib');
const cv = require('./claim-validate');
const views = require('./vault-views');

const MIN_FINDING_BYTES = 500;

function getFlag(name) { const i = process.argv.indexOf(name); return i !== -1 ? process.argv[i + 1] : null; }
function getAll(name) {
  const out = [];
  process.argv.forEach((x, i) => { if (x === name && process.argv[i + 1]) out.push(process.argv[i + 1]); });
  return out;
}
function die(msg) { process.stderr.write('vault-save: ' + msg + '\n'); process.exit(1); }

function newRun() {
  const vault = lib.resolveVault(getFlag('--vault'));
  const rawTopic = getFlag('--topic');
  if (!rawTopic) die('usage: vault-save.js --new-run --topic <slug> [--session <id>] [--vault <dir>]');
  let r;
  try { r = lib.allocateRun(vault, rawTopic, getFlag('--session')); }
  catch (e) { die(e.message); }
  process.stdout.write(JSON.stringify(r) + '\n');
}

function readManifest(runDir) {
  const planFile = path.join(runDir, 'plan.md');
  if (!fs.existsSync(planFile)) die('no plan.md in ' + runDir + ' — the plan must be persisted before fan-out');
  const plan = fs.readFileSync(planFile, 'utf8');
  const m = plan.match(/```manifest\s*\n([\s\S]*?)```/);
  if (!m) die('plan.md has no ```manifest block — start from: node vault-init.js --template plan');
  let manifest;
  try { manifest = JSON.parse(m[1]); } catch (e) { die('manifest block is not valid JSON: ' + e.message); }
  if (!Array.isArray(manifest) || !manifest.length || manifest.some((e) => !e || !e.role || !e.file)) {
    die('manifest must be a non-empty JSON array of {role, file}');
  }
  return { manifest, plan };
}

function stagingReport(runDir) {
  const { manifest, plan } = readManifest(runDir);
  const missing = [], stubs = [], badHeader = [];
  for (const entry of manifest) {
    const f = path.join(runDir, entry.file);
    if (!fs.existsSync(f)) { missing.push(entry.file); continue; }
    const st = fs.statSync(f);
    if (st.size < MIN_FINDING_BYTES) stubs.push(entry.file + ' (' + st.size + 'B < ' + MIN_FINDING_BYTES + 'B)');
    const fm = lib.parseFrontmatter(fs.readFileSync(f, 'utf8'));
    if (!fm.fields.role) badHeader.push(entry.file + ' (missing finding frontmatter: role)');
  }
  return { manifest, plan, missing, stubs, badHeader, ok: !missing.length && !stubs.length && !badHeader.length };
}

function checkStaging(runDir) {
  const r = stagingReport(path.resolve(runDir));
  process.stdout.write(JSON.stringify({ ok: r.ok, agents: r.manifest.length, missing: r.missing, stubs: r.stubs, badHeader: r.badHeader }) + '\n');
  process.exit(r.ok ? 0 : 2);
}

function claimCtx(vault, runId, topic, date) {
  const records = lib.readJsonl(path.join(vault, 'claims.jsonl')).records;
  const { claims: registry } = lib.foldClaims(records);
  const runClaims = Array.from(registry.values()).filter((c) => c.run === runId);
  return {
    vault, runId, topic, date,
    takenIds: new Set(registry.keys()),
    knownIds: new Set(registry.keys()),
    supersedeEdges: new Map(Array.from(registry.values()).map((c) => [c.id, c.supersededBy.slice()])),
    // re-persist guards: claims this run already registered (keyed by the
    // NORMALIZED statement so trivial whitespace/case/punctuation variants
    // don't slip past dedup as new claims), kept with their ids so batch refs
    // still resolve on a re-save
    runStatements: new Set(runClaims.map((c) => lib.normStatement(c.statement))),
    runClaimIdByStatement: new Map(runClaims.map((c) => [lib.normStatement(c.statement), c.id])),
    eventKeys: new Set(records.filter((r) => r && r.op).map((r) => r.op + '|' + r.claim + '|' + (r.by || ''))),
  };
}

function persist(runDir) {
  const vault = lib.resolveVault(getFlag('--vault'));
  if (!fs.existsSync(runDir)) die('run dir missing: ' + runDir);
  const { manifest, plan } = readManifest(runDir);
  const fm = lib.parseFrontmatter(plan).fields;
  const topic = lib.slugify(String(fm.topic || ''));
  if (!fm.topic) die('plan.md frontmatter needs topic: <slug>');
  const folderTopic = path.basename(path.dirname(path.dirname(runDir)));
  if (folderTopic !== topic) die('plan topic "' + topic + '" does not match run folder topic "' + folderTopic + '" — fix plan.md or move the run');
  const runId = path.basename(runDir);
  const light = process.argv.includes('--light');
  const date = lib.today();
  const warnings = [];

  const VOLATILITY = ['stable', 'moving', 'live'];
  let volatility = null;
  if (fm.volatility !== undefined) {
    volatility = String(fm.volatility);
    if (!VOLATILITY.includes(volatility)) {
      warnings.push('unknown volatility "' + volatility + '" (stable | moving | live) — keeping previous/default');
      volatility = null;
    }
  }

  const result = lib.withLock(vault, () => {
    // ---- tier 1: registration that can never be held hostage by claims ----
    const staging = stagingReport(runDir);
    if (!staging.ok) {
      warnings.push('staging incomplete: missing=' + JSON.stringify(staging.missing)
        + ' stubs=' + JSON.stringify(staging.stubs) + ' badHeader=' + JSON.stringify(staging.badHeader));
    }
    if (!light && !fs.existsSync(path.join(runDir, 'synthesis.md'))) {
      warnings.push('no synthesis.md — run persisted without a synthesis');
    }

    const copied = [];
    for (const t of getAll('--transcript')) {
      try {
        fs.mkdirSync(path.join(runDir, 'transcripts'), { recursive: true });
        const gz = zlib.gzipSync(fs.readFileSync(t));
        lib.atomicWrite(path.join(runDir, 'transcripts', path.basename(t) + '.gz'), gz);
        copied.push(path.basename(t) + '.gz');
      } catch (e) { warnings.push('transcript copy failed for ' + t + ': ' + (e.code || e.message)); }
    }

    const uniq = (arr) => Array.from(new Set(arr.filter((x) => typeof x === 'string' && x.trim())));
    const prevIdx = lib.readJsonl(path.join(vault, 'index.jsonl')).records.filter((r) => r && r.slug === topic).pop();
    lib.appendJsonl(path.join(vault, 'index.jsonl'), {
      v: 1, slug: topic, title: String(fm.title || topic),
      aliases: uniq([].concat((prevIdx && prevIdx.aliases) || [], fm.aliases || [])),
      questions: uniq([].concat((prevIdx && prevIdx.questions) || [], fm.questions || [])),
      scope: String(fm.scope || 'general'), run: runId, date,
      volatility: volatility || (prevIdx && prevIdx.volatility) || 'moving',
    });

    lib.atomicWrite(path.join(runDir, 'lineage.json'), JSON.stringify({
      v: 1, session: getFlag('--session') || String(fm.session || 'unknown'),
      run: runId, topic, light, saved: new Date().toISOString(),
      transcripts: copied, agents: manifest.length,
    }, null, 2) + '\n');

    // ---- tier 2: per-record claim validation (quarantine, never abort) ----
    // Two passes: claims land first so staged events can reference ids that
    // don't exist until now. A staged claim may carry "ref": "<local-name>"
    // (a batch-local handle, stripped before registration); staged events may
    // then use "claim": "ref:<local-name>" / "by": "ref:<local-name>".
    let accepted = 0, rejected = 0, downgraded = 0, events = 0, duplicates = 0;
    const ids = [];
    const stagedFile = path.join(runDir, 'claims-staged.jsonl');
    if (fs.existsSync(stagedFile)) {
      const ctx = claimCtx(vault, runId, topic, date);
      const rejFile = path.join(runDir, 'claims-rejected.jsonl');
      const reject = (reason, rec) => { lib.appendJsonl(rejFile, { reason, record: rec }); rejected++; };
      const claimsStaged = [], eventsStaged = [];
      for (const line of fs.readFileSync(stagedFile, 'utf8').split('\n')) {
        if (!line.trim()) continue;
        try {
          const rec = JSON.parse(line);
          (typeof rec.op === 'string' ? eventsStaged : claimsStaged).push(rec);
        } catch (_e) { lib.appendJsonl(rejFile, { reason: 'unparseable JSON', line: line.slice(0, 500) }); rejected++; }
      }
      const refMap = new Map();
      const batchByStatement = new Map(); // normalized statement -> id, for THIS batch
      for (const rec of claimsStaged) {
        const norm = lib.normStatement(rec.statement);
        // dedupe against the registry (re-persist) AND against claims accepted
        // earlier in this same batch — trivial variants collapse to one claim
        const priorId = ctx.runStatements.has(norm) ? ctx.runClaimIdByStatement.get(norm) : batchByStatement.get(norm);
        if (priorId !== undefined) {
          duplicates++;
          if (rec.ref) refMap.set(String(rec.ref), priorId); // refs must still resolve
          continue;
        }
        const ref = rec.ref;
        const clean = Object.assign({}, rec);
        delete clean.ref;
        const res = cv.validateClaim(clean, ctx);
        if (!res.ok) { reject(res.reason, rec); continue; }
        lib.appendJsonl(path.join(vault, 'claims.jsonl'), res.record);
        accepted++; ids.push(res.record.id); ctx.knownIds.add(res.record.id);
        batchByStatement.set(norm, res.record.id);
        if (res.downgraded) downgraded++;
        if (ref) refMap.set(String(ref), res.record.id);
      }
      const deref = (v) => (typeof v === 'string' && v.startsWith('ref:')) ? (refMap.get(v.slice(4)) || v) : v;
      for (const rec of eventsStaged) {
        const resolved = Object.assign({}, rec, { claim: deref(rec.claim) },
          rec.by !== undefined ? { by: deref(rec.by) } : {});
        const key = resolved.op + '|' + resolved.claim + '|' + (resolved.by || '');
        if (ctx.eventKeys.has(key)) { duplicates++; continue; } // re-persist: event already registered
        const res = cv.validateEvent(resolved, ctx);
        if (!res.ok) { reject(res.reason, rec); continue; }
        lib.appendJsonl(path.join(vault, 'claims.jsonl'), res.record);
        ctx.eventKeys.add(key);
        events++;
      }
    } else if (!light) {
      warnings.push('no claims-staged.jsonl — full-path runs usually stage claims (see references/claims.md)');
    }

    // ---- views + metrics + auto-commit ----
    views.regenTopic(vault, topic);
    views.regenIndex(vault);
    lib.appendJsonl(path.join(vault, 'metrics.jsonl'), {
      v: 1, kind: 'save', ts: new Date().toISOString(), run: runId, topic, light,
      fresh: process.argv.includes('--fresh'),
      accepted, rejected, downgraded, events, warnings: warnings.length,
    });
    const c = lib.gitCommit(vault, 'research: persist run ' + runId + ' ' + topic);
    if (c.warning) warnings.push(c.warning);

    return {
      status: rejected ? 'partial' : 'complete', run: runId, topic, light,
      claims: { accepted, rejected, downgraded, events, duplicates, ids }, transcripts: copied.length, warnings,
      provenanceLine: light
        ? 'light run · saved to topics/' + topic + '/runs/' + runId
        : 'fresh run · ' + manifest.length + ' agents · saved to topics/' + topic + '/runs/' + runId,
    };
  });

  process.stdout.write(JSON.stringify(result) + '\n');
}

function saveEvents(file) {
  const vault = lib.resolveVault(getFlag('--vault'));
  if (!fs.existsSync(file)) die('events file missing: ' + file);
  const out = lib.withLock(vault, () => {
    // runId/topic are inert here — events-only validation never registers claims
    const ctx = claimCtx(vault, 'events', null, lib.today());
    if (process.argv.includes('--doctor')) ctx.doctor = true; // the ONLY doctor-powered path — persist never sets this
    let applied = 0;
    const rejectedList = [];
    for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
      if (!line.trim()) continue;
      let rec;
      try { rec = JSON.parse(line); }
      catch (_e) { rejectedList.push({ reason: 'unparseable JSON', line: line.slice(0, 200) }); continue; }
      const key = rec.op + '|' + rec.claim + '|' + (rec.by || '');
      if (ctx.eventKeys.has(key)) continue; // already registered — re-runs must not duplicate events
      const res = cv.validateEvent(rec, ctx);
      if (!res.ok) { rejectedList.push({ reason: res.reason, record: rec }); continue; }
      lib.appendJsonl(path.join(vault, 'claims.jsonl'), res.record);
      ctx.eventKeys.add(key);
      applied++;
    }
    // regenerate every topic that has events (over-broad but always correct)
    const { claims } = lib.foldClaims(lib.readJsonl(path.join(vault, 'claims.jsonl')).records);
    const touched = new Set();
    for (const c of claims.values()) if (c.events.length && c.topic) touched.add(c.topic);
    for (const t of touched) views.regenTopic(vault, t);
    views.regenIndex(vault);
    const c = lib.gitCommit(vault, 'research: apply ' + applied + ' event(s)');
    return { applied, rejected: rejectedList, commitWarning: c.warning };
  });
  process.stdout.write(JSON.stringify(out) + '\n');
  process.exit(out.rejected.length && !out.applied ? 1 : 0);
}

function main() {
  if (process.argv.includes('--new-run')) return newRun();
  const cs = getFlag('--check-staging');
  if (cs) return checkStaging(cs);
  const ev = getFlag('--events');
  if (ev) return saveEvents(ev);
  const runDir = process.argv[2];
  if (!runDir || runDir.startsWith('--')) {
    die('usage: vault-save.js <run-dir> [--vault <dir>] [--session <id>] [--transcript <p>]... [--light] [--fresh] | --new-run --topic <slug> | --check-staging <run-dir> | --events <file> [--doctor]');
  }
  return persist(path.resolve(runDir));
}

function emitFatal(e) {
  process.stdout.write(JSON.stringify({ status: 'error', error: String((e && e.message) || e) }) + '\n');
  process.stderr.write('vault-save: failed — the vault may hold partial, uncommitted writes: ' + ((e && e.stack) || e) + '\n');
  process.exit(1);
}

try { main(); } catch (e) { emitFatal(e); }
