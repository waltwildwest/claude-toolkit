#!/usr/bin/env node
'use strict';
// run-bench — Stage 0 fetch benchmark. LIVE NETWORK, on-demand only (never CI).
// Runs vault-fetch over bench/urls.txt, records per-URL outcomes, prints the
// headline number: usable-rate on non-#hard URLs (feasibility predicted 60-75%).
//
//   node run-bench.js --vault <dir>

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const HERE = __dirname;
const FETCH = path.join(HERE, '..', 'skills', 're-searcher', 'vault-fetch.js');

function arg(name, dflt) {
  const i = process.argv.indexOf(name);
  return i !== -1 ? process.argv[i + 1] : dflt;
}

const vault = arg('--vault', process.env.RESEARCH_VAULT_DIR || null);
if (!vault) { process.stderr.write('usage: run-bench.js --vault <dir>\n'); process.exit(1); }
fs.mkdirSync(vault, { recursive: true });
const resultsDir = path.join(HERE, 'results');
fs.mkdirSync(resultsDir, { recursive: true });
const outFile = path.join(resultsDir, 'fetch-results.jsonl');
fs.writeFileSync(outFile, '');

const lines = fs.readFileSync(path.join(HERE, 'urls.txt'), 'utf8').split('\n')
  .map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));

const rows = [];
for (const line of lines) {
  const hard = /#hard/.test(line);
  const url = line.split(/\s+/)[0];
  const t0 = Date.now();
  let rec;
  try {
    const out = execFileSync('node', [FETCH, url, '--vault', vault, '--timeout', '15000'], { encoding: 'utf8' });
    rec = JSON.parse(out.trim().split('\n').pop());
  } catch (err) {
    const out = (err.stdout || '').toString().trim();
    try { rec = JSON.parse(out.split('\n').pop()); }
    catch (_e) { rec = { url, status: 'fetch-error', signals: [String(err.message).slice(0, 120)], score: null, textLength: null, sourcePath: null }; }
  }
  const row = { url, hard, status: rec.status, score: rec.score, signals: rec.signals, textLength: rec.textLength, sourcePath: rec.sourcePath, ms: Date.now() - t0 };
  rows.push(row);
  fs.appendFileSync(outFile, JSON.stringify(row) + '\n');
  process.stdout.write(row.status.padEnd(15) + String(row.score).padEnd(7) + url + '\n');
}

const normal = rows.filter((r) => !r.hard);
const usable = normal.filter((r) => r.status === 'stored' || r.status === 'duplicate');
const hardCaught = rows.filter((r) => r.hard && r.status !== 'stored');
process.stdout.write('\n== summary ==\n');
process.stdout.write('usable-rate (non-hard): ' + usable.length + '/' + normal.length +
  ' = ' + Math.round((usable.length / normal.length) * 100) + '%  (feasibility prediction: 60-75%)\n');
process.stdout.write('hard URLs correctly gated: ' + hardCaught.length + '/' + rows.filter((r) => r.hard).length + '\n');
process.stdout.write('results: ' + outFile + '\n');
