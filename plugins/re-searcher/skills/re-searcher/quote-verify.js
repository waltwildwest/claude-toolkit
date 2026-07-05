#!/usr/bin/env node
'use strict';
// quote-verify — the deterministic half of "verbatim-grounded".
// Checks that a claim's quote actually appears in a cached source extraction.
// Match ladder: exact substring -> normalized substring (NFKC, straight
// quotes, dashes, collapsed whitespace) -> fuzzy word-window relocation.
// On any verified match the returned sourceQuote is EXACT SOURCE BYTES —
// the source is ground truth, not the model's transcription of it.
//
//   node quote-verify.js --quote-file <q.txt> --source-file <s.md>
//   exit 0 verified / 1 not verified / 2 usage or IO error
//
// Module API: normalize(s), verify(quote, source)

const fs = require('fs');

function normChar(c) {
  if (c === '‘' || c === '’' || c === '‛') return "'";
  if (c === '“' || c === '”') return '"';
  if (c === '–' || c === '—') return '-';
  return c.normalize('NFKC');
}

// Normalize while keeping a map from normalized index -> original index,
// so a normalized-space match can be sliced back out of the original bytes.
function buildNormalized(s) {
  const chars = [];
  const map = [];
  let pendingSpace = false;
  for (let i = 0; i < s.length; i++) {
    const n = normChar(s[i]);
    if (/\s/.test(n)) { pendingSpace = chars.length > 0; continue; }
    if (pendingSpace) { chars.push(' '); map.push(i); pendingSpace = false; }
    for (const ch of n) { chars.push(ch); map.push(i); }
  }
  return { text: chars.join(''), map };
}

function normalize(s) { return buildNormalized(String(s)).text; }

function sliceOriginal(source, map, start, endIncl) {
  return source.slice(map[start], map[endIncl] + 1);
}

function verify(quote, source) {
  const q = String(quote), src = String(source);
  if (q.trim().length === 0) return { verified: false, method: 'none', sourceQuote: null };
  if (src.includes(q)) return { verified: true, method: 'exact', sourceQuote: q };

  const nq = buildNormalized(q), ns = buildNormalized(src);
  const idx = ns.text.indexOf(nq.text);
  if (idx !== -1) {
    return { verified: true, method: 'normalized',
      sourceQuote: sliceOriginal(src, ns.map, idx, idx + nq.text.length - 1) };
  }

  // Fuzzy: anchor on quote word n-grams found in the source word stream,
  // require >=70% of quote words inside the located window.
  const qWords = nq.text.toLowerCase().split(' ').filter(Boolean);
  const sWords = ns.text.toLowerCase().split(' ');
  if (qWords.length < 6) return { verified: false, method: 'none', sourceQuote: null };
  // word start offsets in normalized source
  const offsets = [];
  { let pos = 0;
    for (const w of sWords) { offsets.push(pos); pos += w.length + 1; } }
  const N = Math.min(5, qWords.length);
  const firstGram = qWords.slice(0, N).join(' ');
  const lastGram = qWords.slice(-N).join(' ');
  const lowerNs = ns.text.toLowerCase();
  let start = lowerNs.indexOf(firstGram);
  let endAnchor = lowerNs.lastIndexOf(lastGram);
  if (start === -1 && endAnchor === -1) {
    // last resort: any interior 5-gram
    for (let i = 1; i + N <= qWords.length - 1 && start === -1; i++) {
      start = lowerNs.indexOf(qWords.slice(i, i + N).join(' '));
    }
    if (start === -1) return { verified: false, method: 'none', sourceQuote: null };
  }
  if (start === -1) start = Math.max(0, endAnchor - nq.text.length * 2);
  let end = endAnchor !== -1 && endAnchor >= start
    ? endAnchor + lastGram.length - 1
    : Math.min(ns.text.length - 1, start + Math.floor(nq.text.length * 1.5));
  const windowWords = new Set(lowerNs.slice(start, end + 1).split(' ').filter(Boolean));
  const covered = qWords.filter((w) => windowWords.has(w)).length / qWords.length;
  if (covered < 0.7) return { verified: false, method: 'none', sourceQuote: null };
  return { verified: true, method: 'fuzzy', sourceQuote: sliceOriginal(src, ns.map, start, end) };
}

function arg(name) {
  const i = process.argv.indexOf(name);
  return i !== -1 ? process.argv[i + 1] : null;
}

function main() {
  const qf = arg('--quote-file'), sf = arg('--source-file');
  if (!qf || !sf) { process.stderr.write('usage: quote-verify.js --quote-file <q> --source-file <s>\n'); process.exit(2); }
  let q, s;
  try { q = fs.readFileSync(qf, 'utf8'); s = fs.readFileSync(sf, 'utf8'); }
  catch (err) { process.stderr.write('cannot read input: ' + (err.code || err.message) + '\n'); process.exit(2); }
  const res = verify(q, s);
  process.stdout.write(JSON.stringify(res) + '\n');
  process.exit(res.verified ? 0 : 1);
}

if (require.main === module) main();
module.exports = { normalize, verify };
