# Re:Searcher Stage 2 (Harvester) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the spec's "Roadmap → 2. Harvester": deterministic transcript mining, lazy harvest at recall, `/research save` + `/research harvest` (single + bulk), and the Stop-hook inbox — so no research session's raw findings are ever lost, even when nobody ran `/research`.

**Architecture:** Two new zero-dep scripts + one hook script under `plugins/re-searcher/skills/re-searcher/`: `transcript-mine.js` (deterministic pre-extraction keyed EXCLUSIVELY on the embedded Anthropic Messages shape — Write payloads, source-tool events, final assistant text, all with `transcript:line` pointers), `vault-harvest.js` (mines a transcript into a light-style run — findings digest + harvested summary, NO claims — and persists it by shelling to `vault-save --light`, reusing the entire layered persist/lock/views/auto-commit machinery), and `inbox-note.js` (Stop-hook: appends a harvest POINTER to `inbox.jsonl` — no extraction, no dialog, no stdout, never blocks). `vault-search` grows a lazy-harvest breadcrumb on misses. A tiny refactor moves run allocation (`allocateRun`) and `today()` into `vault-lib` so harvest and save share them.

**Tech Stack:** Node core only (`fs`, `path`, `os`, `child_process`). Bash test harness in house style. Hook registration mirrors `plugins/route/hooks/hooks.json` (`${CLAUDE_PLUGIN_ROOT}` command hooks).

**Reference spec:** `docs/specs/2026-07-05-re-searcher-design.md` (v2, LOCKED — "Harvester (stage 2)" section + Pillar 1 "Safety net (lazy harvest)"). Stage 1 interfaces this builds on are in `docs/plans/2026-07-05-re-searcher-stage1.md` (Interfaces blocks).

**Measured ground truth (verified on this machine, Claude Code 2.1.197 — the parser targets are facts, not guesses):**
- Main transcripts: `~/.claude/projects/<cwd-slug>/<session-id>.jsonl` where `<cwd-slug>` = absolute cwd with `/` and `.` replaced by `-` (e.g. `-Users-walterhoms-Documents-career-switch-pm`). Subagent transcripts (second layout): `~/.claude/projects/<cwd-slug>/<session-id>/subagents/agent-*.jsonl`.
- Envelope line types are NOISY: `queue-operation`, `attachment`, `last-prompt`, `system`, `mode` interleave with `user`/`assistant` — the spec's rule (key on `record.message` with `message.role` + `message.content[]`, never the envelope) is mandatory, not stylistic.
- Message records carry envelope fields `version` ("2.1.197"), `sessionId`, `cwd`, `gitBranch`. Content blocks seen: `text`, `tool_use` (`{type,id,name,input,caller}`), `tool_result`, `thinking`. `Write` input is `{file_path, content}`.

## Global Constraints

- Zero npm dependencies; Node core only; every script starts `#!/usr/bin/env node` + `'use strict';` + a usage-header comment.
- CI tests never touch the live network, never read real `~/.claude` state (transcript locations are overridable via `CLAUDE_PROJECTS_DIR`), and never require a real Claude Code session.
- The harvester keys EXCLUSIVELY on the embedded Messages shape (`message.role`, `message.content` blocks `text`/`tool_use`/`tool_result`) — never the envelope. Line-by-line parsing, skip-don't-abort; version-sniff with a loud stderr warning on unknown majors; every extracted item carries a raw `transcript:line` pointer.
- Golden-test fixtures from ≥2 transcript shapes (current 2.1.x + a legacy-shaped 2.0.x envelope) plus an unknown-major (v99) canary and an unknown-block-type canary — parsing must degrade, never abort.
- The Stop-hook writes POINTERS ONLY: no extraction, no dialog, no stdout, exit 0 always (a Stop hook must never crash or stall a session close). Missing vault → silent no-op (never create a vault). Disable with `RESEARCH_INBOX=off`.
- Harvest runs are light-style: findings digest + harvested summary, NO claims authoring (the librarian mines claims later — stage 3). Persistence goes through `vault-save --light` so the lock/layered-persist/views/auto-commit machinery is reused, never re-implemented.
- Harvest is idempotent: a session that already appears in any run's `lineage.json` is never harvested twice.
- `inbox.jsonl` appends are single-line O_APPEND writes, lock-free BY DESIGN (same precedent as `sources/fetch-log.jsonl`) so the Stop hook can never stall on the vault lock; inbox REWRITES (pointer removal) happen under `withLock` + auto-commit.
- Files ≤800 lines; atomic writes for non-append files; fail loud on real errors; SKILL.md stays ≤200 lines (test-enforced).
- Commit style `feat:`/`fix:`/`test:`/`docs:`, no attribution footer. Windows: tests skip on MINGW/MSYS/CYGWIN.
- **Test authority: `0 failed` + exit 0.** Never add/remove assertions to match a count.
- Do NOT touch `plugins/route/**` or `plugins/handoff/**` (style reference only). Do NOT push to GitHub.
- OUT of scope (stage 3+): librarian/doctor, provenance promotion, orphaned-run sweep, DASHBOARD, `--as-of`, `/research export`, embeddings, wayback drain, LLM mining of the residue (the skill may summarize AFTER the deterministic digest exists, but no script calls an LLM).

## File Structure

```
plugins/re-searcher/
├── skills/re-searcher/
│   ├── vault-lib.js          # Task 1: MODIFY — add today(), allocateRun() (moved from vault-save)
│   ├── vault-save.js         # Task 1: MODIFY — newRun()/persist() delegate to lib.today/allocateRun
│   ├── transcript-mine.js    # Task 2: NEW — deterministic pre-extraction (module + CLI)
│   ├── inbox-note.js         # Task 3: NEW — Stop-hook pointer writer
│   ├── vault-harvest.js      # Task 4: NEW — transcript → light run → vault-save --light; --inbox bulk drain
│   ├── vault-search.js       # Task 5: MODIFY — lazy-harvest breadcrumb on miss
│   ├── SKILL.md              # Task 6: MODIFY — §7 Capture without ceremony (stays ≤200 lines)
│   └── references/harvest.md # Task 6: NEW
├── commands/research.md      # Task 6: MODIFY — save/harvest routed for real (doctor stays stage-3 stub)
├── hooks/hooks.json          # Task 7: NEW — Stop hook, route-style
tests/
├── researcher-mine.test.sh      # Task 2: NEW — golden fixtures (2.1.x, legacy 2.0.x, v99 canary, unknown block, torn lines)
├── researcher-inbox.test.sh     # Task 3: NEW
├── researcher-harvest.test.sh   # Task 4: NEW
├── researcher-lib.test.sh       # Task 1: MODIFY (append allocateRun tests)
├── researcher-search.test.sh    # Task 5: MODIFY (append breadcrumb tests)
├── researcher-skill.test.sh     # Tasks 6+7: MODIFY (harvest docs + hook registration checks)
.claude-plugin/marketplace.json  # Task 7: MODIFY — re-searcher 0.2.0
install.sh                       # Task 7: MODIFY — optional Stop-hook instructions
README.md                        # Task 7: MODIFY — harvest paragraph
docs/plans/2026-07-05-re-searcher-stage2.md   # this plan
```

---

### Task 1: vault-lib gains `today()` + `allocateRun()`; vault-save delegates

**Files:**
- Modify: `plugins/re-searcher/skills/re-searcher/vault-lib.js` (add two functions + exports)
- Modify: `plugins/re-searcher/skills/re-searcher/vault-save.js` (delete its private `today()` and the allocation loop; delegate)
- Modify: `tests/researcher-lib.test.sh` (append before the final `echo; echo "vault-lib: ..."` line)

**Interfaces:**
- Consumes: existing vault-lib internals (`slugify`).
- Produces (used by Tasks 4 and by vault-save):
  - `lib.today() -> 'YYYY-MM-DD'` (local date, zero-padded).
  - `lib.allocateRun(vault, topicRaw, sessionRaw) -> {runId, runDir, topic}` — slugifies the topic, sanitizes the session suffix (non-alnum stripped, first 4, lowercase, fallback `'anon'`), `mkdirSync` the parents recursively, then bare atomic `mkdir` of `topics/<topic>/runs/<YYYY-MM-DD><letter>-<sess4>/` (letters a–z on EEXIST), creates `findings/` inside; THROWS (does not exit) on exhaustion or non-EEXIST errors — CLI callers translate to `die`.
  - vault-save behavior is UNCHANGED (same CLI, same JSON, same exit codes) — this is a pure refactor; the whole researcher-save suite must stay green untouched.

- [ ] **Step 1: Append failing tests**

Append to `tests/researcher-lib.test.sh` immediately **before** the final `echo; echo "vault-lib: ..."` line:

