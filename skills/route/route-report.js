#!/usr/bin/env node
'use strict';
// route-report — what your Claude Code sessions actually cost, and what they
// would have cost on the naive setup (top model, every call, no cache).
// Reads local transcript JSONL under ~/.claude/projects. No network, no deps.
// Prices: platform.claude.com/docs/en/about-claude/pricing (see PRICING below).

const fs = require('fs');
const path = require('path');
const os = require('os');

const MTOK = 1e6;
const CACHE_READ_X = 0.1; // cache hit = 0.1x base input
const CACHE_W5_X = 1.25;  // 5-minute cache write
const CACHE_W1H_X = 2;    // 1-hour cache write

// Sonnet 5 intro pricing ($2 in / $10 out) auto-expires 2026-09-01, reverting
// to standard Sonnet pricing ($3 in / $15 out).
const SONNET5_STANDARD_FROM = Date.parse('2026-09-01');
const PRICES_AS_OF = '2026-07-04';

// Clock is injectable via ROUTE_REPORT_NOW so date-dependent pricing (e.g.
// sonnet5Row below) can be tested deterministically. Defaults to Date.now().
const NOW_MS = process.env.ROUTE_REPORT_NOW ? Date.parse(process.env.ROUTE_REPORT_NOW) : Date.now();

function sonnet5Row() {
  return NOW_MS >= SONNET5_STANDARD_FROM
    ? { match: /sonnet-5/, label: 'Sonnet 5', in: 3, out: 15 }
    : { match: /sonnet-5/, label: 'Sonnet 5 (intro pricing)', in: 2, out: 10 };
}

// Ordered: first regex match wins. USD per MTok.
const PRICING = [
  { match: /fable-5|mythos-5/, label: 'Fable/Mythos 5', in: 10, out: 50 },
  { match: /opus-4-[5-9]/, label: 'Opus 4.5+', in: 5, out: 25 },
  { match: /opus/, label: 'Opus 4.1 and earlier', in: 15, out: 75 },
  sonnet5Row(),
  { match: /sonnet/, label: 'Sonnet 4.x', in: 3, out: 15 },
  { match: /haiku-3-5|3-5-haiku/, label: 'Haiku 3.5', in: 0.8, out: 4 },
  { match: /haiku/, label: 'Haiku 4.5', in: 1, out: 5 },
];

function parseArgs(argv) {
  const args = { days: null, project: null, baseline: null, json: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--days') { args.days = Number(argv[i += 1]); }
    else if (a === '--project') { args.project = argv[i += 1]; }
    else if (a === '--baseline') { args.baseline = argv[i += 1]; }
    else if (a === '--json') { args.json = true; }
    else if (a === '--help' || a === '-h') { args.help = true; }
    else { throw new Error(`unknown flag: ${a}`); }
  }
  if (args.days !== null && (!Number.isFinite(args.days) || args.days <= 0)) {
    throw new Error('--days must be a positive number');
  }
  return args;
}

function findTranscripts(root, projectFilter, cutoffMs) {
  if (!fs.existsSync(root)) return [];
  const files = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.jsonl')) {
        // A file not modified since the cutoff cannot contain newer entries.
        if (cutoffMs) {
          let stat;
          try { stat = fs.statSync(full); } catch { continue; }
          if (stat.mtimeMs < cutoffMs) continue;
        }
        files.push(full);
      }
    }
  };
  walk(root);
  if (!projectFilter) return files;
  const norm = (s) => s.replace(/[^A-Za-z0-9-]/g, '-');
  const normFilter = norm(projectFilter);
  return files.filter((f) => {
    const rel = path.relative(root, f);
    return rel.includes(projectFilter) || rel.includes(normFilter);
  });
}

