#!/usr/bin/env node
'use strict';
// route-detect — a UserPromptSubmit hook that makes route activation deterministic.
//
// Claude Code fires this on EVERY prompt, before the model sees it. It runs cheap,
// model-free signal detection on the prompt text and, when the request looks like
// something route should handle (a wide/parallel job, mechanical grunt work, or a
// cost question), injects a short advisory nudge via hookSpecificOutput. It never
// blocks and never changes the model — the harness forbids that — it only makes
// sure route gets considered instead of relying on probabilistic description-match.
//
// Most prompts match nothing and produce zero output (silent, no context cost).
//
//   route-detect                 # hook mode: reads the hook JSON payload on stdin
//   route-detect --prompt "..."  # test mode: run detection on a literal string
//   route-detect --prompt "..." --explain   # human: show which signals fired
//
// Disable entirely with ROUTE_DETECT=off (or 0/false). Local only, no network, no deps.

const fs = require('fs');
const path = require('path');
const os = require('os');

const DISABLED = /^(off|0|false|no)$/i.test(process.env.ROUTE_DETECT || '');

// Allow-list of tiers a learned rule may name. Anything else is dropped.
const VALID_TIERS = ['haiku', 'sonnet', 'opus', 'top'];

// A learned rule's `match` field is injected into model context (via the nudge
// sentence below), so it must be a short, plain, single-line token — no control
// characters, no HTML/template-ish syntax, no quoting characters that could help
// break out of the sentence it's embedded in.
const VALID_MATCH_RE = /^[A-Za-z0-9][A-Za-z0-9 _.\/-]{2,79}$/;

// route-rules.json is written by route-learn from your own past reviews, but it's
// still an external file on disk — treat every field as untrusted input. A rule
// that fails validation is dropped entirely: never matched against, never injected.
function validRule(r) {
  if (!r || typeof r !== 'object') return false;
  if (typeof r.tier !== 'string' || !VALID_TIERS.includes(r.tier)) return false;
  if (typeof r.match !== 'string' || !VALID_MATCH_RE.test(r.match)) return false;
  return true;
}

// Learned routing rules that route-learn has proposed and you've applied, if any.
// Absent file = no learned rules = base behavior unchanged.
function learnedRules() {
  try {
    const p = path.join(process.env.HOME || os.homedir(), '.claude', 'route-learn', 'route-rules.json');
    const r = JSON.parse(fs.readFileSync(p, 'utf8'));
    const rules = Array.isArray(r.rules) ? r.rules : [];
    return rules.filter(validRule);
  } catch { return []; }
}

function matchLearned(text) {
  const t = text.toLowerCase();
  return learnedRules().filter((r) => r && typeof r.match === 'string' && t.includes(r.match.toLowerCase()));
}

