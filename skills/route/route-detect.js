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

const DISABLED = /^(off|0|false|no)$/i.test(process.env.ROUTE_DETECT || '');

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

  if (args.explain) {
    console.log(fired.length ? `route-detect: ${fired.join(', ')}` : 'route-detect: no signals');
    return 0;
  }
  if (fired.length === 0) return 0; // silent on the vast majority of prompts

  // Lead with the most specific group that fired.
  const lead = fired[0];
  const context = NUDGE[lead];
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'UserPromptSubmit',
      additionalContext: `[route] ${context}`,
    },
  }));
  return 0;
}

try { process.exitCode = main(); } catch (err) {
  // A hook must never break the prompt: report to stderr, exit 0, inject nothing.
  console.error(`route-detect: ${err.message}`);
  process.exitCode = 0;
}
