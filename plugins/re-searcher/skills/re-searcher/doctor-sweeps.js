#!/usr/bin/env node
'use strict';
// doctor-sweeps — the librarian's report-only property checks (module only).
// Every function READS and returns findings; nothing mutates, locks, exits,
// or calls an LLM. vault-doctor.js runs these and folds the results into its
// work report; fixes live there, never here.
//
// Module API (vault = absolute path; claimsMap = lib.foldClaims(...).claims):
//   listRunDirs(vault) sweepOrphanRuns(vault) sweepDuplicateSessions(vault)
//   sweepSourceRefs(vault, claimsMap) sweepQuotes(vault, claimsMap)
//   sweepSecrets(vault) schemaCensus(vault) deadInboxPointers(vault)

const fs = require('fs');
const path = require('path');
const lib = require('./vault-lib');
const { verify } = require('./quote-verify');

const GROUNDED = ['verbatim-grounded', 'externally-verified'];

function listRunDirs(vault) {
  const out = [];
  const topics = path.join(vault, 'topics');
  if (!fs.existsSync(topics)) return out;
  for (const t of fs.readdirSync(topics)) {
    if (t.startsWith('.')) continue;
    const runs = path.join(topics, t, 'runs');
    if (!fs.existsSync(runs)) continue;
    for (const r of fs.readdirSync(runs)) {
      const dir = path.join(runs, r);
      try { if (!fs.statSync(dir).isDirectory()) continue; } catch (_e) { continue; }
      out.push({ topic: t, run: r, dir });
    }
  }
  return out;
}

// Orphaned run (spec Pillar 1): staged artifacts present, persist never
// completed — harvest-failure and crash leftovers. Report-only: runs are
// immutable; deleting one is a human decision.
function sweepOrphanRuns(vault) {
  const out = [];
  for (const e of listRunDirs(vault)) {
    if (fs.existsSync(path.join(e.dir, 'lineage.json'))) continue;
    out.push({ topic: e.topic, run: e.run, reason: 'no lineage.json (persist never completed)' });
  }
  return out;
}

// Two runs sharing a session id = the stage-2 unlocked-idempotence race or a
// manual double-persist.
function sweepDuplicateSessions(vault) {
  const bySession = new Map();
  for (const e of listRunDirs(vault)) {
    const lin = path.join(e.dir, 'lineage.json');
    if (!fs.existsSync(lin)) continue;
    let session = null;
    try { session = JSON.parse(fs.readFileSync(lin, 'utf8')).session; } catch (_e) { continue; }
    if (!session || session === 'unknown') continue;
    const list = bySession.get(session) || [];
    list.push(e.topic + '/' + e.run);
    bySession.set(session, list);
  }
  return Array.from(bySession.entries()).filter(([, runs]) => runs.length > 1)
    .map(([session, runs]) => ({ session, runs }));
}

// Grounded active claims must resolve their source; a tombstone beside a
// missing source is RESOLUTION (redaction happened), not breakage.
function sweepSourceRefs(vault, claimsMap) {
  const broken = [], tombstoned = [];
  for (const c of claimsMap.values()) {
    if (c.status !== 'active' || !c.source) continue;
    if (!GROUNDED.includes(c.provenance)) continue;
    if (fs.existsSync(path.join(vault, 'sources', c.source + '.md'))) continue;
    if (fs.existsSync(path.join(vault, 'sources', c.source + '.tombstone.json'))) {
      tombstoned.push({ claim: c.id, source: c.source });
    } else broken.push({ claim: c.id, source: c.source });
  }
  return { broken, tombstoned };
}

// Deterministic re-run of the quote ladder: a verbatim-grounded quote that no
// longer verifies against its cached extraction is a real defect.
function sweepQuotes(vault, claimsMap) {
  let checked = 0, passed = 0;
  const failed = [];
  for (const c of claimsMap.values()) {
    if (c.status !== 'active' || !GROUNDED.includes(c.provenance)) continue;
    if (!c.source || !c.quote) continue;
    const p = path.join(vault, 'sources', c.source + '.md');
    if (!fs.existsSync(p)) continue; // sweepSourceRefs owns that defect
    checked++;
    const body = lib.parseFrontmatter(fs.readFileSync(p, 'utf8')).body;
    if (verify(String(c.quote), body).verified) passed++;
    else failed.push({ claim: c.id, source: c.source });
  }
  return { checked, passed, failed };
}

const SECRET_PATTERNS = [
  ['aws-access-key', /AKIA[0-9A-Z]{16}/],
  ['github-token', /gh[pousr]_[A-Za-z0-9]{30,}/],
  ['slack-token', /xox[baprs]-[A-Za-z0-9-]{10,}/],
  ['private-key', /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ['anthropic-key', /sk-ant-[A-Za-z0-9-]{20,}/],
  ['bearer-header', /[Aa]uthorization:\s*Bearer\s+[A-Za-z0-9._-]{20,}/],
];

// Raw HTML enters git history — this sweep is the safety net behind the
// store-time scrub. Findings recommend vault-redact; NEVER auto-delete.
function sweepSecrets(vault) {
  const out = [];
  const rawDir = path.join(vault, 'sources', 'raw');
  if (!fs.existsSync(rawDir)) return out;
  for (const f of fs.readdirSync(rawDir)) {
    if (!/\.html$/i.test(f)) continue;
    let text;
    try { text = fs.readFileSync(path.join(rawDir, f), 'utf8'); } catch (_e) { continue; }
    for (const [name, re] of SECRET_PATTERNS) {
      if (re.test(text)) out.push({ file: 'sources/raw/' + f, pattern: name });
    }
  }
  return out;
}

const CENSUS_FILES = ['index.jsonl', 'claims.jsonl', 'metrics.jsonl', 'inbox.jsonl', 'wayback-queue.jsonl'];
const CURRENT_V = 1;

function schemaCensus(vault) {
  const out = {};
  for (const f of CENSUS_FILES) {
    const { records, skipped, missing } = lib.readJsonl(path.join(vault, f));
    if (missing) continue;
    const versions = {};
    let unknownV = 0, aboveCurrent = 0;
    for (const r of records) {
      const v = r && r.v;
      if (typeof v !== 'number') { unknownV++; continue; }
      versions[v] = (versions[v] || 0) + 1;
      if (v > CURRENT_V) aboveCurrent++;
    }
    out[f] = { records: records.length, skipped, versions, unknownV, aboveCurrent };
  }
  return out;
}

function deadInboxPointers(vault) {
  return lib.readJsonl(path.join(vault, 'inbox.jsonl')).records
    .filter((p) => p && p.kind === 'pointer')
    .filter((p) => !p.transcript || !fs.existsSync(p.transcript))
    .map((p) => ({ session: p.session, transcript: p.transcript || null }));
}

module.exports = { listRunDirs, sweepOrphanRuns, sweepDuplicateSessions, sweepSourceRefs, sweepQuotes, sweepSecrets, schemaCensus, deadInboxPointers, SECRET_PATTERNS };