```bash
# 10. today() shape
node -e '
const lib = require(process.argv[1]);
process.exit(/^\d{4}-\d{2}-\d{2}$/.test(lib.today()) ? 0 : 1);
' "$LIB" && ok "today() shape" || no "today" ""

# 11. allocateRun: atomic leaf mkdir, letter bump, findings/ created, throws when exhausted
node -e '
const lib = require(process.argv[1]);
const fs = require("fs"), path = require("path");
const v = process.argv[2];
const a = lib.allocateRun(v, "MCP Auth Landscape", "9f3c2ab1");
if (!/^\d{4}-\d{2}-\d{2}a-9f3c$/.test(a.runId)) process.exit(1);
if (a.topic !== "mcp-auth-landscape") process.exit(2);
if (!fs.existsSync(path.join(a.runDir, "findings"))) process.exit(3);
const b = lib.allocateRun(v, "MCP Auth Landscape", "9f3c2ab1");
if (!/b-9f3c$/.test(b.runId)) process.exit(4);
for (const l of "cdefghijklmnopqrstuvwxyz") lib.allocateRun(v, "MCP Auth Landscape", "9f3c2ab1");
try { lib.allocateRun(v, "MCP Auth Landscape", "9f3c2ab1"); process.exit(5); }
catch (e) { process.exit(/26 same-day/.test(e.message) ? 0 : 6); }
' "$LIB" "$V" && ok "allocateRun atomic + letter bump + throws on exhaustion" || no "allocateRun" "rc=$?"
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/researcher-lib.test.sh`
Expected: pre-existing assertions PASS; the two new ones FAIL (`lib.today is not a function`).

- [ ] **Step 3: Implement in vault-lib.js**

Add after `sha8`/`newId` (before `msleep`):

```js
function today() {
  const d = new Date();
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
}

// Atomic run-folder allocation (spec Pillar 1): parents may be created
// recursively, but the LEAF run dir is a bare mkdir — same-day collisions
// bump the letter, they never race. Throws (never exits) — CLI callers die().
function allocateRun(vault, topicRaw, sessionRaw) {
  const topic = slugify(topicRaw);
  const sess = String(sessionRaw || 'anon').replace(/[^a-z0-9]/gi, '').slice(0, 4).toLowerCase() || 'anon';
  const runsDir = path.join(vault, 'topics', topic, 'runs');
  fs.mkdirSync(runsDir, { recursive: true });
  for (const letter of 'abcdefghijklmnopqrstuvwxyz') {
    const id = today() + letter + '-' + sess;
    const dir = path.join(runsDir, id);
    try { fs.mkdirSync(dir); } catch (e) { if (e.code === 'EEXIST') continue; throw e; }
    fs.mkdirSync(path.join(dir, 'findings'));
    return { runId: id, runDir: dir, topic };
  }
  throw new Error('could not allocate a run folder (26 same-day runs with the same session suffix)');
}
```

Extend the exports line with `today, allocateRun` (keep every existing export).

- [ ] **Step 4: Delegate in vault-save.js**

4a. Delete vault-save's private `today()` function and replace every call to `today()` with `lib.today()` (two call sites: `persist`'s `const date = today();` and `saveEvents`'s `claimCtx(vault, 'events', null, today())`).

4b. Replace the whole `newRun()` function with:

```js
function newRun() {
  const vault = lib.resolveVault(getFlag('--vault'));
  const rawTopic = getFlag('--topic');
  if (!rawTopic) die('usage: vault-save.js --new-run --topic <slug> [--session <id>] [--vault <dir>]');
  let r;
  try { r = lib.allocateRun(vault, rawTopic, getFlag('--session')); }
  catch (e) { die(e.message); }
  process.stdout.write(JSON.stringify(r) + '\n');
}
```

4c. Update vault-lib.js's usage-header comment Module API line to mention `today` and `allocateRun`.

- [ ] **Step 5: Run tests to verify all pass**

Run: `bash tests/researcher-lib.test.sh && bash tests/researcher-save.test.sh && bash tests/researcher-e2e.test.sh`
Expected: all `0 failed`, exit 0 — the save suite (38 asserts) and E2E must pass UNCHANGED; if any save assertion breaks, the refactor changed behavior — fix the refactor, never the tests.

- [ ] **Step 6: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-lib.js plugins/re-searcher/skills/re-searcher/vault-save.js tests/researcher-lib.test.sh
git commit -m "refactor: move today() and run allocation into vault-lib for harvest reuse"
```

---

### Task 2: transcript-mine.js — deterministic pre-extraction

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/transcript-mine.js`
- Test: `tests/researcher-mine.test.sh`

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces (used by Task 4 — exact shape):
  - `mine(filePath) -> {version, versionWarning, sessionId, cwd, writes, sources, finals, summary, unknownBlocks, skippedLines, messages}`
    - `writes: [{line, file, bytes, truncated, content}]` — from `tool_use` blocks named `Write` (`input.file_path` + `input.content`, content capped at 100000 chars with `truncated: true`).
    - `sources: [{line, tool, detail}]` — from `tool_use` blocks whose name matches `/^(WebSearch|WebFetch|mcp__)/`; `detail` is `input.query` (200 chars) or `input.url` (300) or the first input key.
    - `finals: [{line, chars, text}]` — assistant `text` blocks ≥80 trimmed chars, LAST 3 kept; `summary` = text of the last one (or null).
    - `tool_result` and `thinking` blocks are dropped by design; any other block type increments `unknownBlocks` (canary) and never aborts.
    - `version` from the first record carrying one; major ≠ 2 → `versionWarning` set AND a loud stderr line, parsing continues.
    - `line` values are 1-based raw file line numbers (`transcript:line` pointers survive degraded parsing).
  - CLI: `node transcript-mine.js <transcript.jsonl>` → one JSON line; exit 0 parsed (even degraded), 1 unreadable file / usage / zero Messages-shaped records ("wrong file" fails loud).

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-mine.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/transcript-mine.js
# Golden fixtures: current 2.1.x shape, legacy 2.0.x envelope, v99 major
# canary, unknown-block canary, torn lines. Run: bash tests/researcher-mine.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/plugins/re-searcher/skills/re-searcher/transcript-mine.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-mine tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"
echo "transcript-mine tests"

# --- golden fixture 1: current (2.1.x) shape with envelope noise ---
cat > "$W/v2.jsonl" <<'EOF'
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-07-05T10:00:00Z","sessionId":"sess-v2-0001"}
{"parentUuid":null,"isSidechain":false,"type":"assistant","sessionId":"sess-v2-0001","cwd":"/Users/w/proj/mcp-auth-research","version":"2.1.197","gitBranch":"main","message":{"role":"assistant","content":[{"type":"text","text":"Short."}]}}
{"type":"assistant","sessionId":"sess-v2-0001","version":"2.1.197","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/tmp/run/findings/landscape.md","content":"# Findings — landscape\n\nOAuth 2.1 required for remote MCP servers per the June spec revision. Additional detail sentences give the digest something real to carry forward."}}]}}
{"type":"assistant","version":"2.1.197","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"WebSearch","input":{"query":"mcp oauth 2.1 requirements"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"mcp__exa__search","input":{"url":"https://spec.example/auth"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"HUGE-RESULT-BLOB-MUST-BE-DROPPED"}]}}
this line is torn and not json at all
{"type":"attachment","content":{"blob":"noise"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"image_ref","source":"x"},{"type":"text","text":"FINAL: The MCP auth landscape requires OAuth 2.1 with PKCE for remote servers; bearer tokens stay acceptable for local stdio servers. That is the session summary."}]}}
EOF
OUT=$(node "$M" "$W/v2.jsonl" 2>"$W/v2.err"); rcode=$?
[ $rcode -eq 0 ] && ok "v2 fixture parses" || no "v2 rc" "rc=$rcode"
node -e '
const r = JSON.parse(process.argv[1]);
if (r.version !== "2.1.197") process.exit(1);
if (r.sessionId !== "sess-v2-0001") process.exit(2);
if (r.cwd !== "/Users/w/proj/mcp-auth-research") process.exit(3);
if (r.writes.length !== 1 || !r.writes[0].file.endsWith("landscape.md")) process.exit(4);
if (!r.writes[0].content.includes("OAuth 2.1 required")) process.exit(5);
if (r.writes[0].line !== 3) process.exit(6);
if (r.sources.length !== 2) process.exit(7);
if (r.sources[0].tool !== "WebSearch" || r.sources[0].detail !== "mcp oauth 2.1 requirements") process.exit(8);
if (r.sources[1].tool !== "mcp__exa__search" || r.sources[1].detail !== "https://spec.example/auth") process.exit(9);
if (!r.summary || !r.summary.startsWith("FINAL:")) process.exit(10);
if (r.skippedLines < 1) process.exit(11);
if (r.unknownBlocks < 1) process.exit(12);
if (r.versionWarning !== null) process.exit(13);
' "$OUT" && ok "v2 extraction complete + pointers" || no "v2 extraction" "rc=$? $OUT"
has "$OUT" 'MUST-BE-DROPPED' && no "tool_result dropped" "leaked" || ok "tool_result dropped"

