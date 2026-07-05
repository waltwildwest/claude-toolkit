#!/usr/bin/env node
'use strict';
// route-learn — turn the reviews route already does into tuning it proposes.
//
// When the expensive model reviews delegated work, it also judges whether the
// task went to the right tier (right / too_low / too_high). Those verdicts are
// logged here. `review` recognizes a RECURRING pattern (a task-class judged wrong
// several times, Hermes-style "remember a preference", not a statistical rate) and
// drafts a routing rule. By default it only PROPOSES; you review and `apply`.
// Set ROUTE_LEARN=auto to apply automatically (with backup + changelog), or
// ROUTE_LEARN=off to disable review/apply entirely.
//
// It never edits code or SKILL.md — only a user-owned data file the routing
// scripts consult: ~/.claude/route-learn/route-rules.json. Backed up on every
// change, every change recorded in changelog.jsonl, revert with `revert`.
//
//   route-learn log --matched <task-class> --tier <t> --verdict <right|too_low|too_high> [--task <slug>]
//   route-learn review [--json]      # find patterns; propose (or apply if ROUTE_LEARN=auto)
//   route-learn apply <id|--all>     # apply a pending proposal (propose mode)
//   route-learn rules [--json]       # show the learned routing rules in effect
//   route-learn revert                # pop the newest backup, restoring the prior rules
//   route-learn status               # mode, counts, pending proposals
//   route-learn nudge                # one-line summary for the Stop hook (silent if nothing new)
//
// Local only, no network, no deps.

const fs = require('fs');
const path = require('path');
const os = require('os');

const DIR = path.join(process.env.HOME || os.homedir(), '.claude', 'route-learn');
const DECISIONS = path.join(DIR, 'decisions.jsonl');
const RULES = path.join(DIR, 'route-rules.json');
const PROPOSALS = path.join(DIR, 'proposals.json');
const CHANGELOG = path.join(DIR, 'changelog.jsonl');
const BACKUPS = path.join(DIR, 'backups');
const STATE = path.join(DIR, 'state.json'); // { reviewedCount }

const LADDER = ['haiku', 'sonnet', 'opus', 'top']; // cheap -> expensive; "top" = your session model
const PATTERN_MIN = Number(process.env.ROUTE_LEARN_MIN || 3); // "seen enough times" — a memory, not a rate
const VERDICTS = ['right', 'too_low', 'too_high'];
// matched is attacker-influenced (it flows from --matched into decisions.jsonl, and in
// ROUTE_LEARN=auto it can be materialized into route-rules.json unattended). Treat it as
// untrusted at every boundary: a plain task-class token, no control chars/quotes/tags/$/backticks.
const MATCHED_RE = /^[A-Za-z0-9][A-Za-z0-9 _.\/-]{2,79}$/;
function validMatched(s) { return typeof s === 'string' && MATCHED_RE.test(s); }

function mode() {
  const m = (process.env.ROUTE_LEARN || 'propose').toLowerCase();
  return ['propose', 'auto', 'off'].includes(m) ? m : 'propose';
}

function ensureDir() { fs.mkdirSync(DIR, { recursive: true }); }
function readJson(file, dflt) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return dflt; } }
function writeJsonAtomic(file, obj) {
  ensureDir();
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2));
  fs.renameSync(tmp, file);
}
function nowIso() {
  // No Date.now() in some sandboxes; new Date() is fine here at CLI runtime.
  return new Date().toISOString();
}

function parseFlags(argv, spec) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a.startsWith('--') && a.includes('=')) {
      const eq = a.indexOf('='); const name = a.slice(2, eq);
      if (!spec.includes(`--${name}`)) throw new Error(`unknown flag: --${name}`);
      out[name] = a.slice(eq + 1);
    } else if (spec.includes(a)) {
      const name = a.slice(2); const val = argv[i += 1];
      if (val === undefined || (typeof val === 'string' && val.startsWith('--'))) throw new Error(`missing value for ${a}`);
      out[name] = val;
    } else if (a.startsWith('--')) {
      out[a.slice(2)] = true; // boolean flag
    } else out._.push(a);
  }
  return out;
}

function readDecisions() {
  let text;
  try { text = fs.readFileSync(DECISIONS, 'utf8'); } catch { return []; }
  const rows = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try { rows.push(JSON.parse(line)); } catch { /* skip malformed */ }
  }
  return rows;
}

function tierIndex(t) { return LADDER.indexOf(t); }
function up(t) { const i = tierIndex(t); return i >= 0 && i < LADDER.length - 1 ? LADDER[i + 1] : null; }
function down(t) { const i = tierIndex(t); return i > 0 ? LADDER[i - 1] : null; }