// Streaming appends several lines per assistant message; the last line for a
// message.id carries the final usage. Keep last-wins per id.
function collectUsage(files, cutoffMs) {
  const byId = new Map();
  let lineKey = 0;
  for (const file of files) {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch (err) {
      console.error(`route-report: skipped ${file}: ${err.code || err.message}`);
      continue;
    }
    for (const line of text.split('\n')) {
      if (!line.includes('"usage"')) continue;
      let entry;
      try { entry = JSON.parse(line); } catch { continue; }
      const msg = entry && entry.message;
      if (!msg || !msg.usage || typeof msg.model !== 'string' || msg.model.startsWith('<')) continue;
      const ts = entry.timestamp ? Date.parse(entry.timestamp) : NaN;
      if (cutoffMs && !(ts >= cutoffMs)) continue;
      lineKey += 1;
      const key = msg.id || entry.requestId || `line-${file}-${lineKey}`;
      byId.set(key, { model: msg.model, usage: msg.usage });
    }
  }
  return [...byId.values()];
}

function priceFor(model) {
  return PRICING.find((p) => p.match.test(model)) || null;
}

function bucketTokens(records) {
  const buckets = new Map();
  for (const { model, usage } of records) {
    const price = priceFor(model);
    const label = price ? price.label : `${model} (unknown, priced as baseline)`;
    const prev = buckets.get(label) || { price, in: 0, out: 0, read: 0, w5: 0, w1h: 0, calls: 0 };
    const cc = usage.cache_creation || {};
    const w1h = cc.ephemeral_1h_input_tokens || 0;
    const w5 = cc.ephemeral_5m_input_tokens != null
      ? cc.ephemeral_5m_input_tokens
      : Math.max(0, (usage.cache_creation_input_tokens || 0) - w1h);
    buckets.set(label, {
      price,
      in: prev.in + (usage.input_tokens || 0),
      out: prev.out + (usage.output_tokens || 0),
      read: prev.read + (usage.cache_read_input_tokens || 0),
      w5: prev.w5 + w5,
      w1h: prev.w1h + w1h,
      calls: prev.calls + 1,
    });
  }
  return buckets;
}

function costUSD(t, price, withCache) {
  const inputish = withCache
    ? t.in + t.read * CACHE_READ_X + t.w5 * CACHE_W5_X + t.w1h * CACHE_W1H_X
    : t.in + t.read + t.w5 + t.w1h; // no cache: every token at full input price
  return (inputish * price.in + t.out * price.out) / MTOK;
}

function pickBaseline(buckets, requested) {
  if (requested) {
    const p = PRICING.find((x) => x.match.test(requested) || x.label.toLowerCase().includes(requested.toLowerCase()));
    if (!p) throw new Error(`--baseline "${requested}" matches no known model tier`);
    return p;
  }
  const present = [...buckets.values()].map((b) => b.price).filter(Boolean);
  if (present.length === 0) return PRICING[0];
  return present.reduce((top, p) => (p.in > top.in ? p : top));
}

function report(buckets, baselinePrice) {
  const rows = [...buckets.entries()].map(([label, t]) => ({
    label,
    tokens: t.in + t.out + t.read + t.w5 + t.w1h,
    calls: t.calls,
    cost: costUSD(t, t.price || baselinePrice, true),
    raw: t,
  }));
  const total = (mapper) => rows.reduce((sum, r) => sum + mapper(r.raw), 0);
  const actual = rows.reduce((sum, r) => sum + r.cost, 0);
  const all = {
    in: total((t) => t.in), out: total((t) => t.out),
    read: total((t) => t.read), w5: total((t) => t.w5), w1h: total((t) => t.w1h),
  };
  const naive = costUSD(all, baselinePrice, false);        // top model, no cache
  const topCached = costUSD(all, baselinePrice, true);     // top model, with cache
  const mixNoCache = rows.reduce((sum, r) => sum + costUSD(r.raw, r.raw.price || baselinePrice, false), 0);
  const pct = (base) => (base > 0 ? ((base - actual) / base) * 100 : 0);
  return { rows, actual, baselines: { naive, topCached, mixNoCache }, savingsPct: { vsNaive: pct(naive), vsTopCached: pct(topCached), vsMixNoCache: pct(mixNoCache) } };
}

function fmtUSD(n) { return `$${n.toFixed(2)}`; }
function fmtPct(n) { return `${n.toFixed(1)}%`; }

