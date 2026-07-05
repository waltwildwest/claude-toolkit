#!/usr/bin/env node
'use strict';
// vault-search — the only sanctioned recall interface. Raw grep finds
// candidates; this folds events so superseded/retracted claims never serve
// as live. Prints a verdict-ready provenance line per hit, near-misses on a
// miss, and logs every recall to metrics.jsonl unconditionally (audit detail
// belongs in the log; chat gets one line unless something is anomalous).
//
//   node vault-search.js <terms...> [--vault <dir>] [--project <slug>] [--json]
//   node vault-search.js --add-alias <slug> <alias> [--vault <dir>]
//
// exit: 0 hit(s), 2 no hits (near-misses printed), 1 vault missing/usage.
// Reads are lock-free; --add-alias mutates under the lock and auto-commits.

const path = require('path');
const lib = require('./vault-lib');

function getFlag(name) { const i = process.argv.indexOf(name); return i !== -1 ? process.argv[i + 1] : null; }

function lastPerSlug(records) {
  const m = new Map();
  for (const r of records) if (r && r.slug) m.set(r.slug, r);
  return m;
}

function freshness(dateStr) {
  const t = Date.parse(String(dateStr));
  if (Number.isNaN(t)) return 'age unknown — spot-check before trusting';
  const d = Math.max(0, Math.floor((Date.now() - t) / 86400000));
  return d <= 30 ? 'fresh (' + d + 'd)' : 'aging (' + d + 'd) — spot-check before trusting';
}

function trigrams(s) {
  const t = new Set();
  const x = ' ' + String(s).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim() + ' ';
  for (let i = 0; i + 3 <= x.length; i++) t.add(x.slice(i, i + 3));
  return t;
}
function trigramSim(a, b) {
  const ta = trigrams(a), tb = trigrams(b);
  if (!ta.size || !tb.size) return 0;
  let inter = 0;
  for (const g of ta) if (tb.has(g)) inter++;
  return inter / Math.min(ta.size, tb.size);
}

function addAlias(vault) {
  const i = process.argv.indexOf('--add-alias');
  const slug = process.argv[i + 1], alias = process.argv[i + 2];
  if (!slug || !alias || slug.startsWith('--') || alias.startsWith('--')) {
    process.stderr.write('usage: vault-search.js --add-alias <slug> <alias> [--vault <dir>]\n');
    process.exit(1);
  }
  lib.withLock(vault, () => {
    const prev = lastPerSlug(lib.readJsonl(path.join(vault, 'index.jsonl')).records).get(slug);
    if (!prev) { process.stderr.write('vault-search: no topic "' + slug + '" in the index\n'); process.exit(1); }
    const aliases = Array.from(new Set([].concat(prev.aliases || [], [alias])));
    lib.appendJsonl(path.join(vault, 'index.jsonl'), Object.assign({}, prev, { aliases }));
    lib.gitCommit(vault, 'research: learn alias "' + alias + '" for ' + slug);
  });
  process.stdout.write(JSON.stringify({ ok: true, slug, alias }) + '\n');
}