// --- pattern recognition: group decisions by (matched, tier), find recurring mis-sizing ---
function findPatterns(decisions, rules) {
  const groups = new Map(); // key: matched\0tier -> {matched,tier,right,too_low,too_high,samples[]}
  for (const d of decisions) {
    // Defense in depth: cmdLog already rejects bad --matched, but decisions.jsonl can be
    // edited directly (or predate validation), so re-validate before it can shape a rule.
    if (!validMatched(d.matched) || !LADDER.includes(d.tier) || !VERDICTS.includes(d.verdict)) continue;
    const key = `${d.matched}\0${d.tier}`;
    const g = groups.get(key) || { matched: d.matched, tier: d.tier, right: 0, too_low: 0, too_high: 0, samples: [] };
    g[d.verdict] += 1;
    if (g.samples.length < 5) g.samples.push(d.task || d.matched);
    groups.set(key, g);
  }
  const existing = rules || currentRules();
  const inEffect = (matched, tier) => existing.rules.some((r) => r.match === matched && r.tier === tier);
  const proposals = [];
  for (const g of groups.values()) {
    // "too_low N times and never right" => under-sized: propose moving up a tier.
    if (g.too_low >= PATTERN_MIN && g.right === 0) {
      const target = up(g.tier);
      if (target && !inEffect(g.matched, target)) proposals.push(mkProposal(g, target, 'too_low'));
    } else if (g.too_high >= PATTERN_MIN && g.right === 0) {
      const target = down(g.tier);
      if (target && !inEffect(g.matched, target)) proposals.push(mkProposal(g, target, 'too_high'));
    }
  }
  return proposals;
}

function mkProposal(g, target, kind) {
  const id = `${g.matched}->${target}`.replace(/[^a-zA-Z0-9_.>-]/g, '_');
  return {
    id,
    matched: g.matched,
    fromTier: g.tier,
    toTier: target,
    kind,
    evidence: { right: g.right, too_low: g.too_low, too_high: g.too_high, samples: g.samples },
    reason: `"${g.matched}" routed to ${g.tier} was judged ${kind} ${g[kind]}x (right ${g.right}x). Propose routing it to ${target}.`,
  };
}

function currentRules() {
  const r = readJson(RULES, { version: 1, rules: [] });
  if (!Array.isArray(r.rules)) return { version: 1, rules: [] };
  return r;
}

function applyProposalToRules(rules, p) {
  const next = { version: 1, rules: rules.rules.filter((r) => r.match !== p.matched) };
  next.rules.push({ match: p.matched, tier: p.toTier, reason: p.reason, source: 'route-learn', added: nowIso() });
  return next;
}

function deepEqual(a, b) { return JSON.stringify(a) === JSON.stringify(b); }

// backups/ is an UNDO STACK: each entry is a snapshot of the rules as they were
// immediately BEFORE a change (the push). commitRules writes one on every real change,
// including the very first, so applying still reverts back to "no rules". Filenames are
// zero-padded sequence numbers (monotonic, collision-free even within the same ms) so
// "newest" is simply the lexicographically-last file — that's what revert pops.
function nextBackupSeq() {
  const existing = fs.existsSync(BACKUPS) ? fs.readdirSync(BACKUPS).filter((n) => n.endsWith('.json')) : [];
  let max = -1;
  for (const n of existing) {
    const m = /^(\d+)\.json$/.exec(n);
    if (m) max = Math.max(max, Number(m[1]));
  }
  return max + 1;
}

function backupRules() {
  fs.mkdirSync(BACKUPS, { recursive: true });
  const seq = String(nextBackupSeq()).padStart(10, '0');
  const dest = path.join(BACKUPS, `${seq}.json`);
  writeJsonAtomic(dest, currentRules());
  return dest;
}

function logChange(entry) {
  ensureDir();
  fs.appendFileSync(CHANGELOG, JSON.stringify({ at: nowIso(), ...entry }) + '\n');
}

// No-op (no backup, no changelog, no write) when `next` is identical to what's already in
// effect — otherwise re-review of an already-applied pattern would push a redundant undo
// frame every time, spamming backups/changelog and compounding into the revert bug (#2).
function commitRules(next, applied, how) {
  if (deepEqual(next, currentRules())) return null;
  const backup = backupRules();
  writeJsonAtomic(RULES, next);
  for (const p of applied) logChange({ how, id: p.id, match: p.matched, toTier: p.toTier, evidence: p.evidence, backup });
  return backup;
}