// Signal groups. Each is a list of regexes; a group "fires" if any matches.
// Ordered by how specific the resulting nudge is: cost > fanout > grunt.
const SIGNALS = {
  cost: [
    /\b(how much|what).{0,24}(cost|spend|spent|bill|paying)\b/i,
    /\b(am i|are we|how much am i)\b.{0,20}\b(saving|spending)\b/i,
    /\btoken (cost|usage|spend|budget)\b/i,
    /\bcost (of|per|breakdown|report)\b/i,
    /\bwhat('?s| is) (this|my setup) costing\b/i,
  ],
  fanout: [
    /\ball (the )?(files|tests|call ?sites|components|endpoints|functions|modules|routes)\b/i,
    /\bacross the (whole )?(codebase|repo|repository|project)\b/i,
    /\bfor (each|every)\b/i,
    /\bevery (file|test|module|function|component|endpoint|route)\b/i,
    /\b(migrate|refactor|rename|convert|update|port|audit|review) (all|every|the whole|each|the entire)\b/i,
    /\bgo through (each|all|every)\b/i,
    /\baudit\b/i,
    /\b\d{2,}\s+(files|tests|call ?sites|endpoints|components|modules)\b/i,
    /(^|\s)\S*\*\.\w+/, // a glob like src/*.ts or *.py
  ],
  grunt: [
    /\bre-?format|prettify|lint\b/i,
    /\b(extract|pull out|enumerate|tabulate)\b/i,
    /\b(summari[sz]e|tl;?dr)\b/i,
    /\b(search (for|the)|grep|find (all|where|every|the)|locate)\b/i,
    /\b(read (through|all|the whole)|scan the)\b/i,
    /\bboilerplate|scaffold\b/i,
  ],
};

const NUDGE = {
  cost: 'The user is asking about cost or spend. The `route` skill answers this directly: run `route-report.js` (in the route skill dir) for actual cost against three honest baselines (naive / top-model-with-cache / mix-without-cache). Quote any number with its baseline.',
  fanout: 'This request looks wide and parallelizable (many files / for-each / audit across the codebase). The `route` skill applies: run `route-plan.js` to get the tier for your current model, then size the work, fan the independent pieces out across cheaper models in parallel, and review the merged result on your model. Fan-out also keeps the bulk reading out of this session context.',
  grunt: 'This request looks mechanical (reformat / extract / search / summarize). The `route` skill applies: run `route-plan.js` for the tier your current model should delegate to, and consider dispatching this to a cheaper model rather than doing it on the top model. Keep the review on your model.',
};

function detect(text) {
  const fired = [];
  for (const group of Object.keys(SIGNALS)) {
    const hit = SIGNALS[group].find((re) => re.test(text));
    if (hit) fired.push(group);
  }
  return fired; // in SIGNALS key order: cost, fanout, grunt
}

function readStdin() {
  try { return fs.readFileSync(0, 'utf8'); } catch { return ''; }
}

function promptFromPayload(raw) {
  if (!raw.trim()) return '';
  try {
    const d = JSON.parse(raw);
    return typeof d.prompt === 'string' ? d.prompt : '';
  } catch {
    return raw; // tolerate a bare prompt string on stdin
  }
}

function parseArgs(argv) {
  const args = { prompt: null, explain: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--prompt') { args.prompt = argv[i += 1]; if (args.prompt == null) throw new Error('--prompt needs a value'); }
    else if (a === '--explain') { args.explain = true; }
    else if (a === '--help' || a === '-h') { args.help = true; }
    else throw new Error(`unknown flag: ${a}`);
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) { console.log('usage: route-detect [--prompt "..."] [--explain]'); return 0; }
  if (DISABLED) return 0; // opt-out: emit nothing

  const text = args.prompt != null ? args.prompt : promptFromPayload(readStdin());
  const fired = detect(text || '');
  const learned = matchLearned(text || '');

  if (args.explain) {
    const parts = [...fired];
    if (learned.length) parts.push('learned:' + learned.map((r) => `${r.match}->${r.tier}`).join(','));
    console.log(parts.length ? `route-detect: ${parts.join(', ')}` : 'route-detect: no signals');
    return 0;
  }
  if (fired.length === 0 && learned.length === 0) return 0; // silent on the vast majority of prompts

  // A learned rule (from YOUR own reviews) is higher-signal than a generic pattern, so lead with it.
  let context;
  if (learned.length) {
    const r = learned[0];
    // Never advise delegating UP to opus/top — route-plan forbids that direction.
    // For haiku/sonnet, name the tier; for opus/top, say to keep it rather than delegate down.
    const tierAdvice = (r.tier === 'opus' || r.tier === 'top')
      ? 'this kind of task tends to need a stronger model, so keep it on your model rather than delegating it down'
      : `routing it to ${r.tier}`;
    // Wrap the (already char-class-validated) match in brackets so it reads as a quoted
    // label, not a directive, even if someone planted natural-language text in it.
    const learnedSentence = `You've logged [${r.match}]-type work as mis-sized before; route-learn suggests ${tierAdvice}.`;
    // Only append the generic signal-group nudge if a built-in signal actually fired —
    // otherwise it's a false assertion (e.g. claiming the request "looks mechanical").
    context = fired.length
      ? `${learnedSentence} ${NUDGE[fired[0]]}`
      : `${learnedSentence} Run route-plan.js to size it.`;
  } else {
    context = NUDGE[fired[0]];
  }

  // Bound the FULL injected string (prefix included) to 600 chars.
  const MAX_CONTEXT_LEN = 600;
  const PREFIX = '[route] ';
  let additionalContext = PREFIX + context;
  if (additionalContext.length > MAX_CONTEXT_LEN) additionalContext = additionalContext.slice(0, MAX_CONTEXT_LEN);

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'UserPromptSubmit',
      additionalContext,
    },
  }));
  return 0;
}

try { process.exitCode = main(); } catch (err) {
  // A hook must never break the prompt: report to stderr, exit 0, inject nothing.
  console.error(`route-detect: ${err.message}`);
  process.exitCode = 0;
}