# --- golden fixture 2: legacy (2.0.x) envelope, same Messages shape ---
cat > "$W/legacy.jsonl" <<'EOF'
{"uuid":"u1","type":"assistant","sessionId":"sess-old-0001","version":"2.0.14","message":{"role":"assistant","content":[{"type":"tool_use","id":"a1","name":"Write","input":{"file_path":"/tmp/r/findings/notes.md","content":"# Notes\n\nLegacy-envelope transcripts must mine identically because we key on the message shape only, never the envelope fields around it."}}]}}
{"uuid":"u2","type":"assistant","sessionId":"sess-old-0001","version":"2.0.14","message":{"role":"assistant","content":[{"type":"text","text":"FINAL legacy: the answer survived an older envelope layout without any parser changes, proving the keying rule."}]}}
EOF
OUT=$(node "$M" "$W/legacy.jsonl" 2>/dev/null); rcode=$?
node -e '
const r = JSON.parse(process.argv[1]);
process.exit(r.writes.length === 1 && r.summary && r.summary.startsWith("FINAL legacy") && r.version === "2.0.14" && r.versionWarning === null ? 0 : 1);
' "$OUT" && [ $rcode -eq 0 ] && ok "legacy envelope mines identically" || no "legacy" "rc=$rcode $OUT"

# --- v99 major canary: loud warning, still parses ---
sed 's/2\.1\.197/99.1.0/g' "$W/v2.jsonl" > "$W/v99.jsonl"
OUT=$(node "$M" "$W/v99.jsonl" 2>"$W/v99.err"); rcode=$?
{ [ $rcode -eq 0 ] && grep -q 'unknown transcript major' "$W/v99.err"; } && ok "v99: loud warning, no abort" || no "v99" "rc=$rcode $(cat "$W/v99.err")"
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.versionWarning && r.writes.length===1 ? 0 : 1)' "$OUT" \
  && ok "v99 still extracts" || no "v99 extract" "$OUT"

# --- pure envelope noise: no Messages records -> loud exit 1 ---
printf '{"type":"queue-operation"}\n{"type":"mode","mode":"x"}\n' > "$W/noise.jsonl"
ERR=$(node "$M" "$W/noise.jsonl" 2>&1 >/dev/null); rcode=$?
{ [ $rcode -eq 1 ] && has "$ERR" 'no Messages-shaped records'; } && ok "envelope-only file fails loud" || no "noise" "rc=$rcode $ERR"

# --- missing file / usage ---
node "$M" "$W/nope.jsonl" >/dev/null 2>&1; [ $? -eq 1 ] && ok "missing file fails loud" || no "missing" "$?"
node "$M" >/dev/null 2>&1; [ $? -eq 1 ] && ok "usage fails loud" || no "usage" "$?"

