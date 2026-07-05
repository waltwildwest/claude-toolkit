---
name: re-searcher
description: Persistent research vault for Claude Code. Use for any research question ("/research <q>", "research X", "look into", "what's the state of", "compare A and B from sources") and for recall ("have we researched", "what did we find about"). Recall runs first — prior claims come back as dated claims to spot-check, never re-derived. One-off questions get a QUICK unvaulted answer in ~a minute; reusable project research persists plans, per-agent findings, cached sources and quote-verified claims into a git-backed local vault.
---

Research is a state machine: RECALL → CLASSIFY → RUN (quick | light | full) → PERSIST → ANSWER
(the quick path answers unvaulted and skips PERSIST — lazy harvest covers it).
Scripts enforce every rule that matters — when a script prints a warning or an
instruction, follow it; do not improvise around a non-zero exit.

## Setup (top of every research task; shell state does not persist between Bash calls)

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
[ -d "$SKILL_DIR" ] || SKILL_DIR="$HOME/.claude/skills/re-searcher"
[ -d "$SKILL_DIR" ] || SKILL_DIR="$(find "$HOME/.claude/plugins" -type d -path '*/skills/re-searcher' 2>/dev/null | head -1)"
VAULT="${RESEARCH_VAULT_DIR:-$HOME/research-vault}"
command -v node >/dev/null || echo "re-searcher: needs a system Node.js on PATH — research can proceed, but nothing will be vaulted"
```

Missing vault → scripts fail LOUD (never "0 hits"). First contact: ask the user once,
then `node "$SKILL_DIR/vault-init.js" --vault "$VAULT"`, and offer the
`node "$SKILL_DIR/vault-init.js" --allowlist` snippet. Never create the vault silently.

## 1 · RECALL — always first (skip only on an explicit --fresh)

```bash
node "$SKILL_DIR/vault-search.js" <term> <synonym> <synonym2> --vault "$VAULT" --project <cwd-dirname>
```

Use 2–4 probe terms (the question's nouns + likely aliases). By exit code:
- **0 (hit):** serve the vault answer. Claims are *dated claims to spot-check*, never
  verdicts. Full hit → answer now, zero agents: verdict + the printed provenance line.
  Partial hit → carry claims-to-verify + gaps into a run below. Follow any staleness or
  contradiction line the script printed (aging topics get a spot-check, not blind trust).
- **2 (miss):** if near-misses print, ask the user ("closest: X — is that it?"); on a
  recovered near-miss, learn it immediately:
  `node "$SKILL_DIR/vault-search.js" --add-alias <slug> "<term that missed>" --vault "$VAULT"`
- **1:** vault missing or broken — surface the script's message, offer vault-init.

## 2 · CLASSIFY the question — reuse first, then depth

**Axis 1 — reuse: "will this answer be consulted again, or is it a one-off?"** Ask it of
yourself on every question; never block the user with it. One-off signals: "is there a",
"does X exist", "quick check", a yes/no or single-name answer, idle curiosity, no tie to an
ongoing project. Reuse signals: feeds a project decision, comparisons you'll build on, facts
with shelf life you'd hate to re-derive, the question ties to a project the user owns
(the *word* "research" is not a reuse signal — /research invokes this skill for one-offs too).
When unsure, default QUICK — the unvaulted breadcrumb makes correction free.
**Second-ask rule:** a recall near-miss on the topic, or the same topic arriving QUICK a
second time, IS reuse evidence — go LIGHT and vault it.

**Axis 2 — depth:**
- **one-off** (any depth) → QUICK: 0 agents, 2–4 web searches/fetches, nothing vaulted.
- **straightforward + reusable** (one factual answer, single axis) → LIGHT: 0–1 agents, 3–10 tool calls.
- **breadth-first** (compare N things) → FULL: 2–4 agents (one per 1–2 things).
- **depth-first** (open landscape, or the user says "thorough") → FULL: 3–5 agents, hard cap 10.
  Existence checks ("does a tool for X exist?") are NOT depth-first — they're QUICK, or LIGHT
  if the answer will seed a project.
Announce the decomposition in one line as you launch ("N agents: roles — say stop to
adjust") and keep going; block for approval only on unusual cost, never on agent count.

## 3 · QUICK path (one-offs — target ≤1 minute, nothing vaulted)

No run dir, no plan.md, no findings, no claims. (A full recall hit never reaches this path —
§1 already answered it; QUICK runs on a miss or a thin partial.)
1. 2–4 web searches/fetches, independent calls batched in ONE parallel block. The budget is
   a ceiling, not a quota — stop the moment the question is answered.
2. Answer: verdict first, source links inline, then append exactly ONE ignorable line:
   `(unvaulted — "/research save" to keep)`. The Stop-hook inbox pointer means
   `/research save` (or a later `harvest --inbox` drain) can promote this session to a
   vault run — the doctor only cleans dead pointers, it never promotes them.
**No vault yet?** Don't block a one-off on the vault-init dialog: answer, and since there is
no inbox to point at, swap the breadcrumb for
`(no research vault yet — say "set up the research vault" to start keeping findings)`.
The ask-once-then-init rule still governs reusable questions.
If mid-search the question turns out deeper than it looked (conflicting sources, a landscape,
real stakes), say so in one line and upgrade to LIGHT or FULL — never silently stay shallow.

## 4 · LIGHT path (most vaulted runs — keep it ≤1.5x plain asking)

1. `node "$SKILL_DIR/vault-save.js" --new-run --topic <slug> --session <id> --vault "$VAULT"`
2. Write plan.md into the run dir (`node "$SKILL_DIR/vault-init.js" --template plan`) —
   manifest lists your single finding file even when you research inline.
3. Fetch sources: `node "$SKILL_DIR/vault-fetch.js" <url> --vault "$VAULT"` (exit 2 = low
   confidence: better URL, or WebFetch and note provenance: extraction in the finding).
4. Write findings/<role>.md (`--template finding`, ≥500 bytes) and a short synthesis.md.
5. `node "$SKILL_DIR/vault-save.js" <run-dir> --light --session <id> --vault "$VAULT"` —
   NO claims authoring on the light path (the librarian mines them later — §9 doctor, mine pass).
6. Answer: verdict + the provenanceLine from the save JSON.

## 5 · FULL path (fan-out) — details in references/full-path.md

1. Allocate the run (`--new-run`, as above).
2. **Write plan.md BEFORE fan-out** — frontmatter (topic/title/aliases/questions/scope)
   feeds the index; the `manifest` code block (one {role, file} per agent) is the
   completeness contract.
3. Brief each agent from `--template task-spec`: one core objective, scope boundary,
   output file, run-dir path, vault-fetch usage. Agents Write full raw findings to their
   manifest file and return ONLY a ≤2k summary + path. Speed rules for the briefs:
   - **Cheap tier for grunt roles:** searching, fetching and findings-writing are
     mechanical — dispatch those agents on the cheap tier (haiku); synthesis and claims
     stay with you. Use a stronger tier only for an axis that needs judgment calls.
     PASTE the finding template (with frontmatter) into every brief — agents briefed
     without it ship gate-tripping findings regardless of tier.
   - **Hard budget in every brief:** add `BUDGET: ≤12 web searches/fetches — a ceiling,
     not a quota; stop early once your objective is answered. Never cut the vault-fetch
     of a source you cite: uncached sources cannot ground claims.`
   - **Parallel inside agents:** tell agents to batch independent searches/fetches in
     one parallel block instead of sequential calls.
4. **Relay progress:** as each agent lands, give the user its one-line verdict — never go
   silent for the whole fan-out. (This governs DURING the run; §6's silence rule governs
   the final answer.)
5. Gate: `node "$SKILL_DIR/vault-save.js" --check-staging <run-dir>` — exit 2 lists
   missing/stub findings: re-request once or record the hole under Gaps.
6. Read the findings FILES (not the return blurbs) → synthesis.md
   (Verdict · Key claims · Gaps · How to re-verify · Related).
7. Stage claims-staged.jsonl per references/claims.md — copy quotes from the cached
   extractions you actually read; vault-save verifies mechanically and downgrades what
   it can't find (honest provenance beats impressive provenance).
8. `node "$SKILL_DIR/vault-save.js" <run-dir> --session <id> --transcript <path> --vault "$VAULT"`
   then read the JSON: quarantined claims → mention "claims: partial" in the answer.
9. Answer: verdict + provenanceLine.

## 6 · ANSWER format (hard rule)

Verdict first. Then, for anything vaulted (recall hit, light, full): EXACTLY ONE provenance
line — reuse the script's line verbatim
(`vault · <slug> · researched <date> · <freshness>` or `fresh run · N agents · saved to …`).
QUICK instead gets inline source links + its single unvaulted/no-vault line — no run, no
provenance line.
Add lines ONLY on anomaly: near-miss recovery, staleness warning, claims partial or
downgraded, contradiction flag, staging gap, quick→deeper upgrade. Silence is a trust
signal — no term lists, no hit/miss tables in chat (that audit trail is already in
metrics.jsonl).

## 7 · Corrections

Contradicting claims are BOTH served, flagged, dated — never silently pick one. To fix
the record (/research correct): stage supersede/retract/contradict events and apply with
`vault-save.js --events` — procedure in references/correct.md. The registry is
append-only; corrections are events, never edits.

## 8 · Capture without ceremony (harvest)

With a vault present, every session gets a Stop-hook pointer in inbox.jsonl automatically —
pointers only; mining is lazy. Three ways a past session becomes a vault run:
- **/research save** (this session): `node "$SKILL_DIR/vault-harvest.js" --latest --vault "$VAULT"`
  — mines the newest transcript for this project into a light-style run (findings digest +
  harvested summary, NO claims — the librarian upgrades them via the doctor's mine pass, §9). Relay its provenanceLine.
- **/research harvest <session-id>** — same for a specific session; `--inbox` drains every
  pending pointer at once. Harvest is idempotent — already-captured sessions are skipped.
- **Recall breadcrumbs:** a miss may print `unharvested session … may cover this — harvest:`
  lines. Offer to run exactly that command, then re-run the search. Never harvest without a
  recall or user trigger (mining needs a paying customer).
The QUICK path's `(unvaulted — "/research save" to keep)` line is this mechanism: any quick
or ad-hoc answer can be promoted later at zero extra cost. Never a blocking question.

## 9 · LIBRARIAN (/research doctor · export)

Doctor = deterministic sweep first, LLM passes second (never the reverse):
`node "$SKILL_DIR/vault-doctor.js" --vault "$VAULT"` applies the safe fixes (dead
pointers, index compaction, claims-current, alias learning, wayback drain) and prints a
work report; dispatch its LLM passes — promote / freshness / mine / contradictions —
per references/doctor.md. Doctor-granted promotion goes ONLY through
`vault-save.js --events <file> --doctor`. Report one line: fixes + backlog.
`/research export <slug>` → `node "$SKILL_DIR/vault-export.js" <slug> --vault "$VAULT"`
(extraction+link, never raw HTML). Time travel: `vault-search.js … --as-of YYYY-MM-DD`.
Scheduling: offer `vault-doctor.js --schedule-snippet` once, like the allowlist.

Deeper procedures load on demand: references/full-path.md · references/claims.md · references/correct.md · references/harvest.md · references/doctor.md
