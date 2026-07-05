#!/usr/bin/env node
'use strict';
// claim-validate — per-record validation for staged claims and events
// (module only; vault-save feeds it records and quarantines rejects).
// This file owns the claim schema so SKILL.md doesn't have to (spec Pillar 3):
//   script-generated: v, id, run, date, topic
//   hard-enforced (reject): non-empty statement; valid enums; source resolves
//     when provenance claims grounding; staged provenance/events may not
//     claim what only the doctor grants (externally-verified / verify)
//   verified-with-downgrade: verbatim-grounded quotes must be found in the
//     cached extraction (quote-verify ladder incl. markdown-stripped view);
//     verified -> quote rewritten to exact source bytes; miss -> downgrade to
//     model-asserted, never reject
//   defaulted: confidence=medium, type=finding, quantity=null,
//     found_by/tool=unknown; unknown fields preserved verbatim
//
// Module API: validateClaim(rec, ctx), validateEvent(rec, ctx),
//   createsCycle(edges, claimId, byId)
//   ctx = {vault, runId, topic, date, takenIds:Set, knownIds:Set, supersedeEdges:Map}

const fs = require('fs');
const path = require('path');
const lib = require('./vault-lib');
const { verify } = require('./quote-verify');

const TYPES = ['finding', 'absence'];
const STAGEABLE_PROVENANCE = ['verbatim-grounded', 'model-asserted', 'human-asserted'];
const CONFIDENCE = ['high', 'medium', 'speculation'];
const OPS = ['supersede', 'contradict', 'retract', 'verify'];

function sourceBody(vault, sourceId) {
  const p = path.join(vault, 'sources', String(sourceId) + '.md');
  if (!fs.existsSync(p)) return null;
  return lib.parseFrontmatter(fs.readFileSync(p, 'utf8')).body;
}

function validateClaim(rec, ctx) {
  if (!rec.statement || !String(rec.statement).trim()) return { ok: false, reason: 'empty statement' };
  const type = rec.type === undefined ? 'finding' : rec.type;
  if (!TYPES.includes(type)) return { ok: false, reason: 'bad type: ' + rec.type + ' (finding | absence)' };
  const confidence = rec.confidence === undefined ? 'medium' : rec.confidence;
  if (!CONFIDENCE.includes(confidence)) return { ok: false, reason: 'bad confidence: ' + rec.confidence + ' (high | medium | speculation)' };
  let provenance = rec.provenance === undefined ? 'model-asserted' : rec.provenance;
  if (!STAGEABLE_PROVENANCE.includes(provenance)) {
    return { ok: false, reason: 'bad provenance: ' + rec.provenance + ' (verbatim-grounded | model-asserted | human-asserted; externally-verified is doctor-granted, not stageable)' };
  }

  let quote = rec.quote === undefined ? null : rec.quote;
  let downgraded = false, quoteMethod = null, note = null;
  if (provenance === 'verbatim-grounded') {
    if (!rec.source) return { ok: false, reason: 'verbatim-grounded without source' };
    const body = sourceBody(ctx.vault, rec.source);
    if (body === null) return { ok: false, reason: 'source not found: ' + rec.source };
    const res = verify(String(quote || ''), body);
    if (res.verified) { quote = res.sourceQuote; quoteMethod = res.method; }
    else {
      provenance = 'model-asserted'; downgraded = true; quoteMethod = 'none';
      note = 'downgraded: quote not found in ' + rec.source;
    }
  }

  const id = lib.newId('clm', ctx.runId + '|' + rec.statement, ctx.takenIds);
  ctx.takenIds.add(id);
  const record = Object.assign({}, rec, {
    v: 1, id, run: ctx.runId, topic: ctx.topic, date: ctx.date,
    type, confidence, provenance, quote,
    quantity: rec.quantity === undefined ? null : rec.quantity,
    found_by: rec.found_by === undefined ? 'unknown' : rec.found_by,
    tool: rec.tool === undefined ? 'unknown' : rec.tool,
  });
  // validator-owned fields: staged values must never survive. op is deleted
  // too — a claim record smuggling a non-string op would be invisible to
  // foldClaims (which treats any op-bearing record as an event).
  delete record.quote_method;
  delete record.note;
  delete record.op;
  if (quoteMethod) record.quote_method = quoteMethod;
  if (note) record.note = note;
  return { ok: true, record, downgraded, quoteMethod };
}

function validateEvent(rec, ctx) {
  if (!OPS.includes(rec.op)) return { ok: false, reason: 'bad op: ' + rec.op + ' (supersede | contradict | retract)' };
  if (rec.op === 'verify') return { ok: false, reason: 'verify events are doctor-granted (stage 3), not stageable' };
  if (!rec.claim || !ctx.knownIds.has(rec.claim)) return { ok: false, reason: 'unknown claim: ' + rec.claim };
  if (rec.op === 'supersede') {
    if (!rec.by || !ctx.knownIds.has(rec.by)) return { ok: false, reason: 'supersede needs by: <existing claim id>' };
    if (createsCycle(ctx.supersedeEdges, rec.claim, rec.by)) {
      return { ok: false, reason: 'supersede would create a cycle: ' + rec.claim + ' <- ' + rec.by };
    }
    const list = ctx.supersedeEdges.get(rec.claim) || [];
    ctx.supersedeEdges.set(rec.claim, list.concat([rec.by]));
  }
  if (rec.op === 'contradict' && (!rec.by || !ctx.knownIds.has(rec.by))) {
    return { ok: false, reason: 'contradict needs by: <existing claim id>' };
  }
  const record = Object.assign({}, rec, { v: 1, date: rec.date || ctx.date });
  return { ok: true, record };
}

// Edge map: claimId -> [superseding ids]. Adding (claimId <- byId) creates a
// cycle iff byId's existing supersession chain already reaches claimId (a
// self-supersede is the degenerate case).
function createsCycle(edges, claimId, byId) {
  const stack = [byId], seen = new Set();
  while (stack.length) {
    const cur = stack.pop();
    if (cur === claimId) return true;
    if (seen.has(cur)) continue;
    seen.add(cur);
    for (const nxt of edges.get(cur) || []) stack.push(nxt);
  }
  return false;
}

module.exports = { validateClaim, validateEvent, createsCycle };