echo; echo "transcript-mine: $pass passed, $fail failed"; [ $fail -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/researcher-mine.test.sh`
Expected: FAIL — transcript-mine.js not found.

- [ ] **Step 3: Write the implementation**

Create `plugins/re-searcher/skills/re-searcher/transcript-mine.js`:

```js
#!/usr/bin/env node
'use strict';
// transcript-mine — deterministic pre-extraction from Claude Code transcripts
// (spec Harvester): keys EXCLUSIVELY on the embedded Anthropic Messages shape
// (message.role + message.content blocks text/tool_use/tool_result) — never
// the envelope, which churns between Claude Code versions. Line-by-line,
// skip-don't-abort; every extracted item carries a raw transcript:line
// pointer so lineage survives degraded parsing. No LLM anywhere in here.
//
//   node transcript-mine.js <transcript.jsonl>
//
// stdout: one JSON line {version, versionWarning, sessionId, cwd, writes,
//         sources, finals, summary, unknownBlocks, skippedLines, messages}
// exit 0 parsed (even degraded) / 1 unreadable, usage, or no messages found

const fs = require('fs');

const KNOWN_MAJOR = 2;
const SOURCE_TOOLS = /^(WebSearch|WebFetch|mcp__)/;
const MAX_WRITE_CHARS = 100000;
const MIN_FINAL_CHARS = 80;
const KEEP_FINALS = 3;

function summarizeInput(input) {
  if (!input || typeof input !== 'object') return '';
  if (typeof input.query === 'string') return input.query.slice(0, 200);
  if (typeof input.url === 'string') return input.url.slice(0, 300);
  const k = Object.keys(input)[0];
  return k ? (k + '=' + String(input[k]).slice(0, 120)) : '';
}

function mine(file) {
  const raw = fs.readFileSync(file, 'utf8').split('\n');
  const out = { version: null, versionWarning: null, sessionId: null, cwd: null,
    writes: [], sources: [], finals: [], summary: null,
    unknownBlocks: 0, skippedLines: 0, messages: 0 };
  for (let i = 0; i < raw.length; i++) {
    if (!raw[i].trim()) continue;
    let r;
    try { r = JSON.parse(raw[i]); } catch (_e) { out.skippedLines++; continue; }
    if (r && r.version && !out.version) {
      out.version = String(r.version);
      if (parseInt(out.version, 10) !== KNOWN_MAJOR) {
        out.versionWarning = 'unknown transcript major version ' + out.version + ' — extraction may be degraded';
        process.stderr.write('transcript-mine: ' + out.versionWarning + '\n');
      }
    }
    if (r && r.sessionId && !out.sessionId) out.sessionId = String(r.sessionId);
    if (r && r.cwd && !out.cwd) out.cwd = String(r.cwd);
    const m = r && r.message;
    if (!m || !m.role || !Array.isArray(m.content)) continue; // envelope noise, not a message
    out.messages++;
    for (const c of m.content) {
      if (!c || typeof c !== 'object') { out.unknownBlocks++; continue; }
      if (c.type === 'text') {
        if (m.role === 'assistant' && typeof c.text === 'string' && c.text.trim().length >= MIN_FINAL_CHARS) {
          out.finals.push({ line: i + 1, chars: c.text.length, text: c.text });
        }
      } else if (c.type === 'tool_use') {
        if (c.name === 'Write' && c.input && typeof c.input.file_path === 'string') {
          const content = typeof c.input.content === 'string' ? c.input.content : '';
          out.writes.push({ line: i + 1, file: c.input.file_path,
            bytes: Buffer.byteLength(content, 'utf8'),
            truncated: content.length > MAX_WRITE_CHARS,
            content: content.slice(0, MAX_WRITE_CHARS) });
        } else if (typeof c.name === 'string' && SOURCE_TOOLS.test(c.name)) {
          out.sources.push({ line: i + 1, tool: c.name, detail: summarizeInput(c.input) });
        }
      } else if (c.type === 'tool_result' || c.type === 'thinking') {
        // dropped by design: results are bulk noise, thinking is not citable
      } else {
        out.unknownBlocks++; // canary — new block types must never abort parsing
      }
    }
  }
  out.finals = out.finals.slice(-KEEP_FINALS);
  out.summary = out.finals.length ? out.finals[out.finals.length - 1].text : null;
  return out;
}

function main() {
  const file = process.argv[2];
  if (!file || file.startsWith('--')) { process.stderr.write('usage: transcript-mine.js <transcript.jsonl>\n'); process.exit(1); }
  let res;
  try { res = mine(file); }
  catch (err) { process.stderr.write('cannot read ' + file + ': ' + (err.code || err.message) + '\n'); process.exit(1); }
  if (!res.messages) {
    process.stderr.write('no Messages-shaped records found in ' + file + ' — wrong file, or an unknown transcript layout\n');
    process.exit(1);
  }
  process.stdout.write(JSON.stringify(res) + '\n');
}

if (require.main === module) main();
module.exports = { mine };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/researcher-mine.test.sh`
Expected: `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/transcript-mine.js tests/researcher-mine.test.sh
git commit -m "feat: re-searcher transcript-mine — deterministic Messages-shape extraction with line pointers"
```

---

### Task 3: inbox-note.js — the Stop-hook pointer writer

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/inbox-note.js`
- Test: `tests/researcher-inbox.test.sh`

**Interfaces:**
- Consumes: hook stdin JSON (Claude Code Stop-hook payload: `{session_id, transcript_path, cwd, ...}`).
- Produces (used by Tasks 4–5): one appended `inbox.jsonl` record per session:
  `{v:1, kind:"pointer", session, transcript, subagents, cwd, topicGuess, ts, transcript_dies}` where `subagents` = transcript path with `.jsonl` stripped + `/subagents` (the second layout), `topicGuess` = `basename(cwd)`, `transcript_dies` = today + `RESEARCH_TRANSCRIPT_TTL_DAYS` (default 30) as `YYYY-MM-DD`.
- Contract (spec Pillar 1, hard rules): NO stdout ever; exit 0 ALWAYS; vault missing/uninitialized → silent no-op (never create); `RESEARCH_INBOX=off` → no-op; same session already in inbox → no-op; unreadable/garbage stdin → no-op. Appends are single-line O_APPEND, lock-free by design.

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-inbox.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/inbox-note.js (Stop hook).
# Run: bash tests/researcher-inbox.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
N="$ROOT/plugins/re-searcher/skills/re-searcher/inbox-note.js"
I="$ROOT/plugins/re-searcher/skills/re-searcher/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-inbox tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1
HOOK='{"session_id":"sess-hook-0001","transcript_path":"/tmp/t/sess-hook-0001.jsonl","cwd":"/Users/w/proj/alpha-research"}'
echo "inbox-note tests"

# 1. appends a pointer; stdout stays EMPTY
OUT=$(printf '%s' "$HOOK" | RESEARCH_VAULT_DIR="$V" node "$N"); rcode=$?
{ [ $rcode -eq 0 ] && [ -z "$OUT" ]; } && ok "silent exit 0" || no "silent" "rc=$rcode out=$OUT"
node -e '
const fs = require("fs");
const lines = fs.readFileSync(process.argv[1] + "/inbox.jsonl", "utf8").split("\n").filter(Boolean);
if (lines.length !== 1) process.exit(1);
const p = JSON.parse(lines[0]);
if (p.kind !== "pointer" || p.session !== "sess-hook-0001") process.exit(2);
if (p.topicGuess !== "alpha-research") process.exit(3);
if (!p.subagents.endsWith("/sess-hook-0001/subagents")) process.exit(4);
if (!/^\d{4}-\d{2}-\d{2}$/.test(p.transcript_dies)) process.exit(5);
' "$V" && ok "pointer shape (session, topicGuess, subagents, dies)" || no "pointer" "rc=$? $(cat "$V/inbox.jsonl")"

# 2. same session twice -> still one pointer
printf '%s' "$HOOK" | RESEARCH_VAULT_DIR="$V" node "$N"
[ "$(grep -c . "$V/inbox.jsonl")" = "1" ] && ok "session deduped" || no "dedupe" "$(cat "$V/inbox.jsonl")"

# 3. RESEARCH_INBOX=off -> no-op
printf '%s' "${HOOK/sess-hook-0001/sess-hook-0002}" | RESEARCH_INBOX=off RESEARCH_VAULT_DIR="$V" node "$N"
[ "$(grep -c . "$V/inbox.jsonl")" = "1" ] && ok "RESEARCH_INBOX=off disables" || no "off" ""

# 4. missing vault -> silent no-op, nothing created
OUT=$(printf '%s' "$HOOK" | RESEARCH_VAULT_DIR="$W/novault" node "$N" 2>&1); rcode=$?
{ [ $rcode -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$W/novault" ]; } && ok "missing vault: silent, never created" || no "novault" "rc=$rcode $OUT"

# 5. garbage / empty stdin -> silent exit 0
printf 'not json' | RESEARCH_VAULT_DIR="$V" node "$N" 2>/dev/null; [ $? -eq 0 ] && ok "garbage stdin tolerated" || no "garbage" "$?"
printf '{"cwd":"/x"}' | RESEARCH_VAULT_DIR="$V" node "$N"; [ "$(grep -c . "$V/inbox.jsonl")" = "1" ] && ok "missing session/transcript -> no-op" || no "partial stdin" ""

# 6. garbage TTL env var degrades to the default instead of dropping the pointer
printf '%s' "${HOOK/sess-hook-0001/sess-hook-0003}" | RESEARCH_TRANSCRIPT_TTL_DAYS=banana RESEARCH_VAULT_DIR="$V" node "$N"
grep -q 'sess-hook-0003' "$V/inbox.jsonl" && ok "NaN TTL clamps to default" || no "ttl clamp" "$(cat "$V/inbox.jsonl")"

echo; echo "inbox-note: $pass passed, $fail failed"; [ $fail -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/researcher-inbox.test.sh`
Expected: FAIL — inbox-note.js not found.

- [ ] **Step 3: Write the implementation**

Create `plugins/re-searcher/skills/re-searcher/inbox-note.js`:

```js
#!/usr/bin/env node
'use strict';
// inbox-note — Stop-hook safety net (spec Pillar 1): append a harvest POINTER
// for this session to the vault inbox. Pointers only: no extraction, no
// dialog, no stdout — mining happens lazily, when recall has a paying
// customer. A Stop hook must never crash or stall a session close, so this
// exits 0 on every path and appends are single-line O_APPEND writes
// (lock-free by design, same precedent as sources/fetch-log.jsonl — the hook
// can never block on the vault's advisory lock).
//
//   <hook stdin JSON> | node inbox-note.js
//
// Guards: no vault (or not vault-init'd) -> silent no-op, never create one;
// RESEARCH_INBOX=off -> no-op; session already in inbox -> no-op;
// unreadable stdin -> no-op. TTL via RESEARCH_TRANSCRIPT_TTL_DAYS (default 30).

const fs = require('fs');
const path = require('path');
const os = require('os');

function main() {
  if ((process.env.RESEARCH_INBOX || '').toLowerCase() === 'off') return;
  const vault = process.env.RESEARCH_VAULT_DIR || path.join(os.homedir(), 'research-vault');
  const inboxFile = path.join(vault, 'inbox.jsonl');
  if (!fs.existsSync(inboxFile)) return; // no vault: stay silent, never create

  let hook;
  try { hook = JSON.parse(fs.readFileSync(0, 'utf8')); } catch (_e) { return; }
  const session = hook.session_id || hook.sessionId || null;
  const transcript = hook.transcript_path || hook.transcriptPath || null;
  if (!session || !transcript) return;

  try {
    for (const line of fs.readFileSync(inboxFile, 'utf8').split('\n')) {
      if (!line.trim()) continue;
      try { if (JSON.parse(line).session === session) return; } catch (_e) {}
    }
  } catch (_e) { return; }

  // clamp: a garbage TTL env var must degrade to the default, not NaN the
  // date and silently drop this session's pointer
  const rawTtl = Number(process.env.RESEARCH_TRANSCRIPT_TTL_DAYS || 30);
  const ttlDays = Number.isFinite(rawTtl) ? rawTtl : 30;
  const cwd = String(hook.cwd || process.cwd());
  fs.appendFileSync(inboxFile, JSON.stringify({
    v: 1, kind: 'pointer', session: String(session), transcript: String(transcript),
    subagents: String(transcript).replace(/\.jsonl$/, '') + '/subagents',
    cwd, topicGuess: path.basename(cwd),
    ts: new Date().toISOString(),
    transcript_dies: new Date(Date.now() + ttlDays * 86400000).toISOString().slice(0, 10),
  }) + '\n');
}

try { main(); } catch (_e) { /* a Stop hook must never crash the session */ }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/researcher-inbox.test.sh`
Expected: `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/inbox-note.js tests/researcher-inbox.test.sh
git commit -m "feat: re-searcher inbox-note Stop hook — silent harvest pointers, never blocks"
```

---

### Task 4: vault-harvest.js — transcript → light run → persist; `--inbox` bulk drain

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/vault-harvest.js`
- Test: `tests/researcher-harvest.test.sh`

**Interfaces:**
- Consumes: `./transcript-mine` (`mine`), `./vault-lib` (`resolveVault`, `allocateRun`, `today`, `slugify`, `readJsonl`, `atomicWrite`, `withLock`, `gitCommit`), `vault-save.js` CLI (`<run-dir> --light --session <id> --transcript <path> --vault <dir>` → JSON with `provenanceLine`, exit 0).
- Produces (used by the skill and Task 6):
  - CLI single: `node vault-harvest.js <transcript.jsonl | session-id> [--vault <dir>] [--topic <slug>] [--title <t>] [--from-inbox]` and `node vault-harvest.js --latest [--cwd <dir>] [--vault <dir>] [--topic <slug>]`.
    - Transcript resolution: existing file path wins; else `<CLAUDE_PROJECTS_DIR>/*/<arg>.jsonl` (session-id lookup); `--latest` = newest-mtime `.jsonl` in `<CLAUDE_PROJECTS_DIR>/<cwd-slug>` where cwd-slug = cwd with `/` and `.` → `-`. `CLAUDE_PROJECTS_DIR` defaults to `~/.claude/projects` (env override is the CI seam).
    - Idempotent: session already present in any `topics/*/runs/*/lineage.json` → `{status:"already-harvested", existing, session}`, exit 0, no new run.
    - Otherwise: builds a light-style run (plan.md with a 1-role `harvest` manifest + aliases `[topicGuess]`; findings/harvest.md = deterministic digest: summary, files written with `transcript:line` pointers and embedded `.md` payloads in 4-backtick fences, source events, provenance section naming the transcript; synthesis.md = harvested summary) and persists via `vault-save.js --light` (child process — reuses lock/views/commit). Topic: `--topic` else slugified `basename(mined.cwd)` else `'harvested-session'`; title: `--title` else `Harvest: <topic>`.
    - Output: one JSON line `{status:"harvested", session, runId, topic, writes, sources, provenanceLine}`; exit 0. Hard errors (vault missing, transcript unresolvable, mine failure) → stderr + exit 1.
    - `--from-inbox`: after a successful single harvest, remove that session's pointers from inbox.jsonl (under `withLock`, atomic rewrite, auto-commit `research: drain inbox (1 pointer)`).
  - CLI bulk: `node vault-harvest.js --inbox [--vault <dir>]` — for every `kind:"pointer"` inbox record: transcript file missing → drop pointer with `status:"transcript-missing"`; session already harvested → drop with `status:"already-harvested"`; else harvest (topic from pointer `topicGuess`) and drop. Prints `{drained: n, harvested: n, alreadyHarvested: n, missing: n, results: [...]}`; processed pointers removed in ONE locked rewrite + one auto-commit; exit 0 (an empty inbox is fine).

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-harvest.test.sh`:

````bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-harvest.js
# CI-safe: transcripts live in a fake CLAUDE_PROJECTS_DIR. Run: bash tests/researcher-harvest.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/plugins/re-searcher/skills/re-searcher/vault-harvest.js"
I="$ROOT/plugins/re-searcher/skills/re-searcher/vault-init.js"
SR="$ROOT/plugins/re-searcher/skills/re-searcher/vault-search.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-harvest tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"; P="$W/projects"
export CLAUDE_PROJECTS_DIR="$P"
node "$I" --vault "$V" >/dev/null 2>&1
PDIR="$P/-Users-w-proj-mcp-auth-research"
mkdir -p "$PDIR"
T="$PDIR/sessharv0001.jsonl"
cat > "$T" <<'EOF'
{"type":"queue-operation","operation":"enqueue","sessionId":"sessharv0001"}
{"type":"assistant","sessionId":"sessharv0001","cwd":"/Users/w/proj/mcp-auth-research","version":"2.1.197","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/tmp/x/findings/landscape.md","content":"# Findings — landscape\n\nOAuth 2.1 required for remote MCP servers per the June spec revision. Enough real sentences here to make the harvested digest carry substance past the staging floor without padding."}}]}}
{"type":"assistant","sessionId":"sessharv0001","version":"2.1.197","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"WebSearch","input":{"query":"mcp oauth requirements"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"FINAL: remote MCP servers need OAuth 2.1 with PKCE; local stdio servers may keep bearer tokens. Harvested-summary sentence for the synthesis file."}]}}
EOF
echo "vault-harvest tests"

# 1. harvest by explicit path
OUT=$(node "$H" "$T" --vault "$V"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"harvested"'; } && ok "harvest by path" || no "path" "rc=$rcode $OUT"
node -e '
const r = JSON.parse(process.argv[1]);
process.exit(r.session === "sessharv0001" && r.topic === "mcp-auth-research" && r.writes === 1 && r.sources === 1 && /light run/.test(r.provenanceLine) ? 0 : 1);
' "$OUT" && ok "harvest JSON (session, topic guess, counts, light provenance)" || no "json" "$OUT"
RUN=$(ls -d "$V/topics/mcp-auth-research/runs/"*/ | head -1)
grep -q 'OAuth 2.1 required' "$RUN/findings/harvest.md" && grep -q 'transcript:2' "$RUN/findings/harvest.md" \
  && ok "digest embeds .md payload with line pointer" || no "digest" "$(head -30 "$RUN/findings/harvest.md")"
grep -q 'WebSearch — mcp oauth requirements' "$RUN/findings/harvest.md" && ok "digest lists source events" || no "sources" ""
grep -q 'FINAL: remote MCP servers need OAuth 2.1' "$RUN/synthesis.md" && ok "synthesis = harvested summary" || no "synthesis" ""
grep -q '"session": "sessharv0001"' "$RUN/lineage.json" && ok "lineage carries session" || no "lineage" "$(cat "$RUN/lineage.json")"
[ -f "$RUN"/transcripts/sessharv0001.jsonl.gz ] && ok "transcript gzipped into run" || no "gz" "$(ls "$RUN")"
git -C "$V" log --oneline | grep -q 'persist run' && ok "vault auto-commit" || no "git" ""

# 2. idempotent: second harvest of the same session -> already-harvested, no new run
N1=$(ls -d "$V/topics/mcp-auth-research/runs/"*/ | wc -l | tr -d ' ')
OUT=$(node "$H" "$T" --vault "$V"); rcode=$?
N2=$(ls -d "$V/topics/mcp-auth-research/runs/"*/ | wc -l | tr -d ' ')
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"already-harvested"' && [ "$N1" = "$N2" ]; } \
  && ok "idempotent re-harvest" || no "idempotent" "rc=$rcode $N1->$N2 $OUT"

# 3. recall finds the harvested topic
OUT=$(node "$SR" mcp oauth --vault "$V"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" 'mcp-auth-research'; } && ok "harvested run is recallable" || no "recall" "rc=$rcode $OUT"

# 4. resolve by session id (fresh vault)
V2="$W/vault2"; node "$I" --vault "$V2" >/dev/null 2>&1
OUT=$(node "$H" sessharv0001 --vault "$V2" --topic override-topic); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"topic":"override-topic"'; } && ok "session-id lookup + --topic override" || no "session id" "rc=$rcode $OUT"

# 5. --latest picks the newest transcript for the cwd
T2="$PDIR/sessharv0002.jsonl"
sed 's/sessharv0001/sessharv0002/g' "$T" > "$T2"
touch -t 203001011200 "$T2"   # far future mtime -> newest
V3="$W/vault3"; node "$I" --vault "$V3" >/dev/null 2>&1
OUT=$(node "$H" --latest --cwd "/Users/w/proj/mcp-auth-research" --vault "$V3"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"session":"sessharv0002"'; } && ok "--latest resolves newest" || no "latest" "rc=$rcode $OUT"

# 6. --from-inbox removes the session's pointer
V4="$W/vault4"; node "$I" --vault "$V4" >/dev/null 2>&1
printf '{"v":1,"kind":"pointer","session":"sessharv0001","transcript":"%s","cwd":"/Users/w/proj/mcp-auth-research","topicGuess":"mcp-auth-research","ts":"2026-07-05T10:00:00Z","transcript_dies":"2026-08-04"}\n' "$T" >> "$V4/inbox.jsonl"
node "$H" "$T" --vault "$V4" --from-inbox >/dev/null 2>&1
[ "$(grep -c 'sessharv0001' "$V4/inbox.jsonl")" = "0" ] && ok "--from-inbox removes pointer" || no "from-inbox" "$(cat "$V4/inbox.jsonl")"

# 7. --inbox bulk drain: one live pointer, one dead-transcript pointer
V5="$W/vault5"; node "$I" --vault "$V5" >/dev/null 2>&1
printf '{"v":1,"kind":"pointer","session":"sessharv0002","transcript":"%s","cwd":"/Users/w/proj/mcp-auth-research","topicGuess":"mcp-auth-research","ts":"2026-07-05T10:00:00Z","transcript_dies":"2026-08-04"}\n' "$T2" >> "$V5/inbox.jsonl"
printf '{"v":1,"kind":"pointer","session":"sessdead0001","transcript":"%s/gone.jsonl","cwd":"/x","topicGuess":"gone","ts":"2026-07-05T10:00:00Z","transcript_dies":"2026-08-04"}\n' "$W" >> "$V5/inbox.jsonl"
OUT=$(node "$H" --inbox --vault "$V5"); rcode=$?
node -e '
const r = JSON.parse(process.argv[1]);
process.exit(r.drained === 2 && r.harvested === 1 && r.missing === 1 ? 0 : 1);
' "$OUT" && [ $rcode -eq 0 ] && ok "bulk drain tallies" || no "bulk" "rc=$rcode $OUT"
[ "$(grep -c 'pointer' "$V5/inbox.jsonl")" = "0" ] && ok "drained pointers removed" || no "drain removal" "$(cat "$V5/inbox.jsonl")"
git -C "$V5" log --oneline -1 | grep -q 'drain inbox' && ok "drain auto-commit" || no "drain git" "$(git -C "$V5" log --oneline -1)"

# 8. hard failures are loud
node "$H" /nope/missing.jsonl --vault "$V" >/dev/null 2>&1; [ $? -eq 1 ] && ok "unresolvable transcript fails loud" || no "loud" "$?"
RESEARCH_VAULT_DIR= node "$H" "$T" >/dev/null 2>&1
[ $? -eq 1 ] && ok "missing vault fails loud" || no "vault loud" "$?"

echo; echo "vault-harvest: $pass passed, $fail failed"; [ $fail -eq 0 ]
````

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/researcher-harvest.test.sh`
Expected: FAIL — vault-harvest.js not found.

- [ ] **Step 3: Write the implementation**

Create `plugins/re-searcher/skills/re-searcher/vault-harvest.js`:

```js
#!/usr/bin/env node
'use strict';
// vault-harvest — turn a session transcript into a vaulted run (spec Pillar 1
// lazy harvest + /research save|harvest). Light-style: findings digest +
// harvested summary, NO claims — the librarian mines claims later (stage 3).
// Deterministic extraction via transcript-mine; persistence via
// `vault-save.js --light` (child process) so the layered persist, lock,
// views and auto-commit are reused, never re-implemented.
//
//   node vault-harvest.js <transcript.jsonl | session-id> [--vault <dir>]
//        [--topic <slug>] [--title <t>] [--from-inbox]
//   node vault-harvest.js --latest [--cwd <dir>] [--vault <dir>] [--topic <slug>]
//   node vault-harvest.js --inbox [--vault <dir>]
//
// stdout: one JSON line. exit 0 (harvested / already-harvested / drained),
// 1 hard error. Idempotent: a session already present in any run's
// lineage.json is never harvested twice. CLAUDE_PROJECTS_DIR overrides
// ~/.claude/projects (the CI seam).

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');
const lib = require('./vault-lib');
const { mine } = require('./transcript-mine');

function getFlag(name) { const i = process.argv.indexOf(name); return i !== -1 ? process.argv[i + 1] : null; }
function die(msg) { process.stderr.write('vault-harvest: ' + msg + '\n'); process.exit(1); }
function projectsDir() { return process.env.CLAUDE_PROJECTS_DIR || path.join(os.homedir(), '.claude', 'projects'); }
function cwdSlug(cwd) { return String(cwd).replace(/[/.]/g, '-'); }

function resolveTranscript(arg) {
  if (process.argv.includes('--latest')) {
    const dir = path.join(projectsDir(), cwdSlug(getFlag('--cwd') || process.cwd()));
    if (!fs.existsSync(dir)) die('no transcripts dir for this project: ' + dir);
    const files = fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl'))
      .map((f) => ({ f, m: fs.statSync(path.join(dir, f)).mtimeMs }))
      .sort((a, b) => b.m - a.m);
    if (!files.length) die('no transcripts found under ' + dir);
    return path.join(dir, files[0].f);
  }
  if (!arg) die('usage: vault-harvest.js <transcript.jsonl | session-id> [--latest] [--inbox] [--vault <dir>] [--topic <slug>] [--from-inbox]');
  if (fs.existsSync(arg)) return path.resolve(arg);
  const root = projectsDir();
  if (fs.existsSync(root)) {
    for (const d of fs.readdirSync(root)) {
      const p = path.join(root, d, arg + '.jsonl');
      if (fs.existsSync(p)) return p;
    }
  }
  die('transcript not found: ' + arg + ' (looked for a file, then <projects>/*/' + arg + '.jsonl)');
}

function alreadyHarvested(vault, session) {
  if (!session) return null;
  const topics = path.join(vault, 'topics');
  if (!fs.existsSync(topics)) return null;
  for (const t of fs.readdirSync(topics)) {
    const runs = path.join(topics, t, 'runs');
    if (!fs.existsSync(runs)) continue;
    for (const r of fs.readdirSync(runs)) {
      const lin = path.join(runs, r, 'lineage.json');
      if (!fs.existsSync(lin)) continue;
      try { if (JSON.parse(fs.readFileSync(lin, 'utf8')).session === session) return t + '/' + r; } catch (_e) {}
    }
  }
  return null;
}

function digest(mined, transcript) {
  const L = ['## Summary', '', mined.summary ? mined.summary.trim() : '_No final assistant text found._', ''];
  L.push('## Files written during the session', '');
  if (!mined.writes.length) L.push('_None captured._');
  for (const w of mined.writes) {
    L.push('- `' + w.file + '` (' + w.bytes + 'B · transcript:' + w.line + ')');
    if (w.content && /\.md$/i.test(w.file)) {
      L.push('', '````', w.content + (w.truncated ? '\n… [truncated]' : ''), '````', '');
    }
  }
  L.push('', '## Source events', '');
  if (!mined.sources.length) L.push('_None captured._');
  for (const s of mined.sources) L.push('- ' + s.tool + ' — ' + (s.detail || '(no detail)') + ' (transcript:' + s.line + ')');
  L.push('', '## Provenance', '',
    '- transcript: ' + transcript,
    '- extraction: deterministic (transcript-mine); everything above is model output from that session — treat as model-asserted until the librarian verifies it (stage 3)');
  return L.join('\n');
}

function harvestOne(vault, transcript, opts) {
  const mined = mine(transcript);
  if (!mined.messages) return { status: 'error', error: 'no Messages-shaped records in ' + transcript };
  const session = mined.sessionId || path.basename(transcript, '.jsonl');
  const existing = alreadyHarvested(vault, session);
  if (existing) return { status: 'already-harvested', existing, session };

  const topic = lib.slugify(opts.topic || path.basename(mined.cwd || '') || 'harvested-session');
  const title = opts.title || 'Harvest: ' + topic;
  const run = lib.allocateRun(vault, topic, session);
  const date = lib.today();

  lib.atomicWrite(path.join(run.runDir, 'plan.md'), [
    '---', 'topic: ' + run.topic, 'title: ' + title, 'scope: general',
    'classification: harvest', 'session: ' + session,
    'aliases: ' + JSON.stringify([opts.topicGuess || path.basename(mined.cwd || '')].filter(Boolean)),
    'questions: []', 'date: ' + date, '---', '',
    '# Plan — harvested session', '', '## Question', '',
    '(lazy harvest of session ' + session + ' — no explicit research question)', '',
    '```manifest', '[{"role": "harvest", "file": "findings/harvest.md"}]', '```', '',
  ].join('\n'));
  lib.atomicWrite(path.join(run.runDir, 'findings', 'harvest.md'), [
    '---', 'role: harvest', 'run: ' + run.runId, 'task: deterministic transcript harvest',
    'date: ' + date, '---', '', '# Findings — harvest', '', digest(mined, transcript), '',
  ].join('\n'));
  lib.atomicWrite(path.join(run.runDir, 'synthesis.md'),
    '# Synthesis (harvested)\n\n' + (mined.summary ? mined.summary.trim() : '_No final assistant text — digest only._') + '\n');

  const save = execFileSync('node', [path.join(__dirname, 'vault-save.js'), run.runDir,
    '--light', '--vault', vault, '--session', session, '--transcript', transcript], { encoding: 'utf8' });
  const saved = JSON.parse(save.trim().split('\n').pop());
  return { status: 'harvested', session, runId: run.runId, topic: run.topic,
    writes: mined.writes.length, sources: mined.sources.length,
    versionWarning: mined.versionWarning, provenanceLine: saved.provenanceLine };
}

function removePointers(vault, sessions) {
  lib.withLock(vault, () => {
    const inboxFile = path.join(vault, 'inbox.jsonl');
    const keep = lib.readJsonl(inboxFile).records.filter((r) => !(r && sessions.includes(r.session)));
    lib.atomicWrite(inboxFile, keep.map((r) => JSON.stringify(r)).join('\n') + (keep.length ? '\n' : ''));
    lib.gitCommit(vault, 'research: drain inbox (' + sessions.length + ' pointer' + (sessions.length === 1 ? '' : 's') + ')');
  });
}

function drainInbox(vault) {
  const pointers = lib.readJsonl(path.join(vault, 'inbox.jsonl')).records.filter((r) => r && r.kind === 'pointer');
  const results = [];
  const done = [];
  let harvested = 0, already = 0, missing = 0;
  for (const p of pointers) {
    if (!p.transcript || !fs.existsSync(p.transcript)) {
      missing++; done.push(p.session); results.push({ session: p.session, status: 'transcript-missing' });
      continue;
    }
    const r = harvestOne(vault, p.transcript, { topic: p.topicGuess, topicGuess: p.topicGuess });
    results.push(r);
    if (r.status === 'harvested') { harvested++; done.push(p.session); }
    else if (r.status === 'already-harvested') { already++; done.push(p.session); }
  }
  if (done.length) removePointers(vault, done);
  process.stdout.write(JSON.stringify({ drained: done.length, harvested, alreadyHarvested: already, missing, results }) + '\n');
}

function main() {
  const vault = lib.resolveVault(getFlag('--vault'));
  if (process.argv.includes('--inbox')) return drainInbox(vault);
  const posArg = process.argv[2] && !process.argv[2].startsWith('--') ? process.argv[2] : null;
  const transcript = resolveTranscript(posArg);
  const res = harvestOne(vault, transcript, { topic: getFlag('--topic'), title: getFlag('--title') });
  if (res.status === 'error') die(res.error);
  if (process.argv.includes('--from-inbox') && res.session) removePointers(vault, [res.session]);
  process.stdout.write(JSON.stringify(res) + '\n');
}

function emitFatal(e) {
  process.stdout.write(JSON.stringify({ status: 'error', error: String((e && e.message) || e) }) + '\n');
  process.stderr.write('vault-harvest: failed: ' + ((e && e.stack) || e) + '\n');
  process.exit(1);
}

try { main(); } catch (e) { emitFatal(e); }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/researcher-harvest.test.sh && bash tests/researcher-save.test.sh`
Expected: both `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-harvest.js tests/researcher-harvest.test.sh
git commit -m "feat: re-searcher vault-harvest — transcript to light run via vault-save, idempotent, inbox drain"
```

---

### Task 5: vault-search — lazy-harvest breadcrumb on miss

**Files:**
- Modify: `plugins/re-searcher/skills/re-searcher/vault-search.js` (the miss branch only)
- Modify: `tests/researcher-search.test.sh` (append before the final `echo; echo "vault-search: ..."` line)

**Interfaces:**
- Consumes: `inbox.jsonl` pointer records (Task 3 shape).
- Produces: on a MISS (and only a miss — spec: "when a probe misses the index but an inbox pointer looks topically relevant"), up to 3 inbox pointers whose `topicGuess`/`cwd` contain any probe term are announced as
  `unharvested session <sess8> (<topicGuess>, noted <date>, transcript dies <date>) may cover this — harvest: node vault-harvest.js <session>`
  after the near-miss line; the near-miss metrics record gains `inbox: [sessions]`; `--json` miss output gains `inboxPointers: [...]`. Exit code stays 2; hit behavior unchanged.

- [ ] **Step 1: Append failing tests**

Append to `tests/researcher-search.test.sh` immediately **before** the final `echo; echo "vault-search: ..."` line:

```bash
# --- Stage 2: lazy-harvest breadcrumbs on miss ---
printf '{"v":1,"kind":"pointer","session":"sessk8s001x","transcript":"/tmp/none.jsonl","cwd":"/Users/w/proj/kubernetes-ingress-study","topicGuess":"kubernetes-ingress-study","ts":"2026-07-05T09:00:00Z","transcript_dies":"2026-08-04"}\n' >> "$V/inbox.jsonl"
OUT=$(node "$SR" kubernetes ingress --vault "$V"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" 'unharvested session sessk8s0' && has "$OUT" 'vault-harvest.js sessk8s001x'; } \
  && ok "miss announces relevant unharvested session" || no "breadcrumb" "rc=$rcode $OUT"
OUT=$(node "$SR" quantum entanglement --vault "$V"); rcode=$?
{ [ $rcode -eq 2 ] && ! has "$OUT" 'unharvested'; } && ok "irrelevant pointers stay silent" || no "silent" "$OUT"
grep -q '"inbox":\["sessk8s001x"\]' "$V/metrics.jsonl" && ok "breadcrumb logged to metrics" || no "metrics inbox" ""
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/researcher-search.test.sh`
Expected: pre-existing assertions PASS (the earlier "kubernetes ingress" plain-miss test runs BEFORE the pointer is seeded); the three new ones FAIL.

- [ ] **Step 3: Implement**

In `plugins/re-searcher/skills/re-searcher/vault-search.js`, replace the whole `if (!hits.length) { ... process.exit(2); }` miss block with:

```js
  if (!hits.length) {
    const query = terms.join(' ');
    const near = Array.from(index.values())
      .map((r) => ({ slug: r.slug, sim: trigramSim(query, r.slug + ' ' + (r.title || '') + ' ' + (r.aliases || []).join(' ')) }))
      .filter((x) => x.sim > 0.15).sort((a, b) => b.sim - a.sim).slice(0, 3);
    // lazy-harvest breadcrumb (spec Pillar 1): an unharvested session whose
    // pointer looks topically relevant is announced on a miss — mining
    // happens only now, when it has a paying customer.
    const inboxMatches = lib.readJsonl(path.join(vault, 'inbox.jsonl')).records
      .filter((p) => p && p.kind === 'pointer')
      .filter((p) => {
        const hay = ((p.topicGuess || '') + ' ' + (p.cwd || '')).toLowerCase();
        return terms.some((t) => hay.includes(t));
      }).slice(0, 3);
    lib.appendJsonl(path.join(vault, 'metrics.jsonl'), { v: 1, kind: 'near-miss', ts: new Date().toISOString(), terms, near: near.map((n) => n.slug), inbox: inboxMatches.map((p) => p.session) });
    if (wantJson) {
      process.stdout.write(JSON.stringify({ hits: [], nearMisses: near.map((n) => n.slug), inboxPointers: inboxMatches }) + '\n');
      process.exit(2);
    }
    if (near.length) process.stdout.write('no match — closest: ' + near.map((n) => n.slug).join(', ') + ' — one of these? (learn it: vault-search.js --add-alias <slug> "<your term>")\n');
    else process.stdout.write('no match — vault has ' + index.size + ' topic(s), none close.' + (inboxMatches.length ? '' : ' Fresh research needed.') + '\n');
    for (const p of inboxMatches) {
      process.stdout.write('unharvested session ' + String(p.session).slice(0, 8) + ' (' + (p.topicGuess || '?') + ', noted ' + String(p.ts).slice(0, 10) + ', transcript dies ' + (p.transcript_dies || '?') + ') may cover this — harvest: node vault-harvest.js ' + p.session + '\n');
    }
    process.exit(2);
  }
```

Also update the usage-header comment's miss description to mention the breadcrumb.

- [ ] **Step 4: Run tests to verify all pass**

Run: `bash tests/researcher-search.test.sh && bash tests/researcher-e2e.test.sh`
Expected: both `0 failed`, exit 0 (the E2E's near-miss assertion must still hold — the breadcrumb only ADDS lines).

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-search.js tests/researcher-search.test.sh
git commit -m "feat: vault-search announces relevant unharvested sessions on a miss (lazy harvest breadcrumb)"
```

---

### Task 6: docs — SKILL.md §7, references/harvest.md, command routing

**Files:**
- Modify: `plugins/re-searcher/skills/re-searcher/SKILL.md` (add §7; update the references footer; MUST stay ≤200 lines)
- Create: `plugins/re-searcher/skills/re-searcher/references/harvest.md`
- Modify: `plugins/re-searcher/commands/research.md` (route save/harvest for real; doctor stays a stage-3 stub)
- Modify: `tests/researcher-skill.test.sh` (update stub assertion + wire harvest checks)

**Interfaces:**
- Consumes: vault-harvest.js CLI (Task 4 flags exactly), the breadcrumb line shape (Task 5).
- Produces: the user-facing `/research save` and `/research harvest` behavior; the "(unvaulted — …)" one-liner rule.

- [ ] **Step 1: Update the packaging test (failing first)**

In `tests/researcher-skill.test.sh`:

1a. Change the scripts loop line from `for s in vault-init.js vault-fetch.js vault-save.js vault-search.js; do` to:
```bash
for s in vault-init.js vault-fetch.js vault-save.js vault-search.js vault-harvest.js; do
```

1b. Change the references loop line from `for r in full-path claims correct; do` to:
```bash
for r in full-path claims correct harvest; do
```

1c. Replace the stub assertion line `grep -qi 'stage 2' "$C" && ok "honest not-built-yet stubs" || no "stubs" ""` with:
```bash
grep -qi 'stage 3' "$C" && ok "honest stage-3 stub (doctor)" || no "stubs" ""
grep -q 'vault-harvest.js' "$C" && ok "command routes harvest" || no "cmd harvest" ""
```

Run: `bash tests/researcher-skill.test.sh` — Expected: the changed assertions FAIL (no harvest.md, SKILL.md doesn't mention vault-harvest.js, command still says stage 2).

- [ ] **Step 2: Add SKILL.md §7 and update the footer**

In `plugins/re-searcher/skills/re-searcher/SKILL.md`, insert immediately BEFORE the final `Deeper procedures load on demand:` line:

```markdown
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
```

And change the footer line to:

```markdown
Deeper procedures load on demand: references/full-path.md · references/claims.md · references/correct.md · references/harvest.md
```

Verify: `wc -l plugins/re-searcher/skills/re-searcher/SKILL.md` ≤ 200.

- [ ] **Step 3: Write references/harvest.md**

Create `plugins/re-searcher/skills/re-searcher/references/harvest.md`:

```markdown
# Harvest — capturing sessions after the fact

## What a harvest produces

A light-style run under topics/<topic>/runs/<id>/ containing:
- plan.md — classification: harvest, a 1-role manifest, aliases seeded from the topic guess
- findings/harvest.md — the deterministic digest: session summary, every Write payload
  (.md payloads embedded, others listed) with `transcript:<line>` pointers, source-tool
  events (WebSearch / WebFetch / mcp__*), and the transcript path
- synthesis.md — the session's final assistant text, labeled harvested
- lineage.json + transcripts/*.gz — persisted via vault-save --light, so the lock, views
  and auto-commit machinery is the same as any run
NO claims are authored: harvested content is model output — the librarian (stage 3)
verifies and promotes it. Treat harvested material as model-asserted context, not verdicts.

## Mechanics

- Extraction is deterministic (transcript-mine.js): keyed on the embedded Messages shape
  only, never the envelope; unknown transcript majors warn loudly and degrade, never abort.
- Idempotent: a session that appears in ANY run's lineage.json is skipped
  (status already-harvested). Re-running /research save is always safe.
- Resolution order: existing file path → session-id lookup (<projects>/*/<id>.jsonl) →
  --latest (newest .jsonl in the cwd's project dir). CLAUDE_PROJECTS_DIR overrides
  ~/.claude/projects (tests use this; you should not need it).
- The inbox (inbox.jsonl) holds Stop-hook pointers: {session, transcript, subagents, cwd,
  topicGuess, ts, transcript_dies}. Appends are lock-free single lines (the hook must never
  stall); REMOVALS rewrite the file under the vault lock and auto-commit
  (`research: drain inbox (N pointers)`).
- Bulk drain (--inbox): pointers whose transcript file no longer exists are dropped as
  transcript-missing — transcripts rot on Claude Code's retention schedule;
  transcript_dies is the estimate (RESEARCH_TRANSCRIPT_TTL_DAYS tunes it, default 30).
- The Stop hook (inbox-note.js) is silent, exits 0 always, no-ops without a vault, and is
  disabled with RESEARCH_INBOX=off.

## When to harvest

- On a recall breadcrumb (`unharvested session … may cover this`) — run exactly the printed
  command, then re-run the search.
- When the user says "save this" / runs /research save after ad-hoc research.
- Bulk (`harvest --inbox`) only when the user asks — capture is cheap, but runs are
  user-visible artifacts; never drain on your own initiative.
```

- [ ] **Step 4: Update the command file**

In `plugins/re-searcher/commands/research.md`, replace:

```markdown
- `save` / `harvest` → NOT BUILT YET (stage 2 — the harvester). Say so honestly; offer
  to keep findings in a run dir manually if the user needs capture right now.
- `doctor` → NOT BUILT YET (stage 3 — the librarian). Say so honestly.
```

with:

```markdown
- `save` → harvest THIS session now: `node "$SKILL_DIR/vault-harvest.js" --latest --vault "$VAULT"`,
  then relay its provenanceLine (details: skill §7 + references/harvest.md).
- `harvest <session-id>` → harvest that past session; `harvest --inbox` → drain every
  pending pointer. Report the JSON tallies in one line.
- `doctor` → NOT BUILT YET (stage 3 — the librarian). Say so honestly.
```

- [ ] **Step 5: Run tests to verify all pass**

Run: `bash tests/researcher-skill.test.sh`
Expected: `0 failed`, exit 0 (line budget included).

- [ ] **Step 6: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/SKILL.md plugins/re-searcher/skills/re-searcher/references/harvest.md plugins/re-searcher/commands/research.md tests/researcher-skill.test.sh
git commit -m "docs: re-searcher harvest — SKILL §7, references/harvest.md, /research save+harvest routing"
```

---

### Task 7: registration — Stop hook, marketplace 0.2.0, install.sh, README + full sweep & smoke

**Files:**
- Create: `plugins/re-searcher/hooks/hooks.json`
- Modify: `.claude-plugin/marketplace.json` (re-searcher entry: version + keywords)
- Modify: `install.sh` (optional-hooks echo block)
- Modify: `README.md` (harvest paragraph in the re-searcher section)
- Modify: `tests/researcher-skill.test.sh` (append registration checks before the final `echo; echo "skill: ..."` line)

**Interfaces:**
- Consumes: inbox-note.js (Task 3), route's hook registration pattern (`${CLAUDE_PLUGIN_ROOT}` command hooks auto-load from a plugin's `hooks/hooks.json`).
- Produces: the Stop hook active for plugin installs; honest copy-install instructions.

- [ ] **Step 1: Append failing tests**

Append to `tests/researcher-skill.test.sh` immediately **before** the final `echo; echo "skill: ..."` line:

```bash
# --- stage 2 registration ---
HK="$ROOT/plugins/re-searcher/hooks/hooks.json"
node -e '
const h = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const stop = h.hooks.Stop[0].hooks[0];
process.exit(stop.type === "command" && /inbox-note\.js/.test(stop.command) && /CLAUDE_PLUGIN_ROOT/.test(stop.command) ? 0 : 1);
' "$HK" && ok "Stop hook registered" || no "hook" ""
[ -f "$ROOT/plugins/re-searcher/skills/re-searcher/inbox-note.js" ] && ok "hook target exists" || no "hook target" ""
node -e '
const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const p = m.plugins.find((x) => x.name === "re-searcher");
process.exit(p.version === "0.2.0" ? 0 : 1);
' "$ROOT/.claude-plugin/marketplace.json" && ok "marketplace bumped to 0.2.0" || no "version" ""
grep -q 'inbox-note' "$ROOT/install.sh" && ok "install.sh documents the hook" || no "install hook" ""
grep -qi 'harvest' "$ROOT/README.md" && ok "README documents harvest" || no "README harvest" ""
```

Run: `bash tests/researcher-skill.test.sh` — Expected: the five new checks FAIL.

- [ ] **Step 2: Create the hook registration**

Create `plugins/re-searcher/hooks/hooks.json`:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node \"${CLAUDE_PLUGIN_ROOT}/skills/re-searcher/inbox-note.js\""
          }
        ],
        "description": "re-searcher: note this session in the research vault's inbox for lazy harvest (pointers only — no extraction, no dialog; silent no-op without a vault). Disable with RESEARCH_INBOX=off."
      }
    ]
  }
}
```

- [ ] **Step 3: Bump the marketplace entry**

In `.claude-plugin/marketplace.json`, in the `re-searcher` plugin object: change `"version": "0.1.0"` to `"version": "0.2.0"` and add `"harvest"` and `"transcripts"` to its `keywords` array. Validate: `node -e 'JSON.parse(require("fs").readFileSync(".claude-plugin/marketplace.json","utf8")); console.log("ok")'`.

- [ ] **Step 4: install.sh + README**

4a. In `install.sh`, inside the "Optional — smarter activation" echo block (after the route hook lines, before the final node check), add:

```bash
echo "    re-searcher ships a Stop hook that notes each session in the research vault's"
echo "    inbox for lazy harvest (silent; pointers only; needs an initialized vault). To"
echo "    enable it with a copy install, add to \"hooks\" > \"Stop\" alongside route's:"
echo "      { \"type\": \"command\", \"command\": \"node '$SKILLS/re-searcher/inbox-note.js'\" }"
echo "    Disable with RESEARCH_INBOX=off. Plugin installs load it automatically."
```

4b. In `README.md`, append to the `### re-searcher — research that survives the session` section (after its existing second paragraph):

