#!/usr/bin/env node
'use strict';
// vault-save — the persist gate. Layered so bookkeeping can never hold a run
// hostage: tier 1 (plan/findings/synthesis registration, lineage, transcript
// copies, index append, view regen) always lands; tier 2 validates claims
// PER RECORD and quarantines rejects to the run's claims-rejected.jsonl.
// All mutation happens under the advisory vault lock; every save auto-commits.
//
//   node vault-save.js <run-dir> [--vault <dir>] [--session <id>]
//                      [--transcript <path>]... [--light]        # persist (Task 8)
//   node vault-save.js --new-run --topic <slug> [--session <id>] [--vault <dir>]
//   node vault-save.js --check-staging <run-dir>
//   node vault-save.js --events <file.jsonl> [--vault <dir>]     # Task 8
//
// stdout: one JSON line always. exit 0 ok (complete or partial claims),
// 2 staging incomplete (--check-staging), 1 hard error.

const fs = require('fs');
const path = require('path');
const lib = require('./vault-lib');

const MIN_FINDING_BYTES = 500;

function getFlag(name) { const i = process.argv.indexOf(name); return i !== -1 ? process.argv[i + 1] : null; }
function getAll(name) {
  const out = [];
  process.argv.forEach((x, i) => { if (x === name && process.argv[i + 1]) out.push(process.argv[i + 1]); });
  return out;
}
function die(msg) { process.stderr.write('vault-save: ' + msg + '\n'); process.exit(1); }

function today() {
  const d = new Date();
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
}

function newRun() {
  const vault = lib.resolveVault(getFlag('--vault'));
  const rawTopic = getFlag('--topic');
  if (!rawTopic) die('usage: vault-save.js --new-run --topic <slug> [--session <id>] [--vault <dir>]');
  const topic = lib.slugify(rawTopic);
  const sess = (getFlag('--session') || 'anon').replace(/[^a-z0-9]/gi, '').slice(0, 4).toLowerCase() || 'anon';
  const runsDir = path.join(vault, 'topics', topic, 'runs');
  fs.mkdirSync(runsDir, { recursive: true });
  for (const letter of 'abcdefghijklmnopqrstuvwxyz') {
    const id = today() + letter + '-' + sess;
    const dir = path.join(runsDir, id);
    try { fs.mkdirSync(dir); } catch (e) { if (e.code === 'EEXIST') continue; throw e; }
    fs.mkdirSync(path.join(dir, 'findings'));
    process.stdout.write(JSON.stringify({ runId: id, runDir: dir, topic }) + '\n');
    return;
  }
  die('could not allocate a run folder (26 same-day runs with the same session suffix)');
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

function main() {
  if (process.argv.includes('--new-run')) return newRun();
  const cs = getFlag('--check-staging');
  if (cs) return checkStaging(cs);
  const ev = getFlag('--events');
  if (ev) return die('--events mode is not built yet (arrives with persist)'); // replaced in Task 8
  const runDir = process.argv[2];
  if (!runDir || runDir.startsWith('--')) {
    die('usage: vault-save.js <run-dir> [--vault <dir>] [--session <id>] [--transcript <p>]... [--light] | --new-run --topic <slug> | --check-staging <run-dir> | --events <file>');
  }
  die('persist mode is not built yet (Task 8 of the stage-1 plan)'); // replaced in Task 8
}

main();
