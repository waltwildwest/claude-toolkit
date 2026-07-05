#!/usr/bin/env node
'use strict';
// vault-export — one shareable markdown file per topic: latest synthesis +
// live claims (folded: retracted/superseded never export) + cited sources as
// extraction+link. NEVER raw HTML (licensing posture: exports default to
// extraction+link, not raw copyrighted bytes). Read-only: no lock, no
// commit, no vault mutation — the export lands in the CWD by default.
//
//   node vault-export.js <topic-slug> [--vault <dir>] [--out <file>] [--no-extracts]
//
// stdout: one JSON line {status, file, claims, sources}. exit 0 / 1.

const fs = require('fs');
const path = require('path');
const lib = require('./vault-lib');

function strFlag(name) { const i = process.argv.indexOf(name); return i !== -1 ? process.argv[i + 1] : null; }
function die(msg) { process.stderr.write('vault-export: ' + msg + '\n'); process.exit(1); }

function main() {
  const slug = process.argv[2];
  if (!slug || slug.startsWith('--')) die('usage: vault-export.js <topic-slug> [--vault <dir>] [--out <file>] [--no-extracts]');
  if (!lib.isSafeName(slug)) die('unsafe slug "' + slug + '" — slugs are alnum plus - _ . with no path separators or ".." (traversal refused)');
  const vault = lib.resolveVault(strFlag('--vault'));
  const topicDir = path.join(vault, 'topics', slug);
  if (!fs.existsSync(topicDir)) die('no topic "' + slug + '" in the vault (topics/' + slug + ' missing)');

  const idx = lib.readJsonl(path.join(vault, 'index.jsonl')).records.filter((r) => r && r.slug === slug).pop() || { slug };
  const { claims } = lib.foldClaims(lib.readJsonl(path.join(vault, 'claims.jsonl')).records);
  const live = [];
  for (const c of claims.values()) if (c.topic === slug && c.status === 'active') live.push(c);
  live.sort((a, b) => String(a.date).localeCompare(String(b.date)) || String(a.id).localeCompare(String(b.id)));

  const runsDir = path.join(topicDir, 'runs');
  const runs = fs.existsSync(runsDir) ? fs.readdirSync(runsDir).sort() : [];
  let synthesis = '_No synthesis recorded._';
  let latestRun = null;
  for (let i = runs.length - 1; i >= 0; i--) {
    const p = path.join(runsDir, runs[i], 'synthesis.md');
    if (fs.existsSync(p)) { synthesis = fs.readFileSync(p, 'utf8').trim(); latestRun = runs[i]; break; }
  }

  const withExtracts = !process.argv.includes('--no-extracts');
  const sourceIds = Array.from(new Set(live.map((c) => c.source).filter(Boolean)));
  const L = ['# ' + (idx.title || slug), '',
    '_Exported from a re-searcher vault on ' + lib.today() + ' · topic `' + slug + '`'
      + (latestRun ? ' · latest run ' + latestRun : '') + '._',
    '_Sources are cached extractions + original links — never raw page copies._', '',
    '## Synthesis', '', synthesis, '', '## Claims (' + live.length + ' live)', ''];
  if (!live.length) L.push('_None registered._');
  for (const c of live) {
    L.push('- [' + [c.provenance, c.confidence, c.date].filter(Boolean).join(' · ') + '] ' + c.statement
      + (c.source ? ' — `' + c.source + '`' : ''));
    if (c.contradictedBy.length) L.push('  - ⚠ contradicted by ' + c.contradictedBy.join(', ') + ' (unresolved)');
  }
  L.push('', '## Sources', '');
  if (!sourceIds.length) L.push('_None cited by live claims._');
  let exported = 0;
  for (const id of sourceIds) {
    const p = path.join(vault, 'sources', id + '.md');
    if (!fs.existsSync(p)) { L.push('### ' + id, '', '_Source unavailable (redacted or missing)._', ''); continue; }
    const { fields, body } = lib.parseFrontmatter(fs.readFileSync(p, 'utf8'));
    exported++;
    L.push('### ' + (fields.title || id), '',
      '- original: ' + (fields.final_url || fields.url || '(unknown)'),
      '- fetched: ' + (fields.fetched || '?') + ' · id `' + id + '`');
    if (fields.wayback_url) L.push('- wayback: ' + fields.wayback_url);
    L.push('');
    if (withExtracts) L.push('<details><summary>cached extraction</summary>', '', body.trim(), '', '</details>', '');
  }
  const out = path.resolve(strFlag('--out') || ('research-export-' + slug + '-' + lib.today() + '.md'));
  lib.atomicWrite(out, L.join('\n') + '\n');
  process.stdout.write(JSON.stringify({ status: 'exported', file: out, claims: live.length, sources: exported }) + '\n');
}

main();
