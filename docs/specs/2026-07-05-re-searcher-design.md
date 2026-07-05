# Re:Searcher — Design Spec v2

**Date:** 2026-07-05 (v2, same day — post second adversarial review)
**Status:** Locked design, pre-implementation
**Author:** Walter + Claude
**History:** v1 = brainstorm → adversarial review round 1 → Claude Science / Anthropic
architecture study. v2 = round-2 review by four fresh-context reviewers (mechanics red-team,
daily-use UX, implementation feasibility, completeness critic); 25 amendments applied.
v1 is in git history.

## Problem

When Claude Code fans out research subagents, each agent burns tens of thousands of tokens
exploring, then returns a compressed summary. Only the synthesis survives; the raw findings,
sources read, and search paths evaporate. Future sessions either trust summaries-of-summaries
(drift) or re-research from scratch (cost). Anthropic documents this as the "game of
telephone" problem in their multi-agent research system writeup.

Re:Searcher is a persistent research vault for Claude Code: every research run's plan,
per-agent findings, cached sources, and claims are captured in an inspectable local markdown
vault with lineage down to the agent transcripts, and future research is vault-first —
prior claims are spot-checked and gaps filled instead of everything re-derived.

## Review-validated principles (both rounds)

1. **Capture is a property of the system, not a habit.** Nothing depends on agent obedience
   or user discipline; ground truth lives on disk, checkable by anyone.
2. **Never block the user on rigor.** Recall is always the fastest thing in the room;
   verification, freshness, and bookkeeping run off the critical path.
3. **Scripts enforce, prose suggests.** Every rule that matters lives in a script's
   validation, not in SKILL.md text (instruction bloat degrades compliance).
4. **Honest provenance beats impressive provenance.** Extractions are labeled extractions;
   unverified claims are `model-asserted`; misses are disclosed with near-matches.
5. **The cheap path must be genuinely cheap** (≤1.5x plain asking), or the vault never
   captures the ad-hoc research its recall value depends on.

## Goals

