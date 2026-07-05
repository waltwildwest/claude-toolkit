# /research doctor — the librarian's LLM passes

Deterministic half first (or read the report the user already has):

```bash
node "$SKILL_DIR/vault-doctor.js" --vault "$VAULT"
```

Its one JSON line: `fixed` (already applied — report, never redo), `report` (needs a
human or vault-redact), `work` (YOUR four passes, below), `dropped` (cap overflows —
mention when non-zero; overflow contradiction pairs are LOST, not queued — the hwm
advances past them, so raise --max-pairs BEFORE a big sweep, not after).

Ground rules (non-negotiable):
- The work report is the ONLY source of work items — never rescan the vault yourself.
- Everything you produce re-enters through vault-save: verify events via
  `--events <file> --doctor`; supersede/contradict/retract events via `--events`; new
  claims via a staged run or a claims-staged.jsonl re-persist. NEVER append to
  claims.jsonl directly.
- Never invent claim ids — copy them from the work report.
- This is maintenance, not research: skip empty passes, keep tool budgets small.

## 1 · PROMOTE (work.promote — provenance promotion)

Per item {claim, statement, quote, source}: read sources/<source>.md and judge whether
the source genuinely SUPPORTS the statement (not merely contains the quote).
- Supported → stage `{"op":"verify","claim":"<id>","by":"doctor","reason":"<one line>"}`.
- Unsupported / quote out of context → leave it (verbatim-grounded is already honest).
  Actively wrong → stage a retract (by: doctor, reason) instead.
Write events to a temp file with the Write tool, then apply:
`node "$SKILL_DIR/vault-save.js" --events <file> --doctor --vault "$VAULT"`

## 2 · FRESHNESS (work.freshness — adversarial, no special trust)

Per topic: launch ONE freshness agent briefed to REFUTE the listed aging claims
(task-spec template; objective "find evidence these claims are now false or outdated";
3–10 tool calls). Run it as a normal light run on that topic:
- Its findings persist through the standard flow; its claims pass the same vault-save
  gauntlet — freshness agents get no shortcut trust.
- ONLY refutations trigger supersession: stage supersede events (old claim ← new claim
  id from the run's claims.ids) via --events. Confirmation = do nothing.
- Superseded claims stay preserved; recall announces the change (the ↳ annotation);
  the next window re-attacks. That property ends the who-verifies-the-verifier regress.

## 3 · MINE (work.mine — claims from light/harvest runs)

Per {topic, run}: read topics/<topic>/runs/<run>/findings/*.md + synthesis.md. Stage
claims-staged.jsonl IN THAT RUN DIR per references/claims.md (quote only from sources
actually cached; otherwise model-asserted), then re-persist the same run dir:
`node "$SKILL_DIR/vault-save.js" <run-dir> --light --vault "$VAULT"`
Re-persist dedup makes this safe — already-registered statements are skipped.

## 4 · CONTRADICTIONS (work.contradictions — judge, don't delete)

Per pair: do the two statements ACTUALLY contradict (not just overlap)? If yes, stage
`{"op":"contradict","claim":"<a>","by":"<b>","reason":"<one line>"}` via --events.
Both claims keep serving, flagged; resolution stays human (/research correct).

## Report format (chat)

One line: `doctor: <fixed counts> · work: promoted X, freshness-checked Y topic(s)
(Z superseded), mined M run(s), flagged C contradiction(s)`. Anomalies after, only if
present: secrets → recommend `vault-redact.js <source-id>`; orphan/duplicate runs →
list them (deletion is the user's call); dropped counts → say the sweep was capped.

## Scheduling

`node "$SKILL_DIR/vault-doctor.js" --schedule-snippet` prints a cron line (deterministic
half only) and a scheduled-agent recipe (weekly `/research doctor`). Offer it once when
the user first runs the doctor — same pattern as vault-init --allowlist.

## Redaction (on demand, never scheduled)

Secrets hit or bad source: `node "$SKILL_DIR/vault-redact.js" <source-id> --reason "…"` —
deletes files, writes the tombstone, downgrades dependent claims. `vault-redact.js
clm_<id>` retracts one claim. True git-history purge = git filter-repo (manual — say so).
