# Task 13 — final fixes note

Verification pass over the four pre-specified fixes for the re-searcher stage 1 branch.
All four fixes were found already applied verbatim in the working tree (matching an
earlier commit `2b366f3`), so no additional edits were needed beyond confirming the
exact text and re-running the suites.

## Fix 1 — vault-save.js: re-persist safety (refs resolve, events dedupe)

`claimCtx` now also returns `runStatements` / `runClaimIdByStatement` (claims this run
already registered, keyed by statement, with their ids preserved) and `eventKeys` (a
`op|claim|by` key set built from every event-bearing record already in `claims.jsonl`).

- In `persist`'s claims pass: a staged claim whose statement is already in
  `runStatements` is counted as a `duplicate` instead of being re-validated — and if it
  carried a `ref`, that ref is still resolved to the previously-registered claim id, so
  staged events referencing it don't produce phantom rejects on a re-save.
- In `persist`'s events pass: a resolved event whose `op|claim|by` key is already in
  `ctx.eventKeys` is counted as a `duplicate` and skipped (not re-appended, not
  re-validated).
- In `saveEvents` (the standalone `--events` path): the same key-based skip is applied
  before validation, and `ctx.eventKeys` is grown as events are applied, so repeated
  `--events` runs against the same file never duplicate.

Tests updated in `tests/researcher-save.test.sh`: re-persisting a run with human-edited
`topic.md` now asserts notes survive, claims stay at 6, the persist tallies come back as
`rejected===1` (only the one genuinely-still-invalid staged record re-rejects — this is
correct, not a regression, since that record was never registered the first time either),
`events===0`, `duplicates===7`, no phantom `unknown claim: ref:` reject appears, and the
`contradict` event appears exactly once in `claims.jsonl`.

## Fix 2 — claim-validate.js: strip non-string op from claim records

`op` is now deleted from the validated record alongside the existing validator-owned
fields (`quote_method`, `note`). A claim record smuggling a non-string `op` would
otherwise be invisible to `foldClaims` (which treats any op-bearing record as an event),
silently corrupting the fold.

Test added in `tests/researcher-claims.test.sh` (test 10): a claim staged with
`"op":5` (non-string) is accepted as a claim and its persisted record has no `op` key.

## Fix 3 — vault-search.js: addAlias re-reads index record inside the lock

`addAlias` still validates the slug exists outside the lock (so a failing `process.exit`
never leaks the lock directory), but now re-reads the latest index record for that slug
*inside* the lock before merging aliases, falling back to the outside-lock probe only if
nothing newer was found. This closes a race where a concurrent persist appends a newer
index record for the same slug between the validation read and the lock acquisition —
without the re-read, that newer record's merges (aliases/questions added by the other
process) would be lost when `addAlias` appends its own record on top of the stale one.

## Fix 4 — README.md: repository-layout block refreshed

The "Repository layout" section's tree now lists `plugins/re-searcher/` (skills/re-searcher
scripts + commands/research.md) alongside `handoff` and `route`, matching their existing
two-line formatting style. The stale "143 tests" line was replaced with "327 checks across
17 suites (routing, activation, self-tuning, cost, cache, vault extract/quote/fetch/save/
search/views/claims + a contract E2E)". The "install.sh copies from both subdirs" sentence
was updated to "all plugin subdirs" now that there are three plugins.

## Test commands run

```bash
cd /Users/walterhoms/Documents/claude-toolkit/.claude/worktrees/re-searcher-stage1
for t in tests/researcher-save.test.sh tests/researcher-claims.test.sh tests/researcher-search.test.sh tests/researcher-e2e.test.sh; do
  echo "=== $t ==="; bash "$t" 2>/dev/null | tail -1
done
```

## Final tail-line output per suite

```
=== tests/researcher-save.test.sh ===
vault-save: 38 passed, 0 failed
=== tests/researcher-claims.test.sh ===
claim-validate: 16 passed, 0 failed
=== tests/researcher-search.test.sh ===
vault-search: 17 passed, 0 failed
=== tests/researcher-e2e.test.sh ===
e2e: 19 passed, 0 failed
```

Key regression checks in `researcher-save.test.sh` output, confirmed passing:
- `PASS  re-persist: only the still-invalid record re-rejects, event deduped`
- `PASS  contradict registered exactly once`
