# Re:Searcher — Design Spec

**Date:** 2026-07-05
**Status:** Approved design, pre-implementation
**Author:** Walter + Claude (brainstorm → adversarial review → Claude Science/Anthropic architecture study)

## Problem

When Claude Code fans out research subagents, each agent burns tens of thousands of tokens
exploring, then returns a compressed summary. Only the synthesis survives in context; the raw
findings, the sources read, and the search paths taken all evaporate. Future sessions either
trust summaries-of-summaries (drift) or re-research from scratch (cost). Anthropic documents
this as the "game of telephone" problem in their multi-agent research system writeup.

Re:Searcher is a persistent research vault for Claude Code: every research run's plan,
per-agent findings, cached sources, and claims are captured in an inspectable local markdown
vault with full lineage back to the agent transcripts, and future research is vault-first —
prior claims are spot-checked and gaps filled instead of everything re-derived.

## Validation summary (adversarial review, 2026-07-05)

Three independent review passes shaped this design:

- **Prior art:** the exact combination is open space. Closest neighbors: claude-obsidian
  (8.8k★, PKM/wiki pipeline, not a capture layer for native Claude Code research),
  obsidian-second-brain (3k★, vault-first gap-filling but heavy, API-key-dependent, no
  per-agent findings), Hindsight/claude-mem (own the "subagent findings evaporate" framing
  but store to opaque memory banks, no artifact layer). Differentiators to protect:
  capture of *ordinary* Claude Code research fan-outs, claim-level provenance,
  transcript-pointer lineage, git-commit staleness for code research.
- **Red team (fatal findings, both fixed structurally):** (1) obedience-based agent-side
  vault writes fail silently → fixed by single-Write staging + lead completeness check +
  transcript harvester; (2) WebFetch returns AI extractions, not raw pages → fixed by raw
  fetch pipeline + honest `extraction` labeling; (3) vault-first-as-primary-context anchors
  future research → fixed by claims-to-verify recall posture; (4) grep recall fails silently
  → fixed by save-time grep-bait + recall audit lines.
- **Pragmatist:** at solo scale (2–5 runs/week) grep never breaks; index machinery must not
  be built for imaginary scale. Kept: JSONL registry is append-only and grep-friendly, no
  database, no embeddings until metrics prove grep misses.

## Goals

1. No research run's raw findings are ever lost (capture is a property of the system, not a habit).
2. Every claim is walkable to its provenance: quote → cached source → agent transcript.
3. Repeat research is cheaper and *less* biased than re-research (claims-to-verify, not verdicts-as-context).
4. The vault improves with age (librarian maintenance), instead of rotting.
5. Everything is plain files: markdown + JSONL, Obsidian-openable, zero external services.

## Non-goals

- Not a general memory system (that's auto-memory / claude-mem territory).
- Not a team knowledge base (single-writer assumptions are allowed).
- No embeddings/vector store in v1 (revisit only if recall metrics demand it).
- No background LLM extraction hooks (harvest is deferred mining, on command).

## Architecture: five pillars

### Pillar 1 — Capture guaranteed by the harness

Two capture paths, neither trusting agent obedience:

**Front door (the skill).** Research agents write their full raw findings directly into the
run's `findings/` folder with a single plain `Write` call (no scripts, no schema burden
mid-research — the run folder is the staging area until vault-save registers it), and return a
1–2k distilled summary + the file path — Anthropic's documented "store work externally, pass
lightweight references" pattern. The lead then runs a **deterministic completeness check**:
it spawned N agents, so N staging files must exist before synthesis. Missing file → visible
gap (re-request or log under Gaps). The lead persists everything to the vault post-synthesis
in one deterministic step.

**Safety net (the harvester).** Every subagent's full transcript already exists on disk
(`agent-*.jsonl` under `~/.claude/projects/<project>/`). `/research harvest` mines a chosen
session's transcripts into proper vault entries after the fact — covering research done
without the skill, including retroactively. A Stop-hook may drop a one-line pointer
("session did fan-out research, unharvested") into `vault/inbox.jsonl`; the hook writes
pointers only, never runs extraction.

### Pillar 2 — Raw sources, actually raw

`vault-fetch` pipeline, in order of preference:

1. `curl` raw HTML → readability-style HTML→markdown extraction. Store **both** raw HTML
   (content-hashed on raw bytes — dedupe works) and the markdown extraction.
2. Browser fallback (claude-in-chrome MCP when available) for JS-rendered/login-walled pages.
3. WebFetch as last resort — output stored but labeled `provenance: extraction` (it is an
   AI summary, never presented as ground truth).

PDFs and binaries → `attachments/`. Every cited URL gets a Wayback Machine save request
(best-effort, non-blocking) so provenance survives link rot.

