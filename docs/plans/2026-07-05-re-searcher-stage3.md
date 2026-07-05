# Re:Searcher Stage 3 (Librarian) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the spec's "Roadmap → 3. Librarian": a working `/research doctor` — a deterministic `vault-doctor.js` (property checks, sweeps, queue drains, compactions) emitting a machine-readable work report that the skill's doctor flow consumes to dispatch the LLM passes (provenance promotion via doctor-sanctioned `verify` events, adversarial freshness for aging `moving` claims, claim mining from light runs, contradiction judging) — plus incremental within-topic contradiction candidates, generated DASHBOARD.md, source/tool-quality scoring into `profiles/`, `vault-search --as-of`, `/research export`, `vault-redact.js`, Wayback enqueue+drain, and subagent-transcript mining in harvest.

**Architecture:** Four new zero-dep scripts (`vault-doctor.js` CLI orchestrator, `doctor-sweeps.js` pure report-only property checks, `doctor-quality.js` pure source/tool scoring, `vault-redact.js`, `vault-export.js`) plus surgical extensions to the shipped surface: `claim-validate.js` gains the doctor-sanctioned `verify` seam (`ctx.doctor`), `vault-lib.foldClaims` learns the script-only `downgrade` event, `vault-save` gains `--events --doctor` and `--fresh`, `vault-search` gains `--as-of` and `--set-volatility`, `vault-fetch` gains the Wayback availability-check/save with queue fallback, `vault-views` gains `regenDashboard`, `vault-harvest` mines subagent transcripts and tallies drain errors. Deterministic script work and LLM passes are strictly separated: the script emits a work report; the skill (references/doctor.md) dispatches agents; every agent-produced claim/event goes through the standard vault-save gauntlet.

**Tech Stack:** Node core only (`fs`, `path`, `crypto`, `zlib`, `http`/`https`, `child_process`). Bash test harness in house style (ok/no counters, mktemp dirs, Windows skip, fixture HTTP servers, `CLAUDE_PROJECTS_DIR` + `WAYBACK_API` env seams).

**Reference spec:** `docs/specs/2026-07-05-re-searcher-design.md` (v2, LOCKED — "Pillar 5 — The librarian", "Vault lifecycle", "Staleness" (web only), "Roadmap → 3. Librarian"). Shipped interfaces this builds on are the actual files under `plugins/re-searcher/skills/re-searcher/` (stage 1+2 plans were amended in-place, so plan==code there; this plan quotes current signatures directly).

**User decisions locked for this stage (2026-07-05):**
- Code-staleness three-valued git checks: **descoped** (no claims carry code locators yet; revisit when code-research runs exist). Document as unimplemented where relevant.
- Wayback: **enqueue + drain built** (vault-fetch fire-and-forget with ~3s cap → wayback-queue.jsonl on failure; doctor drains slowly; `WAYBACK_API` endpoint override for CI).
- Subagent transcripts: **mined in harvest** (glob `<transcript-stem>/subagents/agent-*.jsonl`, fold into the digest, gzip alongside the main transcript).

## Global Constraints

