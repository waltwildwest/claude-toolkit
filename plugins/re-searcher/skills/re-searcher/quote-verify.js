#!/usr/bin/env node
'use strict';
// quote-verify — the deterministic half of "verbatim-grounded".
// Checks that a claim's quote actually appears in a cached source extraction.
// Match ladder: exact substring -> normalized substring (NFKC, straight
// quotes, dashes, collapsed whitespace) -> markdown-stripped + normalized
// substring -> fuzzy word-window relocation (all tiers operating in
// stripped+normalized space).
// Fuzzy tier: anchors a bounded window, then requires order-sensitive word
// coverage (LCS >= 0.8 of quote words) plus matching negation-word counts
// between quote and window — order/polarity-blind word-set coverage is
// rejected. On any verified match at the stripped tier or fuzzy tier,
// sourceQuote is widened to never clip mid-link. Residual risk:
// a meaning-preserving, high-overlap paraphrase could still pass; this is
// a documented tradeoff (Task 7 manually inspects every fuzzy match).
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

// Markdown-stripped view (Stage 0 amendment: markup mismatch was the entire
// observed claim-demotion class): [label](url) -> label, ** and backticks
// removed — with an index map back to the original bytes so any match still
// slices exact source truth.
function buildStripped(s) {
  const chars = [], map = [];
  let i = 0;
  while (i < s.length) {
    if (s[i] === '[') {
      const close = s.indexOf(']', i);
      if (close !== -1 && close - i <= 300 && s[close + 1] === '(') {
        const paren = s.indexOf(')', close + 2);
        if (paren !== -1 && paren - close <= 600) {
          for (let j = i + 1; j < close; j++) { chars.push(s[j]); map.push(j); }
          i = paren + 1;
          continue;
        }
      }
    }
    if (s[i] === '*' && s[i + 1] === '*') { i += 2; continue; }
    if (s[i] === '`') { i += 1; continue; }
    chars.push(s[i]); map.push(i);
    i++;
  }
  return { text: chars.join(''), map };
}

// Normalized view of the stripped text, with maps composed so a normalized
// index still resolves to an ORIGINAL source index.
function buildStrippedNormalized(s) {
  const st = buildStripped(s);
  const nz = buildNormalized(st.text);
  return { text: nz.text, map: nz.map.map((i) => st.map[i]) };
}

// Never clip a sourceQuote mid-link: if the byte span [a,b] cuts into a
// [label](url) construct, widen to include the whole link.
function wholeLinks(src, a, b) {
  const linkRe = /\[[^\]\n]{0,300}\]\([^()\s]{0,600}\)/g;
  let m;
  while ((m = linkRe.exec(src)) !== null) {
    const s0 = m.index, e0 = m.index + m[0].length - 1;
    if (s0 > b) break;
    if (e0 < a) continue;
    if (s0 < a) a = s0;
    if (e0 > b) b = e0;
  }
  return [a, b];
}

function verify(quote, source) {
  const q = String(quote), src = String(source);
  if (q.trim().length === 0) return { verified: false, method: 'none', sourceQuote: null };
  if (src.includes(q)) return { verified: true, method: 'exact', sourceQuote: q };

  const nq = buildNormalized(q), ns = buildNormalized(src);
  let idx = ns.text.indexOf(nq.text);
  if (idx !== -1) {
    return { verified: true, method: 'normalized',
      sourceQuote: sliceOriginal(src, ns.map, idx, idx + nq.text.length - 1) };
  }

  // markdown-stripped tier
  const sq = buildStrippedNormalized(q), ss = buildStrippedNormalized(src);
  if (sq.text.length > 0) {
    idx = ss.text.indexOf(sq.text);
    if (idx !== -1) {
      const [a, b] = wholeLinks(src, ss.map[idx], ss.map[idx + sq.text.length - 1]);
      return { verified: true, method: 'normalized', sourceQuote: src.slice(a, b + 1) };
    }
  }

  return fuzzyMatch(sq, ss, src);
}

// Fuzzy tier, operating in the stripped+normalized space. Body is the Stage 0
// fuzzy logic verbatim (n-gram anchoring, window shrink, LCS >= 0.8, negation
// parity, 2x window cap) — do NOT weaken any guard. Only the final slice is
// new: it goes through wholeLinks so windows never clip mid-link.
function fuzzyMatch(nq, ns, src) {
  const qWords = nq.text.toLowerCase().split(' ').filter(Boolean);
  if (qWords.length < 6) return { verified: false, method: 'none', sourceQuote: null };
  const N = Math.min(5, qWords.length);
  const firstGram = qWords.slice(0, N).join(' ');
  const lastGram = qWords.slice(-N).join(' ');
  const lowerNs = ns.text.toLowerCase();
  let start = lowerNs.indexOf(firstGram);
  let endAnchor = lowerNs.lastIndexOf(lastGram);
  if (start === -1 && endAnchor === -1) {
    for (let i = 1; i + N <= qWords.length - 1 && start === -1; i++) {
      start = lowerNs.indexOf(qWords.slice(i, i + N).join(' '));
    }
    if (start === -1) return { verified: false, method: 'none', sourceQuote: null };
  }
  if (start === -1) start = Math.max(0, endAnchor - nq.text.length * 2);
  let end = endAnchor !== -1 && endAnchor >= start
    ? endAnchor + lastGram.length - 1
    : Math.min(ns.text.length - 1, start + Math.floor(nq.text.length * 1.5));

  const stripPunct = (w) => w.replace(/^[^a-z0-9]+|[^a-z0-9]+$/g, '');
  const qWordsClean = qWords.map(stripPunct);
  const qWordSet = new Set(qWordsClean);
  const rawWindowWords = lowerNs.slice(start, end + 1).split(' ').filter(Boolean);
  let firstHit = -1, lastHit = -1;
  { let pos = start;
    for (const w of rawWindowWords) {
      if (qWordSet.has(stripPunct(w))) { if (firstHit === -1) firstHit = pos; lastHit = pos + w.length - 1; }
      pos += w.length + 1;
    } }
  if (firstHit === -1) return { verified: false, method: 'none', sourceQuote: null };
  start = firstHit; end = lastHit;

  if (end - start + 1 > nq.text.length * 2) return { verified: false, method: 'none', sourceQuote: null };

  const windowWordsClean = lowerNs.slice(start, end + 1).split(' ').filter(Boolean).map(stripPunct);
  if (windowWordsClean.length > qWords.length * 3) return { verified: false, method: 'none', sourceQuote: null };

  const lcsLen = lcsLength(qWordsClean, windowWordsClean);
  if (lcsLen / qWordsClean.length < 0.8) return { verified: false, method: 'none', sourceQuote: null };

  const negRe = /\b(not|never|no|none|cannot|can't|won't|don't|doesn't|didn't|isn't|aren't|wasn't|weren't|without)\b/gi;
  const qNegCount = (nq.text.match(negRe) || []).length;
  const windowText = lowerNs.slice(start, end + 1);
  const wNegCount = (windowText.match(negRe) || []).length;
  if (qNegCount !== wNegCount) return { verified: false, method: 'none', sourceQuote: null };

  const [a, b] = wholeLinks(src, ns.map[start], ns.map[end]);
  return { verified: true, method: 'fuzzy', sourceQuote: src.slice(a, b + 1) };
}

// Longest common subsequence length between two word arrays (order-sensitive).
function lcsLength(a, b) {
  const dp = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      dp[i][j] = a[i - 1] === b[j - 1] ? dp[i - 1][j - 1] + 1 : Math.max(dp[i - 1][j], dp[i][j - 1]);
    }
  }
  return dp[a.length][b.length];
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