### Pillar 3 — Claims as first-class objects

The atomic unit is the **claim**: one statement + verbatim quote + source link + date +
confidence + status. Stored in an **append-only JSONL registry** (models are documented to
be less likely to mangle JSON than markdown; append-only makes history free). Markdown notes
are *views* over the registry, regenerated by scripts — never the source of truth.

Claim record (JSONL, one per line):

```json
{"id": "clm_...", "topic": "mcp-auth-landscape", "run": "2026-07-05a",
 "statement": "...", "quote": "...", "source": "src_3f9a12", "locator": "file:line|url#fragment",
 "provenance": "verbatim-grounded|model-asserted|externally-verified",
 "confidence": "high|medium|speculation",
 "status": "active|stale|superseded|contradicted", "supersedes": null, "contradicted_by": null,
 "date": "2026-07-05", "found_by": "agent-role", "tool": "websearch|gh|mcp:<server>"}
```

Provenance axis (from Claude Science's session-grounded vs library-verified distinction):
- `verbatim-grounded` — quote mechanically verified present in the cached source
- `model-asserted` — agent stated it without a checkable quote
- `externally-verified` — a later freshness/verification pass confirmed it

New research never overwrites: claims get `superseded`/`contradicted` links, so what was
believed and when is preserved.

### Pillar 4 — Recall that doesn't lie

**Save-time:** the writer generates grep-bait — aliases, synonyms, and 3–5 anticipated future
questions per topic, written into the index for a future grep to hit.

**Recall-time:** just-in-time loading — grep the index with multiple model-generated probe
phrasings; load matching topic claims as **dated, falsifiable claims to spot-check**
("On 2026-03-02 we concluded X because Y — does Y still hold?"), never as verdicts-as-context.
Full notes load on demand only.

**Audit line, always:** "vault checked — terms tried: X, Y, Z — 2 hits (1 stale), 1 gap."
Misses are visible, so recall quality is measurable. Every recall hit/miss is appended to
`vault/metrics.jsonl`.

### Pillar 5 — The librarian

Maintenance is a job, not a hope. `/research doctor` (manually or scheduled) runs a
property-checker, not a vibes-reviewer (Claude Science reviewer pattern):

- quote-traceability: is each `verbatim-grounded` quote actually in its cached source?
- link integrity: do all source/transcript pointers resolve?
- staleness sweep by volatility; **adversarial** freshness checks (verifiers try to *refute*
  stale claims, not confirm them)
- contradiction detection across claims; flags, never silently resolves
- alias enrichment from recall misses in `metrics.jsonl`
- source/tool quality scoring: which tools historically produced claims that survived
  verification (feeds the routing table)
- emits `DASHBOARD.md`: recent runs, stale/contradicted claims, hit rate, top sources

Judge rubric for run quality (Anthropic's documented dimensions): factual accuracy, citation
accuracy, completeness, source quality, tool efficiency.

## Vault layout

```
~/research-vault/
├── DASHBOARD.md                    # generated by librarian
├── index.jsonl                     # topic index: slug, question, aliases, anticipated questions, tags, project, volatility, dates
├── INDEX.md                        # generated human/Obsidian view of index.jsonl
├── claims.jsonl                    # append-only claim registry
├── metrics.jsonl                   # recall hits/misses, run stats
├── inbox.jsonl                     # harvest pointers (optional Stop-hook)
├── topics/<slug>/
│   ├── topic.md                    # current view: verdict, key claims, gaps, how-to-reverify, related
│   └── runs/<date><n>/
│       ├── plan.md                 # persisted BEFORE fan-out; scope, decomposition, out-of-scope
│       ├── findings/<agent-role>.md  # verbatim agent findings + embedded task spec
│       └── lineage.json            # session id, agent transcript paths, tool budgets spent
├── sources/<hash8>--<domain>--<slug>.md   # extraction w/ frontmatter: url, fetched, hash, provenance
├── sources/raw/<hash8>.html        # raw bytes
├── attachments/
└── profiles/<name>.md              # distilled researcher profiles (reusable task specs)
```

Topic notes and findings are Obsidian-friendly markdown with wiki-links topic → findings →
sources; filenames are the link contract; structure optimized for machine recall first,
human browsing second.

## Research run lifecycle

1. **Trigger:** explicit `/research <question>` (+ `--fresh`, `fork <topic> "<variant>"`,
   `harvest`, `doctor`). Keyword auto-activation is conservative in v1; the skill may
   *suggest* itself after ad-hoc fan-out research ("save this run to the vault?").
2. **Recall:** multi-probe grep of `index.jsonl` (project-scoped first, then global) →
   full hit (answer from vault, zero agents, audit line) / partial hit (claims-to-verify +
   gap list) / miss.
3. **Plan:** classify depth-first / breadth-first / straightforward; size fan-out with
   Anthropic's budgets (1 agent + 3–10 tool calls simple; 2–4 agents comparisons; 5–10
   complex; stop-at-diminishing-returns rule). Inventory available tools (ToolSearch, MCP
   servers, `gh`) and route sources per the routing table + profiles. **Persist plan.md
   before any fan-out.** Fan-outs of 4+ agents present the decomposition for approval first.
4. **Fan-out:** each agent gets one core objective, output format, source guidance, scope
   boundaries (embedded task spec). Agents fetch sources via the fetch pipeline, `Write`
   full findings into the run's `findings/` folder, return distilled summary + path.
5. **Verify (concurrent):** as findings land, a fresh-context verifier spot-checks
   quote-traceability per finding (pipelined — overlaps slower agents). Claims enter the
   registry with earned provenance status.
6. **Synthesize:** lead runs completeness check (N files for N agents), reads findings
   (not the return blurbs), writes topic.md: verdict, key claims, explicit **Gaps**,
   **How to re-verify** (queries that worked, authoritative sources), **Related** links.
7. **Persist:** one deterministic step — registry append, index update, lineage.json with
   session/transcript pointers, INDEX.md regeneration. Answer in chat = verdict + vault
   path + audit line.

## Staleness

- **Web:** `volatility: stable|moving|live` set at research time, human-overridable.
  stable → trusted; moving → after ~30 days a recall hit triggers one adversarial freshness
  agent, corrections merge as superseding claims; live → always re-verify, vault is background.
- **Code:** per-claim `commit` + referenced paths; on recall, `git diff --stat <commit>..HEAD -- <paths>`
  clean → fresh regardless of age; dirty → re-extract changed files only, supersede affected
  claims. Non-git sources: mtime/hash comparison.
- Trust decisions are always announced ("served from vault, stable, researched 2026-05-02").

## Scripts (zero-dep Node, each with bash tests)

| Script | Job |
|---|---|
| `vault-init.js` | Idempotent skeleton creation |
| `vault-fetch.js` | Raw fetch → hash → dedupe → store raw+extraction → print source id/link; Wayback ping |
| `vault-save.js` | Post-synthesis persist: validate claim records, append registries, write notes, regenerate views atomically |
| `vault-search.js` | Multi-term index/claims grep; emits audit line data; logs hit/miss to metrics.jsonl |
| `vault-doctor.js` | Deterministic checks (quote presence, link integrity, staleness candidates); LLM passes are agent work driven by its report |

Scripts fail loud with actionable messages; atomic writes via temp+rename; a run's staging
either persists completely or is reported as unharvested (never half-registered).

## Error handling

- Agent dies mid-run → completeness check surfaces it; synthesis lists it under Gaps.
- Fetch fails (paywall/bot-block) → claim recorded as `model-asserted` with the URL; never
  fake a grounding.
- vault-save validation failure → nothing persisted for that run; staging retained; clear error.
- Recall finds contradictory active claims → both loaded, contradiction flagged in the answer.

## Testing & instrumentation

- Bash tests per script (happy path, malformed input, dedupe, atomicity, regeneration).
- End-to-end skill test: seeded fake staging → synthesis → registry/view assertions.
- Eval set: ~20 real research questions (Anthropic's starting number), LLM-judge rubric
  scored 0–1 + pass/fail; re-run after skill prompt changes.
- `metrics.jsonl` answers the ROI question with data: recall hit rate, agents avoided,
  freshness corrections caught.

## Staged roadmap (each stage shippable + a post)

1. **Core loop:** vault format, `/research`, recall, staging capture, completeness check,
   post-synthesis persist, `vault-fetch` (curl path), claims registry, basic staleness announce.
2. **Harvester:** transcript mining, `/research harvest`, optional Stop-hook inbox.
3. **Librarian:** `/research doctor`, adversarial freshness, contradiction detection,
   DASHBOARD.md, source-quality scoring, profiles.
4. **Smart recall (metrics-gated):** alias learning from misses; embeddings only if hit-rate
   data proves grep insufficient.

## Positioning

"Anthropic's research architecture — orchestrator/workers, files-over-telephone, citation
verification, background reviewer — rebuilt as a local, inspectable markdown vault for
Claude Code." vs claude-obsidian: capture layer for native research fan-outs, not a PKM
pipeline. vs obsidian-second-brain: zero-dep, no API keys, claim-level provenance. vs
claude-mem/Hindsight: artifacts you can open, grep, and defend, not an opaque memory bank.

## Open questions (deferred, not blocking)

- Keyword auto-activation aggressiveness after v1 misfire data.
- Wayback integration failure modes (rate limits) — best-effort only.
- Whether profiles should be shareable via the toolkit marketplace.