- Zero npm dependencies; Node core only; every script starts `#!/usr/bin/env node` + `'use strict';` + a usage-header comment. Files ≤800 lines.
- CI tests never touch the live network, never read real `~/.claude` (env seams: `CLAUDE_PROJECTS_DIR`, `WAYBACK_API`, `WAYBACK=off`), never require a real Claude Code session, never call an LLM.
- **The doctor is a PROPERTY-CHECKER, not a vibes-reviewer.** `vault-doctor.js` never calls an LLM. It applies deterministic fixes itself (under the advisory lock, auto-committed) and emits work items for the skill's LLM passes. Agent-produced claims/events NEVER bypass validation: promotion events go through `vault-save.js --events <file> --doctor` (the `ctx.doctor` seam), freshness/mined claims go through normal staged runs.
- **Adversarial freshness has no special trust:** freshness agents' claims pass the same validation; only refutations trigger supersession; superseded claims are preserved; recall already announces supersessions (fold + `↳` annotation).
- **Contradiction detection is within topic only (+ topics sharing index aliases), INCREMENTAL from a high-water mark** stored in metrics.jsonl (`kind: "doctor"` records) — never O(n²) over the registry. Caps are never silent: every capped list reports a `dropped` count (spec "no silent caps").
- The doctor never deletes run artifacts or sources (runs are immutable; redaction is `vault-redact.js`'s job, a human decision). Its only destructive fixes are: dead inbox pointers, index compaction (last-record-per-slug, same data), and wayback-queue entries that succeeded or exhausted retries.
- Every mutation happens under the ONE advisory lock (`lib.withLock`) and auto-commits; append-only single-line JSONL appends (metrics, wayback-queue) stay lock-free by precedent. Network probes happen OUTSIDE the lock (withLock's fn is synchronous); only the resulting file mutations happen inside it.
- `withLock(fn)` takes a SYNC fn only. Async work (Wayback HTTP) must complete before entering the lock.
- Exports default to extraction+link, NEVER raw copyrighted HTML (licensing posture).
- "Scheduled" = the user's scheduler: `vault-doctor.js --schedule-snippet` prints cron + Claude scheduled-agent snippets (same pattern as `vault-init --allowlist`); `/research doctor` is the on-demand path.
- SKILL.md stays ≤200 lines (test-enforced; currently 110). Scripts enforce, prose suggests.
- Atomic writes (`lib.atomicWrite`) for all non-append files; fail loud with actionable messages; stdout is ONE JSON line per script run; readers accept `v` ≤ current and preserve unknown fields.
- Commit style `feat:`/`fix:`/`test:`/`docs:`/`refactor:`, NO attribution footers. Windows: tests skip on MINGW/MSYS/CYGWIN.
- **Test authority: `0 failed` + exit 0.** Never add/remove assertions to match a count. All 20 existing suites must not regress.
- Do NOT touch `plugins/route/**` or `plugins/handoff/**` (style reference only). Do NOT push to GitHub.
- OUT of scope: stage 4 (embeddings/smart recall), keyword auto-activation tuning, multi-writer merge, code-staleness git checks (descoped above), `vault-migrate.js` (no v2 schema exists), LinkedIn posts.

## Interfaces already shipped (authoritative — do not break)

- `vault-lib.js` exports: `resolveVault(cliVal,{mustExist})`, `atomicWrite(file,data)`, `readJsonl(file)->{records,skipped,missing}`, `appendJsonl(file,obj)`, `parseFrontmatter(text)->{fields,body}`, `slugify(s)`, `sha8(s)`, `newId(prefix,seed,taken)`, `today()->'YYYY-MM-DD'`, `allocateRun(vault,topicRaw,sessionRaw)->{runId,runDir,topic}`, `msleep(ms)`, `withLock(vault,fn)` (advisory `.lock/` mkdir, stale>5min steal, 10s throw; SYNC fn), `gitCommit(vault,msg)->{committed,warning}` (never throws), `foldClaims(records)->{claims:Map,skippedEvents}` (claim gets `{status,supersededBy[],contradictedBy[],events[]}`; `verify` event → `provenance='externally-verified'`), `resolveTerminal(claimsMap,id)->[claims]` (cycle-safe).
- `claim-validate.js` exports: `validateClaim(rec,ctx)->{ok,record,downgraded,quoteMethod}|{ok:false,reason}`, `validateEvent(rec,ctx)->{ok,record}|{ok:false,reason}`, `createsCycle(edges,claimId,byId)`. `ctx = {vault,runId,topic,date,takenIds:Set,knownIds:Set,supersedeEdges:Map}` (built by vault-save's `claimCtx`). TODAY it rejects op `verify` unconditionally ("doctor-granted (stage 3)") and rejects staged provenance `externally-verified`.
- `vault-save.js` CLI: `<run-dir> [--vault] [--session] [--transcript <p>]... [--light]` | `--new-run --topic <slug>` | `--check-staging <run-dir>` | `--events <file>`. Persist is two-pass (claims then events), batch `ref:` handles, re-persist dedup via `runStatements`+`eventKeys`, quarantine to run's `claims-rejected.jsonl`, JSON incl. `claims.ids`, metrics `{kind:'save',...}` append, auto-commit. `saveEvents` regenerates every event-touched topic + INDEX.
- `vault-search.js` CLI: `<terms...> [--project <slug>] [--json]` | `--add-alias <slug> <alias>`. Scores index (slug/title 3, alias 2, question 1) + claim statements (2), project bonus 5; exit 0 hits / 2 miss (near-miss via trigramSim>0.15 + inbox breadcrumbs) / 1 usage-or-missing-vault. Metrics: `{kind:'recall',ts,terms,project,hits}` and `{kind:'near-miss',ts,terms,near,inbox}`.
- `vault-views.js` exports `regenTopic(vault,slug)`, `regenIndex(vault)`; topic.md preserves the LAST line-anchored `## Notes (human)` section.
- `vault-fetch.js` CLI: `<url> [--vault] [--timeout <ms>] [--max-bytes <n>]`; JSON `{status: stored|duplicate|low-confidence|fetch-error, sourceId, sourcePath, rawPath, extractionHash, ...}`; exits 0/0/2/1. Sources: `sources/<hash8>--<host>--<slug>.md` (frontmatter `v,kind,url,final_url,fetched,title,raw_sha256,extraction_sha256,score,signals,auth_context`), raw at `sources/raw/<hash8>.html`, dedupe via `sources/fetch-log.jsonl` (`norm_url`+`extraction_sha256`).
- `vault-harvest.js` CLI: `<transcript|session-id>` | `--latest [--cwd]` | `--inbox`; idempotent by lineage.json session; drain summary `{drained,harvested,alreadyHarvested,missing,results}`. `transcript-mine.js` exports `mine(file)` → `{version,versionWarning,sessionId,cwd,writes,sources,finals,summary,unknownBlocks,skippedLines,messages}`.
- `lineage.json` shape: `{v,session,run,topic,light,saved,transcripts:[names],agents}`. Index records: `{v,slug,title,aliases,questions,scope,run,date}` (last-record-per-slug wins). Inbox pointers: `{v,kind:'pointer',session,transcript,subagents,cwd,topicGuess,ts,transcript_dies}`.
- Tests: house harness per suite (`ok`/`no` counters, `has()` substring helper, mktemp `W`/vault `V`, Windows skip line). SKILL.md budget + packaging enforced by `tests/researcher-skill.test.sh` (asserts marketplace version — currently `0.2.0`, this stage bumps to `0.3.0`).

## File Structure

```
plugins/re-searcher/
├── skills/re-searcher/
│   ├── claim-validate.js     # Task 1: MODIFY — ctx.doctor seam for op:verify
│   ├── vault-lib.js          # Task 1: MODIFY — foldClaims 'downgrade' op + lock comments
│   ├── vault-save.js         # Task 1: MODIFY — --events --doctor; Task 2: volatility→index, --fresh metric
│   ├── vault-search.js       # Task 2: MODIFY — --as-of, --set-volatility
│   ├── vault-fetch.js        # Task 3: MODIFY — Wayback check/save/queue + frontmatter status
│   ├── doctor-sweeps.js      # Task 4: NEW — pure report-only property checks (module)
│   ├── doctor-quality.js     # Task 5: NEW — source/tool scoring (module)
│   ├── vault-views.js        # Task 5: MODIFY — regenDashboard(vault, doctorSummary)
│   ├── vault-doctor.js       # Task 6: NEW — CLI orchestrator: sweeps → fixes → work report
│   ├── vault-redact.js       # Task 7: NEW — tombstones, retract, dependent downgrades
│   ├── vault-export.js       # Task 8: NEW — topic → single shareable markdown
│   ├── vault-harvest.js      # Task 9: MODIFY — subagent mining + drain errors tally
│   ├── SKILL.md              # Task 10: MODIFY — §8 Librarian (stays ≤200 lines)
│   └── references/doctor.md  # Task 10: NEW — the LLM-pass procedures
├── commands/research.md      # Task 10: MODIFY — doctor + export routed for real
tests/
├── researcher-claims.test.sh    # Task 1: MODIFY (append)
├── researcher-lib.test.sh       # Task 1: MODIFY (append)
├── researcher-save.test.sh      # Task 1+2: MODIFY (append)
├── researcher-search.test.sh    # Task 2: MODIFY (append)
├── researcher-fetch.test.sh     # Task 3: MODIFY (append wayback fixture routes + tests)
├── researcher-sweeps.test.sh    # Task 4: NEW
├── researcher-quality.test.sh   # Task 5: NEW (quality + dashboard)
├── researcher-doctor.test.sh    # Task 6: NEW — incl. the seeded-defects contract E2E
├── researcher-redact.test.sh    # Task 7: NEW
├── researcher-export.test.sh    # Task 8: NEW
├── researcher-harvest.test.sh   # Task 9: MODIFY (append)
├── researcher-skill.test.sh     # Task 10: MODIFY (0.3.0, doctor/export routing, new refs)
.claude-plugin/marketplace.json  # Task 10: MODIFY — re-searcher 0.3.0
README.md                        # Task 10: MODIFY — librarian paragraph
docs/plans/2026-07-05-re-searcher-stage3.md   # this plan
```

Execution notes for the controller: haiku implementers (this plan embeds complete code), sonnet task reviewers, most-capable model for the final whole-branch review only. FIX subagents do the work DIRECTLY — never spawn their own subagents; fixes under ~10 lines the controller applies itself (plan kept in sync, same commit). Keep the ledger at `.superpowers/sdd/progress.md` (gitignored) from Task 1. Amend this plan IN-PLACE for every review-driven fix, same commit as the fix.

---

### Task 1: Doctor-sanctioned `verify` events + `downgrade` fold + lock comments

**Files:**
- Modify: `plugins/re-searcher/skills/re-searcher/claim-validate.js` (validateEvent: `ctx.doctor` seam)
- Modify: `plugins/re-searcher/skills/re-searcher/vault-save.js` (saveEvents: `--doctor` flag → `ctx.doctor`)
- Modify: `plugins/re-searcher/skills/re-searcher/vault-lib.js` (foldClaims: `downgrade` op; two lock comments)
- Modify: `tests/researcher-claims.test.sh`, `tests/researcher-lib.test.sh`, `tests/researcher-save.test.sh` (append)

**Interfaces:**
- Consumes: `cv.validateEvent(rec, ctx)`, `vault-save.js --events <file>` path, `lib.foldClaims`.
- Produces (used by Tasks 6, 7 and references/doctor.md):
  - `validateEvent(rec, ctx)` accepts `op: "verify"` **iff `ctx.doctor === true`**; otherwise rejects with the existing doctor-granted message (now naming the flag). All other validation (known claim id) unchanged. `verify` events need no `by` (defaults handled by caller; record passes through with `v` + `date` added like other events).
  - `vault-save.js --events <file.jsonl> --doctor` sets `ctx.doctor = true`. WITHOUT `--doctor`, staged `verify` is still rejected — the persist path (`claims-staged.jsonl`) NEVER gets doctor powers (persist's `claimCtx` never sets `ctx.doctor`).
  - `foldClaims`: event `{op:"downgrade", claim, to?, reason?}` sets the folded claim's `provenance` to `rec.to || 'model-asserted'` and records the event (status untouched). `downgrade` is SCRIPT-ONLY: `validateEvent` keeps rejecting it as a bad op (OPS list unchanged) — only `vault-redact.js` (Task 7) appends it directly.
  - Staged provenance `externally-verified` remains rejected ALWAYS (even with `--doctor`): promotion is an event on an existing claim, never a stageable field.

- [ ] **Step 1: Append failing tests**

Append to `tests/researcher-lib.test.sh` immediately **before** the final `echo; echo "vault-lib: ..."` line:

````bash
# 12. foldClaims: downgrade event lowers provenance, script-only op
node -e '
const lib = require(process.argv[1]);
const { claims } = lib.foldClaims([
  {v:1, id:"clm_dg1", topic:"t", statement:"s", provenance:"verbatim-grounded"},
  {v:1, op:"downgrade", claim:"clm_dg1", by:"redaction", to:"model-asserted", reason:"source redacted: test"},
  {v:1, op:"downgrade", claim:"clm_missing"},
]);
const c = claims.get("clm_dg1");
if (!c || c.provenance !== "model-asserted") process.exit(1);
if (c.status !== "active") process.exit(2);
if (c.events.length !== 1) process.exit(3);
' "$LIB" && ok "foldClaims downgrade lowers provenance, keeps status" || no "downgrade fold" "rc=$?"
````

Append to `tests/researcher-claims.test.sh` immediately **before** the final `echo; echo "claim-validate: ..."` line:

````bash
# 11. verify events: rejected without ctx.doctor, accepted with it; downgrade never stageable
node -e '
const cv = require(process.argv[1]);
const ctx = { vault: "/nowhere", runId: "r", topic: "t", date: "2026-07-05",
  takenIds: new Set(), knownIds: new Set(["clm_a"]), supersedeEdges: new Map() };
const r1 = cv.validateEvent({op:"verify", claim:"clm_a", by:"doctor"}, ctx);
if (r1.ok || !/doctor/.test(r1.reason)) process.exit(1);
const r2 = cv.validateEvent({op:"verify", claim:"clm_a", by:"doctor"}, Object.assign({}, ctx, {doctor:true}));
if (!r2.ok || r2.record.op !== "verify" || r2.record.v !== 1) process.exit(2);
const r3 = cv.validateEvent({op:"verify", claim:"clm_nope"}, Object.assign({}, ctx, {doctor:true}));
if (r3.ok) process.exit(3);
const r4 = cv.validateEvent({op:"downgrade", claim:"clm_a"}, Object.assign({}, ctx, {doctor:true}));
if (r4.ok) process.exit(4);
' "$CV" && ok "verify needs ctx.doctor; unknown claim still rejected; downgrade never stageable" || no "doctor seam" "rc=$?"
````

Append to `tests/researcher-save.test.sh` immediately **before** the final `echo; echo "vault-save: ..."` line:

````bash
# --- stage 3: --events --doctor (provenance promotion) ---

# doctor-applied verify promotes provenance end-to-end; plain --events still rejects
CID=$(node -e '
const lib = require(process.argv[1]);
const recs = lib.readJsonl(process.argv[2] + "/claims.jsonl").records;
const c = recs.find((r) => r.id && !r.op);
process.stdout.write(c ? c.id : "");
' "$ROOT/plugins/re-searcher/skills/re-searcher/vault-lib.js" "$V")
[ -n "$CID" ] || no "doctor verify precondition" "no claim found in registry"
printf '{"op":"verify","claim":"%s","by":"doctor","reason":"quote re-verified"}\n' "$CID" > "$W/verify-events.jsonl"
OUT=$(node "$S" --events "$W/verify-events.jsonl" --vault "$V"); rcode=$?
has "$OUT" '"applied":0' && ok "plain --events still rejects verify" || no "verify gate" "rc=$rcode $OUT"
OUT=$(node "$S" --events "$W/verify-events.jsonl" --vault "$V" --doctor); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"applied":1'; } && ok "--doctor applies verify" || no "doctor apply" "rc=$rcode $OUT"
node -e '
const lib = require(process.argv[1]);
const { claims } = lib.foldClaims(lib.readJsonl(process.argv[2] + "/claims.jsonl").records);
const c = claims.get(process.argv[3]);
process.exit(c && c.provenance === "externally-verified" ? 0 : 1);
' "$ROOT/plugins/re-searcher/skills/re-searcher/vault-lib.js" "$V" "$CID" \
  && ok "verify event promotes provenance in the fold" || no "promotion fold" ""
OUT=$(node "$S" --events "$W/verify-events.jsonl" --vault "$V" --doctor)
has "$OUT" '"applied":0' && ok "doctor re-apply dedupes (idempotent)" || no "verify dedupe" "$OUT"
````

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/researcher-lib.test.sh; bash tests/researcher-claims.test.sh; bash tests/researcher-save.test.sh`
Expected: every pre-existing assertion PASSES; the new ones FAIL (`downgrade fold`, `doctor seam`, `doctor apply`, `promotion fold`). ("plain --events still rejects verify" may already pass — that is fine.)

- [ ] **Step 3: Implement**

In `plugins/re-searcher/skills/re-searcher/claim-validate.js`, replace the line:

```js
  if (rec.op === 'verify') return { ok: false, reason: 'verify events are doctor-granted (stage 3), not stageable' };
```

with:

```js
  if (rec.op === 'verify' && !ctx.doctor) {
    return { ok: false, reason: 'verify events are doctor-granted — apply via vault-save.js --events <file> --doctor' };
  }
```

Also update the module header comment line `staged provenance/events may not claim what only the doctor grants (externally-verified / verify)` to read `staged provenance may never claim externally-verified; verify events need ctx.doctor (vault-save --events --doctor)`.

In `plugins/re-searcher/skills/re-searcher/vault-save.js`, in `saveEvents(file)`, replace:

```js
    const ctx = claimCtx(vault, 'events', null, lib.today());
```

with:

```js
    const ctx = claimCtx(vault, 'events', null, lib.today());
    if (process.argv.includes('--doctor')) ctx.doctor = true; // the ONLY doctor-powered path — persist never sets this
```

and update the usage strings (both the `die()` usage in `main()` and the header comment) from `--events <file.jsonl> [--vault <dir>]` to `--events <file.jsonl> [--doctor] [--vault <dir>]`.

In `plugins/re-searcher/skills/re-searcher/vault-lib.js`, in `foldClaims`, after the `else if (r.op === 'verify')` line, add:

```js
    else if (r.op === 'downgrade') c.provenance = (typeof r.to === 'string' && r.to) || 'model-asserted';
```

(the event is already pushed to `c.events` above — the reason survives there). Update the fold's block comment from `event records (op) mutate ONLY the folded view` to also name downgrade: `// ... verify promotes provenance; downgrade (script-only, written by vault-redact) lowers it.`

Two documentation-only comments (stage-1/2 ledger leftovers):
- In `withLock`, on the stale-steal `continue;` line, add: `// steal path skips the 10s deadline check — pathological only (needs a fresh stale lock every loop)`
- In `vault-init.js` `main()`, above the `for (const d of [...])` mkdir loop, add: `// init mutates without the vault lock BY CHOICE: it is the only writer of a not-yet-announced vault, and must work before .lock/'s parent exists (fail-soft).`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/researcher-lib.test.sh && bash tests/researcher-claims.test.sh && bash tests/researcher-save.test.sh`
Expected: all three end `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/claim-validate.js plugins/re-searcher/skills/re-searcher/vault-save.js plugins/re-searcher/skills/re-searcher/vault-lib.js plugins/re-searcher/skills/re-searcher/vault-init.js tests/researcher-claims.test.sh tests/researcher-lib.test.sh tests/researcher-save.test.sh
git commit -m "feat: doctor-sanctioned verify events (--events --doctor) + downgrade fold"
```

---

### Task 2: Topic volatility in the index, `vault-save --fresh` metric, `vault-search --as-of` + `--set-volatility`

**Files:**
- Modify: `plugins/re-searcher/skills/re-searcher/vault-save.js` (persist: volatility → index record; `--fresh` → save metric)
- Modify: `plugins/re-searcher/skills/re-searcher/vault-search.js` (`--as-of`, `--set-volatility`, freshness vs. as-of)
- Modify: `tests/researcher-save.test.sh`, `tests/researcher-search.test.sh` (append)

**Interfaces:**
- Consumes: index record shape (last-record-per-slug), `lib.foldClaims`, `lastPerSlug`, the `--add-alias` lock pattern.
- Produces (used by Tasks 5, 6 and the doctor's staleness sweep):
  - Index records MAY carry `volatility: "stable"|"moving"|"live"`. Sources: plan.md frontmatter `volatility:` (validated; invalid → warning + ignored), else the previous index record's value is preserved, else default `"moving"`. Readers treat a missing field as `"moving"`.
  - `vault-search.js --set-volatility <slug> <stable|moving|live>` appends an updated index record under the lock (exactly the `--add-alias` pattern: validate outside, re-read inside, auto-commit `research: set volatility <v> for <slug>`). Prints `{ok:true, slug, volatility}`.
  - `vault-search.js <terms...> --as-of YYYY-MM-DD` filters BOTH index records and claim/event records to `date <= as-of` (string compare; claims AND events carry `date`) before folding — time travel over the append-only files. Freshness ages are computed relative to the as-of date; every provenance line gets `· as-of <date>` appended. Bad format → usage, exit 1. Recall metrics records gain `asOf: <date>|null`.
  - `vault-save.js <run-dir> ... --fresh` records `fresh: true` in the save metrics record (`{kind:'save', ...}`) — the `--fresh` abandonment canary the dashboard counts. Default `fresh: false`.

- [ ] **Step 1: Append failing tests**

Append to `tests/researcher-save.test.sh` immediately **before** the final `echo; echo "vault-save: ..."` line (NOTE: this appends AFTER Task 1's block — keep both):

````bash
# --- stage 3: volatility + --fresh ---
R3=$(node "$S" --new-run --topic vol-topic --session volt1 --vault "$V")
RD3=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).runDir)' "$R3")
cat > "$RD3/plan.md" <<'EOF'
---
topic: vol-topic
title: Volatility test
scope: general
volatility: live
session: volt1
aliases: []
questions: []
---

# Plan

```manifest
[{"role": "solo", "file": "findings/solo.md"}]
```
EOF
{ printf -- '---\nrole: solo\n---\n'; head -c 600 /dev/zero | tr '\0' 'x'; } > "$RD3/findings/solo.md"
OUT=$(node "$S" "$RD3" --light --fresh --session volt1 --vault "$V"); rcode=$?
[ $rcode -eq 0 ] || no "vol persist" "rc=$rcode $OUT"
node -e '
const lib = require(process.argv[1]);
const idx = lib.readJsonl(process.argv[2] + "/index.jsonl").records.filter((r) => r.slug === "vol-topic").pop();
process.exit(idx && idx.volatility === "live" ? 0 : 1);
' "$ROOT/plugins/re-searcher/skills/re-searcher/vault-lib.js" "$V" && ok "plan volatility lands in index" || no "volatility" ""
grep '"kind":"save"' "$V/metrics.jsonl" | grep -q '"fresh":true' && ok "--fresh recorded in save metric" || no "fresh metric" ""

# a second run WITHOUT volatility preserves the previous value (never resets to moving)
R4=$(node "$S" --new-run --topic vol-topic --session volt2 --vault "$V")
RD4=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).runDir)' "$R4")
sed -e 's/^volatility: live$//' -e 's/volt1/volt2/' "$RD3/plan.md" > "$RD4/plan.md"
cp "$RD3/findings/solo.md" "$RD4/findings/solo.md"
node "$S" "$RD4" --light --session volt2 --vault "$V" >/dev/null
node -e '
const lib = require(process.argv[1]);
const idx = lib.readJsonl(process.argv[2] + "/index.jsonl").records.filter((r) => r.slug === "vol-topic").pop();
const m = lib.readJsonl(process.argv[2] + "/metrics.jsonl").records.filter((r) => r.kind === "save").pop();
if (!idx || idx.volatility !== "live") process.exit(1);
if (!m || m.fresh !== false) process.exit(2);
' "$ROOT/plugins/re-searcher/skills/re-searcher/vault-lib.js" "$V" && ok "absent volatility preserved; fresh defaults false" || no "vol preserve" "rc=$?"
````

Append to `tests/researcher-search.test.sh` immediately **before** the final `echo; echo "vault-search: ..."` line:

````bash
# --- stage 3: --as-of + --set-volatility ---
OUT=$(node "$SR" mcp oauth --as-of "$OLD" --vault "$V"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" "as-of $OLD" && has "$OUT" 'fresh (0d)'; } && ok "--as-of serves the historical view" || no "as-of hit" "rc=$rcode $OUT"
OUT=$(node "$SR" mcp oauth --as-of 2020-01-01 --vault "$V"); rcode=$?
[ $rcode -eq 2 ] && ok "--as-of before first run is a miss" || no "as-of miss" "rc=$rcode $OUT"
node "$SR" mcp oauth --as-of "07/05/2026" --vault "$V" >/dev/null 2>&1; [ $? -eq 1 ] && ok "--as-of validates date format" || no "as-of fmt" ""
OUT=$(node "$SR" --set-volatility mcp-auth stable --vault "$V"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"volatility":"stable"'; } && ok "--set-volatility appends" || no "set-vol" "rc=$rcode $OUT"
node -e '
const fs = require("fs");
const recs = fs.readFileSync(process.argv[1] + "/index.jsonl", "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
const last = recs.filter((r) => r.slug === "mcp-auth").pop();
process.exit(last.volatility === "stable" && Array.isArray(last.aliases) && last.aliases.length >= 2 ? 0 : 1);
' "$V" && ok "volatility recorded, prior fields preserved" || no "vol record" ""
node "$SR" --set-volatility mcp-auth hourly --vault "$V" >/dev/null 2>&1; [ $? -eq 1 ] && ok "bad volatility rejected" || no "vol enum" ""
node "$SR" --set-volatility nope-topic stable --vault "$V" >/dev/null 2>&1; [ $? -eq 1 ] && ok "unknown slug rejected" || no "vol slug" ""
````

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/researcher-save.test.sh; bash tests/researcher-search.test.sh`
Expected: pre-existing assertions PASS; new ones FAIL (volatility missing from index, no `fresh` field, `--as-of` unknown flag treated as no-op → "as-of hit" fails on the missing `as-of` suffix, `--set-volatility` falls through to term search).

- [ ] **Step 3: Implement vault-save changes**

In `persist(runDir)`, after `const date = lib.today();` add:

```js
  const VOLATILITY = ['stable', 'moving', 'live'];
  let volatility = null;
  if (fm.volatility !== undefined) {
    volatility = String(fm.volatility);
    if (!VOLATILITY.includes(volatility)) {
      warnings.push('unknown volatility "' + volatility + '" (stable | moving | live) — keeping previous/default');
      volatility = null;
    }
  }
```

Wait — `warnings` is declared after `date`. Put the block immediately AFTER the `const warnings = [];` line instead (order in file: `light`, `date`, `warnings`).

In the tier-1 index append, change the record to carry volatility (previous-value fallback):

```js
    lib.appendJsonl(path.join(vault, 'index.jsonl'), {
      v: 1, slug: topic, title: String(fm.title || topic),
      aliases: uniq([].concat((prevIdx && prevIdx.aliases) || [], fm.aliases || [])),
      questions: uniq([].concat((prevIdx && prevIdx.questions) || [], fm.questions || [])),
      scope: String(fm.scope || 'general'), run: runId, date,
      volatility: volatility || (prevIdx && prevIdx.volatility) || 'moving',
    });
```

In the metrics append inside `persist`, add the fresh flag:

```js
    lib.appendJsonl(path.join(vault, 'metrics.jsonl'), {
      v: 1, kind: 'save', ts: new Date().toISOString(), run: runId, topic, light,
      fresh: process.argv.includes('--fresh'),
      accepted, rejected, downgraded, events, warnings: warnings.length,
    });
```

Update the usage strings (header comment + `die()` in `main()`): `<run-dir> [--vault <dir>] [--session <id>] [--transcript <p>]... [--light] [--fresh]`.

- [ ] **Step 4: Implement vault-search changes**

Replace `function freshness(dateStr) {...}` with:

```js
function freshness(dateStr, nowMs) {
  const t = Date.parse(String(dateStr));
  if (Number.isNaN(t)) return 'age unknown — spot-check before trusting';
  const now = typeof nowMs === 'number' && !Number.isNaN(nowMs) ? nowMs : Date.now();
  const d = Math.max(0, Math.floor((now - t) / 86400000));
  return d <= 30 ? 'fresh (' + d + 'd)' : 'aging (' + d + 'd) — spot-check before trusting';
}
```

Add after `addAlias(vault)` (same pattern, including the outside-the-lock validation comment):

```js
const VOLATILITY = ['stable', 'moving', 'live'];

function setVolatility(vault) {
  const i = process.argv.indexOf('--set-volatility');
  const slug = process.argv[i + 1], vol = process.argv[i + 2];
  if (!slug || slug.startsWith('--') || !VOLATILITY.includes(vol || '')) {
    process.stderr.write('usage: vault-search.js --set-volatility <slug> <stable|moving|live> [--vault <dir>]\n');
    process.exit(1);
  }
  // validate OUTSIDE the lock (reads are lock-free) — process.exit inside
  // withLock's fn would skip its finally and leak the lock dir for 5 minutes
  const probe = lastPerSlug(lib.readJsonl(path.join(vault, 'index.jsonl')).records).get(slug);
  if (!probe) { process.stderr.write('vault-search: no topic "' + slug + '" in the index\n'); process.exit(1); }
  lib.withLock(vault, () => {
    const prev = lastPerSlug(lib.readJsonl(path.join(vault, 'index.jsonl')).records).get(slug) || probe;
    lib.appendJsonl(path.join(vault, 'index.jsonl'), Object.assign({}, prev, { volatility: vol }));
    lib.gitCommit(vault, 'research: set volatility ' + vol + ' for ' + slug);
  });
  process.stdout.write(JSON.stringify({ ok: true, slug, volatility: vol }) + '\n');
}
```

In `main()`:
- after the `--add-alias` dispatch add: `if (process.argv.includes('--set-volatility')) return setVolatility(vault);`
- change `const takesValue = new Set(['--vault', '--project']);` to `new Set(['--vault', '--project', '--as-of'])`
- after `const wantJson = ...` add:

```js
  const asOf = getFlag('--as-of');
  if (asOf && !/^\d{4}-\d{2}-\d{2}$/.test(asOf)) {
    process.stderr.write('vault-search: --as-of wants YYYY-MM-DD\n');
    process.exit(1);
  }
  const asOfMs = asOf ? Date.parse(asOf) : null;
```

- replace the two read lines with the filtered versions:

```js
  let indexRecords = lib.readJsonl(path.join(vault, 'index.jsonl')).records;
  let claimRecords = lib.readJsonl(path.join(vault, 'claims.jsonl')).records;
  if (asOf) {
    // time travel: both claims and events carry date; string compare works on ISO dates
    indexRecords = indexRecords.filter((r) => r && String(r.date || '') <= asOf);
    claimRecords = claimRecords.filter((r) => r && String(r.date || '') <= asOf);
  }
  const index = lastPerSlug(indexRecords);
  const { claims } = lib.foldClaims(claimRecords);
```

- in the recall metrics append, add `asOf: asOf || null` after `project: project || null`.
- replace the `provLine` definition with:

```js
  const provLine = (b) => 'vault · ' + b.slug + ' · researched ' + (b.rec.date || 'unknown') + ' · '
    + freshness(b.rec.date, asOfMs) + (asOf ? ' · as-of ' + asOf : '');
```

- update the usage string in `main()` and the header comment: `<terms...> [--vault <dir>] [--project <slug>] [--as-of YYYY-MM-DD] [--json]` and add the `--set-volatility` form.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/researcher-save.test.sh && bash tests/researcher-search.test.sh && bash tests/researcher-e2e.test.sh`
Expected: all end `0 failed`, exit 0 (e2e guards against accidental persist regressions).

- [ ] **Step 6: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-save.js plugins/re-searcher/skills/re-searcher/vault-search.js tests/researcher-save.test.sh tests/researcher-search.test.sh
git commit -m "feat: topic volatility, --fresh canary metric, vault-search --as-of + --set-volatility"
```

---

### Task 3: Wayback enqueue in vault-fetch (availability check → save → queue fallback)

**Files:**
- Modify: `plugins/re-searcher/skills/re-searcher/vault-fetch.js`
- Modify: `tests/researcher-fetch.test.sh` (one route tweak + `WAYBACK=off` guard + appended tests with a second fixture server)

**Interfaces:**
- Consumes: existing `fetchRaw(u, timeoutMs, maxBytes, redirects, cb)` (follows redirects, gzip, non-200 → error), `normalizeUrl`, the stored-source flow.
- Produces (used by Task 6's drain and Task 5's dashboard):
  - Env seams: `WAYBACK=off` disables entirely (status `"off"`); `WAYBACK_API=<base>` overrides BOTH endpoint hosts (availability `<base>/wayback/available?url=<enc>`, save `<base>/save/<url>`; defaults `https://archive.org` / `https://web.archive.org`); `WAYBACK_TIMEOUT_MS` (default 3000).
  - Per-source status recorded in source frontmatter (`wayback: exists|requested|queued|failed|off`, plus `wayback_url:` when a snapshot exists), in the fetch-log record (`wayback` field), and in the stored JSON output (`wayback` field). Statuses per spec Pillar 2.
  - Queue records appended (lock-free single line, `fetch-log` precedent) to `wayback-queue.jsonl`: `{v:1, url:<norm>, source_id, ts, attempts:0}`. ONLY the failure path enqueues.
  - Wayback runs ONLY on the `stored` path (never duplicate/low-confidence/fetch-error) and can never fail the fetch — every error degrades to `queued` (or `failed` if even the queue append throws).

- [ ] **Step 1: Adjust existing tests + append failing tests**

In `tests/researcher-fetch.test.sh`:

(a) After the line `W="$(mktemp -d)"; V="$W/vault"; mkdir -p "$V"` insert:

```bash
export WAYBACK=off   # pre-existing tests must never hit live archive.org; wayback tests re-enable per-call
```

(b) In the fixture `server.js` heredoc, change the article route line

```js
  if (req.url === '/article') {
```

to

```js
  if (req.url.split('?')[0] === '/article') {
```

(query-string variants of /article let the wayback tests dodge the url+hash dedupe).

(c) Append immediately **before** the final `echo; echo "vault-fetch: ..."` line:

````bash
# --- stage 3: wayback enqueue ---
cat > "$W/wb-server.js" <<'EOF'
'use strict';
const http = require('http');
const srv = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/wayback/available') {
    const target = u.searchParams.get('url') || '';
    res.writeHead(200, { 'content-type': 'application/json' });
    if (target.includes('wb%3Dknown') || target.includes('wb=known')) {
      return res.end(JSON.stringify({ archived_snapshots: { closest: { available: true, url: 'http://archive.example/snap/1' } } }));
    }
    return res.end(JSON.stringify({ archived_snapshots: {} }));
  }
  if (u.pathname.startsWith('/save/')) {
    if (req.url.includes('wb=save')) { res.writeHead(200); return res.end('saved'); }
    res.writeHead(429); return res.end('slow down');
  }
  res.writeHead(404); res.end();
});
srv.listen(0, '127.0.0.1', () => console.log(srv.address().port));
EOF
node "$W/wb-server.js" > "$W/wbport.txt" & WBSRV=$!
trap 'kill $SRV $WBSRV 2>/dev/null' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$W/wbport.txt" ] && break; sleep 0.2; done
WBBASE="http://127.0.0.1:$(cat "$W/wbport.txt")"

# 8. snapshot exists -> wayback: exists + wayback_url in frontmatter
OUT=$(WAYBACK= WAYBACK_API="$WBBASE" node "$F" "$BASE/article?wb=known" --vault "$V"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"wayback":"exists"'; } && ok "wayback exists detected" || no "wb exists" "rc=$rcode $OUT"
SRCP=$(node -e 'console.log(JSON.parse(process.argv[1]).sourcePath)' "$OUT")
grep -q '^wayback: exists$' "$SRCP" && grep -q '^wayback_url: http://archive.example/snap/1$' "$SRCP" \
  && ok "wayback status + url in frontmatter" || no "wb frontmatter" "$(head -20 "$SRCP")"

# 9. no snapshot, save accepted -> requested
OUT=$(WAYBACK= WAYBACK_API="$WBBASE" node "$F" "$BASE/article?wb=save" --vault "$V")
has "$OUT" '"wayback":"requested"' && ok "wayback save requested" || no "wb requested" "$OUT"

# 10. no snapshot, save fails (429) -> queued with attempts:0 and the source id
OUT=$(WAYBACK= WAYBACK_API="$WBBASE" node "$F" "$BASE/article?wb=fail" --vault "$V"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"wayback":"queued"'; } && ok "wayback failure queues" || no "wb queued" "rc=$rcode $OUT"
grep 'wb%3Dfail\|wb=fail' "$V/wayback-queue.jsonl" | grep -q '"attempts":0' && ok "queue record written" || no "wb queue file" "$(cat "$V/wayback-queue.jsonl" 2>/dev/null)"
QN=$(grep -c . "$V/wayback-queue.jsonl")

# 11. WAYBACK=off -> status off, no queue growth, no network attempt
OUT=$(WAYBACK=off node "$F" "$BASE/article?wb=off" --vault "$V"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"wayback":"off"' && [ "$(grep -c . "$V/wayback-queue.jsonl")" = "$QN" ]; } \
  && ok "WAYBACK=off skips cleanly" || no "wb off" "rc=$rcode $OUT"

# 12. duplicate fetch never re-runs wayback (same URL as test 8)
OUT=$(WAYBACK= WAYBACK_API="http://127.0.0.1:1" node "$F" "$BASE/article?wb=known" --vault "$V"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"duplicate"'; } && ok "duplicate skips wayback" || no "wb dup" "rc=$rcode $OUT"
````

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/researcher-fetch.test.sh`
Expected: tests 1–7 PASS (with `WAYBACK=off` exported they are unaffected even before implementation); tests 8–12 FAIL (`"wayback"` absent from JSON).

- [ ] **Step 3: Implement**

In `plugins/re-searcher/skills/re-searcher/vault-fetch.js`:

After the `MAX_REDIRECTS` constant add:

```js
const WAYBACK_OFF = (process.env.WAYBACK || '').toLowerCase() === 'off';
const WB_BASE = process.env.WAYBACK_API || null;
const WB_AVAIL = (WB_BASE || 'https://archive.org') + '/wayback/available?url=';
const WB_SAVE = (WB_BASE || 'https://web.archive.org') + '/save/';
const WB_TIMEOUT = Number(process.env.WAYBACK_TIMEOUT_MS || 3000);

// Wayback (spec Pillar 2): availability-check first (snapshot exists -> record
// it); else fire the save with a short cap; on failure/429 append to
// wayback-queue.jsonl, drained slowly by the doctor. NEVER on the critical
// path: every error degrades to a queue entry, the fetch result stands.
function waybackStep(vault, normUrl, sourceId, cb) {
  if (WAYBACK_OFF) return cb({ status: 'off' });
  fetchRaw(WB_AVAIL + encodeURIComponent(normUrl), WB_TIMEOUT, 512 * 1024, 0, (err, res) => {
    if (!err) {
      try {
        const j = JSON.parse(res.body.toString('utf8'));
        const c = j && j.archived_snapshots && j.archived_snapshots.closest;
        if (c && c.available && c.url) return cb({ status: 'exists', snapshot: String(c.url) });
      } catch (_e) { /* unparseable availability answer — fall through to save */ }
    }
    fetchRaw(WB_SAVE + normUrl, WB_TIMEOUT, 512 * 1024, 0, (err2) => {
      if (!err2) return cb({ status: 'requested' });
      try {
        fs.appendFileSync(path.join(vault, 'wayback-queue.jsonl'),
          JSON.stringify({ v: 1, url: normUrl, source_id: sourceId, ts: new Date().toISOString(), attempts: 0 }) + '\n');
        return cb({ status: 'queued' });
      } catch (_e) { return cb({ status: 'failed' }); }
    });
  });
}
```

In `main()`: add `wayback: null` to the `base` object. Then wrap the tail of the stored path (everything from the `const fetched = ...` line through the final `emit(...)`) in the wayback callback, so the status lands in the frontmatter and log:

```js
    waybackStep(vault, normUrl, id, (wb) => {
      const fetched = new Date().toISOString();
      const fmLines = ['---', 'v: 1', 'kind: web', 'url: ' + url, 'final_url: ' + res.finalUrl,
        'fetched: ' + fetched, 'title: ' + JSON.stringify(ext.title), 'raw_sha256: ' + rawSha,
        'extraction_sha256: ' + extSha, 'score: ' + conf.score,
        'signals: ' + JSON.stringify(conf.signals), 'auth_context: public',
        'wayback: ' + wb.status];
      if (wb.snapshot) fmLines.push('wayback_url: ' + wb.snapshot);
      const fm = fmLines.concat(['---', '']).join('\n');
      atomicWrite(sourcePath, fm + ext.markdown + '\n');
      atomicWrite(rawPath, res.body);
      fs.appendFileSync(logFile, JSON.stringify({ v: 1, source_id: id, source_path: sourcePath, norm_url: normUrl, url, final_url: res.finalUrl, raw_sha256: rawSha, extraction_sha256: extSha, fetched, score: conf.score, wayback: wb.status }) + '\n');
      emit(Object.assign(filled, { status: 'stored', sourceId: id, sourcePath, rawPath, wayback: wb.status }), 0);
    });
```

(the `hash8`/`host`/`id`/`sourcePath`/`rawPath` computations stay where they are, BEFORE the `waybackStep` call — the queue record needs the id). Update the header comment: add `wayback` to the JSON field list and mention the env seams.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/researcher-fetch.test.sh`
Expected: `0 failed`, exit 0, including tests 8–12.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-fetch.js tests/researcher-fetch.test.sh
git commit -m "feat: wayback availability-check/save in vault-fetch with queue fallback"
```

---

### Task 4: `doctor-sweeps.js` — report-only property checks (module)

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/doctor-sweeps.js`
- Create: `tests/researcher-sweeps.test.sh`

**Interfaces:**
- Consumes: `lib.readJsonl`, `lib.parseFrontmatter`, `lib.foldClaims` output shape, `quote-verify.verify(quote, source) -> {verified, sourceQuote, method}`.
- Produces (consumed by Task 6's vault-doctor.js):
  - `listRunDirs(vault) -> [{topic, run, dir}]` (every directory under `topics/*/runs/`).
  - `sweepOrphanRuns(vault) -> [{topic, run, reason}]` — run dirs with NO `lineage.json` (persist never completed: harvest-failure orphans, crash leftovers).
  - `sweepDuplicateSessions(vault) -> [{session, runs: ["topic/run", ...]}]` — sessions appearing in >1 lineage.json (the stage-2 unlocked-idempotence race's cleanup detector). Sessions `'unknown'`/missing are skipped.
  - `sweepSourceRefs(vault, claimsMap) -> {broken: [{claim, source}], tombstoned: [{claim, source}]}` — ACTIVE claims with grounded provenance (`verbatim-grounded`/`externally-verified`) whose `sources/<id>.md` is missing; a `sources/<id>.tombstone.json` beside it makes it `tombstoned` (resolution, not breakage).
  - `sweepQuotes(vault, claimsMap) -> {checked, passed, failed: [{claim, source}]}` — deterministic quote-ladder re-check for active grounded claims with a quote and an existing source.
  - `sweepSecrets(vault) -> [{file, pattern}]` over `sources/raw/*.html`; exported `SECRET_PATTERNS` list of `[name, regex]`.
  - `schemaCensus(vault) -> {<file>: {records, skipped, versions, unknownV, aboveCurrent}}` for the five root JSONL files.
  - `deadInboxPointers(vault) -> [{session, transcript}]` — pointers whose transcript file no longer exists.
  - Everything is PURE READ: no mutation, no lock, no process.exit, no LLM.

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-sweeps.test.sh`:

````bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/doctor-sweeps.js (module).
# Run: bash tests/researcher-sweeps.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/plugins/re-searcher/skills/re-searcher"
SW="$SK/doctor-sweeps.js"
I="$SK/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-sweeps tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1
echo "doctor-sweeps tests"

# Seed runs: one healthy, one orphan (no lineage), two sharing a session
mkdir -p "$V/topics/topic-a/runs/2026-07-01a-good/findings" \
         "$V/topics/topic-a/runs/2026-07-02a-orph/findings" \
         "$V/topics/topic-b/runs/2026-07-03a-dup1" \
         "$V/topics/topic-b/runs/2026-07-03b-dup2"
echo '{"v":1,"session":"sess-good","run":"2026-07-01a-good","topic":"topic-a"}' > "$V/topics/topic-a/runs/2026-07-01a-good/lineage.json"
echo '# plan' > "$V/topics/topic-a/runs/2026-07-02a-orph/plan.md"
echo '{"v":1,"session":"sess-dup","run":"2026-07-03a-dup1","topic":"topic-b"}' > "$V/topics/topic-b/runs/2026-07-03a-dup1/lineage.json"
echo '{"v":1,"session":"sess-dup","run":"2026-07-03b-dup2","topic":"topic-b"}' > "$V/topics/topic-b/runs/2026-07-03b-dup2/lineage.json"

# Seed sources + claims: good quote, bad quote, missing source, tombstoned source, v2 record, torn line
cat > "$V/sources/srcok.md" <<'EOF'
---
v: 1
kind: web
---
The MCP spec requires OAuth 2.1 with PKCE for all remote servers.
EOF
printf '{"v":1,"source":"srcgone2","reason":"test","date":"2026-07-01"}\n' > "$V/sources/srcgone2.tombstone.json"
cat >> "$V/claims.jsonl" <<'EOF'
{"v":1,"id":"clm_ok","topic":"topic-a","statement":"OAuth 2.1 required","quote":"requires OAuth 2.1 with PKCE","source":"srcok","provenance":"verbatim-grounded","date":"2026-07-01"}
{"v":1,"id":"clm_badq","topic":"topic-a","statement":"Bearer allowed","quote":"bearer tokens are fine forever","source":"srcok","provenance":"verbatim-grounded","date":"2026-07-01"}
{"v":1,"id":"clm_gone","topic":"topic-a","statement":"claim on missing source","quote":"x","source":"srcgone1","provenance":"verbatim-grounded","date":"2026-07-01"}
{"v":1,"id":"clm_tomb","topic":"topic-a","statement":"claim on redacted source","quote":"x","source":"srcgone2","provenance":"verbatim-grounded","date":"2026-07-01"}
{"v":2,"id":"clm_v2","topic":"topic-a","statement":"future schema","provenance":"model-asserted","date":"2026-07-01"}
not json at all
EOF

# Seed inbox (one live pointer, one dead) + raw html (one secret, one clean)
printf '%s\n' "{\"v\":1,\"kind\":\"pointer\",\"session\":\"alive\",\"transcript\":\"$V/sources/srcok.md\"}" >> "$V/inbox.jsonl"
printf '{"v":1,"kind":"pointer","session":"dead","transcript":"/nonexistent/t.jsonl"}\n' >> "$V/inbox.jsonl"
printf '<html>key AKIAABCDEFGHIJKLMNOP here</html>' > "$V/sources/raw/aaaa1111.html"
printf '<html>clean page</html>' > "$V/sources/raw/bbbb2222.html"

node -e '
const path = require("path");
const lib = require(path.join(process.argv[2], "vault-lib.js"));
const sw = require(process.argv[1]);
const V = process.argv[3];
const { claims } = lib.foldClaims(lib.readJsonl(path.join(V, "claims.jsonl")).records);
const orph = sw.sweepOrphanRuns(V);
if (orph.length !== 1 || orph[0].run !== "2026-07-02a-orph") process.exit(1);
const dup = sw.sweepDuplicateSessions(V);
if (dup.length !== 1 || dup[0].session !== "sess-dup" || dup[0].runs.length !== 2) process.exit(2);
const refs = sw.sweepSourceRefs(V, claims);
if (refs.broken.length !== 1 || refs.broken[0].source !== "srcgone1") process.exit(3);
if (refs.tombstoned.length !== 1 || refs.tombstoned[0].source !== "srcgone2") process.exit(4);
const q = sw.sweepQuotes(V, claims);
if (q.checked !== 2 || q.passed !== 1 || q.failed.length !== 1 || q.failed[0].claim !== "clm_badq") process.exit(5);
const sec = sw.sweepSecrets(V);
if (sec.length !== 1 || sec[0].pattern !== "aws-access-key" || !/aaaa1111/.test(sec[0].file)) process.exit(6);
const dead = sw.deadInboxPointers(V);
if (dead.length !== 1 || dead[0].session !== "dead") process.exit(7);
const census = sw.schemaCensus(V);
const cc = census["claims.jsonl"];
if (!cc || cc.skipped !== 1 || cc.aboveCurrent !== 1) process.exit(8);
if (!sw.listRunDirs(V).length === 4) process.exit(9);
' "$SW" "$SK" "$V" 2>/dev/null \
  && ok "all sweeps find exactly the seeded defects" || no "sweeps" "rc=$?"

# Sweeps are pure: nothing in the vault changed
node -e '
const fs = require("fs");
process.exit(fs.existsSync(process.argv[1] + "/.lock") ? 1 : 0);
' "$V" && ok "no lock left, no mutation" || no "purity" ""

echo; echo "doctor-sweeps: $pass passed, $fail failed"; [ $fail -eq 0 ]
````

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/researcher-sweeps.test.sh`
Expected: FAIL — `Cannot find module .../doctor-sweeps.js`.

- [ ] **Step 3: Implement `doctor-sweeps.js`**

```js
#!/usr/bin/env node
'use strict';
// doctor-sweeps — the librarian's report-only property checks (module only).
// Every function READS and returns findings; nothing mutates, locks, exits,
// or calls an LLM. vault-doctor.js runs these and folds the results into its
// work report; fixes live there, never here.
//
// Module API (vault = absolute path; claimsMap = lib.foldClaims(...).claims):
//   listRunDirs(vault) sweepOrphanRuns(vault) sweepDuplicateSessions(vault)
//   sweepSourceRefs(vault, claimsMap) sweepQuotes(vault, claimsMap)
//   sweepSecrets(vault) schemaCensus(vault) deadInboxPointers(vault)

const fs = require('fs');
const path = require('path');
const lib = require('./vault-lib');
const { verify } = require('./quote-verify');

const GROUNDED = ['verbatim-grounded', 'externally-verified'];

function listRunDirs(vault) {
  const out = [];
  const topics = path.join(vault, 'topics');
  if (!fs.existsSync(topics)) return out;
  for (const t of fs.readdirSync(topics)) {
    if (t.startsWith('.')) continue;
    const runs = path.join(topics, t, 'runs');
    if (!fs.existsSync(runs)) continue;
    for (const r of fs.readdirSync(runs)) {
      const dir = path.join(runs, r);
      try { if (!fs.statSync(dir).isDirectory()) continue; } catch (_e) { continue; }
      out.push({ topic: t, run: r, dir });
    }
  }
  return out;
}

// Orphaned run (spec Pillar 1): staged artifacts present, persist never
// completed — harvest-failure and crash leftovers. Report-only: runs are
// immutable; deleting one is a human decision.
function sweepOrphanRuns(vault) {
  const out = [];
  for (const e of listRunDirs(vault)) {
    if (fs.existsSync(path.join(e.dir, 'lineage.json'))) continue;
    out.push({ topic: e.topic, run: e.run, reason: 'no lineage.json (persist never completed)' });
  }
  return out;
}

// Two runs sharing a session id = the stage-2 unlocked-idempotence race or a
// manual double-persist.
function sweepDuplicateSessions(vault) {
  const bySession = new Map();
  for (const e of listRunDirs(vault)) {
    const lin = path.join(e.dir, 'lineage.json');
    if (!fs.existsSync(lin)) continue;
    let session = null;
    try { session = JSON.parse(fs.readFileSync(lin, 'utf8')).session; } catch (_e) { continue; }
    if (!session || session === 'unknown') continue;
    const list = bySession.get(session) || [];
    list.push(e.topic + '/' + e.run);
    bySession.set(session, list);
  }
  return Array.from(bySession.entries()).filter(([, runs]) => runs.length > 1)
    .map(([session, runs]) => ({ session, runs }));
}

// Grounded active claims must resolve their source; a tombstone beside a
// missing source is RESOLUTION (redaction happened), not breakage.
function sweepSourceRefs(vault, claimsMap) {
  const broken = [], tombstoned = [];
  for (const c of claimsMap.values()) {
    if (c.status !== 'active' || !c.source) continue;
    if (!GROUNDED.includes(c.provenance)) continue;
    if (fs.existsSync(path.join(vault, 'sources', c.source + '.md'))) continue;
    if (fs.existsSync(path.join(vault, 'sources', c.source + '.tombstone.json'))) {
      tombstoned.push({ claim: c.id, source: c.source });
    } else broken.push({ claim: c.id, source: c.source });
  }
  return { broken, tombstoned };
}

// Deterministic re-run of the quote ladder: a verbatim-grounded quote that no
// longer verifies against its cached extraction is a real defect.
function sweepQuotes(vault, claimsMap) {
  let checked = 0, passed = 0;
  const failed = [];
  for (const c of claimsMap.values()) {
    if (c.status !== 'active' || !GROUNDED.includes(c.provenance)) continue;
    if (!c.source || !c.quote) continue;
    const p = path.join(vault, 'sources', c.source + '.md');
    if (!fs.existsSync(p)) continue; // sweepSourceRefs owns that defect
    checked++;
    const body = lib.parseFrontmatter(fs.readFileSync(p, 'utf8')).body;
    if (verify(String(c.quote), body).verified) passed++;
    else failed.push({ claim: c.id, source: c.source });
  }
  return { checked, passed, failed };
}

const SECRET_PATTERNS = [
  ['aws-access-key', /AKIA[0-9A-Z]{16}/],
  ['github-token', /gh[pousr]_[A-Za-z0-9]{30,}/],
  ['slack-token', /xox[baprs]-[A-Za-z0-9-]{10,}/],
  ['private-key', /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ['anthropic-key', /sk-ant-[A-Za-z0-9-]{20,}/],
  ['bearer-header', /[Aa]uthorization:\s*Bearer\s+[A-Za-z0-9._-]{20,}/],
];

// Raw HTML enters git history — this sweep is the safety net behind the
// store-time scrub. Findings recommend vault-redact; NEVER auto-delete.
function sweepSecrets(vault) {
  const out = [];
  const rawDir = path.join(vault, 'sources', 'raw');
  if (!fs.existsSync(rawDir)) return out;
  for (const f of fs.readdirSync(rawDir)) {
    if (!/\.html$/i.test(f)) continue;
    let text;
    try { text = fs.readFileSync(path.join(rawDir, f), 'utf8'); } catch (_e) { continue; }
    for (const [name, re] of SECRET_PATTERNS) {
      if (re.test(text)) out.push({ file: 'sources/raw/' + f, pattern: name });
    }
  }
  return out;
}

const CENSUS_FILES = ['index.jsonl', 'claims.jsonl', 'metrics.jsonl', 'inbox.jsonl', 'wayback-queue.jsonl'];
const CURRENT_V = 1;

function schemaCensus(vault) {
  const out = {};
  for (const f of CENSUS_FILES) {
    const { records, skipped, missing } = lib.readJsonl(path.join(vault, f));
    if (missing) continue;
    const versions = {};
    let unknownV = 0, aboveCurrent = 0;
    for (const r of records) {
      const v = r && r.v;
      if (typeof v !== 'number') { unknownV++; continue; }
      versions[v] = (versions[v] || 0) + 1;
      if (v > CURRENT_V) aboveCurrent++;
    }
    out[f] = { records: records.length, skipped, versions, unknownV, aboveCurrent };
  }
  return out;
}

function deadInboxPointers(vault) {
  return lib.readJsonl(path.join(vault, 'inbox.jsonl')).records
    .filter((p) => p && p.kind === 'pointer')
    .filter((p) => !p.transcript || !fs.existsSync(p.transcript))
    .map((p) => ({ session: p.session, transcript: p.transcript || null }));
}

module.exports = { listRunDirs, sweepOrphanRuns, sweepDuplicateSessions, sweepSourceRefs, sweepQuotes, sweepSecrets, schemaCensus, deadInboxPointers, SECRET_PATTERNS };
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/researcher-sweeps.test.sh`
Expected: `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/doctor-sweeps.js tests/researcher-sweeps.test.sh
git commit -m "feat: doctor-sweeps — report-only vault property checks"
```

---

### Task 5: `doctor-quality.js` scoring + `vault-views.regenDashboard`

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/doctor-quality.js`
- Modify: `plugins/re-searcher/skills/re-searcher/vault-views.js` (add `regenDashboard`, export it)
- Create: `tests/researcher-quality.test.sh`

**Interfaces:**
- Consumes: `lib.foldClaims` output shape (folded claim: `{status, provenance, tool, source, note, events[], supersededBy[], contradictedBy[], statement, date}`), index/metrics record shapes, `lib.atomicWrite`, `lastPerSlug` (module-local in vault-views).
- Produces (consumed by Task 6):
  - `doctor-quality.js`: `scoreQuality(claimsMap) -> {tools, hosts, totals}` — per key a bucket `{claims, live, verified, downgraded, superseded, retracted}`. `live` = active AND never downgraded (note match or `downgrade` event). Host derives from the sourceId's second `--` segment (`hostOf(source)`, `'(none)'` fallback). `renderProfile(q, generatedDate) -> markdown` with Tools + Hosts tables and a fenced `Machine block` JSON line.
  - `vault-views.regenDashboard(vault, doctorSummary|null) -> dashboardPath` — atomically writes `DASHBOARD.md` from index/claims/metrics/runs: vault totals, active-provenance histogram, recall count + hit rate + near-misses, `--fresh` canary by month (table), Attention section (contradicted claims ≤5, stale `moving` topics ≤5 [index date >30d old], doctor backlog line when `doctorSummary.work` present), Belief changes (last 5 supersede events, `~~was~~ → ids`), Recent runs (last 5, markdown links), last-doctor-run line, link to INDEX.md. Safe to regenerate always (no human-owned section).

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-quality.test.sh`:

````bash
#!/usr/bin/env bash
# Tests for doctor-quality.js (module) + vault-views.regenDashboard.
# Run: bash tests/researcher-quality.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/plugins/re-searcher/skills/re-searcher"
Q="$SK/doctor-quality.js"
VW="$SK/vault-views.js"
I="$SK/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-quality tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1
echo "doctor-quality + dashboard tests"

# 1. scoreQuality + renderProfile on a synthetic fold
node -e '
const q = require(process.argv[1]);
const claims = new Map();
const mk = (id, extra) => Object.assign({ id, status: "active", supersededBy: [], contradictedBy: [], events: [],
  provenance: "model-asserted", tool: "websearch", source: "aaaa1111--spec-example--page", statement: "s", date: "2026-07-01" }, extra);
claims.set("c1", mk("c1", {}));
claims.set("c2", mk("c2", { provenance: "externally-verified", tool: "gh" }));
claims.set("c3", mk("c3", { status: "retracted" }));
claims.set("c4", mk("c4", { note: "downgraded: quote not found in x" }));
claims.set("c5", mk("c5", { source: null, tool: undefined, events: [{op:"downgrade", claim:"c5"}] }));
const s = q.scoreQuality(claims);
if (s.tools.websearch.claims !== 3) process.exit(1);
if (s.tools.websearch.live !== 1) process.exit(2);
if (s.tools.gh.verified !== 1) process.exit(3);
if (s.tools.unknown.downgraded !== 1) process.exit(4);
if (s.hosts["spec-example"].claims !== 4) process.exit(5);
if (s.hosts["(none)"].claims !== 1) process.exit(6);
if (s.totals.claims !== 5 || s.totals.retracted !== 1 || s.totals.downgraded !== 2) process.exit(7);
const md = q.renderProfile(s, "2026-07-05");
if (!/\| websearch \| 3 \|/.test(md) || !/Machine block/.test(md) || !/"v":1/.test(md)) process.exit(8);
' "$Q" && ok "scoreQuality buckets + renderProfile tables" || no "quality" "rc=$?"

# 2. regenDashboard with real numbers
OLD=$(node -e 'const d=new Date(Date.now()-45*86400000); console.log(d.toISOString().slice(0,10))')
cat >> "$V/index.jsonl" <<EOF
{"v":1,"slug":"old-moving","title":"Old Moving","aliases":[],"questions":[],"scope":"general","run":"r1","date":"$OLD","volatility":"moving"}
{"v":1,"slug":"new-stable","title":"New Stable","aliases":[],"questions":[],"scope":"general","run":"r2","date":"2026-07-05","volatility":"stable"}
EOF
cat >> "$V/claims.jsonl" <<'EOF'
{"v":1,"id":"clm_a","topic":"old-moving","statement":"old belief","provenance":"model-asserted","date":"2026-05-01"}
{"v":1,"id":"clm_b","topic":"old-moving","statement":"new belief","provenance":"model-asserted","date":"2026-06-01"}
{"v":1,"op":"supersede","claim":"clm_a","by":"clm_b","date":"2026-06-01"}
{"v":1,"id":"clm_c","topic":"new-stable","statement":"claim c","provenance":"model-asserted","date":"2026-07-01"}
{"v":1,"id":"clm_d","topic":"new-stable","statement":"claim d","provenance":"model-asserted","date":"2026-07-01"}
{"v":1,"op":"contradict","claim":"clm_c","by":"clm_d","date":"2026-07-02"}
{"v":1,"op":"verify","claim":"clm_b","by":"doctor","date":"2026-07-02"}
EOF
cat >> "$V/metrics.jsonl" <<'EOF'
{"v":1,"kind":"recall","ts":"2026-07-01T00:00:00Z","terms":["a"],"hits":["old-moving"]}
{"v":1,"kind":"recall","ts":"2026-07-02T00:00:00Z","terms":["b"],"hits":[]}
{"v":1,"kind":"near-miss","ts":"2026-07-02T00:00:01Z","terms":["b"],"near":["old-moving"],"inbox":[]}
{"v":1,"kind":"save","ts":"2026-07-03T00:00:00Z","run":"r1","topic":"old-moving","light":true,"fresh":false}
{"v":1,"kind":"save","ts":"2026-07-04T00:00:00Z","run":"r2","topic":"new-stable","light":false,"fresh":true}
EOF
mkdir -p "$V/topics/old-moving/runs/r1" "$V/topics/new-stable/runs/r2"
node -e 'require(process.argv[1]).regenDashboard(process.argv[2], null);' "$VW" "$V"
D="$V/DASHBOARD.md"
grep -q '2 topics · 2 runs' "$D" && ok "topic/run counts" || no "counts" "$(head -8 "$D")"
grep -q 'claims 3 active / 1 superseded / 0 retracted' "$D" && ok "claim tallies" || no "tallies" "$(grep claims "$D")"
grep -q 'hit rate 50%' "$D" && ok "hit rate from metrics" || no "hit rate" ""
grep -q '| 2026-07 | 2 | 1 | 50% |' "$D" && ok "--fresh canary table" || no "canary" "$(grep 2026-07 "$D")"
grep -q 'contradicted' "$D" && grep -q 'stale moving topic: old-moving' "$D" && ok "attention lines" || no "attention" ""
grep -q -- '~~old belief~~' "$D" && ok "belief-change line" || no "belief" ""
grep -q 'never run' "$D" && ok "doctor never-run line" || no "doctor line" ""

# 3. regenDashboard with a doctor summary adds the backlog line
node -e '
require(process.argv[1]).regenDashboard(process.argv[2], { work: { promote: [1], freshness: [], mine: [1,2], contradictions: [] } });
' "$VW" "$V"
grep -q 'doctor backlog: 1 to promote' "$D" && grep -q '2 runs to mine' "$D" && ok "doctor backlog line" || no "backlog" "$(grep backlog "$D")"

echo; echo "quality+dashboard: $pass passed, $fail failed"; [ $fail -eq 0 ]
````

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/researcher-quality.test.sh`
Expected: FAIL — `Cannot find module .../doctor-quality.js`.

- [ ] **Step 3: Implement `doctor-quality.js`**

```js
#!/usr/bin/env node
'use strict';
// doctor-quality — source/tool quality scoring (module only, spec Pillar 5):
// which tools and source hosts produced claims that SURVIVED (still active,
// never downgraded) vs. got verified, downgraded, superseded or retracted.
// Pure derivation from the folded registry; vault-doctor writes the result to
// profiles/source-quality.md (vault data feeding routing decisions, not
// skill prose).
//
// Module API: scoreQuality(claimsMap) -> {tools, hosts, totals}
//             renderProfile(q, generatedDate) -> markdown
//             hostOf(sourceId) -> host slug | '(none)'

function bucket() { return { claims: 0, live: 0, verified: 0, downgraded: 0, superseded: 0, retracted: 0 }; }

function hostOf(source) {
  if (typeof source !== 'string') return '(none)';
  const parts = source.split('--');
  return (parts.length >= 2 && parts[1]) ? parts[1] : '(none)';
}

function tally(b, c, wasDowngraded) {
  b.claims++;
  if (c.status === 'active' && !wasDowngraded) b.live++;
  if (c.provenance === 'externally-verified') b.verified++;
  if (wasDowngraded) b.downgraded++;
  if (c.status === 'superseded') b.superseded++;
  if (c.status === 'retracted') b.retracted++;
}

function scoreQuality(claimsMap) {
  const tools = {}, hosts = {}, totals = bucket();
  for (const c of claimsMap.values()) {
    const wasDowngraded = (typeof c.note === 'string' && /downgraded/.test(c.note))
      || (c.events || []).some((e) => e && e.op === 'downgrade');
    const tKey = String(c.tool || 'unknown');
    const hKey = hostOf(c.source);
    tally(tools[tKey] || (tools[tKey] = bucket()), c, wasDowngraded);
    tally(hosts[hKey] || (hosts[hKey] = bucket()), c, wasDowngraded);
    tally(totals, c, wasDowngraded);
  }
  return { tools, hosts, totals };
}

function table(title, map) {
  const keys = Object.keys(map).sort((a, b) => map[b].claims - map[a].claims || a.localeCompare(b));
  const L = ['## ' + title, '',
    '| ' + title.toLowerCase().replace(/s$/, '') + ' | claims | live | verified | downgraded | superseded | retracted |',
    '|---|---|---|---|---|---|---|'];
  if (!keys.length) L.push('| _none yet_ |  |  |  |  |  |  |');
  for (const k of keys) {
    const b = map[k];
    L.push('| ' + k + ' | ' + b.claims + ' | ' + b.live + ' | ' + b.verified + ' | ' + b.downgraded + ' | ' + b.superseded + ' | ' + b.retracted + ' |');
  }
  return L.join('\n');
}

function renderProfile(q, generatedDate) {
  return ['# Source & tool quality', '',
    '_Generated by the librarian (vault-doctor.js) on ' + generatedDate + ' — derived from claims.jsonl; do not edit._', '',
    table('Tools', q.tools), '', table('Hosts', q.hosts), '',
    '## Machine block', '', '```json',
    JSON.stringify({ v: 1, generated: generatedDate, tools: q.tools, hosts: q.hosts, totals: q.totals }),
    '```', ''].join('\n');
}

module.exports = { scoreQuality, renderProfile, hostOf };
```

- [ ] **Step 4: Implement `regenDashboard` in vault-views.js**

Add after `regenIndex` (before `main`):

```js
// DASHBOARD.md (spec Pillar 5): the Obsidian home note. Fully generated, no
// human-owned section — always safe to regenerate. doctorSummary (optional)
// is vault-doctor's in-flight result; without it the doctor lines fall back
// to "run the doctor".
function regenDashboard(vault, doctorSummary) {
  const idx = lastPerSlug(lib.readJsonl(path.join(vault, 'index.jsonl')).records);
  const { claims } = lib.foldClaims(lib.readJsonl(path.join(vault, 'claims.jsonl')).records);
  const metrics = lib.readJsonl(path.join(vault, 'metrics.jsonl')).records;

  let active = 0, superseded = 0, retracted = 0;
  const prov = {};
  const contradicted = [];
  for (const c of claims.values()) {
    if (c.status === 'active') {
      active++;
      prov[c.provenance || 'unknown'] = (prov[c.provenance || 'unknown'] || 0) + 1;
      if (c.contradictedBy.length) contradicted.push(c);
    } else if (c.status === 'superseded') superseded++;
    else if (c.status === 'retracted') retracted++;
  }

  const changes = [];
  for (const c of claims.values()) {
    for (const e of c.events) if (e.op === 'supersede') changes.push({ was: c, e });
  }
  changes.sort((a, b) => String(a.e.date || '').localeCompare(String(b.e.date || '')));
  const recentChanges = changes.slice(-5).reverse();

  const runs = [];
  for (const slug of idx.keys()) {
    const dir = path.join(vault, 'topics', slug, 'runs');
    if (!fs.existsSync(dir)) continue;
    for (const r of fs.readdirSync(dir)) if (!r.startsWith('.')) runs.push({ topic: slug, run: r });
  }
  runs.sort((a, b) => a.run.localeCompare(b.run));
  const recentRuns = runs.slice(-5).reverse();

  const recalls = metrics.filter((m) => m && m.kind === 'recall');
  const recallHits = recalls.filter((m) => Array.isArray(m.hits) && m.hits.length).length;
  const nearMisses = metrics.filter((m) => m && m.kind === 'near-miss').length;
  const hitRate = recalls.length ? Math.round(100 * recallHits / recalls.length) : null;

  const byMonth = new Map();
  for (const s of metrics.filter((m) => m && m.kind === 'save')) {
    const mo = String(s.ts || '').slice(0, 7) || 'unknown';
    const b = byMonth.get(mo) || { saves: 0, fresh: 0 };
    b.saves++;
    if (s.fresh) b.fresh++;
    byMonth.set(mo, b);
  }

  const staleTopics = [];
  for (const rec of idx.values()) {
    if ((rec.volatility || 'moving') !== 'moving') continue;
    const t = Date.parse(String(rec.date || ''));
    if (!Number.isNaN(t) && (Date.now() - t) / 86400000 > 30) staleTopics.push(rec.slug + ' (' + rec.date + ')');
  }
  const lastDoctor = metrics.filter((m) => m && m.kind === 'doctor').pop() || null;

  const L = ['# Research Dashboard', '',
    '_Generated by the librarian (vault-doctor.js) — regenerate any time; do not edit._', '',
    '**Vault:** ' + idx.size + ' topics · ' + runs.length + ' runs · claims ' + active + ' active / ' + superseded + ' superseded / ' + retracted + ' retracted', '',
    '**Provenance (active):** ' + (Object.keys(prov).sort().map((k) => k + ' ' + prov[k]).join(' · ') || '_none_'), '',
    '**Recall:** ' + recalls.length + ' recalls · hit rate ' + (hitRate === null ? 'n/a' : hitRate + '%') + ' · ' + nearMisses + ' near-misses', '',
    '## --fresh usage (abandonment canary)', ''];
  if (!byMonth.size) L.push('_No saves recorded._');
  else {
    L.push('| month | saves | --fresh | rate |', '|---|---|---|---|');
    for (const [mo, b] of Array.from(byMonth.entries()).sort()) {
      L.push('| ' + mo + ' | ' + b.saves + ' | ' + b.fresh + ' | ' + Math.round(100 * b.fresh / b.saves) + '% |');
    }
  }

  L.push('', '## Attention', '');
  const attention = [];
  for (const c of contradicted.slice(0, 5)) {
    attention.push('- ⚠ contradicted: ' + String(c.statement).slice(0, 100) + ' (' + c.id + ' ⇄ ' + c.contradictedBy.join(', ') + ')');
  }
  for (const s of staleTopics.slice(0, 5)) attention.push('- ⏳ stale moving topic: ' + s);
  if (doctorSummary && doctorSummary.work) {
    const w = doctorSummary.work;
    const n = (x) => (Array.isArray(x) ? x.length : 0);
    attention.push('- 🩺 doctor backlog: ' + n(w.promote) + ' to promote · ' + n(w.freshness)
      + ' topics to freshness-check · ' + n(w.mine) + ' runs to mine · ' + n(w.contradictions) + ' pairs to judge');
  }
  L.push(attention.length ? attention.join('\n') : '_Nothing needs attention._');

  L.push('', '## Belief changes (then vs now)', '');
  if (!recentChanges.length) L.push('_No supersessions yet._');
  for (const ch of recentChanges) {
    L.push('- ' + (ch.e.date || '?') + ': ~~' + String(ch.was.statement).slice(0, 90) + '~~ → ' + ch.was.supersededBy.join(', '));
  }

  L.push('', '## Recent runs', '');
  if (!recentRuns.length) L.push('_None yet._');
  for (const r of recentRuns) {
    L.push('- [' + r.run + '](topics/' + r.topic + '/runs/' + r.run + '/plan.md) — [' + r.topic + '](topics/' + r.topic + '/topic.md)');
  }
  L.push('', '**Doctor:** ' + (lastDoctor ? 'last run ' + String(lastDoctor.ts).slice(0, 10) : '_never run — see /research doctor_'), '',
    'See [INDEX](INDEX.md).', '');
  const out = path.join(vault, 'DASHBOARD.md');
  lib.atomicWrite(out, L.join('\n'));
  return out;
}
```

and change the exports line to:

```js
module.exports = { regenTopic, regenIndex, regenDashboard };
```

Update the header comment's first line to mention DASHBOARD.md as a third generated view.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/researcher-quality.test.sh && bash tests/researcher-views.test.sh`
Expected: both `0 failed`, exit 0 (views suite guards regenTopic/regenIndex regressions).

- [ ] **Step 6: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/doctor-quality.js plugins/re-searcher/skills/re-searcher/vault-views.js tests/researcher-quality.test.sh
git commit -m "feat: source/tool quality scoring + generated DASHBOARD.md"
```

---

### Task 6: `vault-doctor.js` — the deterministic librarian CLI

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/vault-doctor.js`
- Create: `tests/researcher-doctor.test.sh` (includes the seeded-defects contract E2E)

**Interfaces:**
- Consumes: everything from Tasks 1–5: `doctor-sweeps` functions, `doctor-quality.scoreQuality/renderProfile`, `views.regenDashboard(vault, {work})`, `lib.*`, index `volatility`, metrics record kinds (`recall`, `near-miss`, `save`, `doctor`), wayback-queue records `{v,url,source_id,ts,attempts}`, `WAYBACK_API`/`WAYBACK_TIMEOUT_MS` env seams (same semantics as vault-fetch).
- Produces (consumed by references/doctor.md, Task 10):
  - CLI: `node vault-doctor.js [--vault <dir>] [--stale-days <n=30>] [--max-pairs <n=40>] [--max-drain <n=10>] [--no-network]` and `node vault-doctor.js --schedule-snippet`.
  - stdout ONE JSON line: `{status:'ok', vault, fixed, report, work, dropped, hwm}`. Exit 0 ran (even with findings), 1 hard error. One human summary line on stderr.
  - `fixed` = `{deadPointersDropped, indexCompacted:{before,after}, claimsCurrent, aliasesLearned:[{slug,alias}], wayback:{exists,requested,retried,droppedFailed,kept}, commitWarning?}` — actions the doctor APPLIED (under one `withLock`, auto-committed `research: doctor sweep`).
  - `report` = `{orphanRuns, duplicateSessions, sourceRefs:{broken,tombstoned}, quotes:{checked,passed,failed}, secrets, census, deadPointers}` — findings needing a human or the redactor (never auto-deleted).
  - `work` = `{promote:[{claim,topic,statement,quote,source}], freshness:[{topic,claims:[{claim,statement,date}]}], mine:[{topic,run}], contradictions:[{a,b,topic,aStatement,bStatement}]}` — items for the skill's LLM passes; `dropped` carries per-list cap overflow counts (no silent caps).
  - High-water mark: metrics record `{v:1, kind:'doctor', ts, hwm:{claims,metrics}, fixed:{...counts}, work:{...counts}, report:{...counts}}`. `hwm.claims`/`hwm.metrics` are the RECORD counts of claims.jsonl / metrics.jsonl at sweep time; the next run's contradiction scan and alias mining start there (incremental, never O(n²)).
  - Promote list self-consumes: a `verify` event flips folded provenance to `externally-verified`, which the `provenance === 'verbatim-grounded'` filter then excludes. Contradiction pairs appear ONCE (the run that first sees the new claim) — the skill flow judges them from that run's output; re-runs return `[]` until new claims arrive (documented incremental behavior).
  - Idempotent: an immediate re-run applies zero fixes (`deadPointersDropped 0`, `before==after`, no aliases, empty queue untouched) and stable absolute work lists (promote/freshness/mine).

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-doctor.test.sh`:

````bash
#!/usr/bin/env bash
# Contract E2E for vault-doctor.js: a vault seeded with every known defect ->
# the report names each -> deterministic fixes leave a clean re-run.
# CI-safe: wayback via local fixture server (WAYBACK_API); no live network, no LLM.
# Run: bash tests/researcher-doctor.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/plugins/re-searcher/skills/re-searcher"
D="$SK/vault-doctor.js"
S="$SK/vault-save.js"
SR="$SK/vault-search.js"
I="$SK/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-doctor tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1

cat > "$W/wb-server.js" <<'EOF'
'use strict';
const http = require('http');
const srv = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/wayback/available') {
    const target = u.searchParams.get('url') || '';
    res.writeHead(200, { 'content-type': 'application/json' });
    if (target.includes('wb%3Dknown') || target.includes('wb=known')) {
      return res.end(JSON.stringify({ archived_snapshots: { closest: { available: true, url: 'http://archive.example/snap/9' } } }));
    }
    return res.end(JSON.stringify({ archived_snapshots: {} }));
  }
  if (u.pathname.startsWith('/save/')) { res.writeHead(429); return res.end('no'); }
  res.writeHead(404); res.end();
});
srv.listen(0, '127.0.0.1', () => console.log(srv.address().port));
EOF
node "$W/wb-server.js" > "$W/wbport.txt" & WBSRV=$!
trap 'kill $WBSRV 2>/dev/null' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$W/wbport.txt" ] && break; sleep 0.2; done
export WAYBACK_API="http://127.0.0.1:$(cat "$W/wbport.txt")"

OLD=$(node -e 'const d=new Date(Date.now()-45*86400000); console.log(d.toISOString().slice(0,10))')

# --- seed every defect the handoff names ---
# orphan run, duplicate-session runs, an unmined light run
mkdir -p "$V/topics/seeded/runs/2026-06-01a-orph" \
         "$V/topics/seeded/runs/2026-06-02a-dupa" "$V/topics/seeded/runs/2026-06-02b-dupb" \
         "$V/topics/seeded/runs/2026-06-03a-lite"
echo '# plan' > "$V/topics/seeded/runs/2026-06-01a-orph/plan.md"
echo '{"v":1,"session":"sess-dup","light":false}' > "$V/topics/seeded/runs/2026-06-02a-dupa/lineage.json"
echo '{"v":1,"session":"sess-dup","light":false}' > "$V/topics/seeded/runs/2026-06-02b-dupb/lineage.json"
echo '{"v":1,"session":"sess-lite","light":true}' > "$V/topics/seeded/runs/2026-06-03a-lite/lineage.json"

# index: a stale MOVING topic (two records -> compaction has work) + alias-learning target
cat >> "$V/index.jsonl" <<EOF
{"v":1,"slug":"seeded","title":"Seeded Topic","aliases":["seed probe"],"questions":[],"scope":"general","run":"r0","date":"$OLD","volatility":"moving"}
{"v":1,"slug":"seeded","title":"Seeded Topic","aliases":["seed probe"],"questions":[],"scope":"general","run":"r0b","date":"$OLD","volatility":"moving"}
{"v":1,"slug":"kube-networking","title":"Kube Networking","aliases":[],"questions":[],"scope":"general","run":"r1","date":"2026-07-01"}
EOF

# source (wayback still queued) + claims: promote target (valid quote), stale
# moving claim, contradiction pair, broken source ref
cat > "$V/sources/srcpromo.md" <<'EOF'
---
v: 1
kind: web
wayback: queued
---
OAuth 2.1 is required for all remote MCP servers.
EOF
cat >> "$V/claims.jsonl" <<EOF
{"v":1,"id":"clm_promo","run":"r0","topic":"seeded","statement":"OAuth is required for remote MCP servers","quote":"OAuth 2.1 is required for all remote MCP servers.","source":"srcpromo","provenance":"verbatim-grounded","confidence":"high","date":"$OLD"}
{"v":1,"id":"clm_contra","run":"r0b","topic":"seeded","statement":"OAuth is optional for remote MCP servers","provenance":"model-asserted","date":"2026-07-05"}
{"v":1,"id":"clm_broken","run":"r0","topic":"seeded","statement":"claim with vanished origin","quote":"x","source":"srcnope","provenance":"verbatim-grounded","date":"2026-07-05"}
EOF

# dead inbox pointer, wayback queue (one resolvable, one exhausted), alias-learning metrics, raw secret
printf '{"v":1,"kind":"pointer","session":"deadsess","transcript":"/nonexistent/x.jsonl"}\n' >> "$V/inbox.jsonl"
cat >> "$V/wayback-queue.jsonl" <<'EOF'
{"v":1,"url":"http://target.example/page?wb=known","source_id":"srcpromo","ts":"2026-07-01T00:00:00Z","attempts":0}
{"v":1,"url":"http://target.example/dead?wb=fail","source_id":null,"ts":"2026-07-01T00:00:00Z","attempts":4}
EOF
cat >> "$V/metrics.jsonl" <<'EOF'
{"v":1,"kind":"near-miss","ts":"2026-07-01T00:00:00Z","terms":["k8s","ingress"],"near":["kube-networking"],"inbox":[]}
{"v":1,"kind":"recall","ts":"2026-07-02T00:00:00Z","terms":["k8s","ingress"],"hits":["kube-networking"]}
EOF
printf '<html>AKIAABCDEFGHIJKLMNOP</html>' > "$V/sources/raw/cccc3333.html"

echo "vault-doctor contract E2E (wayback fixture on $WAYBACK_API)"

# --- first run: every seeded defect is named; fixes applied ---
OUT=$(node "$D" --vault "$V" 2>/dev/null); rcode=$?
[ $rcode -eq 0 ] && ok "doctor exits 0" || no "exit" "rc=$rcode"
printf '%s' "$OUT" > "$W/report1.json"
node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const must = (c, m) => { if (!c) { process.stderr.write("MISS: " + m + "\n"); process.exit(1); } };
must(r.status === "ok", "status");
must(r.report.orphanRuns.length === 1 && r.report.orphanRuns[0].run === "2026-06-01a-orph", "orphan run");
must(r.report.duplicateSessions.length === 1 && r.report.duplicateSessions[0].session === "sess-dup", "duplicate sessions");
must(r.report.sourceRefs.broken.length === 1 && r.report.sourceRefs.broken[0].claim === "clm_broken", "broken source ref");
must(r.report.quotes.checked === 1 && r.report.quotes.failed.length === 0, "quote recheck");
must(r.report.secrets.length === 1, "secret hit");
must(r.fixed.deadPointersDropped === 1, "dead pointer dropped");
must(r.fixed.indexCompacted.before === 3 && r.fixed.indexCompacted.after === 2, "index compacted");
must(r.fixed.claimsCurrent === 3, "claims-current count");
must(r.fixed.aliasesLearned.length === 1 && r.fixed.aliasesLearned[0].alias === "k8s ingress", "alias learned");
must(r.fixed.wayback.exists === 1 && r.fixed.wayback.droppedFailed === 1, "wayback drain");
must(r.work.promote.length === 2, "promote items");
must(r.work.freshness.length === 1 && r.work.freshness[0].topic === "seeded" && r.work.freshness[0].claims.length === 1, "freshness topic");
must(r.work.mine.length === 1 && r.work.mine[0].run === "2026-06-03a-lite", "mine item");
must(r.work.contradictions.length === 1, "contradiction pair");
must(r.hwm.claims === 3 && typeof r.hwm.metrics === "number", "hwm");
' "$W/report1.json" && ok "report names every seeded defect" || no "report" "$(cat "$W/report1.json")"

# fixes are on disk
grep -q '^wayback: exists$' "$V/sources/srcpromo.md" && grep -q '^wayback_url: http://archive.example/snap/9$' "$V/sources/srcpromo.md" \
  && ok "source frontmatter wayback updated" || no "wb frontmatter" "$(head -8 "$V/sources/srcpromo.md")"
[ "$(grep -c . "$V/wayback-queue.jsonl")" = "0" ] && ok "wayback queue drained" || no "queue" "$(cat "$V/wayback-queue.jsonl")"
[ "$(grep -c . "$V/inbox.jsonl")" = "0" ] && ok "dead pointer removed" || no "inbox" "$(cat "$V/inbox.jsonl")"
[ "$(grep -c . "$V/index.jsonl")" = "3" ] && ok "index compacted + alias append" || no "index lines" "$(cat "$V/index.jsonl")"
node -e '
const fs = require("fs");
const recs = fs.readFileSync(process.argv[1] + "/index.jsonl", "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
const k = recs.filter((r) => r.slug === "kube-networking").pop();
process.exit(k && k.aliases.includes("k8s ingress") ? 0 : 1);
' "$V" && ok "learned alias in index" || no "alias" ""
[ "$(grep -c . "$V/claims-current.jsonl")" = "3" ] && ok "claims-current materialized" || no "claims-current" ""
grep -q '| unknown | 1 |' "$V/profiles/source-quality.md" && ok "profiles/source-quality.md written" || no "profiles" "$(cat "$V/profiles/source-quality.md" 2>/dev/null | head -20)"
grep -q 'doctor backlog: 2 to promote' "$V/DASHBOARD.md" && ok "dashboard has doctor backlog" || no "dashboard" "$(grep backlog "$V/DASHBOARD.md")"

# --- promotion path: doctor-sanctioned verify -> recall serves externally-verified ---
printf '{"op":"verify","claim":"clm_promo","by":"doctor","reason":"semantically supported by srcpromo"}\n' > "$W/ev.jsonl"
OUT=$(node "$S" --events "$W/ev.jsonl" --doctor --vault "$V")
has "$OUT" '"applied":1' && ok "verify applied via --doctor" || no "verify apply" "$OUT"
OUT=$(node "$SR" oauth remote --vault "$V" --json 2>/dev/null)
has "$OUT" '"provenance":"externally-verified"' && ok "recall serves promoted claim" || no "recall promoted" "$OUT"

# --- second run: idempotent; promotion consumed; contradictions incremental ---
OUT2=$(node "$D" --vault "$V" 2>/dev/null); rcode=$?
printf '%s' "$OUT2" > "$W/report2.json"
node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const must = (c, m) => { if (!c) { process.stderr.write("MISS: " + m + "\n"); process.exit(1); } };
must(r.fixed.deadPointersDropped === 0, "no pointers to drop");
must(r.fixed.indexCompacted.before === r.fixed.indexCompacted.after, "index already compact");
must(r.fixed.aliasesLearned.length === 0, "no new aliases");
must(r.fixed.wayback.exists + r.fixed.wayback.requested + r.fixed.wayback.retried + r.fixed.wayback.droppedFailed === 0, "queue stays empty");
must(r.work.promote.length === 1 && r.work.promote[0].claim === "clm_broken", "promotion consumed");
must(r.work.freshness.length === 1, "freshness stable");
must(r.work.mine.length === 1, "mine stable");
must(r.work.contradictions.length === 0, "contradictions incremental");
must(r.report.orphanRuns.length === 1 && r.report.duplicateSessions.length === 1, "report items persist");
' "$W/report2.json" && ok "re-run is clean and incremental" || no "idempotent" "$(cat "$W/report2.json")"

# hwm advanced past the verify event
node -e '
const lib = require(process.argv[1] + "/vault-lib.js");
const last = lib.readJsonl(process.argv[2] + "/metrics.jsonl").records.filter((m) => m.kind === "doctor").pop();
process.exit(last && last.hwm.claims === 4 ? 0 : 1);
' "$SK" "$V" && ok "hwm advances with the registry" || no "hwm" ""

# --no-network keeps queue entries untouched
printf '{"v":1,"url":"http://x.example/q?wb=known","source_id":null,"ts":"2026-07-05T00:00:00Z","attempts":0}\n' >> "$V/wayback-queue.jsonl"
OUT=$(node "$D" --vault "$V" --no-network 2>/dev/null)
node -e '
const r = JSON.parse(process.argv[1]);
process.exit(r.fixed.wayback.kept === 1 && r.fixed.wayback.exists === 0 ? 0 : 1);
' "$OUT" && [ "$(grep -c . "$V/wayback-queue.jsonl")" = "1" ] && ok "--no-network keeps the queue" || no "no-network" "$OUT"

# --schedule-snippet
OUT=$(node "$D" --schedule-snippet)
{ has "$OUT" 'cron' && has "$OUT" '/research doctor'; } && ok "--schedule-snippet prints both paths" || no "snippet" "$OUT"

echo; echo "vault-doctor: $pass passed, $fail failed"; [ $fail -eq 0 ]
````

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/researcher-doctor.test.sh`
Expected: FAIL — `Cannot find module .../vault-doctor.js` (module not found error from node).

- [ ] **Step 3: Implement `vault-doctor.js`**

```js
#!/usr/bin/env node
'use strict';
// vault-doctor — the librarian's deterministic half (spec Pillar 5).
// Property-checker, not vibes-reviewer: NEVER calls an LLM. Three phases:
//   1. SWEEP  (read-only, no lock)   doctor-sweeps property checks + work items
//   2. PROBE  (read-only network)    wayback-queue availability/save retries
//   3. FIX    (ONE withLock)         drop dead inbox pointers, compact
//      index.jsonl, materialize claims-current.jsonl, learn aliases from
//      recall misses, apply wayback outcomes, write profiles/source-quality.md,
//      regenerate DASHBOARD.md, append the doctor hwm record, auto-commit.
// Emits ONE JSON line {status, fixed, report, work, dropped, hwm} — the work
// report the skill's doctor flow (references/doctor.md) consumes to dispatch
// LLM passes. Agent output re-enters ONLY through vault-save (staged runs or
// --events --doctor); this script grants nothing by itself.
//
//   node vault-doctor.js [--vault <dir>] [--stale-days <n=30>]
//                        [--max-pairs <n=40>] [--max-drain <n=10>] [--no-network]
//   node vault-doctor.js --schedule-snippet
//
// exit 0 ran (findings included) / 1 hard error.

const fs = require('fs');
const path = require('path');
const lib = require('./vault-lib');
const sweeps = require('./doctor-sweeps');
const quality = require('./doctor-quality');
const views = require('./vault-views');

const CAPS = { promote: 50, freshnessTopics: 10, mine: 10 };
const MAX_ATTEMPTS = 5;
const STOP = new Set(['this', 'that', 'with', 'from', 'have', 'will', 'been', 'were', 'they', 'their',
  'which', 'about', 'into', 'than', 'then', 'when', 'where', 'only', 'also', 'more', 'most', 'some', 'such']);

const WB_BASE = process.env.WAYBACK_API || null;
const WB_AVAIL = (WB_BASE || 'https://archive.org') + '/wayback/available?url=';
const WB_SAVE = (WB_BASE || 'https://web.archive.org') + '/save/';
const WB_TIMEOUT = Number(process.env.WAYBACK_TIMEOUT_MS || 3000);

const SNIPPET = 'Run the librarian on a schedule (the deterministic half is also fine on demand via /research doctor):\n'
  + '\n'
  + '# cron — weekly, Monday 08:00, deterministic half only (no LLM passes):\n'
  + '0 8 * * 1  RESEARCH_VAULT_DIR="$HOME/research-vault" node "' + __dirname + '/vault-doctor.js"\n'
  + '\n'
  + '# Claude Code scheduled agent — deterministic half + the LLM passes:\n'
  + '#   create a weekly scheduled task / routine whose prompt is:  /research doctor\n'
  + '\n'
  + 'Plain cron leaves promotion/freshness/mining/contradiction judging queued in the\n'
  + 'work report until a /research doctor session picks them up.\n';

function strFlag(name) { const i = process.argv.indexOf(name); return i !== -1 ? process.argv[i + 1] : null; }
function numFlag(name, dflt) {
  const i = process.argv.indexOf(name);
  if (i === -1) return dflt;
  const n = Number(process.argv[i + 1]);
  return Number.isFinite(n) && n >= 0 ? n : dflt;
}

function httpGet(url, timeoutMs, redirects) {
  return new Promise((resolve, reject) => {
    let mod;
    try { mod = new URL(url).protocol === 'http:' ? require('http') : require('https'); }
    catch (e) { return reject(e); }
    const req = mod.get(url, { headers: { 'user-agent': 're-searcher-vault-doctor/0.3' } }, (res) => {
      const loc = res.headers.location;
      if (res.statusCode >= 300 && res.statusCode < 400 && loc) {
        res.resume();
        if ((redirects || 0) >= 5) return reject(new Error('too many redirects'));
        return httpGet(new URL(loc, url).toString(), timeoutMs, (redirects || 0) + 1).then(resolve, reject);
      }
      if (res.statusCode !== 200) { res.resume(); return reject(new Error('http ' + res.statusCode)); }
      const chunks = [];
      res.on('data', (c) => { if (chunks.length < 64) chunks.push(c); });
      res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
      res.on('error', reject);
    });
    req.setTimeout(timeoutMs, () => req.destroy(new Error('timeout')));
    req.on('error', reject);
  });
}

// PROBE phase — network OUTSIDE the lock (withLock takes a sync fn). Returns
// per-entry outcomes; the FIX phase rewrites the queue from them. "Drained
// slowly": at most maxDrain probes per run.
async function probeWayback(vault, maxDrain, noNetwork) {
  const queue = lib.readJsonl(path.join(vault, 'wayback-queue.jsonl')).records;
  const outcomes = [];
  let probed = 0;
  for (const entry of queue) {
    if (!entry || !entry.url) { outcomes.push({ entry, action: 'drop-failed' }); continue; }
    if (noNetwork || probed >= maxDrain) { outcomes.push({ entry, action: 'keep' }); continue; }
    probed++;
    let action = null, snap = null;
    try {
      const j = JSON.parse(await httpGet(WB_AVAIL + encodeURIComponent(entry.url), WB_TIMEOUT, 0));
      const c = j && j.archived_snapshots && j.archived_snapshots.closest;
      if (c && c.available && c.url) { action = 'exists'; snap = String(c.url); }
    } catch (_e) { /* availability failed — try the save */ }
    if (!action) {
      try { await httpGet(WB_SAVE + entry.url, WB_TIMEOUT, 0); action = 'requested'; }
      catch (_e) { action = ((entry.attempts || 0) + 1) >= MAX_ATTEMPTS ? 'drop-failed' : 'retry'; }
    }
    outcomes.push({ entry, action, snap });
  }
  return outcomes;
}

function updateSourceWayback(vault, sourceId, status, snapshot) {
  if (!sourceId) return;
  const p = path.join(vault, 'sources', String(sourceId) + '.md');
  if (!fs.existsSync(p)) return;
  const text = fs.readFileSync(p, 'utf8');
  let updated = text.replace(/^wayback: .*$/m, 'wayback: ' + status);
  if (snapshot && !/^wayback_url: /m.test(updated)) {
    updated = updated.replace(/^wayback: .*$/m, 'wayback: ' + status + '\nwayback_url: ' + snapshot);
  }
  if (updated !== text) lib.atomicWrite(p, updated);
}

// Alias enrichment (spec Pillar 5): a near-miss whose exact probe LATER hit a
// topic means the vocabulary gap healed via a slower path — make it a direct
// alias. Incremental from the metrics hwm.
function mineAliases(metricsRecords, fromIdx, indexMap) {
  const learned = [];
  const seen = new Set();
  for (let i = fromIdx; i < metricsRecords.length; i++) {
    const nm = metricsRecords[i];
    if (!nm || nm.kind !== 'near-miss' || !Array.isArray(nm.terms) || !nm.terms.length) continue;
    const probe = nm.terms.join(' ').toLowerCase();
    for (let j = i + 1; j < metricsRecords.length; j++) {
      const rc = metricsRecords[j];
      if (!rc || rc.kind !== 'recall' || !Array.isArray(rc.hits) || !rc.hits.length) continue;
      if ((rc.terms || []).join(' ').toLowerCase() !== probe) continue;
      const slug = rc.hits[0];
      const rec = indexMap.get(slug);
      if (rec) {
        const hay = (slug + ' ' + (rec.title || '') + ' ' + (rec.aliases || []).join(' ')).toLowerCase();
        const key = slug + '|' + probe;
        if (!hay.includes(probe) && !seen.has(key)) { learned.push({ slug, alias: probe }); seen.add(key); }
      }
      break;
    }
  }
  return learned;
}

function tokensOf(s) {
  return new Set(String(s).toLowerCase().split(/[^a-z0-9.]+/).filter((w) => w.length >= 4 && !STOP.has(w)));
}

// Work items for the LLM passes. All caps report a dropped count.
function buildWork(vault, claims, indexMap, claimRecords, hwmClaims, staleDays, maxPairs) {
  const work = { promote: [], freshness: [], mine: [], contradictions: [] };
  const dropped = { promote: 0, freshness: 0, mine: 0, contradictions: 0 };

  for (const c of claims.values()) {
    if (c.status !== 'active' || c.provenance !== 'verbatim-grounded') continue;
    if (work.promote.length >= CAPS.promote) { dropped.promote++; continue; }
    work.promote.push({ claim: c.id, topic: c.topic || null, statement: c.statement, quote: c.quote || null, source: c.source || null });
  }

  const cutoff = Date.now() - staleDays * 86400000;
  const byTopic = new Map();
  for (const c of claims.values()) {
    if (c.status !== 'active' || !c.topic) continue;
    const rec = indexMap.get(c.topic);
    if (!rec || (rec.volatility || 'moving') !== 'moving') continue;
    const t = Date.parse(String(c.date || ''));
    if (Number.isNaN(t) || t > cutoff) continue;
    const list = byTopic.get(c.topic) || [];
    list.push({ claim: c.id, statement: c.statement, date: c.date });
    byTopic.set(c.topic, list);
  }
  for (const [topic, list] of byTopic) {
    if (work.freshness.length >= CAPS.freshnessTopics) { dropped.freshness++; continue; }
    work.freshness.push({ topic, claims: list });
  }

  const runsWithClaims = new Set(Array.from(claims.values()).map((c) => c.run));
  for (const e of sweeps.listRunDirs(vault)) {
    const lin = path.join(e.dir, 'lineage.json');
    if (!fs.existsSync(lin)) continue;
    let l;
    try { l = JSON.parse(fs.readFileSync(lin, 'utf8')); } catch (_e) { continue; }
    if (!l.light || runsWithClaims.has(e.run)) continue;
    if (work.mine.length >= CAPS.mine) { dropped.mine++; continue; }
    work.mine.push({ topic: e.topic, run: e.run });
  }

  // contradictions: only claims REGISTERED since the hwm, within topic +
  // alias-shared topics, token-overlap prefiltered — incremental by design.
  const aliasTopics = new Map();
  for (const rec of indexMap.values()) {
    for (const a of rec.aliases || []) {
      const k = String(a).toLowerCase();
      const s = aliasTopics.get(k) || new Set();
      s.add(rec.slug);
      aliasTopics.set(k, s);
    }
  }
  const newClaims = claimRecords.slice(hwmClaims).filter((r) => r && r.id && !r.op);
  const seenPairs = new Set();
  for (const nc of newClaims) {
    const a = claims.get(nc.id);
    if (!a || a.status !== 'active' || !a.topic) continue;
    const candidateTopics = new Set([a.topic]);
    const rec = indexMap.get(a.topic);
    for (const al of (rec && rec.aliases) || []) {
      for (const s of aliasTopics.get(String(al).toLowerCase()) || []) candidateTopics.add(s);
    }
    const ta = tokensOf(a.statement);
    for (const b of claims.values()) {
      if (b.id === a.id || b.status !== 'active' || !candidateTopics.has(b.topic)) continue;
      if (a.contradictedBy.includes(b.id)) continue;
      const key = [a.id, b.id].sort().join('|');
      if (seenPairs.has(key)) continue;
      let overlap = 0;
      for (const w of tokensOf(b.statement)) if (ta.has(w)) overlap++;
      if (!overlap) continue;
      seenPairs.add(key);
      if (work.contradictions.length >= maxPairs) { dropped.contradictions++; continue; }
      work.contradictions.push({ a: a.id, b: b.id, topic: a.topic, aStatement: a.statement, bStatement: b.statement });
    }
  }
  return { work, dropped };
}

async function run() {
  if (process.argv.includes('--schedule-snippet')) { process.stdout.write(SNIPPET); return; }
  const vault = lib.resolveVault(strFlag('--vault'));
  const staleDays = numFlag('--stale-days', 30);
  const maxPairs = numFlag('--max-pairs', 40);
  const maxDrain = numFlag('--max-drain', 10);
  const noNetwork = process.argv.includes('--no-network');

  // ---- phase 1: read-only sweeps + work items ----
  const claimRecords = lib.readJsonl(path.join(vault, 'claims.jsonl')).records;
  const { claims } = lib.foldClaims(claimRecords);
  const metricsRecords = lib.readJsonl(path.join(vault, 'metrics.jsonl')).records;
  const indexMap = new Map();
  for (const r of lib.readJsonl(path.join(vault, 'index.jsonl')).records) if (r && r.slug) indexMap.set(r.slug, r);
  const lastDoctor = metricsRecords.filter((m) => m && m.kind === 'doctor').pop() || null;
  const hwm = (lastDoctor && lastDoctor.hwm) || { claims: 0, metrics: 0 };

  const report = {
    orphanRuns: sweeps.sweepOrphanRuns(vault),
    duplicateSessions: sweeps.sweepDuplicateSessions(vault),
    sourceRefs: sweeps.sweepSourceRefs(vault, claims),
    quotes: sweeps.sweepQuotes(vault, claims),
    secrets: sweeps.sweepSecrets(vault),
    census: sweeps.schemaCensus(vault),
    deadPointers: sweeps.deadInboxPointers(vault),
  };
  const { work, dropped } = buildWork(vault, claims, indexMap, claimRecords, hwm.claims || 0, staleDays, maxPairs);

  // ---- phase 2: network probes (outside the lock) ----
  const outcomes = await probeWayback(vault, maxDrain, noNetwork);

  // ---- phase 3: fixes under ONE lock ----
  const fixed = lib.withLock(vault, () => {
    const f = { deadPointersDropped: 0, indexCompacted: null, claimsCurrent: 0, aliasesLearned: [],
      wayback: { exists: 0, requested: 0, retried: 0, droppedFailed: 0, kept: 0 } };

    if (report.deadPointers.length) {
      const deadSet = new Set(report.deadPointers.map((p) => p.session));
      const inboxFile = path.join(vault, 'inbox.jsonl');
      const keep = lib.readJsonl(inboxFile).records.filter((r) => !(r && r.kind === 'pointer' && deadSet.has(r.session)));
      lib.atomicWrite(inboxFile, keep.map((r) => JSON.stringify(r)).join('\n') + (keep.length ? '\n' : ''));
      f.deadPointersDropped = report.deadPointers.length;
    }

    // index compaction: last-record-per-slug (same data the readers already see)
    const idxFile = path.join(vault, 'index.jsonl');
    const idxRecords = lib.readJsonl(idxFile).records;
    const lastBySlug = new Map();
    for (const r of idxRecords) if (r && r.slug) lastBySlug.set(r.slug, r);
    if (lastBySlug.size < idxRecords.length) {
      lib.atomicWrite(idxFile, Array.from(lastBySlug.values()).map((r) => JSON.stringify(r)).join('\n') + (lastBySlug.size ? '\n' : ''));
    }
    f.indexCompacted = { before: idxRecords.length, after: lastBySlug.size };

    // claims-current: the materialized view for cheap greps (active only,
    // effective provenance; events dropped — JSON.stringify skips undefined)
    const current = Array.from(claims.values()).filter((c) => c.status === 'active')
      .map((c) => Object.assign({}, c, { events: undefined }));
    lib.atomicWrite(path.join(vault, 'claims-current.jsonl'),
      current.map((c) => JSON.stringify(c)).join('\n') + (current.length ? '\n' : ''));
    f.claimsCurrent = current.length;

    for (const { slug, alias } of mineAliases(metricsRecords, hwm.metrics || 0, lastBySlug)) {
      const prev = lastBySlug.get(slug);
      if (!prev) continue;
      const rec = Object.assign({}, prev, { aliases: Array.from(new Set([].concat(prev.aliases || [], [alias]))) });
      lib.appendJsonl(idxFile, rec);
      lastBySlug.set(slug, rec);
      f.aliasesLearned.push({ slug, alias });
    }

    const keepQ = [];
    for (const o of outcomes) {
      if (o.action === 'exists') { f.wayback.exists++; updateSourceWayback(vault, o.entry.source_id, 'exists', o.snap); }
      else if (o.action === 'requested') { f.wayback.requested++; updateSourceWayback(vault, o.entry.source_id, 'requested', null); }
      else if (o.action === 'retry') { f.wayback.retried++; keepQ.push(Object.assign({}, o.entry, { attempts: (o.entry.attempts || 0) + 1 })); }
      else if (o.action === 'drop-failed') { f.wayback.droppedFailed++; if (o.entry) updateSourceWayback(vault, o.entry.source_id, 'failed', null); }
      else { f.wayback.kept++; keepQ.push(o.entry); }
    }
    lib.atomicWrite(path.join(vault, 'wayback-queue.jsonl'),
      keepQ.map((r) => JSON.stringify(r)).join('\n') + (keepQ.length ? '\n' : ''));

    fs.mkdirSync(path.join(vault, 'profiles'), { recursive: true });
    lib.atomicWrite(path.join(vault, 'profiles', 'source-quality.md'),
      quality.renderProfile(quality.scoreQuality(claims), lib.today()));
    views.regenDashboard(vault, { work });

    lib.appendJsonl(path.join(vault, 'metrics.jsonl'), {
      v: 1, kind: 'doctor', ts: new Date().toISOString(),
      hwm: { claims: claimRecords.length, metrics: metricsRecords.length },
      fixed: { deadPointersDropped: f.deadPointersDropped, aliasesLearned: f.aliasesLearned.length, wayback: f.wayback },
      work: { promote: work.promote.length, freshness: work.freshness.length, mine: work.mine.length, contradictions: work.contradictions.length },
      report: { orphanRuns: report.orphanRuns.length, duplicateSessions: report.duplicateSessions.length,
        brokenRefs: report.sourceRefs.broken.length, quoteFails: report.quotes.failed.length, secrets: report.secrets.length },
    });
    const c = lib.gitCommit(vault, 'research: doctor sweep');
    if (c.warning) f.commitWarning = c.warning;
    return f;
  });

  process.stdout.write(JSON.stringify({ status: 'ok', vault, fixed, report, work, dropped,
    hwm: { claims: claimRecords.length, metrics: metricsRecords.length } }) + '\n');
  process.stderr.write('doctor: ' + report.orphanRuns.length + ' orphan run(s) · '
    + report.duplicateSessions.length + ' duplicate session(s) · ' + report.sourceRefs.broken.length + ' broken ref(s) · '
    + report.quotes.failed.length + ' quote fail(s) · ' + report.secrets.length + ' secret hit(s) — work: '
    + work.promote.length + ' promote, ' + work.freshness.length + ' freshness, '
    + work.mine.length + ' mine, ' + work.contradictions.length + ' pair(s)\n');
}

run().catch((e) => {
  process.stdout.write(JSON.stringify({ status: 'error', error: String((e && e.message) || e) }) + '\n');
  process.stderr.write('vault-doctor: failed: ' + ((e && e.stack) || e) + '\n');
  process.exit(1);
});
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/researcher-doctor.test.sh`
Expected: `0 failed`, exit 0. Then run the full pile to catch cross-suite regressions: `for t in tests/researcher-*.test.sh; do bash "$t" >/dev/null 2>&1 || echo "FAILED: $t"; done` — expect no output.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-doctor.js tests/researcher-doctor.test.sh
git commit -m "feat: vault-doctor — deterministic librarian sweep, fixes, work report"
```

---

### Task 7: `vault-redact.js` — tombstones, retracts, dependent downgrades

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/vault-redact.js`
- Create: `tests/researcher-redact.test.sh`

**Interfaces:**
- Consumes: `lib.*`, `views.regenTopic/regenIndex`, the `downgrade` fold from Task 1, tombstone naming from Task 4 (`sources/<id>.tombstone.json`), fetch-log dedupe shape from vault-fetch.
- Produces (consumed by the doctor's tombstone-aware sweep and references/doctor.md):
  - CLI: `node vault-redact.js <source-id | claim-id> [--vault <dir>] [--reason "<r>"]`. Ids starting `clm_` are claims; anything else is a source id.
  - Source redaction (under ONE `withLock`, auto-commit `research: redact source <id>`): deletes `sources/<id>.md` + `sources/raw/<hash8>.html` (hash8 = id's first `--` segment), writes `sources/<id>.tombstone.json` `{v,source,reason,date,removed}`, rewrites `sources/fetch-log.jsonl` without that source (a refetch must never dedupe into a tombstone), appends a script-only `{op:'downgrade', to:'model-asserted', by:'redaction', reason:'source redacted: …'}` event for every non-retracted grounded claim citing it, regenerates touched topic views. JSON `{status:'redacted', kind:'source', id, removed, downgraded, note}` — the note names `git filter-repo` for true history purges.
  - Claim redaction: appends a `retract` event (`by:'human'`), regenerates the topic. `{status:'redacted', kind:'claim', id, alreadyRetracted}`.
  - Idempotent-ish: re-redacting a tombstoned source returns `{status:'already-redacted'}` exit 0; unknown id → loud exit 1.

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-redact.test.sh`:

````bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-redact.js
# Run: bash tests/researcher-redact.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/plugins/re-searcher/skills/re-searcher"
R="$SK/vault-redact.js"
I="$SK/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-redact tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1
echo "vault-redact tests"

SID="aaaa1111--example--secret-page"
cat > "$V/sources/$SID.md" <<'EOF'
---
v: 1
kind: web
url: http://example.test/secret
---
Page with a leaked credential in it.
EOF
printf '<html>AKIAABCDEFGHIJKLMNOP</html>' > "$V/sources/raw/aaaa1111.html"
printf '{"v":1,"source_id":"%s","norm_url":"http://example.test/secret","extraction_sha256":"e3"}\n' "$SID" > "$V/sources/fetch-log.jsonl"
cat >> "$V/claims.jsonl" <<EOF
{"v":1,"id":"clm_dep","run":"r1","topic":"red-topic","statement":"grounded on the doomed source","quote":"leaked credential","source":"$SID","provenance":"verbatim-grounded","date":"2026-07-01"}
{"v":1,"id":"clm_free","run":"r1","topic":"red-topic","statement":"independent claim","provenance":"model-asserted","date":"2026-07-01"}
EOF
cat >> "$V/index.jsonl" <<'EOF'
{"v":1,"slug":"red-topic","title":"Redaction Topic","aliases":[],"questions":[],"scope":"general","run":"r1","date":"2026-07-01"}
EOF

# 1. redact the source: files gone, tombstone written, dependent downgraded
OUT=$(node "$R" "$SID" --vault "$V" --reason "leaked credential"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"redacted"' && has "$OUT" '"downgraded":["clm_dep"]' && has "$OUT" 'filter-repo'; } \
  && ok "source redacted with downgrade list" || no "redact" "rc=$rcode $OUT"
[ ! -f "$V/sources/$SID.md" ] && [ ! -f "$V/sources/raw/aaaa1111.html" ] && ok "source files deleted" || no "files" ""
node -e '
const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.exit(t.v === 1 && t.reason === "leaked credential" && t.removed.length === 2 ? 0 : 1);
' "$V/sources/$SID.tombstone.json" && ok "tombstone written" || no "tombstone" "$(cat "$V/sources/$SID.tombstone.json" 2>/dev/null)"
[ "$(grep -c . "$V/sources/fetch-log.jsonl")" = "0" ] && ok "fetch-log entry dropped (refetch allowed)" || no "fetch-log" ""
node -e '
const lib = require(process.argv[1] + "/vault-lib.js");
const { claims } = lib.foldClaims(lib.readJsonl(process.argv[2] + "/claims.jsonl").records);
const c = claims.get("clm_dep");
if (!c || c.provenance !== "model-asserted" || c.status !== "active") process.exit(1);
if (claims.get("clm_free").provenance !== "model-asserted") process.exit(2);
' "$SK" "$V" && ok "dependent claim downgraded, not retracted" || no "downgrade" "rc=$?"
grep -q 'model-asserted' "$V/topics/red-topic/topic.md" && ok "topic view regenerated" || no "view" ""

# 2. re-redact -> already-redacted, exit 0
OUT=$(node "$R" "$SID" --vault "$V"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"already-redacted"'; } && ok "re-redact is a no-op" || no "re-redact" "rc=$rcode $OUT"

# 3. redact a claim -> retract event, never served again
OUT=$(node "$R" clm_free --vault "$V" --reason "wrong research"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"kind":"claim"'; } && ok "claim redaction accepted" || no "claim" "rc=$rcode $OUT"
node -e '
const lib = require(process.argv[1] + "/vault-lib.js");
const { claims } = lib.foldClaims(lib.readJsonl(process.argv[2] + "/claims.jsonl").records);
process.exit(claims.get("clm_free").status === "retracted" ? 0 : 1);
' "$SK" "$V" && ok "claim folded as retracted" || no "retract fold" ""

# 4. unknown id -> loud exit 1; append-only registry untouched by redaction
node "$R" clm_nope --vault "$V" >/dev/null 2>&1; [ $? -eq 1 ] && ok "unknown claim rejected" || no "unknown claim" ""
node "$R" not-a-source --vault "$V" >/dev/null 2>&1; [ $? -eq 1 ] && ok "unknown source rejected" || no "unknown source" ""
grep -c '"id":"clm_dep"' "$V/claims.jsonl" | grep -qx 1 && ok "claim records never edited in place" || no "append-only" ""

echo; echo "vault-redact: $pass passed, $fail failed"; [ $fail -eq 0 ]
````

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/researcher-redact.test.sh`
Expected: FAIL — `Cannot find module .../vault-redact.js`.

- [ ] **Step 3: Implement `vault-redact.js`**

```js
#!/usr/bin/env node
'use strict';
// vault-redact — the deletion path that keeps epistemics honest (spec Vault
// lifecycle). Redacting a SOURCE deletes its files, writes a tombstone,
// drops its fetch-log records (a refetch must never dedupe into a deleted
// file), and DOWNGRADES dependent grounded claims via the script-only
// 'downgrade' event. Redacting a CLAIM appends a retract event. The registry
// stays append-only: corrections are events, never edits. Raw bytes remain
// in the vault's git history — a true purge is `git filter-repo`, documented
// and manual, never automatic.
//
//   node vault-redact.js <source-id | claim-id> [--vault <dir>] [--reason "<r>"]
//
// stdout: one JSON line. exit 0 done (incl. already-redacted) / 1 unknown id.

const fs = require('fs');
const path = require('path');
const lib = require('./vault-lib');
const views = require('./vault-views');

const GROUNDED = ['verbatim-grounded', 'externally-verified'];

function strFlag(name) { const i = process.argv.indexOf(name); return i !== -1 ? process.argv[i + 1] : null; }
function die(msg) { process.stderr.write('vault-redact: ' + msg + '\n'); process.exit(1); }

function redactClaim(vault, id, reason) {
  return lib.withLock(vault, () => {
    const claimsFile = path.join(vault, 'claims.jsonl');
    const { claims } = lib.foldClaims(lib.readJsonl(claimsFile).records);
    const c = claims.get(id);
    if (!c) return null;
    const alreadyRetracted = c.status === 'retracted';
    if (!alreadyRetracted) {
      lib.appendJsonl(claimsFile, { v: 1, op: 'retract', claim: id, by: 'human', date: lib.today(), reason: reason || 'redacted' });
    }
    if (c.topic) views.regenTopic(vault, c.topic);
    views.regenIndex(vault);
    lib.gitCommit(vault, 'research: redact claim ' + id);
    return { status: 'redacted', kind: 'claim', id, alreadyRetracted };
  });
}

function redactSource(vault, id, reason) {
  const srcMd = path.join(vault, 'sources', id + '.md');
  const tomb = path.join(vault, 'sources', id + '.tombstone.json');
  if (!fs.existsSync(srcMd)) {
    return fs.existsSync(tomb) ? { status: 'already-redacted', kind: 'source', id } : null;
  }
  return lib.withLock(vault, () => {
    const removed = [];
    fs.rmSync(srcMd, { force: true });
    removed.push('sources/' + id + '.md');
    const hash8 = id.split('--')[0];
    const rawPath = path.join(vault, 'sources', 'raw', hash8 + '.html');
    if (fs.existsSync(rawPath)) { fs.rmSync(rawPath, { force: true }); removed.push('sources/raw/' + hash8 + '.html'); }
    lib.atomicWrite(tomb, JSON.stringify({ v: 1, source: id, reason: reason || 'redacted', date: lib.today(), removed }, null, 2) + '\n');

    const logFile = path.join(vault, 'sources', 'fetch-log.jsonl');
    if (fs.existsSync(logFile)) {
      const keep = lib.readJsonl(logFile).records.filter((r) => !(r && r.source_id === id));
      lib.atomicWrite(logFile, keep.map((r) => JSON.stringify(r)).join('\n') + (keep.length ? '\n' : ''));
    }

    const claimsFile = path.join(vault, 'claims.jsonl');
    const { claims } = lib.foldClaims(lib.readJsonl(claimsFile).records);
    const downgraded = [];
    const touched = new Set();
    for (const c of claims.values()) {
      if (c.source !== id || c.status === 'retracted' || !GROUNDED.includes(c.provenance)) continue;
      lib.appendJsonl(claimsFile, { v: 1, op: 'downgrade', claim: c.id, by: 'redaction', to: 'model-asserted',
        date: lib.today(), reason: 'source redacted: ' + (reason || 'unspecified') });
      downgraded.push(c.id);
      if (c.topic) touched.add(c.topic);
    }
    for (const t of touched) views.regenTopic(vault, t);
    views.regenIndex(vault);
    lib.gitCommit(vault, 'research: redact source ' + id);
    return { status: 'redacted', kind: 'source', id, removed, downgraded,
      note: 'raw bytes remain in the vault git history — run git filter-repo for a true purge' };
  });
}

function main() {
  const id = process.argv[2];
  if (!id || id.startsWith('--')) die('usage: vault-redact.js <source-id | claim-id> [--vault <dir>] [--reason "<r>"]');
  const vault = lib.resolveVault(strFlag('--vault'));
  const reason = strFlag('--reason');
  const out = id.startsWith('clm_') ? redactClaim(vault, id, reason) : redactSource(vault, id, reason);
  if (!out) die('unknown id: ' + id + ' — not a registered claim, not a stored source');
  process.stdout.write(JSON.stringify(out) + '\n');
}

main();
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/researcher-redact.test.sh && bash tests/researcher-doctor.test.sh`
Expected: both `0 failed` (doctor suite proves the tombstone shape stays sweep-compatible).

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-redact.js tests/researcher-redact.test.sh
git commit -m "feat: vault-redact — tombstones, retract events, dependent downgrades"
```

---

### Task 8: `vault-export.js` — shareable topic exports (extraction+link)

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/vault-export.js`
- Create: `tests/researcher-export.test.sh`

**Interfaces:**
- Consumes: `lib.readJsonl/foldClaims/parseFrontmatter/atomicWrite/today/resolveVault`, topic layout, source frontmatter fields (`title`, `url`, `final_url`, `fetched`, `wayback_url`).
- Produces (consumed by Task 10's command routing):
  - CLI: `node vault-export.js <topic-slug> [--vault <dir>] [--out <file>] [--no-extracts]`. Default out: `./research-export-<slug>-<date>.md` in the CWD (a share artifact — the export never mutates the vault: no lock, no commit).
  - The export contains: title header + provenance banner, latest synthesis (newest run that has one), live claims (folded — retracted/superseded never exported; contradictions flagged), then per cited source: title, original URL, fetched date, wayback link if any, and the cached extraction inside `<details>` (omitted with `--no-extracts`). NEVER raw HTML (licensing posture). Missing/redacted sources export as "unavailable".
  - JSON `{status:'exported', file, claims, sources}`; unknown topic → loud exit 1.

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-export.test.sh`:

````bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-export.js
# Run: bash tests/researcher-export.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/plugins/re-searcher/skills/re-searcher"
E="$SK/vault-export.js"
I="$SK/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-export tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1
echo "vault-export tests"

cat >> "$V/index.jsonl" <<'EOF'
{"v":1,"slug":"exp-topic","title":"Export Topic","aliases":[],"questions":[],"scope":"general","run":"r1","date":"2026-07-01"}
EOF
mkdir -p "$V/topics/exp-topic/runs/2026-07-01a-abcd"
printf '# Synthesis\n\nThe considered verdict lives here.\n' > "$V/topics/exp-topic/runs/2026-07-01a-abcd/synthesis.md"
cat > "$V/sources/bbbb2222--docs-example--auth.md" <<'EOF'
---
v: 1
kind: web
url: http://docs.example/auth
final_url: http://docs.example/auth
fetched: 2026-07-01T00:00:00Z
title: "Auth Docs"
wayback_url: http://archive.example/snap/2
---
The extraction body: tokens must rotate every 90 days.
EOF
cat >> "$V/claims.jsonl" <<'EOF'
{"v":1,"id":"clm_e1","run":"r1","topic":"exp-topic","statement":"Tokens rotate every 90 days","quote":"tokens must rotate every 90 days","source":"bbbb2222--docs-example--auth","provenance":"verbatim-grounded","confidence":"high","date":"2026-07-01"}
{"v":1,"id":"clm_e2","run":"r1","topic":"exp-topic","statement":"Old belief","provenance":"model-asserted","date":"2026-06-01"}
{"v":1,"op":"retract","claim":"clm_e2","by":"human","date":"2026-07-01","reason":"wrong"}
{"v":1,"id":"clm_e3","run":"r1","topic":"exp-topic","statement":"Claim citing a vanished source","source":"gone--x--y","provenance":"model-asserted","date":"2026-07-01"}
EOF

# 1. default export: synthesis + live claims + extraction, retracted excluded
OUT=$(cd "$W" && node "$E" exp-topic --vault "$V"); rcode=$?
FILE=$(node -e 'console.log(JSON.parse(process.argv[1]).file)' "$OUT")
{ [ $rcode -eq 0 ] && has "$OUT" '"claims":2' && [ -f "$FILE" ]; } && ok "export written" || no "export" "rc=$rcode $OUT"
grep -q 'The considered verdict lives here.' "$FILE" && ok "synthesis included" || no "synthesis" ""
grep -q 'Tokens rotate every 90 days' "$FILE" && ok "live claim included" || no "claim" ""
grep -q 'Old belief' "$FILE" && no "retracted excluded" "retracted claim leaked" || ok "retracted excluded"
grep -q 'original: http://docs.example/auth' "$FILE" && grep -q 'wayback: http://archive.example/snap/2' "$FILE" \
  && ok "source links included" || no "links" ""
grep -q 'tokens must rotate every 90 days' "$FILE" && ok "extraction embedded" || no "extraction" ""
grep -q 'Source unavailable' "$FILE" && ok "missing source disclosed" || no "missing src" ""
grep -qi '<html' "$FILE" && no "no raw html" "raw html leaked" || ok "no raw html"

# 2. --no-extracts: links only
OUT=$(cd "$W" && node "$E" exp-topic --vault "$V" --out "$W/lean.md" --no-extracts)
grep -q 'tokens must rotate every 90 days' "$W/lean.md" && no "no-extracts" "extraction leaked" || ok "--no-extracts omits bodies"
grep -q 'original: http://docs.example/auth' "$W/lean.md" && ok "links survive --no-extracts" || no "lean links" ""

# 3. unknown topic -> loud exit 1
node "$E" nope-topic --vault "$V" >/dev/null 2>&1; [ $? -eq 1 ] && ok "unknown topic rejected" || no "unknown" ""

echo; echo "vault-export: $pass passed, $fail failed"; [ $fail -eq 0 ]
````

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/researcher-export.test.sh`
Expected: FAIL — `Cannot find module .../vault-export.js`.

- [ ] **Step 3: Implement `vault-export.js`**

```js
#!/usr/bin/env node
'use strict';
// vault-export — one shareable markdown file per topic: latest synthesis +
// live claims (folded: retracted/superseded never export) + cited sources as
// extraction+link. NEVER raw HTML (licensing posture: exports default to
// extraction+link, not raw copyrighted bytes). Read-only: no lock, no
// commit, no vault mutation — the export lands in the CWD by default.
//
//   node vault-export.js <topic-slug> [--vault <dir>] [--out <file>] [--no-extracts]
//
// stdout: one JSON line {status, file, claims, sources}. exit 0 / 1.

const fs = require('fs');
const path = require('path');
const lib = require('./vault-lib');

function strFlag(name) { const i = process.argv.indexOf(name); return i !== -1 ? process.argv[i + 1] : null; }
function die(msg) { process.stderr.write('vault-export: ' + msg + '\n'); process.exit(1); }

function main() {
  const slug = process.argv[2];
  if (!slug || slug.startsWith('--')) die('usage: vault-export.js <topic-slug> [--vault <dir>] [--out <file>] [--no-extracts]');
  const vault = lib.resolveVault(strFlag('--vault'));
  const topicDir = path.join(vault, 'topics', slug);
  if (!fs.existsSync(topicDir)) die('no topic "' + slug + '" in the vault (topics/' + slug + ' missing)');

  const idx = lib.readJsonl(path.join(vault, 'index.jsonl')).records.filter((r) => r && r.slug === slug).pop() || { slug };
  const { claims } = lib.foldClaims(lib.readJsonl(path.join(vault, 'claims.jsonl')).records);
  const live = [];
  for (const c of claims.values()) if (c.topic === slug && c.status === 'active') live.push(c);
  live.sort((a, b) => String(a.date).localeCompare(String(b.date)) || String(a.id).localeCompare(String(b.id)));

  const runsDir = path.join(topicDir, 'runs');
  const runs = fs.existsSync(runsDir) ? fs.readdirSync(runsDir).sort() : [];
  let synthesis = '_No synthesis recorded._';
  let latestRun = null;
  for (let i = runs.length - 1; i >= 0; i--) {
    const p = path.join(runsDir, runs[i], 'synthesis.md');
    if (fs.existsSync(p)) { synthesis = fs.readFileSync(p, 'utf8').trim(); latestRun = runs[i]; break; }
  }

  const withExtracts = !process.argv.includes('--no-extracts');
  const sourceIds = Array.from(new Set(live.map((c) => c.source).filter(Boolean)));
  const L = ['# ' + (idx.title || slug), '',
    '_Exported from a re-searcher vault on ' + lib.today() + ' · topic `' + slug + '`'
      + (latestRun ? ' · latest run ' + latestRun : '') + '._',
    '_Sources are cached extractions + original links — never raw page copies._', '',
    '## Synthesis', '', synthesis, '', '## Claims (' + live.length + ' live)', ''];
  if (!live.length) L.push('_None registered._');
  for (const c of live) {
    L.push('- [' + [c.provenance, c.confidence, c.date].filter(Boolean).join(' · ') + '] ' + c.statement
      + (c.source ? ' — `' + c.source + '`' : ''));
    if (c.contradictedBy.length) L.push('  - ⚠ contradicted by ' + c.contradictedBy.join(', ') + ' (unresolved)');
  }
  L.push('', '## Sources', '');
  if (!sourceIds.length) L.push('_None cited by live claims._');
  let exported = 0;
  for (const id of sourceIds) {
    const p = path.join(vault, 'sources', id + '.md');
    if (!fs.existsSync(p)) { L.push('### ' + id, '', '_Source unavailable (redacted or missing)._', ''); continue; }
    const { fields, body } = lib.parseFrontmatter(fs.readFileSync(p, 'utf8'));
    exported++;
    L.push('### ' + (fields.title || id), '',
      '- original: ' + (fields.final_url || fields.url || '(unknown)'),
      '- fetched: ' + (fields.fetched || '?') + ' · id `' + id + '`');
    if (fields.wayback_url) L.push('- wayback: ' + fields.wayback_url);
    L.push('');
    if (withExtracts) L.push('<details><summary>cached extraction</summary>', '', body.trim(), '', '</details>', '');
  }
  const out = path.resolve(strFlag('--out') || ('research-export-' + slug + '-' + lib.today() + '.md'));
  lib.atomicWrite(out, L.join('\n') + '\n');
  process.stdout.write(JSON.stringify({ status: 'exported', file: out, claims: live.length, sources: exported }) + '\n');
}

main();
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/researcher-export.test.sh`
Expected: `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-export.js tests/researcher-export.test.sh
git commit -m "feat: vault-export — shareable topic exports, extraction+link only"
```

---

### Task 9: Harvest mines subagent transcripts; drain gets an `errors` tally

**Files:**
- Modify: `plugins/re-searcher/skills/re-searcher/vault-harvest.js`
- Modify: `plugins/re-searcher/skills/re-searcher/references/harvest.md` (drop the "not yet mined" deferral)
- Modify: `tests/researcher-harvest.test.sh` (append)

**Interfaces:**
- Consumes: `mine(file)` from transcript-mine, existing `harvestOne`/`digest`/`drainInbox`, the subagent layout fact from stage 2 (`<projects>/<cwd-slug>/<session-id>/subagents/agent-*.jsonl` — i.e. transcript path minus `.jsonl`, then `/subagents`).
- Produces:
  - `harvestOne` mines every `agent-*.jsonl` under the sibling subagents dir (unreadable/non-Messages files are skipped silently — main mining stands), folds them into the digest under `## Subagents (N mined)` (per-agent: truncated summary, Write payloads and source events with `<file>:<line>` pointers), passes each as an extra `--transcript` to vault-save (so they gzip into the run), and reports `subagents: N` in its JSON.
  - `--inbox` drain summary gains `errors` (pointers whose harvest returned `status:'error'`); error pointers are KEPT for the next drain (now counted, no longer silent).
  - references/harvest.md documents both behaviors.

- [ ] **Step 1: Append failing tests**

Append to `tests/researcher-harvest.test.sh` immediately **before** the final `echo; echo "vault-harvest: ..."` line:

````bash
# --- stage 3: subagent mining ---
sed 's/sessharv0001/sessub00001/g' "$T" > "$PDIR/sessub00001.jsonl"
mkdir -p "$PDIR/sessub00001/subagents"
cat > "$PDIR/sessub00001/subagents/agent-a01.jsonl" <<'EOF'
{"version":"2.1.197","sessionId":"agent-a01","cwd":"/Users/w/proj/mcp-auth-research"}
{"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/tmp/sub-finding.md","content":"Subagent dug up the OAuth details here."}}]}}
{"message":{"role":"assistant","content":[{"type":"text","text":"Subagent final: OAuth 2.1 with PKCE is mandatory for remote MCP servers, full details written to the findings file."}]}}
EOF
V8="$W/vault8"; node "$I" --vault "$V8" >/dev/null 2>&1
OUT=$(node "$H" sessub00001 --vault "$V8" --topic sub-smoke); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"subagents":1'; } && ok "subagent transcript mined" || no "subagents" "rc=$rcode $OUT"
FH=$(find "$V8/topics/sub-smoke" -name harvest.md)
grep -q '## Subagents (1 mined)' "$FH" && grep -q 'agent-a01' "$FH" && grep -q 'sub-finding.md' "$FH" \
  && ok "digest folds subagent writes" || no "sub digest" "$(grep -n Subagent "$FH")"
find "$V8/topics/sub-smoke" -name 'agent-a01.jsonl.gz' | grep -q . && ok "subagent transcript gzipped into the run" || no "sub gz" "$(find "$V8/topics/sub-smoke" -name '*.gz')"

# --- stage 3: drain errors tally ---
V9="$W/vault9"; node "$I" --vault "$V9" >/dev/null 2>&1
printf 'this is not a transcript\n' > "$W/garbage.jsonl"
printf '{"v":1,"kind":"pointer","session":"badsess","transcript":"%s","topicGuess":"junk"}\n' "$W/garbage.jsonl" >> "$V9/inbox.jsonl"
OUT=$(node "$H" --inbox --vault "$V9" 2>/dev/null); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"errors":1' && has "$OUT" '"drained":0'; } && ok "drain counts errors" || no "errors tally" "rc=$rcode $OUT"
[ "$(grep -c . "$V9/inbox.jsonl")" = "1" ] && ok "error pointer kept for retry" || no "pointer kept" ""
````

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/researcher-harvest.test.sh`
Expected: pre-existing assertions PASS; new ones FAIL (`"subagents"` absent, `"errors"` absent).

- [ ] **Step 3: Implement**

In `plugins/re-searcher/skills/re-searcher/vault-harvest.js`:

Add after `cwdSlug`:

```js
// Subagent transcripts (stage-2 measured layout): sibling dir named after the
// transcript stem, agent-*.jsonl inside. Mining is best-effort — a broken
// subagent file never fails the harvest.
function mineSubagents(transcript) {
  const dir = path.join(path.dirname(transcript), path.basename(transcript, '.jsonl'), 'subagents');
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const f of fs.readdirSync(dir).sort()) {
    if (!/^agent-.*\.jsonl$/.test(f)) continue;
    const p = path.join(dir, f);
    try {
      const m = mine(p);
      if (m.messages) out.push({ file: f, path: p, mined: m });
    } catch (_e) { /* unreadable subagent transcript — main mining stands */ }
  }
  return out;
}
```

Change `digest(mined, transcript)` to `digest(mined, transcript, subs)` and add before the `## Provenance` block:

```js
  if (subs && subs.length) {
    L.push('', '## Subagents (' + subs.length + ' mined)', '');
    for (const s of subs) {
      L.push('### ' + s.file, '');
      if (s.mined.summary) L.push(s.mined.summary.trim().slice(0, 2000), '');
      for (const w of s.mined.writes) L.push('- Write `' + w.file + '` (' + w.bytes + 'B · ' + s.file + ':' + w.line + ')');
      for (const src of s.mined.sources) L.push('- ' + src.tool + ' — ' + (src.detail || '(no detail)') + ' (' + s.file + ':' + src.line + ')');
      L.push('');
    }
  }
```

In `harvestOne`, after `const mined = mine(transcript);` (and the `messages` guard) add `const subs = mineSubagents(transcript);`; change the digest call to `digest(mined, transcript, subs)`; build the save args with the extra transcripts:

```js
    const saveArgs = [path.join(__dirname, 'vault-save.js'), run.runDir,
      '--light', '--vault', vault, '--session', session, '--transcript', transcript];
    for (const s of subs) saveArgs.push('--transcript', s.path);
    const save = execFileSync('node', saveArgs, { encoding: 'utf8' });
```

and add `subagents: subs.length,` to the returned `status: 'harvested'` object.

In `drainInbox`, change the tallies line to `let harvested = 0, already = 0, missing = 0, errors = 0;`, add after the `already-harvested` branch:

```js
    else if (r.status === 'error') errors++; // pointer KEPT — retried next drain, now visibly counted
```

and add `errors,` to the summary JSON (`{ drained: done.length, harvested, alreadyHarvested: already, missing, errors, results }`). Update the header comment's drain-summary shape.

In `references/harvest.md`, replace the sentence `Subagent transcripts are pointed to (the \`subagents\` path), not yet mined — that is librarian territory (stage 3).` with:

```
Subagent transcripts ARE mined (stage 3): every agent-*.jsonl under the
  session's subagents/ dir is folded into the digest (## Subagents) and
  gzipped into the run beside the main transcript. Drains report an `errors`
  tally; error pointers stay queued for the next drain.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/researcher-harvest.test.sh && bash tests/researcher-inbox.test.sh && bash tests/researcher-mine.test.sh`
Expected: all `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-harvest.js plugins/re-searcher/skills/re-searcher/references/harvest.md tests/researcher-harvest.test.sh
git commit -m "feat: harvest mines subagent transcripts; inbox drain errors tally"
```

---

### Task 10: SKILL §8 + references/doctor.md + command routing + registration (0.3.0)

**Files:**
- Modify: `plugins/re-searcher/skills/re-searcher/SKILL.md` (add §8, extend references line; stays ≤200 lines)
- Create: `plugins/re-searcher/skills/re-searcher/references/doctor.md`
- Modify: `plugins/re-searcher/commands/research.md` (doctor + export routed for real)
- Modify: `.claude-plugin/marketplace.json` (re-searcher `0.2.0` → `0.3.0`)
- Modify: `README.md` (librarian paragraph + test-list line)
- Modify: `tests/researcher-skill.test.sh` (new scripts/references/routing/version asserts)

**Interfaces:**
- Consumes: every CLI shipped in Tasks 1–9.
- Produces: the user-facing surface — `/research doctor` and `/research export <slug>` work end-to-end; the LLM-pass procedures live in references/doctor.md (progressive disclosure, SKILL.md stays lean).

- [ ] **Step 1: Update the packaging tests first (failing)**

In `tests/researcher-skill.test.sh`:

(a) Change the script-reference loop list from `vault-init.js vault-fetch.js vault-save.js vault-search.js vault-harvest.js` to `vault-init.js vault-fetch.js vault-save.js vault-search.js vault-harvest.js vault-doctor.js vault-export.js`.

(b) Change the references loop from `for r in full-path claims correct harvest; do` to `for r in full-path claims correct harvest doctor; do`.

(c) Replace the line:

```bash
grep -qi 'stage 3' "$C" && ok "honest stage-3 stub (doctor)" || no "stubs" ""
```

with:

```bash
{ grep -q 'vault-doctor.js' "$C" && grep -q 'vault-export.js' "$C"; } && ok "doctor + export routed" || no "doctor/export" ""
```

(d) In the stage-2 registration block, change `p.version === "0.2.0"` to `p.version === "0.3.0"` and the ok message from `"marketplace bumped to 0.2.0"` to `"marketplace bumped to 0.3.0"`.

(e) Append immediately **before** the final `echo; echo "skill: ..."` line:

```bash
# --- stage 3 registration ---
ALL=1
for s in vault-doctor.js doctor-sweeps.js doctor-quality.js vault-redact.js vault-export.js; do
  [ -f "$SK/$s" ] || { ALL=0; echo "    missing: $s"; }
done
[ $ALL -eq 1 ] && ok "stage-3 scripts shipped" || no "stage3 scripts" ""
grep -q 'schedule-snippet' "$SK/references/doctor.md" && ok "doctor reference covers scheduling" || no "schedule ref" ""
grep -q -- '--events <file> --doctor\|--events .* --doctor' "$SK/references/doctor.md" && ok "promotion path documented" || no "promotion doc" ""
grep -qi 'librarian' "$ROOT/README.md" && ok "README documents the librarian" || no "README librarian" ""
```

Run: `bash tests/researcher-skill.test.sh` — expect the changed/new assertions to FAIL (everything else PASS).

- [ ] **Step 2: SKILL.md §8**

Replace the final line of `plugins/re-searcher/skills/re-searcher/SKILL.md`:

```
Deeper procedures load on demand: references/full-path.md · references/claims.md · references/correct.md · references/harvest.md
```

with:

```
## 8 · LIBRARIAN (/research doctor · export)

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
```

Verify: `wc -l plugins/re-searcher/skills/re-searcher/SKILL.md` ≤ 200 (expect ~123).

- [ ] **Step 3: Create `references/doctor.md`**

```markdown
# /research doctor — the librarian's LLM passes

Deterministic half first (or read the report the user already has):

```bash
node "$SKILL_DIR/vault-doctor.js" --vault "$VAULT"
```

Its one JSON line: `fixed` (already applied — report, never redo), `report` (needs a
human or vault-redact), `work` (YOUR four passes, below), `dropped` (cap overflows —
mention when non-zero and re-run the doctor after clearing backlog).

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
```

- [ ] **Step 4: Route the command**

In `plugins/re-searcher/commands/research.md`, replace:

```
- `doctor` → NOT BUILT YET (stage 3 — the librarian). Say so honestly.
```

with:

```
- `doctor` → the librarian: `node "$SKILL_DIR/vault-doctor.js" --vault "$VAULT"` (deterministic
  sweep — fixes + work report JSON), then dispatch the LLM passes from that report per the
  skill's references/doctor.md. One-line report: fixes + work backlog.
- `export <slug>` → `node "$SKILL_DIR/vault-export.js" <slug> --vault "$VAULT"` — relay the
  file path from the JSON (`--no-extracts` for links-only).
```

- [ ] **Step 5: Registration + README**

In `.claude-plugin/marketplace.json`, in the plugin entry with `"name": "re-searcher"`, change `"version": "0.2.0"` to `"version": "0.3.0"`.

In `README.md` (re-searcher section, `### re-searcher — research that survives the session`):
- Replace `idempotently, and with no claims invented: the librarian
(stage 3) does the verifying.` with `idempotently, and with no claims invented up front — the librarian mines and
verifies them later.`
- Append a new paragraph after it:

```
The vault maintains itself: `/research doctor` runs the deterministic librarian sweep
(orphan/duplicate-run detection, quote re-verification, a secrets scan over raw captures,
index compaction, wayback-queue drain, alias learning from recall misses, a generated
DASHBOARD.md and a source/tool quality profile) and emits a work report that drives the
LLM passes — provenance promotion (`verify` events), adversarial freshness checks on
aging claims, claim mining from light runs, contradiction judging. `/research export
<topic>` writes a shareable extraction+link markdown file (never raw HTML);
`vault-redact.js` deletes a source honestly (tombstone + downgrade of dependent claims);
`vault-search --as-of` time-travels the registry.
```

- In the README tests line, replace `mine/inbox/harvest + a contract E2E` with `mine/inbox/harvest/sweeps/quality/doctor/redact/export + contract E2Es`.

- [ ] **Step 6: Run the full pile**

Run: `for t in tests/*.test.sh; do bash "$t" 2>/dev/null | tail -1; done`
Expected: EVERY suite prints `... 0 failed` (or a Windows-skip line); overall no suite exits non-zero. Also `wc -l plugins/re-searcher/skills/re-searcher/*.js` — every file ≤800 lines.

- [ ] **Step 7: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/SKILL.md plugins/re-searcher/skills/re-searcher/references/doctor.md plugins/re-searcher/commands/research.md .claude-plugin/marketplace.json README.md tests/researcher-skill.test.sh
git commit -m "docs: librarian SKILL §8, references/doctor.md, doctor+export routing, 0.3.0"
```

---

## Whole-stage verification (before the final review)

1. `for t in tests/*.test.sh; do bash "$t" 2>/dev/null | tail -1; done` → every suite `0 failed` + exit 0 (20 pre-existing suites unregressed; 5 new suites: sweeps, quality, doctor, redact, export).
2. The handoff's contract E2E is `tests/researcher-doctor.test.sh`: seeded orphan run, duplicate-session runs, stale moving claim, contradiction candidates, unverified verbatim-grounded claim, dead inbox pointer → the report names each → deterministic fixes leave a clean re-run.
3. Promotion path: verify event via `--events --doctor` → vault-search serves `externally-verified` (asserted in both the save suite and the doctor E2E).
4. DASHBOARD.md regenerates with real numbers (quality suite + doctor E2E).
5. Manual smoke on a mktemp vault (controller runs, presents output to the user):

```bash
SMOKE=$(mktemp -d); SK=plugins/re-searcher/skills/re-searcher
node $SK/vault-init.js --vault "$SMOKE/v"
node $SK/vault-doctor.js --vault "$SMOKE/v" --no-network   # empty-vault run: zero findings, DASHBOARD written
node $SK/vault-doctor.js --schedule-snippet
cat "$SMOKE/v/DASHBOARD.md"
```

6. Final whole-branch review on the most capable model; merge ONLY via superpowers:finishing-a-development-branch after it returns READY and the user picks the merge option. No GitHub push.

## Self-review (performed while writing)

- **Spec coverage (Roadmap → 3):** scheduled doctor → Task 6 + `--schedule-snippet`; provenance promotion → Tasks 1+6 + doctor.md §1; adversarial freshness → Task 6 work items + doctor.md §2; within-topic contradiction detection (incremental, hwm) → Task 6; DASHBOARD → Task 5; source-quality scoring → Task 5; profiles → Task 6 writes `profiles/source-quality.md`; `--as-of` → Task 2; `/research export` → Tasks 8+10. Vault lifecycle: redaction → Task 7; secrets sweep → Task 4; schema census → Task 4. Pillar 5 extras: orphan sweep → Task 4; alias enrichment from misses → Task 6; wayback drain → Tasks 3+6; claims-current + index compaction → Task 6; light-run claim mining → Task 6 + doctor.md §3. Stage-1/2 leftovers: orphan/duplicate sweep ✓, drain `errors` tally ✓ (Task 9), subagent mining ✓ (Task 9), lock comments ✓ (Task 1). Descoped per user decision: code-staleness git checks. NOT descoped silently: raw-bytes compaction — the spec marks it "optional"; claims-current + index compaction cover the required "compactions"; raw compaction is deliberately left for a later stage (it destroys data and wants real-world aging first) — flagged here, not hidden.
- **Type consistency:** `ctx.doctor` (1→6, doctor.md); `downgrade` event `{op,claim,by,to,reason}` (1→7); index `volatility` (2→5,6); wayback queue `{v,url,source_id,ts,attempts}` + statuses (3→6); `sources/<id>.tombstone.json` (4→7); `regenDashboard(vault, {work})` (5→6); metrics `{kind:'doctor', hwm:{claims,metrics}}` (6→6 next run); harvest `subagents` count + drain `errors` (9). Checked against shipped signatures quoted in "Interfaces already shipped".
- **Placeholder scan:** none — every step carries complete code or an exact textual edit.