```markdown
Sessions you never ran through `/research` aren't lost either: a silent Stop hook drops a
pointer into the vault inbox, and `/research save` (this session), `/research harvest
<session>`, or `harvest --inbox` (bulk) mine transcripts into light runs after the fact —
deterministically (Write payloads, source events, final summary, every item with a
transcript:line pointer), idempotently, and with no claims invented: the librarian
(stage 3) does the verifying.
```

- [ ] **Step 5: Run the packaging test, then the FULL sweep**

Run: `bash tests/researcher-skill.test.sh`
Expected: `0 failed`, exit 0.

Run: `for t in tests/*.test.sh; do printf '%-34s ' "$(basename "$t")"; bash "$t" 2>/dev/null | tail -1; done`
Expected: EVERY suite ends `0 failed` (route/handoff suites included — nothing may regress).

- [ ] **Step 6: Manual smoke — harvest a real transcript**

```bash
SMOKE=$(mktemp -d)/vault
SK=plugins/re-searcher/skills/re-searcher
node $SK/vault-init.js --vault "$SMOKE" >/dev/null
node $SK/vault-harvest.js --latest --cwd /Users/walterhoms/Documents/career-switch-pm --vault "$SMOKE" --topic smoke-harvest
node $SK/vault-search.js smoke harvest --vault "$SMOKE"
git -C "$SMOKE" log --oneline
```