function main() {
  const vault = lib.resolveVault(getFlag('--vault'));
  if (process.argv.includes('--add-alias')) return addAlias(vault);

  const takesValue = new Set(['--vault', '--project']);
  const terms = [];
  for (let i = 2; i < process.argv.length; i++) {
    const a = process.argv[i];
    if (a.startsWith('--')) { if (takesValue.has(a)) i++; continue; }
    terms.push(a.toLowerCase());
  }
  if (!terms.length) { process.stderr.write('usage: vault-search.js <terms...> [--project <slug>] [--json]\n'); process.exit(1); }
  const project = getFlag('--project');
  const wantJson = process.argv.includes('--json');

  const index = lastPerSlug(lib.readJsonl(path.join(vault, 'index.jsonl')).records);
  const { claims } = lib.foldClaims(lib.readJsonl(path.join(vault, 'claims.jsonl')).records);

  const scores = new Map(), claimHits = new Map();
  const bump = (slug, n) => scores.set(slug, (scores.get(slug) || 0) + n);
  for (const [slug, rec] of index) {
    const strong = (slug + ' ' + (rec.title || '')).toLowerCase();
    const alias = (rec.aliases || []).join(' ').toLowerCase();
    const question = (rec.questions || []).join(' ').toLowerCase();
    for (const t of terms) {
      if (strong.includes(t)) bump(slug, 3);
      else if (alias.includes(t)) bump(slug, 2);
      else if (question.includes(t)) bump(slug, 1);
    }
  }
  for (const c of claims.values()) {
    if (c.status === 'retracted' || !c.topic) continue;
    const st = String(c.statement || '').toLowerCase();
    if (!terms.some((t) => st.includes(t))) continue;
    bump(c.topic, 2);
    const list = claimHits.get(c.topic) || [];
    list.push(c);
    claimHits.set(c.topic, list);
  }
  if (project) {
    for (const [slug, rec] of index) if (scores.has(slug) && rec.scope === 'project:' + project) bump(slug, 5);
  }

  const hits = Array.from(scores.entries()).filter(([, s]) => s > 0).sort((a, b) => b[1] - a[1]).map(([slug]) => slug);
  lib.appendJsonl(path.join(vault, 'metrics.jsonl'), { v: 1, kind: 'recall', ts: new Date().toISOString(), terms, project: project || null, hits });

  if (!hits.length) {
    const query = terms.join(' ');
    const near = Array.from(index.values())
      .map((r) => ({ slug: r.slug, sim: trigramSim(query, r.slug + ' ' + (r.title || '') + ' ' + (r.aliases || []).join(' ')) }))
      .filter((x) => x.sim > 0.15).sort((a, b) => b.sim - a.sim).slice(0, 3);
    lib.appendJsonl(path.join(vault, 'metrics.jsonl'), { v: 1, kind: 'near-miss', ts: new Date().toISOString(), terms, near: near.map((n) => n.slug) });
    if (wantJson) process.stdout.write(JSON.stringify({ hits: [], nearMisses: near.map((n) => n.slug) }) + '\n');
    else if (near.length) process.stdout.write('no match — closest: ' + near.map((n) => n.slug).join(', ') + ' — one of these? (learn it: vault-search.js --add-alias <slug> "<your term>")\n');
    else process.stdout.write('no match — vault has ' + index.size + ' topic(s), none close. Fresh research needed.\n');
    process.exit(2);
  }

  const blocks = [];
  for (const slug of hits) {
    const rec = index.get(slug) || { slug };
    const served = [];
    const seen = new Set();
    for (const c of (claimHits.get(slug) || [])) {
      const terminals = c.status === 'active' ? [c] : lib.resolveTerminal(claims, c.id);
      for (const t of terminals) {
        if (seen.has(t.id)) continue;
        seen.add(t.id);
        served.push({ claim: t, supersedes: t.id === c.id ? null : c.id });
      }
    }
    blocks.push({ slug, rec, served });
  }

  const provLine = (b) => 'vault · ' + b.slug + ' · researched ' + (b.rec.date || 'unknown') + ' · ' + freshness(b.rec.date);
  if (wantJson) {
    process.stdout.write(JSON.stringify({ hits: blocks.map((b) => ({
      slug: b.slug, title: b.rec.title || b.slug, date: b.rec.date || null, scope: b.rec.scope || 'general',
      provenanceLine: provLine(b), topicFile: 'topics/' + b.slug + '/topic.md',
      claims: b.served.map((s) => ({
        id: s.claim.id, statement: s.claim.statement, provenance: s.claim.provenance,
        confidence: s.claim.confidence, date: s.claim.date, source: s.claim.source || null,
        supersedes: s.supersedes, contradictedBy: s.claim.contradictedBy,
      })),
    })) }) + '\n');
    process.exit(0);
  }

  for (const b of blocks) {
    process.stdout.write('== ' + (b.rec.title || b.slug) + ' (' + b.slug + ') ==\n');
    process.stdout.write(provLine(b) + '\n');
    if (b.rec.scope && b.rec.scope.startsWith('project:') && b.rec.scope !== 'project:' + (project || '')) {
      process.stdout.write('note: researched for ' + b.rec.scope + ' — still applicable here?\n');
    }
    if (b.served.length) {
      process.stdout.write('claims to spot-check (dated + falsifiable, not verdicts):\n');
      for (const s of b.served) {
        const c = s.claim;
        process.stdout.write('- [' + [c.provenance, c.confidence, c.date].filter(Boolean).join(' · ') + '] '
          + c.statement + (c.source ? ' (' + c.id + ' · ' + c.source + ')' : ' (' + c.id + ')') + '\n');
        if (s.supersedes) process.stdout.write('    ↳ updated: supersedes ' + s.supersedes + '\n');
        if (c.contradictedBy.length) {
          process.stdout.write('    ⚠ contradicted by ' + c.contradictedBy.join(', ') + ' — both stand until resolved (/research correct)\n');
        }
      }
    }
    process.stdout.write('full topic: topics/' + b.slug + '/topic.md\n\n');
  }
  process.exit(0);
}

main();