// --- commands ---
function cmdLog(argv) {
  const f = parseFlags(argv, ['--matched', '--tier', '--verdict', '--task']);
  if (!f.matched) throw new Error('log requires --matched <task-class>');
  // matched ends up in decisions.jsonl and (in ROUTE_LEARN=auto) can be materialized
  // unattended into route-rules.json — reject anything that isn't a plain task-class token.
  if (!validMatched(f.matched)) throw new Error('--matched must be a plain task-class token (3-80 chars, letters/digits/space/_.-/, no control chars, quotes, tags, $, or backticks)');
  if (!LADDER.includes(f.tier)) throw new Error(`--tier must be one of ${LADDER.join('|')}`);
  if (!VERDICTS.includes(f.verdict)) throw new Error(`--verdict must be one of ${VERDICTS.join('|')}`);
  ensureDir();
  fs.appendFileSync(DECISIONS, JSON.stringify({ at: nowIso(), matched: f.matched, tier: f.tier, verdict: f.verdict, task: f.task || null }) + '\n');
  console.error(`route-learn: logged ${f.matched} @ ${f.tier} = ${f.verdict}`);
  return 0;
}

function cmdReview(argv) {
  const f = parseFlags(argv, []);
  if (mode() === 'off') { console.error('route-learn: ROUTE_LEARN=off, review disabled'); return 0; }
  const proposals = findPatterns(readDecisions());
  // mark decisions as reviewed (for the nudge)
  writeJsonAtomic(STATE, { reviewedCount: readDecisions().length, at: nowIso() });

  if (mode() === 'auto') {
    if (proposals.length) {
      let rules = currentRules();
      for (const p of proposals) rules = applyProposalToRules(rules, p);
      commitRules(rules, proposals, 'auto');
    }
    const out = { mode: 'auto', applied: proposals.map((p) => p.id), proposals };
    if (f.json) console.log(JSON.stringify(out, null, 2));
    else console.log(proposals.length ? `route-learn (auto): applied ${proposals.length} rule change(s):\n` + proposals.map((p) => '  ' + p.reason).join('\n') : 'route-learn (auto): no new patterns');
    return 0;
  }
  // propose mode
  writeJsonAtomic(PROPOSALS, { at: nowIso(), proposals });
  if (f.json) { console.log(JSON.stringify({ mode: 'propose', proposals }, null, 2)); return 0; }
  if (!proposals.length) { console.log('route-learn: no new patterns worth a rule change yet'); return 0; }
  console.log(`route-learn found ${proposals.length} pattern(s). Review, then apply what you agree with:\n`);
  for (const p of proposals) console.log(`  [${p.id}]\n    ${p.reason}\n    evidence: right=${p.evidence.right} too_low=${p.evidence.too_low} too_high=${p.evidence.too_high}\n    apply: route-learn apply ${p.id}\n`);
  console.log('Apply all with: route-learn apply --all   (or set ROUTE_LEARN=auto to skip this step)');
  return 0;
}

function cmdApply(argv) {
  const f = parseFlags(argv, []);
  if (mode() === 'off') throw new Error('ROUTE_LEARN=off, apply disabled');
  const pending = readJson(PROPOSALS, { proposals: [] }).proposals || [];
  if (!pending.length) { console.log('route-learn: no pending proposals — run review first'); return 0; }
  const wantAll = f._.includes('--all') || f.all;
  const chosen = wantAll ? pending : pending.filter((p) => f._.includes(p.id));
  if (!chosen.length) { console.error('route-learn: no matching proposal id (use --all or a printed id)'); return 1; }
  let rules = currentRules();
  for (const p of chosen) rules = applyProposalToRules(rules, p);
  commitRules(rules, chosen, 'manual');
  const remaining = pending.filter((p) => !chosen.includes(p));
  writeJsonAtomic(PROPOSALS, { at: nowIso(), proposals: remaining });
  console.log(`route-learn: applied ${chosen.length} rule(s). ${remaining.length} proposal(s) left. Revert with: route-learn revert`);
  return 0;
}

function cmdRules(argv) {
  const f = parseFlags(argv, []);
  const r = currentRules();
  if (f.json) { console.log(JSON.stringify(r, null, 2)); return 0; }
  if (!r.rules.length) { console.log('route-learn: no learned rules yet (routing uses the built-in ladder)'); return 0; }
  console.log('learned routing rules in effect:');
  for (const rule of r.rules) console.log(`  "${rule.match}" -> ${rule.tier}   (${rule.reason || 'manual'})`);
  return 0;
}

