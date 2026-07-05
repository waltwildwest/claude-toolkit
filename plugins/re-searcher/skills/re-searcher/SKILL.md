---
name: re-searcher
description: Persistent research vault for Claude Code. Use for any research question ("/research <q>", "research X", "look into", "what's the state of", "compare A and B from sources") and for recall ("have we researched", "what did we find about"). Recall runs first — prior claims come back as dated claims to spot-check, never re-derived; new runs persist plans, per-agent findings, cached sources and quote-verified claims into a git-backed local vault.
---

Research is a state machine: RECALL → CLASSIFY → RUN (light | full) → PERSIST → ANSWER.
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

## 2 · CLASSIFY the question

- **straightforward** (one factual answer, single axis) → LIGHT: 0–1 agents, 3–10 tool calls.
- **breadth-first** (compare N things) → FULL: 2–4 agents (one per 1–2 things).
- **depth-first** ("state of X", open landscape) → FULL: 3–5 agents, hard cap 10.
Announce the decomposition in one line as you launch ("N agents: roles — say stop to
adjust") and keep going; block for approval only on unusual cost, never on agent count.

## 3 · LIGHT path (most runs — keep it ≤1.5x plain asking)

1. `node "$SKILL_DIR/vault-save.js" --new-run --topic <slug> --session <id> --vault "$VAULT"`
2. Write plan.md into the run dir (`node "$SKILL_DIR/vault-init.js" --template plan`) —
   manifest lists your single finding file even when you research inline.
3. Fetch sources: `node "$SKILL_DIR/vault-fetch.js" <url> --vault "$VAULT"` (exit 2 = low
   confidence: better URL, or WebFetch and note provenance: extraction in the finding).
4. Write findings/<role>.md (`--template finding`, ≥500 bytes) and a short synthesis.md.
5. `node "$SKILL_DIR/vault-save.js" <run-dir> --light --session <id> --vault "$VAULT"` —
   NO claims authoring on the light path (the doctor mines them later, stage 3).
6. Answer: verdict + the provenanceLine from the save JSON.

## 4 · FULL path (fan-out) — details in references/full-path.md

1. Allocate the run (`--new-run`, as above).
2. **Write plan.md BEFORE fan-out** — frontmatter (topic/title/aliases/questions/scope)
   feeds the index; the ```manifest block (one {role, file} per agent) is the
   completeness contract.
3. Brief each agent from `--template task-spec`: one core objective, scope boundary,
   output file, run-dir path, vault-fetch usage. Agents Write full raw findings to their
   manifest file and return ONLY a ≤2k summary + path.
4. Gate: `node "$SKILL_DIR/vault-save.js" --check-staging <run-dir>` — exit 2 lists
   missing/stub findings: re-request once or record the hole under Gaps.
5. Read the findings FILES (not the return blurbs) → synthesis.md
   (Verdict · Key claims · Gaps · How to re-verify · Related).
6. Stage claims-staged.jsonl per references/claims.md — copy quotes from the cached
   extractions you actually read; vault-save verifies mechanically and downgrades what
   it can't find (honest provenance beats impressive provenance).
7. `node "$SKILL_DIR/vault-save.js" <run-dir> --session <id> --transcript <path> --vault "$VAULT"`
   then read the JSON: quarantined claims → mention "claims: partial" in the answer.
8. Answer: verdict + provenanceLine.

## 5 · ANSWER format (hard rule)

Verdict first, then EXACTLY ONE provenance line — reuse the script's line verbatim
(`vault · <slug> · researched <date> · <freshness>` or `fresh run · N agents · saved to …`).
Add lines ONLY on anomaly: near-miss recovery, staleness warning, claims partial or
downgraded, contradiction flag, staging gap. Silence is a trust signal — no term lists,
no hit/miss tables in chat (that audit trail is already in metrics.jsonl).

## 6 · Corrections

Contradicting claims are BOTH served, flagged, dated — never silently pick one. To fix
the record (/research correct): stage supersede/retract/contradict events and apply with
`vault-save.js --events` — procedure in references/correct.md. The registry is
append-only; corrections are events, never edits.

## 7 · Capture without ceremony (harvest)

With a vault present, every session gets a Stop-hook pointer in inbox.jsonl automatically —
pointers only; mining is lazy. Three ways a past session becomes a vault run:
- **/research save** (this session): `node "$SKILL_DIR/vault-harvest.js" --latest --vault "$VAULT"`
  — mines the newest transcript for this project into a light-style run (findings digest +
  harvested summary, NO claims — the librarian upgrades them in stage 3). Relay its provenanceLine.
- **/research harvest <session-id>** — same for a specific session; `--inbox` drains every
  pending pointer at once. Harvest is idempotent — already-captured sessions are skipped.
- **Recall breadcrumbs:** a miss may print `unharvested session … may cover this — harvest:`
  lines. Offer to run exactly that command, then re-run the search. Never harvest without a
  recall or user trigger (mining needs a paying customer).
After answering an ad-hoc research question that didn't go through a run, you may append ONE
ignorable line: `(unvaulted — "/research save" to keep)`. Never a blocking question.

Deeper procedures load on demand: references/full-path.md · references/claims.md · references/correct.md · references/harvest.md