function printHuman(r, baselinePrice, opts) {
  const scope = [opts.project && `project~${opts.project}`, opts.days && `last ${opts.days}d`].filter(Boolean).join(', ') || 'all local transcripts';
  console.log(`route-report (${scope})\n`);
  const width = Math.max(...r.rows.map((x) => x.label.length), 8);
  for (const row of r.rows.sort((a, b) => b.cost - a.cost)) {
    console.log(`  ${row.label.padEnd(width)}  ${String(row.calls).padStart(6)} calls  ${(row.tokens / MTOK).toFixed(2).padStart(8)} MTok  ${fmtUSD(row.cost).padStart(9)}`);
  }
  console.log(`\n  actual cost                     ${fmtUSD(r.actual)}`);
  console.log(`\n  vs "${baselinePrice.label}" on every call:`);
  console.log(`  naive baseline (no cache)       ${fmtUSD(r.baselines.naive)}   you saved ${fmtPct(r.savingsPct.vsNaive)}`);
  console.log(`  same top model, with cache      ${fmtUSD(r.baselines.topCached)}   routing alone saved ${fmtPct(r.savingsPct.vsTopCached)}`);
  console.log(`  your mix, cache off             ${fmtUSD(r.baselines.mixNoCache)}   caching alone saved ${fmtPct(r.savingsPct.vsMixNoCache)}`);
  console.log('\n  The headline number is the naive baseline. The other two keep it honest.');
  console.log(`  (token prices as of ${PRICES_AS_OF}; Sonnet 5 intro pricing auto-expires 2026-09-01)`);
  console.log('  Not counted: server tool fees (e.g. web search billed per request).');
  console.log('  Fable-class tokenizers emit ~30% more tokens for the same text, so the naive baseline is understated; savings shown are conservative.');
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log('usage: route-report [--days N] [--project substr] [--baseline model] [--json]');
    return 0;
  }
  const root = path.join(os.homedir(), '.claude', 'projects');
  const cutoff = args.days ? NOW_MS - args.days * 86400e3 : null;
  const files = findTranscripts(root, args.project, cutoff);
  const records = collectUsage(files, cutoff);
  if (records.length === 0) {
    if (args.json) {
      console.log(JSON.stringify({
        scope: { days: args.days, project: args.project },
        baseline: null,
        pricesAsOf: PRICES_AS_OF,
        perModel: [],
        actualUSD: 0,
        baselinesUSD: { naiveNoCache: 0, topModelWithCache: 0, yourMixNoCache: 0 },
        savingsPct: { vsNaive: 0, routingAlone: 0, cachingAlone: 0 },
      }, null, 2));
    } else {
      console.error('route-report: no transcript usage found under ~/.claude/projects for that scope.');
    }
    return 0;
  }
  const buckets = bucketTokens(records);
  const baselinePrice = pickBaseline(buckets, args.baseline);
  const r = report(buckets, baselinePrice);
  if (args.json) {
    console.log(JSON.stringify({
      scope: { days: args.days, project: args.project },
      baseline: baselinePrice.label,
      pricesAsOf: PRICES_AS_OF,
      perModel: r.rows.map(({ label, calls, tokens, cost }) => ({ label, calls, tokens, costUSD: Number(cost.toFixed(4)) })),
      actualUSD: Number(r.actual.toFixed(4)),
      baselinesUSD: {
        naiveNoCache: Number(r.baselines.naive.toFixed(4)),
        topModelWithCache: Number(r.baselines.topCached.toFixed(4)),
        yourMixNoCache: Number(r.baselines.mixNoCache.toFixed(4)),
      },
      savingsPct: {
        vsNaive: Number(r.savingsPct.vsNaive.toFixed(2)),
        routingAlone: Number(r.savingsPct.vsTopCached.toFixed(2)),
        cachingAlone: Number(r.savingsPct.vsMixNoCache.toFixed(2)),
      },
    }, null, 2));
  } else {
    printHuman(r, baselinePrice, args);
  }
  return 0;
}

try { process.exitCode = main(); } catch (err) {
  console.error(`route-report: ${err.message}`);
  process.exitCode = 1;
}