1. No research run's raw findings are ever lost.
2. Every claim is walkable to its provenance: quote → cached source → agent transcript
   (transcripts copied into the vault — they must not rot with Claude Code's retention window).
3. Repeat research is cheaper and *less* biased than re-research (claims-to-verify, never
   verdicts-as-context).
4. The vault improves with age (librarian), instead of rotting.
5. Everything is plain files: markdown + JSONL in a git repo, Obsidian-openable, zero
   external services.

## Non-goals

- Not a general memory system (auto-memory's job; see Ecosystem).
- Not a team knowledge base (single-writer semantics + advisory lock; git remote is the
  interim two-machine answer; true multi-writer merge is punted until it hurts).
- No embeddings/vector store until metrics prove grep+aliases insufficient (stage 4 gate).
- No background LLM extraction hooks (the Stop-hook writes pointers only; harvest is lazy).
- No `fork` command (a new `/research` question + Related links is the fork; runs are
  immutable so history is already preserved).

## Architecture: five pillars

### Pillar 1 — Capture guaranteed by the harness

**Front door (the skill).** Research agents write full raw findings directly into the run's
`findings/` folder with a single plain `Write` (the run folder is the staging area), and
return a 1–2k distilled summary + path (Anthropic's "store work externally, pass lightweight
references" pattern).

Ground truth is on disk, not in the lead's context:
- `plan.md` (persisted **before** fan-out) contains a machine-readable **agent manifest**:
  roles + expected findings filenames.
- Completeness = `vault-save.js --check-staging <run-dir>`: manifest vs. files, per-file
  size floor (≥500 bytes) and required task-spec header. Checkable by the lead, a resumed
  session after compaction, or the doctor.
- Run folders are allocated by bare atomic `mkdir` (no `-p`) named
  `runs/<date><n>-<session4>/` — same-day collisions are impossible, not just unlikely.
- At persist time the run's agent transcripts are **gzipped and copied into
  `runs/<id>/transcripts/`**. The vault owns its provenance bottom layer; `~/.claude` paths
  are secondary pointers.
- Doctor sweeps for orphaned runs (manifest present, no `lineage.json`) → flags "unharvested
  run" and recall on that topic announces it.

**Safety net (lazy harvest).** A Stop-hook may append a pointer (session id, transcript
paths, topic guess, `transcript_dies: <date>`) to `inbox.jsonl` — pointers only, no
extraction, no dialog. Harvest happens **lazily at recall time**: when a probe misses the
index but an inbox pointer looks topically relevant, that one transcript is mined then —
when the mining has a paying customer. `/research save` (explicit) and `/research harvest`
(bulk) also exist; ad-hoc research answers may carry an ignorable one-liner:
`(unvaulted — "/research save" to keep)`. Never a modal suggestion.

### Pillar 2 — Raw sources, honestly labeled

`vault-fetch.js` pipeline:

1. `curl` raw HTML (proper UA, gzip, redirects, size/time caps) → zero-dep readability-style
   extraction to markdown. Store raw bytes + extraction.
2. **Extraction-confidence gate:** every fetch gets a confidence score (extracted-text
   length, link density, challenge-page signatures like `cf-ray`/"Just a moment"). Below
   threshold → do not store garbage; emit "escalate to browser/WebFetch" so the agent takes
   path 2/3.
3. Browser fallback (claude-in-chrome MCP, when available) for JS-rendered/authenticated
   pages — see secrets rules in Vault lifecycle.
4. WebFetch last resort; output stored labeled `provenance: extraction` (it is an AI summary).

**Dedupe:** keyed on normalized-URL + hash(extracted markdown) — raw-byte hashes never match
on modern pages (nonces, timestamps) and are used only as storage ids/filenames. Both hashes
recorded in frontmatter.

**Wayback:** availability-check first (snapshot exists → record it); else fire-and-forget
save with ~3s connect timeout; on failure/429 append to `wayback-queue.jsonl`, drained
slowly by the librarian. Per-source status: `exists|requested|queued|failed`. Never on the
critical path.

PDFs and binaries are first-class sources (see source model), not a dumping ground.

### Pillar 3 — Claims as immutable records + events

The atomic unit is the **claim**. `claims.jsonl` is append-only and immutable; anything
mutable is an **event record** appended later. Effective status is *derived* by folding
events — raw grep finds candidates, but `vault-search.js` (which folds) is the only
sanctioned recall interface. The librarian periodically emits `claims-current.jsonl`
(materialized view, under lock) for cheap greps.

Claim record:

```json
{"v": 1, "id": "clm_...", "topic": "mcp-auth-landscape", "run": "2026-07-05a-9f3c",
 "type": "finding|absence",
 "statement": "...", "quote": "...", "source": "src_3f9a12", "locator": "url#fragment|pdf:page=12|file:line|transcript:t=04:31|session:<uuid>",
 "provenance": "verbatim-grounded|model-asserted|human-asserted|externally-verified",
 "confidence": "high|medium|speculation",
 "quantity": null,
 "date": "2026-07-05", "found_by": "agent-role", "tool": "websearch|gh|mcp:<server>"}
```

Event records (same file, appended):

```json
{"v": 1, "op": "supersede|contradict|retract|verify", "claim": "clm_A", "by": "clm_B|human|doctor",
 "date": "...", "reason": "..."}
```

Semantics (specified, not improvised):
- `supersede` edges form a DAG; `vault-save` rejects cycle-creating edges. Recall resolves
  each chain to its terminal claim(s).
- `contradict` is symmetric, flags both claims, removes neither from recall — both are
  served with flags and dates; a human resolves via an explicit supersede
  (`/research correct`).
- `retract` tombstones a claim (wrong research, redacted source); retracted claims never
  serve.
- `verify` promotes provenance (`model-asserted` → `externally-verified`), typically from
  doctor passes.
- Claim ids are assigned by `vault-save`, never by the LLM.
- Parsers skip unparseable lines with a counted warning (doctor reports the count);
  malformed lines are tombstoned, not edited.

Field rules in `vault-save`:
- **Script-generated:** `v`, `id`, `run`, `date`.
- **Hard-enforced (reject record → quarantine):** non-empty `statement`, valid enums,
  `source` resolves when provenance claims grounding.
- **Mechanically verified with downgrade, not rejection:** `verbatim-grounded` requires the
  quote to be found in the cached extraction after normalization (NFKC, whitespace collapse,
  curly-quote straightening); on fuzzy match the quote is rewritten to exact source bytes
  (source is ground truth, not the LLM's transcription); on miss → downgrade to
  `model-asserted`, logged. This deterministic check *is* the run-time verifier.
- **Defaulted:** `confidence→medium`, `type→finding`, `quantity→null`, `found_by/tool→unknown`.

`absence` claims record "searched X, found nothing as of <date>" with the queries tried —
staleness-managed like any claim, so exhaustive null results are never silently re-run.
`quantity: {value, unit, as_of, method}` is reserved now (schema rule: unknown fields
preserved), populated from stage 3.

**Source records** carry: `kind: web|pdf|video-transcript|dataset|conversation|session|user`,
kind-appropriate locators, `tier: official|primary|secondary|community` (domain heuristics +
agent judgment, doctor-adjustable), `auth_context: public|authenticated`, both hashes,
wayback status. `human-asserted` provenance ("Walter said the deadline is March") is a
distinct — and higher — trust class than `model-asserted`.

### Pillar 4 — Recall that doesn't lie and doesn't lecture

**Save-time:** writer generates grep-bait — aliases, synonyms, 3–5 anticipated future
questions per topic — into the index.

**Recall-time:**
- Multi-probe grep of `index.jsonl` **and the claims registry** (claims cross topics),
  via `vault-search --project <cwd-slug>` (project hits ranked first — mechanism, not prose).
- Hits load as **dated, falsifiable claims to spot-check**, never verdicts-as-context.
- **Near-miss disclosure:** on any miss or thin hit, show the 2–3 nearest topic titles
  ("no match — closest: mcp-auth-landscape, oauth-device-flow — one of these?"). A
  recovered near-miss appends the failed probe as a new alias immediately (real-time alias
  learning; doctor also mines `metrics.jsonl` misses).
- **Context-scope check:** topics carry `scope: general | project:<name>` (set at save time
  from the plan). Cross-project recall announces: "researched for project-A under React-17
  constraints — still applicable?"
- **Answer format: verdict first, then exactly one provenance line**
  (`vault · researched 2026-05-02 · stable` or `fresh run · 3 agents · saved to <path>`).
  Full audit detail (terms tried, hits/misses) is written to `metrics.jsonl` unconditionally
  but appears in chat **only on anomaly**: miss, staleness event, contradiction, unharvested
  run. Silence is a trust signal. Contradiction flags always surface.

### Pillar 5 — The librarian

Scheduled (not manual — nobody runs maintenance commands; `/research doctor` exists for
on-demand). Property-checker, not vibes-reviewer:

- Quote-traceability re-checks; provenance **promotion** in batch (`verify` events) — the
  LLM-semantic verification lives here, off every run's critical path.
- Link/pointer integrity; orphaned-run sweep; tombstone-aware (a redacted source is
  resolution, not breakage).
- Staleness sweep by volatility with **adversarial** freshness (verifiers try to refute).
  Freshness agents get no special trust: their claims pass the same vault-save gauntlet,
  only refutations trigger supersession, superseded claims are preserved, next window
  re-attacks — plus recall announces freshness supersessions. That property terminates the
  who-verifies-the-verifier regress.
- Contradiction detection **within topic only** (+ across topics sharing index aliases),
  **incremental** from a high-water mark in `metrics.jsonl` — never O(n²) over the registry.
- Alias enrichment from recall misses; source/tool quality scoring (which tiers/tools
  produced claims that survived verification) feeding the routing table.
- Wayback queue drain; secrets-pattern sweep over raw sources; schema-version census.
- Emits `DASHBOARD.md`: recent runs, stale/contradicted claims, belief changes
  ("what I believed then vs now" — supersession chains), hit rate, `--fresh` usage
  (abandonment canary), vault size/growth.
- Optional compaction: for `externally-verified` + `stable` claims older than N months,
  drop raw bytes, keep extraction + hashes + Wayback link, tombstone the raw file.

Judge rubric for run quality (Anthropic's dimensions): factual accuracy, citation accuracy,
completeness, source quality, tool efficiency.

## Vault layout

```
$RESEARCH_VAULT_DIR (default ~/research-vault/) — a git repo (vault-init runs git init;
every mutation auto-commits)
├── DASHBOARD.md                    # generated; Obsidian home note (wiki-links in)
├── index.jsonl                     # append-only, last-record-per-slug wins; librarian compacts
├── INDEX.md                        # generated view
├── claims.jsonl                    # append-only: claim records + event records
├── claims-current.jsonl            # materialized view (librarian, under lock)
├── metrics.jsonl                   # recall hits/misses, run stats, high-water marks
├── inbox.jsonl                     # harvest pointers (Stop-hook)
├── wayback-queue.jsonl
├── .lock/                          # advisory mkdir lock (all mutation)
├── topics/<slug>/
│   ├── topic.md                    # FULLY GENERATED view: latest synthesis + live claims
│   │                               #   folded from registry + gaps + staleness banners
│   │                               #   + "## Notes (human)" section preserved verbatim
│   └── runs/<date><n>-<session4>/
│       ├── plan.md                 # pre-fan-out; includes machine-readable agent manifest
│       ├── findings/<agent-role>.md
│       ├── synthesis.md            # lead-authored, immutable run artifact
│       ├── claims-rejected.jsonl   # per-record quarantine + validation reasons
│       ├── lineage.json            # session id, budgets, transcript pointers
│       └── transcripts/*.jsonl.gz  # copied at persist — provenance bottom layer
├── sources/<hash8>--<domain>--<slug>.md    # extraction + frontmatter (kind, tier, hashes,
│                                           #   auth_context, wayback, provenance)
├── sources/raw/<hash8>.html               # raw bytes (public captures only)
├── sources/*.tombstone.json               # redaction markers
├── attachments/
└── profiles/<name>.md              # distilled researcher profiles (vault data, not skill prose)
```

Two sources of truth, cleanly split: **run artifacts** (plan, findings, synthesis,
transcripts) are lead/agent-authored and immutable; **views** (topic.md, INDEX.md,
DASHBOARD.md) are fully script-generated and always safe to regenerate — except the
`## Notes (human)` section, preserved verbatim (one clobbered annotation ends human browsing
forever). Machinery (JSONL, runs/, raw/) is Obsidian-excluded so the graph shows topics and
sources, not plumbing.

## Research run lifecycle

**Tiered by the query classification** (depth-first / breadth-first / straightforward,
Anthropic's budgets: 1 agent + 3–10 calls simple; 2–4 comparisons; 5–10 complex; explicit
stop-at-diminishing-returns).

**Light path (straightforward class — most runs):** recall → 1 agent → findings + synthesis
captured, topic view regenerated, sources cached if fetched. **No claims authoring, no
verification** — the doctor mines claims from light runs later. Cost target: ≤1.5x plain
asking.

**Full path (3+ agents):**
1. **Trigger:** `/research <question>` (+ `--fresh`, `save`, `harvest`, `doctor`, `correct`,
   `export` [stage 3]). Keyword auto-activation stays conservative; misfire data decides later.
2. **Recall** (Pillar 4). Full hit → answer from vault, zero agents. Partial → claims-to-
   verify + gap list. Miss → near-miss disclosure, then research.
3. **Plan:** classify, size, inventory available tools (ToolSearch/MCP/`gh`) against the
   routing table + profiles; write `plan.md` with agent manifest; allocate run folder
   (atomic mkdir). **Show-and-go:** the decomposition is displayed as it launches ("say
   stop to adjust") — blocking approval only above a *cost* threshold, never agent count.
4. **Fan-out:** each agent gets one core objective, output format, source guidance, scope
   boundaries, the run-folder path, and the emitted task-spec template. Agents fetch via
   vault-fetch, `Write` findings, return summary + path.
5. **Completeness check:** `vault-save --check-staging` (manifest vs. files). Missing/stub
   findings → visible gap: re-request or record under Gaps.
6. **Synthesize:** lead reads findings files (not return blurbs), writes immutable
   `synthesis.md` (verdict, key claims, Gaps, How-to-re-verify, Related).
7. **Persist (layered — bookkeeping can never hold the run hostage):**
   - Tier 1, cannot fail: findings/plan/synthesis registered, lineage.json written,
     transcripts copied, index appended, views regenerated. Under the advisory lock.
   - Tier 2, per-record: claims validated individually; rejects → `claims-rejected.jsonl`
     with reasons; run marked `claims: partial` and surfaced in the answer.
   - Answer in chat: verdict + one provenance line (+ anomaly lines only).

## Staleness

- **Web:** `volatility: stable|moving|live` (human-overridable frontmatter).
  stable → trusted. moving → after ~30 days, **serve-then-verify**: the vault answer
  returns immediately ("from vault, 31 days old — freshness check running"); one
  adversarial freshness agent runs in the background; corrections follow up in-chat and
  land as superseding claims. live → vault is background context, always re-verify.
  Staleness never sits between the user and a recall hit.
- **Code (three-valued, never silently fresh):**
  1. `git cat-file -e <commit>` fails → **unknown** → treat stale, announce "commit unreachable".
  2. Any recorded path absent from `git ls-tree <commit>` → **invalid metadata** → flag to
     doctor, never serve as fresh. (`vault-save` validates claim paths against
     `git ls-tree` at persist, so bad paths die at write time.)
  3. Paths present + `git diff --stat <commit>..HEAD -- <paths>` clean → fresh regardless
     of age. Dirty → re-extract changed files only; file missing at HEAD → stale,
     "file removed/renamed".
- Non-git sources: mtime/hash comparison.
- Trust decisions are announced in the single provenance line.

## Vault lifecycle (designed as one unit)

- **Git:** `vault-init` runs `git init`; every `vault-save`/`harvest`/`doctor` mutation
  auto-commits (`research: persist run <id> <topic>`). Restore points, tamper history,
  as-of time travel, two-machine sync via remote (pull before write).
- **Redaction:** `vault-redact.js <source|claim>` — deletes source files, writes
  `*.tombstone.json` (reason + date), appends `retract` events, downgrades dependent claims
  to `model-asserted (source redacted)`. Doctor treats tombstones as resolution. Redaction
  guidance includes `git filter-repo` for history purges (documented, manual).
- **Secrets/PII:** authenticated browser captures default to **extraction-only storage**
  (no raw bytes) + scrub pass (script/meta-csrf/query-token/secret-pattern stripping) +
  `auth_context: authenticated` tag. Doctor sweeps `sources/raw/` with secret patterns.
  Raw HTML enters git history — hygiene happens *before* storage, not after.
- **Schema evolution:** `"v": 1` on every record; readers accept versions ≤ current and
  preserve unknown fields on rewrite; migrations are forward-only `vault-migrate.js`
  scripts (append-transform to new file, archive old).
- **Location:** `RESEARCH_VAULT_DIR` env var. Scripts hard-distinguish "vault present, 0
  hits" from "vault missing" and fail loud on the latter ("run vault-init or set
  RESEARCH_VAULT_DIR") — a missing vault must never masquerade as an empty one.
- **Permissions:** `vault-init` offers a documented allowlist snippet
  (`Write($RESEARCH_VAULT_DIR/**)`, the scripts, curl) so first contact isn't a prompt storm.

## Concurrency

Single advisory lock for all mutation: `vault-save` and the librarian acquire `.lock/` via
atomic `mkdir` (stale-lock timeout + loud message), mutate, release. Reads are lock-free.
`index.jsonl` is append-only last-record-wins, compacted by the librarian under the lock.
Run-folder allocation is lock-free by construction (atomic mkdir + session suffix). No
lock-free cleverness anywhere else — take the lock.

## Scripts (zero-dep Node, house style = /route)

| Script | Job |
|---|---|
| `vault-init.js` | Idempotent skeleton + git init; `--template task-spec\|plan\|finding` emits templates; offers allowlist |
| `vault-fetch.js` | Fetch pipeline + confidence gate + dedupe + wayback + scrub; prints source id/link |
| `vault-save.js` | Layered persist under lock; per-record validation; quote verify/downgrade/rewrite; id assignment; DAG check; `--check-staging`; view regeneration; auto-commit |
| `vault-search.js` | Multi-probe search over index + claims; event folding; `--project`, `--as-of` (stage 3); prints provenance/audit lines and near-misses; logs metrics |
| `vault-doctor.js` | Deterministic checks + queue drains + compactions; emits work report that the librarian agent pass consumes |
| `vault-redact.js` | Tombstones, retract events, dependent-claim downgrades |
| `vault-migrate.js` | Forward-only schema migrations (added when v2 schema exists) |

Scripts fail loud with actionable messages; atomic per-file writes (temp+rename); model
composes nothing a script can print.

## SKILL.md budget

≤200 lines: the state machine only (recall → plan → fan-out → synthesize → persist, one-line
rules). Schema knowledge lives in vault-save's validator and error messages; staleness math
and audit lines are printed by vault-search; templates are emitted by vault-init; harvest/
doctor/correct procedures live in `references/*.md` loaded on demand; routing table and
profiles are vault data files. The command file does subcommand routing.

## Harvester (stage 2)

Keys **exclusively on the embedded Anthropic Messages shape** (`message.role`,
`message.content` blocks: `text`, `tool_use{name,input}`, `tool_result`) — never the
envelope, which churns between Claude Code versions. `tool_use: Write` → candidate finding;
`WebSearch`/`WebFetch`/`mcp__*` → source events; final assistant text → summary.
Deterministic pre-extraction first (drop tool results, pull Write payloads + finals), LLM
only on the residue. Line-by-line parsing, skip-don't-abort; glob both transcript layouts;
version-sniff with loud warning on unknown majors; always emit raw `file:line` pointers so
lineage survives degraded parsing. Golden-test fixtures from ≥2 Claude Code versions,
with an unknown-block-type canary.

## Ecosystem boundaries

- **auto-memory:** sourced facts about the world → vault; project/user preferences and
  workflow facts → auto-memory. Memory may hold a one-line *pointer* to a vault topic,
  never the claims themselves (that's the telephone game's side door).
- **CLAUDE.md/global rules:** vault-init offers a pointer line ("before web research, run
  vault recall").
- **Existing deep-research skill:** retired into `/research` (wrapped or replaced —
  decision at stage 1 implementation; they must not race for the same triggers).
- **/route:** research runs are themselves routable workloads; profiles may pin models per
  agent role (stage 3).

## Error handling

- Agent dies / stub findings → completeness check surfaces; Gaps records it.
- Fetch fails or below confidence → escalate path or record claim as `model-asserted` with
  URL; never fake grounding.
- Claim validation failure → per-record quarantine; run persists; `claims: partial`.
- Contradictory active claims at recall → both served, flagged, dated.
- Sources conflict within a run → both claims recorded with mutual `contradict` events;
  synthesis states which tier won and why.
- Vault missing → loud failure, never "0 hits".
- Torn/unparseable JSONL lines → skipped with counted warning; doctor reports; tombstone.

## Testing (honest pyramid)

- **CI, no API:** all script bash tests against local fixture HTML (tiny node http server /
  `file://`, never live network); dedupe/atomicity/lock/validation/quote-normalization/
  event-folding/DAG tests; harvester vs. committed transcript fixtures; Wayback via
  endpoint-override env var; **contract E2E**: seeded fake staging → vault-save → assert
  registry/index/views (tests the persist contract without an LLM).
- **Pre-release, cheap API:** one headless `claude -p "/research <canned question>"` with
  fetch stubbed, asserting vault artifacts appear — the only true test of skill compliance.
- **On-demand, costed:** ~20-question eval, LLM judge (rubric above), re-run after prompt
  changes, results appended to `metrics.jsonl`.

## Success criteria (pre-committed)

Evaluate at 8 weeks of real use:
- **Healthy:** recall hit rate ≥25% on repeat-adjacent questions AND ≥1 freshness
  correction caught.
- **Failing:** hit rate <10% with ≥20 recalls attempted → strip to capture+harvest only
  (drop recall ceremony) or sunset.
- **Canary:** `--fresh` usage rate climbing month-over-month = user routing around the
  vault; earliest abandonment signal.
- Stage 4 (embeddings/smart recall) is gated on these same numbers.

## Roadmap (each stage shippable + a post)

0. **Prototype-first slice (before anything else):** vault-fetch (curl + extractor +
   confidence gate) + vault-save's quote verifier, run against ~20 real research URLs +
   one hand-driven research run. The number that validates or kills the core promise:
   **% of claims that can earn `verbatim-grounded`.**
1. **Core loop** (~2–2.5 route-units): vault format, `/research` light+full paths, recall
   with near-miss disclosure, staging capture + manifest completeness, layered persist,
   claims registry with events, transcripts copied, git lifecycle, serve-then-verify
   staleness announcements.
2. **Harvester** (~0.75–1): transcript mining, lazy harvest at recall, `/research save`,
   Stop-hook inbox.
3. **Librarian** (~1–1.5): scheduled doctor, provenance promotion, adversarial freshness,
   within-topic contradiction detection, DASHBOARD, source-quality scoring, profiles,
   `--as-of`, `/research export`.
4. **Smart recall** (~0.25–0.5, metrics-gated): alias learning at scale; embeddings only if
   hit-rate data demands.

Total ≈ 4.5–5.5 route-units.

## Positioning

"Anthropic's research architecture — orchestrator/workers, files-over-telephone, citation
verification, background reviewer — rebuilt as a local, inspectable markdown vault for
Claude Code." vs claude-obsidian: a capture layer for native research fan-outs, not a PKM
pipeline. vs obsidian-second-brain: zero-dep, no API keys, claim-level provenance. vs
claude-mem/Hindsight: artifacts you can open, grep, and defend — not an opaque memory bank.
Unique: transcript-owned lineage, event-sourced claims with epistemics (supersession,
contradiction, absence, human assertion), git-commit staleness for code research.

## Open questions (deferred, not blocking)

- Keyword auto-activation aggressiveness (decide on misfire data after stage 1).
- Profile sharing via toolkit marketplace (export exists at stage 3; licensing posture:
  exports default to extraction+link, not raw copyrighted HTML).
- True multi-writer vault merge (punted; git remote pull-before-write is the interim answer).