Confirm by eye: status harvested with real write/source counts, a `light run · saved to …` provenanceLine, the search hits `smoke-harvest`, git log shows `research: persist run …`. Then re-run the harvest command — expect `already-harvested`. (This reads a real local transcript; it is the pre-release measurement tier, not CI.)

- [ ] **Step 7: Commit**

```bash
git add plugins/re-searcher/hooks/hooks.json .claude-plugin/marketplace.json install.sh README.md tests/researcher-skill.test.sh
git commit -m "feat: register re-searcher Stop hook, bump plugin to 0.2.0, document harvest"
```

---

## Self-Review (performed at write time)

1. **Spec coverage (Roadmap item 2 + Pillar 1 safety net):** transcript mining keyed on the Messages shape with Write→findings, source-tools→events, final text→summary, line pointers, skip-don't-abort, version sniff → Task 2; golden fixtures ≥2 shapes + unknown-major + unknown-block canaries → Task 2 tests; Stop-hook pointers only (session, transcript paths incl. subagents layout, topic guess, transcript_dies), silent, never modal → Task 3; lazy harvest at recall (miss + topically relevant pointer → announce; mining only with a paying customer) → Task 5 + SKILL §7; `/research save` (explicit) and `/research harvest` (bulk) → Tasks 4+6; the ignorable `(unvaulted — "/research save" to keep)` one-liner → SKILL §7; harvest = light-style run, no claims, doctor mines later → Task 4 constraints. Deliberately out (stage 3+): librarian, provenance promotion, orphan sweep, LLM residue mining.
2. **Placeholder scan:** every code step carries complete code; the only free-form step is Task 7's smoke (a real-transcript measurement with exact commands and pass criteria, like Stage 1's Task 13).
3. **Type consistency:** `mine()`'s `{writes[{line,file,bytes,truncated,content}], sources[{line,tool,detail}], finals, summary, sessionId, cwd, versionWarning, messages}` is consumed field-by-field in Task 4's `harvestOne`/`digest` and asserted in both Task 2 and Task 4 tests; `lib.allocateRun -> {runId, runDir, topic}` matches vault-save's `newRun` JSON (Task 1) and harvest's usage (Task 4); the inbox pointer shape written by Task 3 is exactly what Task 4's drain and Task 5's breadcrumb filter read (`kind/session/transcript/cwd/topicGuess/ts/transcript_dies`); vault-save CLI flags used by harvest (`--light --vault --session --transcript`) shipped in Stage 1 and are unchanged here.
4. **Known judgment calls (do not "fix" without discussion):** inbox APPENDS are lock-free by design (hook latency beats strict locking; precedent: fetch-log.jsonl) while REMOVALS lock — asymmetry is intentional; `--inbox` drops dead-transcript pointers rather than queueing them (they can never be harvested); harvest topic defaults to the cwd basename (the spec's "topic guess"), `--topic` overrides; only `.md` Write payloads are embedded in the digest (others listed by path+bytes) to keep harvested runs readable.


