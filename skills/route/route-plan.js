#!/usr/bin/env node
'use strict';
// route-plan — read the model you're running and print a delegation plan.
//
// Reads the last model in the current session transcript (same source handoff
// uses: ~/.claude/projects/<enc-cwd>/$CLAUDE_CODE_SESSION_ID.jsonl), places it on
// a cost/capability ladder, and recommends which tier gets grunt work and which
// gets standard work. It NEVER routes up: it only ever delegates to a model
// strictly cheaper than the one you're running, and reasoning + the final review
// always stay on your model. If you're already on the cheapest tier, it tells you
// to do the work yourself rather than fish with dynamite in reverse.
//
//   route-plan [--model <id>] [--json]
//     --model  override detection (testing, or planning for a model you'll switch to)
//     --json   machine-readable plan
//
// Local only, no network, no deps.

const fs = require('fs');
const path = require('path');
const os = require('os');

// Cheap -> top. First match wins; unknown ids are assumed strong (tier = top),
// so an unfamiliar new model still delegates its grunt work downward safely.
const LADDER = [
  { tier: 0, label: 'cheapest', match: /haiku/i },
  { tier: 1, label: 'mid', match: /sonnet/i },
  { tier: 2, label: 'high', match: /opus/i },
  { tier: 3, label: 'top', match: /fable|mythos/i },
];
const TOP_TIER = 3;
const GRUNT = { tier: 0, name: 'haiku' };
const STANDARD = { tier: 1, name: 'sonnet' };

function parseArgs(argv) {
  const args = { model: null, json: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--model') { args.model = argv[i += 1]; if (args.model == null) throw new Error('--model needs a value'); }
    else if (a === '--json') { args.json = true; }
    else if (a === '--help' || a === '-h') { args.help = true; }
    else { throw new Error(`unknown flag: ${a}`); }
  }
  return args;
}

function findTranscript() {
  const sessionId = process.env.CLAUDE_CODE_SESSION_ID;
  if (!sessionId) return null;
  const base = path.join(process.env.HOME || os.homedir(), '.claude', 'projects');
  if (!fs.existsSync(base)) return null;
  for (const dir of fs.readdirSync(base)) {
    const p = path.join(base, dir, `${sessionId}.jsonl`);
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function detectModel() {
  const tx = findTranscript();
  if (!tx) return null;
  let model = null;
  let text;
  try { text = fs.readFileSync(tx, 'utf8'); } catch { return null; }
  for (const line of text.split('\n')) {
    if (!line.includes('"model"')) continue;
    let d;
    try { d = JSON.parse(line); } catch { continue; }
    const m = (d.message && d.message.model) || d.model;
    if (m && typeof m === 'string' && !m.startsWith('<')) model = m; // last wins
  }
  return model;
}

function tierOf(model) {
  if (!model) return { tier: TOP_TIER, known: false };
  const hit = LADDER.find((l) => l.match.test(model));
  return hit ? { tier: hit.tier, label: hit.label, known: true } : { tier: TOP_TIER, known: false };
}

function buildPlan(model) {
  const { tier, label, known } = tierOf(model);
  const grunt = GRUNT.tier < tier ? GRUNT.name : null;
  const standard = STANDARD.tier < tier ? STANDARD.name : null;
  return {
    brain: model || null,
    brainKnown: known,
    brainTier: known ? label : 'assumed-top',
    grunt,      // model for grunt work, or null = keep it yourself
    standard,   // model for standard work, or null = keep it yourself
    reviewer: model || null, // review/judgment always stays on your model
    delegates: Boolean(grunt || standard),
  };
}

function printHuman(p) {
  const who = p.brain || 'current session model (undetected)';
  console.log(`route plan (brain = ${who}${p.brainKnown ? `, ${p.brainTier} tier` : ', tier assumed top'})`);
  if (!p.delegates) {
    console.log('  you are on the cheapest tier — do delegable work yourself, never route up');
    return;
  }
  if (p.grunt) console.log(`  grunt work      -> ${p.grunt}`);
  if (p.standard) console.log(`  standard work   -> ${p.standard}`);
  console.log(`  reasoning + final review stay on your model (${who})`);
  console.log('  never delegate to a model as costly as or costlier than your own');
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) { console.log('usage: route-plan [--model <id>] [--json]'); return 0; }
  const model = args.model || detectModel();
  const plan = buildPlan(model);
  if (args.json) console.log(JSON.stringify(plan, null, 1));
  else printHuman(plan);
  return 0;
}

try { process.exitCode = main(); } catch (err) {
  console.error(`route-plan: ${err.message}`);
  process.exitCode = 1;
}