// Proper UNDO STACK: restore the newest backup, then POP it (delete it) so the next
// revert walks back to the one before it. Does NOT push a new backup of the state being
// discarded — that self-backup is what made the old revert oscillate between two states
// instead of walking back through history.
// Backups sorted oldest -> newest, keyed strictly by their numeric sequence, so
// a stray non-conforming file in backups/ can never misdirect "newest".
function listBackupsSorted() {
  if (!fs.existsSync(BACKUPS)) return [];
  return fs.readdirSync(BACKUPS)
    .map((n) => { const m = /^(\d+)\.json$/.exec(n); return m ? { name: n, seq: Number(m[1]) } : null; })
    .filter(Boolean)
    .sort((a, b) => a.seq - b.seq);
}

function cmdRevert() {
  const candidates = listBackupsSorted();
  if (!candidates.length) { console.log('route-learn: nothing to revert'); return 0; }
  // Pop the newest backup, but CLAIM it first with an atomic rename so two concurrent
  // reverts can't both grab the same one: exactly one rename wins; the loser gets ENOENT,
  // drops that candidate, and claims the next-newest. No race, no crash, no under-pop.
  for (let i = candidates.length - 1; i >= 0; i -= 1) {
    const chosen = candidates[i];
    const src = path.join(BACKUPS, chosen.name);
    const claim = path.join(BACKUPS, `.claim-${process.pid}-${chosen.seq}.tmp`);
    try {
      fs.renameSync(src, claim);
    } catch (err) {
      if (err.code === 'ENOENT') continue; // another revert took this one; try the next
      throw err;
    }
    try {
      fs.copyFileSync(claim, RULES);
    } catch (err) {
      try { fs.renameSync(claim, src); } catch { /* leave the claim; sequence unaffected */ }
      throw err;
    }
    try { fs.unlinkSync(claim); } catch { /* best effort */ }
    logChange({ how: 'revert', restoredFrom: chosen.name });
    console.log(`route-learn: reverted route-rules.json from ${chosen.name}`);
    return 0;
  }
  console.log('route-learn: nothing to revert');
  return 0;
}

function cmdStatus() {
  const decisions = readDecisions();
  const rules = currentRules();
  const pending = readJson(PROPOSALS, { proposals: [] }).proposals || [];
  console.log(`route-learn status`);
  console.log(`  mode:            ${mode()} (ROUTE_LEARN)`);
  console.log(`  decisions logged: ${decisions.length}`);
  console.log(`  learned rules:    ${rules.rules.length}`);
  console.log(`  pending proposals:${pending.length}`);
  console.log(`  pattern threshold:${PATTERN_MIN} sightings`);
  return 0;
}

// Quiet unless there are new decisions since the last review; for the Stop hook.
// The Stop event does not inject hookSpecificOutput.additionalContext, so the reminder
// has to go to stderr instead (the pattern that actually surfaces for Stop hooks).
// Also quiet after it has already nudged once for the current batch: it records the
// decision count it nudged at (state.nudgedAt) and stays silent until either a `review`
// runs (which bumps reviewedCount) or PATTERN_MIN more decisions land past nudgedAt too,
// so it doesn't re-fire every single turn while the user is ignoring it.
function cmdNudge() {
  if (mode() === 'off') return 0;
  const total = readDecisions().length;
  const state = readJson(STATE, { reviewedCount: 0 });
  const seen = state.reviewedCount || 0;
  const fresh = total - seen;
  if (fresh < PATTERN_MIN) return 0; // nothing worth surfacing

  const nudgedAt = state.nudgedAt || 0;
  const sinceNudge = total - nudgedAt;
  if (nudgedAt > seen && sinceNudge < PATTERN_MIN) return 0; // already nudged for this batch

  writeJsonAtomic(STATE, { ...state, nudgedAt: total, at: nowIso() });
  process.stderr.write(`[route-learn] ${fresh} new routing verdicts logged since the last review. Run \`route-learn review\` to see any proposed tuning${mode() === 'auto' ? ' (auto-apply is on)' : ' (you approve each change)'}.\n`);
  return 0;
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const cmds = { log: cmdLog, review: cmdReview, apply: cmdApply, rules: cmdRules, revert: cmdRevert, status: cmdStatus, nudge: cmdNudge };
  if (!cmd || cmd === '--help' || cmd === '-h' || !cmds[cmd]) {
    console.log('usage: route-learn log|review|apply|rules|revert|status|nudge  (see file header)');
    return cmd && cmd !== '--help' && cmd !== '-h' ? 1 : 0;
  }
  return cmds[cmd](rest);
}

try { process.exitCode = main(); } catch (err) {
  console.error(`route-learn: ${err.message}`);
  process.exitCode = 1;
}
