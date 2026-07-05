# Re:Searcher Stage 1 (Core Loop) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working `/research` skill (light + full paths) whose runs persist plans, per-agent findings, synthesis, quote-verified claims and cached sources into a git-backed markdown vault — the spec's "Roadmap → 1. Core loop" — plus the five Stage 0 benchmark amendments.

**Architecture:** Six new zero-dep Node scripts/modules under `plugins/re-searcher/skills/re-searcher/` layered on the shipped Stage 0 trio (`html-extract.js`, `quote-verify.js`, `vault-fetch.js`): `vault-lib.js` (shared core: vault resolution, atomic writes, JSONL, advisory lock, event folding), `vault-init.js` (skeleton + git + templates + allowlist), `claim-validate.js` (per-record claim/event validation incl. quote verify/downgrade/rewrite and the supersedes-DAG check), `vault-views.js` (generated topic.md/INDEX.md, human notes preserved), `vault-save.js` (run allocation, staging completeness, layered persist under lock, auto-commit), `vault-search.js` (multi-probe recall with event folding, near-misses, metrics). On top: `SKILL.md` (≤200 lines, state machine only), `commands/research.md` (routing), `references/*.md` (progressive disclosure), and marketplace/install/README registration in the route plugin's style.

**Tech Stack:** Node core only (`fs`, `path`, `crypto`, `zlib`, `child_process`). Bash test harness in house style (`tests/*.test.sh`, `ok`/`no` counters, temp dirs, Windows skip, no live network in CI).

**Reference spec:** `docs/specs/2026-07-05-re-searcher-design.md` (v2, LOCKED — do not redesign). Amendments source: `plugins/re-searcher/bench/results/STAGE0-REPORT.md` (GO verdict + five required fixes). Form reference: `docs/plans/2026-07-05-re-searcher-stage0.md`.

## Global Constraints

- Zero npm dependencies; Node core modules only; every script starts `#!/usr/bin/env node` + `'use strict';` + a usage-header comment (house style: `plugins/route/skills/route/route-cache.js`).
- CI tests never touch the live network — fixtures from files or a loopback-only inline node HTTP server.
- Files ≤800 lines; functions <50 lines where practical; many small modules over one big script.
- Atomic writes (temp file + rename) for every file written under the vault; append-only files use plain `appendFileSync`.
- All vault **mutation** happens under the single advisory `.lock/` mkdir lock (vault-lib `withLock`). Reads are lock-free. No other concurrency cleverness.
- Fail loud: a missing vault must never masquerade as an empty one — exit 1 with "run vault-init.js or set RESEARCH_VAULT_DIR". Unusable input → non-zero exit + actionable stderr.
- Claims are immutable records + appended event records; status is DERIVED by folding events, never a mutable field. Claim ids are assigned by scripts, never the LLM.
- Layered persist: tier 1 (findings/plan/synthesis/lineage/transcripts/index/views) always lands; tier 2 validates claims PER RECORD and quarantines rejects — bookkeeping can never hold a run hostage.
- SKILL.md ≤200 lines (enforced by a test); every rule that can live in a script's validation or printed output goes there, not in prose.
- Vault dir from `--vault` arg or `RESEARCH_VAULT_DIR` env (suggest default `~/research-vault`); parsers skip unparseable JSONL lines with a counted stderr warning; unknown record fields are preserved on rewrite; every record carries `"v": 1`.
- Commit style: `feat:` / `fix:` / `test:` / `docs:` / `chore:`, no attribution footer.
- Windows: tests skip on MINGW/MSYS/CYGWIN like the Stage 0 tests do.
- **Test authority: `0 failed` + exit 0.** Any "Expected: N passed" prose below is descriptive; do NOT add/remove assertions to match a count.
- Do NOT touch `plugins/route/**` (a separate session may be working on route-learn) except reading it as style reference. Do NOT push to GitHub.

## File Structure

```
plugins/re-searcher/
├── skills/re-searcher/
│   ├── html-extract.js       # Task 1: MODIFY — amendments (b) structural challenge, (d) covered by test, (e) code fences, CLI flag order
│   ├── quote-verify.js       # Task 2: MODIFY — amendments (a) markdown-stripped view, (c) link-safe windows
│   ├── vault-fetch.js        # unchanged (Stage 0)
│   ├── vault-lib.js          # Task 3: NEW — shared core (resolve/atomic/jsonl/lock/fold/git)
│   ├── vault-init.js         # Task 4: NEW — skeleton + git init + templates + allowlist
│   ├── claim-validate.js     # Task 6: NEW — per-record claim/event validation + DAG check
│   ├── vault-views.js        # Task 7: NEW — topic.md + INDEX.md generation (notes preserved)
│   ├── vault-save.js         # Tasks 5+8: NEW — --new-run, --check-staging, persist, --events
│   ├── vault-search.js       # Task 9: NEW — multi-probe recall, folding, near-miss, metrics
│   ├── SKILL.md              # Task 11: NEW — ≤200 lines, state machine only
│   └── references/
│       ├── full-path.md      # Task 11: NEW
│       ├── claims.md         # Task 11: NEW
│       └── correct.md        # Task 11: NEW
├── commands/research.md      # Task 11: NEW — subcommand routing
tests/
├── researcher-extract.test.sh   # Task 1: MODIFY (append)
├── researcher-quote.test.sh     # Task 2: MODIFY (append)
├── researcher-lib.test.sh       # Task 3: NEW
├── researcher-init.test.sh      # Task 4: NEW
├── researcher-save.test.sh      # Tasks 5+8: NEW then extend
├── researcher-claims.test.sh    # Task 6: NEW
├── researcher-views.test.sh     # Task 7: NEW
├── researcher-search.test.sh    # Task 9: NEW
├── researcher-e2e.test.sh       # Task 10: NEW — the contract E2E
└── researcher-skill.test.sh     # Tasks 11+12: NEW then extend
.claude-plugin/marketplace.json  # Task 12: MODIFY — add re-searcher plugin entry
install.sh                       # Task 12: MODIFY — chmod + Done echo
README.md                        # Task 12: MODIFY — re-searcher section
docs/plans/2026-07-05-re-searcher-stage1.md   # this plan (committed first)
```

**Vault layout produced at runtime** (spec subset for Stage 1 — DASHBOARD is a stub, inbox/wayback-queue are seeded empty for stage 2/3):

```
$RESEARCH_VAULT_DIR/            # a git repo; every mutation auto-commits
├── DASHBOARD.md  INDEX.md  index.jsonl  claims.jsonl  metrics.jsonl
├── inbox.jsonl  wayback-queue.jsonl  .lock/ (transient)  .obsidian/app.json
├── topics/<slug>/topic.md      # generated view, '## Notes (human)' preserved
├── topics/<slug>/runs/<date><n>-<sess4>/
│   ├── plan.md  findings/*.md  synthesis.md  lineage.json
│   ├── claims-staged.jsonl (input)  claims-rejected.jsonl (quarantine)
│   └── transcripts/*.gz
├── sources/…  sources/raw/…  (Stage 0 vault-fetch layout, unchanged)
├── attachments/  profiles/
```

---

### Task 1: html-extract.js — Stage 0 amendments (b), (d), (e) + CLI flag order

**Files:**
- Modify: `plugins/re-searcher/skills/re-searcher/html-extract.js`
- Modify: `tests/researcher-extract.test.sh` (append before the final `echo; echo "extract: ..."` line)

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces (unchanged signatures — Tasks 6/8 and vault-fetch depend on them):
  - `extract(html) -> {title, markdown, textLength, linkDensity}` — markdown now wraps restored `<pre>` blocks in ``` fences (amendment e).
  - `assess(html, ext) -> {score, usable, signals}` — `challenge-page` now fires ONLY when the signature is in the `<title>` or co-occurs with `textLength < 400` (amendment b). Signals vocabulary unchanged: `challenge-page|thin-text|link-farm|script-shell`.
  - CLI: `node html-extract.js <file.html> [--assess]` — flag may now appear before OR after the file argument.

- [ ] **Step 1: Append failing tests**

Append to `tests/researcher-extract.test.sh` immediately **before** the final `echo; echo "extract: ..."` line:

```bash
# --- Stage 1 amendments (STAGE0-REPORT) ---

# (b) structural challenge detection: a "Captcha" string inside a big real
# article (login/edit chrome) must NOT refuse the page
cat > "$W/wiki.html" <<'EOF'
<html><head><title>Model Context Protocol - Encyclopedia</title></head><body>
<article><h1>Model Context Protocol</h1>
EOF
for i in $(seq 1 30); do
  echo "<p>The protocol defines a client server architecture for tool use, paragraph $i of the article body text.</p>" >> "$W/wiki.html"
done
cat >> "$W/wiki.html" <<'EOF'
<p>Log in with Captcha to edit this page.</p>
</article></body></html>
EOF
OUT=$(node "$X" "$W/wiki.html" --assess)
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.usable && !r.signals.includes("challenge-page") ? 0 : 1)' "$OUT" \
  && ok "captcha in article chrome does not false-refuse" || no "structural challenge" "$OUT"

# regression: title-signature challenge page still refused
OUT=$(node "$X" "$W/challenge.html" --assess)
node -e 'const r=JSON.parse(process.argv[1]); process.exit(!r.usable && r.signals.includes("challenge-page") ? 0 : 1)' "$OUT" \
  && ok "title-signature challenge still refused" || no "title challenge" "$OUT"

# (d) script-shell signal has a dedicated fixture (was untested in CI)
node -e '
const p = "<p>Real page text sentence that is long enough to escape the thin gate when repeated a bit more.</p>";
const html = "<html><head><title>Shell</title></head><body><main>" + p.repeat(6) + "</main>"
  + "<script>" + "x".repeat(150000) + "</script></body></html>";
require("fs").writeFileSync(process.argv[1], html);' "$W/shell.html"
OUT=$(node "$X" "$W/shell.html" --assess)
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.signals.includes("script-shell") ? 0 : 1)' "$OUT" \
  && ok "script-shell signal fires" || no "script-shell" "$OUT"

# (e) code fences restored around <pre> blocks
OUT=$(node "$X" "$W/article.html")
has "$OUT" '```' && ok "pre restored inside code fences" || no "fences" "$OUT"

# CLI: --assess may precede the file argument
OUT=$(node "$X" --assess "$W/article.html")
has "$OUT" '"usable":true' && ok "--assess before file works" || no "flag order" "$OUT"
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/researcher-extract.test.sh`
Expected: all pre-existing assertions still PASS; the five new ones FAIL (challenge false-fires, no script-shell fixture pass is actually the one that may pass already — the authoritative check is which of the five fail; at minimum "captcha…", "pre restored…", "--assess before file" FAIL). Exit non-zero.

- [ ] **Step 3: Implement the amendments**

In `plugins/re-searcher/skills/re-searcher/html-extract.js`:

3a. Replace the fence-restore line (currently `md = md.replace(/~~~(\d+)~~~/g, (_, i) => fences[Number(i)] || '');`) with:

```js
  md = md.replace(/~~~(\d+)~~~/g, (_, i) => '```\n' + (fences[Number(i)] || '') + '\n```');
```

3b. Replace the whole `assess` function with:

```js
function assess(html, ext) {
  const signals = [];
  let score = 1.0;
  // Structural challenge detection (Stage 0 amendment): a challenge signature
  // only counts when it appears in the <title> or co-occurs with a thin
  // extraction — a "Captcha" string in a 43K-char article's login chrome is
  // not a challenge page.
  const inTitle = CHALLENGE_RE.test(ext.title || '');
  const inBody = CHALLENGE_RE.test(String(html));
  if (inTitle || (inBody && ext.textLength < 400)) { signals.push('challenge-page'); score -= 0.6; }
  if (ext.textLength < 400) { signals.push('thin-text'); score -= 0.55; }
  if (ext.linkDensity > 0.5) { signals.push('link-farm'); score -= 0.3; }
  const rawLen = String(html).length;
  if (rawLen > 20000 && ext.textLength < rawLen / 200) { signals.push('script-shell'); score -= 0.3; }
  score = Math.max(0, Math.min(1, Number(score.toFixed(2))));
  return { score, usable: score >= 0.5, signals };
}
```

3c. Replace the whole `main` function with (flag position independent):

```js
function main() {
  const argv = process.argv.slice(2);
  const wantAssess = argv.includes('--assess');
  const file = argv.find((a) => !a.startsWith('--'));
  if (!file) { process.stderr.write('usage: html-extract.js <file.html> [--assess]\n'); process.exit(1); }
  let html;
  try { html = fs.readFileSync(file, 'utf8'); }
  catch (err) { process.stderr.write('cannot read ' + file + ': ' + (err.code || err.message) + '\n'); process.exit(1); }
  const ext = extract(html);
  const out = wantAssess ? Object.assign({}, ext, assess(html, ext)) : ext;
  process.stdout.write(JSON.stringify(out) + '\n');
}
```

3d. Update the usage-header comment's CLI line to `node html-extract.js <file.html> [--assess]   # flag position free`.

- [ ] **Step 4: Run tests to verify all pass**

Run: `bash tests/researcher-extract.test.sh && bash tests/researcher-fetch.test.sh`
Expected: both end `0 failed`, exit 0 (fetch suite proves `assess`'s consumers didn't regress — its challenge fixture has the signature in the `<title>` so it still gates).

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/html-extract.js tests/researcher-extract.test.sh
git commit -m "fix: re-searcher structural challenge detection, code-fence restore, flag order (stage-0 amendments b/d/e)"
```

---

### Task 2: quote-verify.js — amendments (a) markdown-stripped view, (c) link-safe windows

**Files:**
- Modify: `plugins/re-searcher/skills/re-searcher/quote-verify.js`
- Modify: `tests/researcher-quote.test.sh` (append before the final `echo; echo "quote-verify: ..."` line)

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces (used by Task 6's claim-validate; signature unchanged):
  - `normalize(s)`, `verify(quote, source) -> {verified, method: exact|normalized|fuzzy|none, sourceQuote}`.
  - NEW behavior: after the raw exact/normalized ladder, matching retries against a **markdown-stripped view** of both quote and source (`[label](url)` → label, `**` and backticks removed) with an index map back to original bytes — a match there reports `method: "normalized"` and `sourceQuote` is exact source bytes INCLUDING the markup. Fuzzy runs in the stripped space too.
  - NEW behavior: any verified `sourceQuote` span that cuts into a `[label](url)` construct is widened to include the whole link — sourceQuotes never clip mid-link.
  - Fuzzy guards are NOT weakened: LCS ≥ 0.8 order-sensitive, negation parity, window ≤ 2x quote length all stay.

- [ ] **Step 1: Append failing tests**

Append to `tests/researcher-quote.test.sh` immediately **before** the final `echo; echo "quote-verify: ..."` line:

```bash
# --- Stage 1 amendments: markdown-stripped matching + link-safe windows ---

cat > "$W/s.md" <<'EOF'
# Redirects

Use the **303 See Other** code with a [Location](https://mdn.example/loc) header after PUT requests.
The `Cache-Control` header controls **revalidation** behavior for [shared caches](https://mdn.example/cache) everywhere.
EOF

# (a) plain transcription of marked-up source -> verified via stripped view
printf 'Use the 303 See Other code with a Location header after PUT requests.' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"method":"normalized"'; } && ok "markdown-stripped match" || no "stripped" "rc=$rcode $OUT"
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.sourceQuote.includes("**303 See Other**") && r.sourceQuote.includes("[Location](https://mdn.example/loc)") ? 0 : 1)' "$OUT" \
  && ok "sourceQuote keeps real markup bytes" || no "markup bytes" "$OUT"

# backticks + bold + link inside one quoted span
printf 'The Cache-Control header controls revalidation behavior for shared caches everywhere.' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"method":"normalized"'; } && ok "backtick+bold+link stripped match" || no "dense markup" "rc=$rcode $OUT"

# (c) a match ending inside a link label must not clip mid-link
printf 'code with a Location' > "$W/q.txt"
OUT=$(qv); rcode=$?
node -e 'const r=JSON.parse(process.argv[1]); if(!r.verified) process.exit(1); const q=r.sourceQuote; const opens=(q.match(/\[/g)||[]).length; const full=(q.match(/\]\([^)]*\)/g)||[]).length; process.exit(opens===full ? 0 : 1)' "$OUT" \
  && ok "sourceQuote never clips mid-link" || no "link clip" "rc=$rcode $OUT"

# regression: negation-flip must still be rejected (guards not weakened)
cat > "$W/s.md" <<'EOF'
The device flow is not required for public clients and should be avoided when the standard flow works.
EOF
printf 'The device flow is required for public clients and should be avoided when the standard flow works.' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" '"method":"none"'; } && ok "negation flip still rejected" || no "negation" "rc=$rcode $OUT"
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/researcher-quote.test.sh`
Expected: pre-existing assertions PASS; "markdown-stripped match", "sourceQuote keeps real markup bytes", "backtick+bold+link", and "never clips mid-link" FAIL. "negation flip" already passes (it's a regression pin). Exit non-zero.

- [ ] **Step 3: Implement**

In `plugins/re-searcher/skills/re-searcher/quote-verify.js`:

3a. After `sliceOriginal`, add the stripped-view builders and the link-widening repair:

```js
// Markdown-stripped view (Stage 0 amendment: markup mismatch was the entire
// observed claim-demotion class): [label](url) -> label, ** and backticks
// removed — with an index map back to the original bytes so any match still
// slices exact source truth.
function buildStripped(s) {
  const chars = [], map = [];
  let i = 0;
  while (i < s.length) {
    if (s[i] === '[') {
      const close = s.indexOf(']', i);
      if (close !== -1 && close - i <= 300 && s[close + 1] === '(') {
        const paren = s.indexOf(')', close + 2);
        if (paren !== -1 && paren - close <= 600) {
          for (let j = i + 1; j < close; j++) { chars.push(s[j]); map.push(j); }
          i = paren + 1;
          continue;
        }
      }
    }
    if (s[i] === '*' && s[i + 1] === '*') { i += 2; continue; }
    if (s[i] === '`') { i += 1; continue; }
    chars.push(s[i]); map.push(i);
    i++;
  }
  return { text: chars.join(''), map };
}

// Normalized view of the stripped text, with maps composed so a normalized
// index still resolves to an ORIGINAL source index.
function buildStrippedNormalized(s) {
  const st = buildStripped(s);
  const nz = buildNormalized(st.text);
  return { text: nz.text, map: nz.map.map((i) => st.map[i]) };
}

// Never clip a sourceQuote mid-link: if the byte span [a,b] cuts into a
// [label](url) construct, widen to include the whole link.
function wholeLinks(src, a, b) {
  const linkRe = /\[[^\]\n]{0,300}\]\([^()\s]{0,600}\)/g;
  let m;
  while ((m = linkRe.exec(src)) !== null) {
    const s0 = m.index, e0 = m.index + m[0].length - 1;
    if (s0 > b) break;
    if (e0 < a) continue;
    if (s0 < a) a = s0;
    if (e0 > b) b = e0;
  }
  return [a, b];
}
```

3b. Replace the whole `verify` function with a ladder that adds the stripped tier and delegates fuzzy to a helper operating in the stripped space (the helper body is the EXISTING fuzzy code, unchanged except its final return widens through `wholeLinks`):

```js
function verify(quote, source) {
  const q = String(quote), src = String(source);
  if (q.trim().length === 0) return { verified: false, method: 'none', sourceQuote: null };
  if (src.includes(q)) return { verified: true, method: 'exact', sourceQuote: q };

  const nq = buildNormalized(q), ns = buildNormalized(src);
  let idx = ns.text.indexOf(nq.text);
  if (idx !== -1) {
    return { verified: true, method: 'normalized',
      sourceQuote: sliceOriginal(src, ns.map, idx, idx + nq.text.length - 1) };
  }

  // markdown-stripped tier
  const sq = buildStrippedNormalized(q), ss = buildStrippedNormalized(src);
  if (sq.text.length > 0) {
    idx = ss.text.indexOf(sq.text);
    if (idx !== -1) {
      const [a, b] = wholeLinks(src, ss.map[idx], ss.map[idx + sq.text.length - 1]);
      return { verified: true, method: 'normalized', sourceQuote: src.slice(a, b + 1) };
    }
  }

  return fuzzyMatch(sq, ss, src);
}

// Fuzzy tier, operating in the stripped+normalized space. Body is the Stage 0
// fuzzy logic verbatim (n-gram anchoring, window shrink, LCS >= 0.8, negation
// parity, 2x window cap) — do NOT weaken any guard. Only the final slice is
// new: it goes through wholeLinks so windows never clip mid-link.
function fuzzyMatch(nq, ns, src) {
  const qWords = nq.text.toLowerCase().split(' ').filter(Boolean);
  if (qWords.length < 6) return { verified: false, method: 'none', sourceQuote: null };
  const N = Math.min(5, qWords.length);
  const firstGram = qWords.slice(0, N).join(' ');
  const lastGram = qWords.slice(-N).join(' ');
  const lowerNs = ns.text.toLowerCase();
  let start = lowerNs.indexOf(firstGram);
  let endAnchor = lowerNs.lastIndexOf(lastGram);
  if (start === -1 && endAnchor === -1) {
    for (let i = 1; i + N <= qWords.length - 1 && start === -1; i++) {
      start = lowerNs.indexOf(qWords.slice(i, i + N).join(' '));
    }
    if (start === -1) return { verified: false, method: 'none', sourceQuote: null };
  }
  if (start === -1) start = Math.max(0, endAnchor - nq.text.length * 2);
  let end = endAnchor !== -1 && endAnchor >= start
    ? endAnchor + lastGram.length - 1
    : Math.min(ns.text.length - 1, start + Math.floor(nq.text.length * 1.5));

  const stripPunct = (w) => w.replace(/^[^a-z0-9]+|[^a-z0-9]+$/g, '');
  const qWordsClean = qWords.map(stripPunct);
  const qWordSet = new Set(qWordsClean);
  const rawWindowWords = lowerNs.slice(start, end + 1).split(' ').filter(Boolean);
  let firstHit = -1, lastHit = -1;
  { let pos = start;
    for (const w of rawWindowWords) {
      if (qWordSet.has(stripPunct(w))) { if (firstHit === -1) firstHit = pos; lastHit = pos + w.length - 1; }
      pos += w.length + 1;
    } }
  if (firstHit === -1) return { verified: false, method: 'none', sourceQuote: null };
  start = firstHit; end = lastHit;

  if (end - start + 1 > nq.text.length * 2) return { verified: false, method: 'none', sourceQuote: null };

  const windowWordsClean = lowerNs.slice(start, end + 1).split(' ').filter(Boolean).map(stripPunct);
  if (windowWordsClean.length > qWords.length * 3) return { verified: false, method: 'none', sourceQuote: null };

  const lcsLen = lcsLength(qWordsClean, windowWordsClean);
  if (lcsLen / qWordsClean.length < 0.8) return { verified: false, method: 'none', sourceQuote: null };

  const negRe = /\b(not|never|no|none|cannot|can't|won't|don't|doesn't|didn't|isn't|aren't|wasn't|weren't|without)\b/gi;
  const qNegCount = (nq.text.match(negRe) || []).length;
  const windowText = lowerNs.slice(start, end + 1);
  const wNegCount = (windowText.match(negRe) || []).length;
  if (qNegCount !== wNegCount) return { verified: false, method: 'none', sourceQuote: null };

  const [a, b] = wholeLinks(src, ns.map[start], ns.map[end]);
  return { verified: true, method: 'fuzzy', sourceQuote: src.slice(a, b + 1) };
}
```

(Delete the old fuzzy body from `verify` — it now lives in `fuzzyMatch`. `lcsLength`, `normChar`, `buildNormalized`, `sliceOriginal`, CLI `main`, and exports are unchanged. Update the usage-header comment to mention the stripped tier and link-safe windows.)

- [ ] **Step 4: Run tests to verify all pass**

Run: `bash tests/researcher-quote.test.sh`
Expected: `0 failed`, exit 0 — all pre-existing assertions (exact, normalized, dash, fuzzy relocation, fabrication, negation, usage) must still pass; the fuzzy tier now anchors in the stripped space, which is a superset of the old behavior on markup-free sources.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/quote-verify.js tests/researcher-quote.test.sh
git commit -m "fix: quote-verify markdown-stripped matching + link-safe windows (stage-0 amendments a/c)"
```

---

### Task 3: vault-lib.js — shared core

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/vault-lib.js`
- Test: `tests/researcher-lib.test.sh`

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces (used by Tasks 4–10 — exact signatures):
  - `resolveVault(cliVal, {mustExist=true}) -> abs path` — exits 1 loud if unset/missing (init passes `mustExist:false`).
  - `atomicWrite(file, data)`; `readJsonl(file) -> {records, skipped, missing}` (skip-don't-abort, counted stderr warning); `appendJsonl(file, obj)`.
  - `parseFrontmatter(text) -> {fields, body}` — `---` delimited `key: value`; values that parse as JSON (arrays etc.) are parsed.
  - `slugify(s)`; `sha8(s)`; `newId(prefix, seed, takenSet)`; `msleep(ms)`.
  - `withLock(vault, fn)` — advisory `.lock/` mkdir; stale >5min stolen with a loud warning; waits up to 10s then throws.
  - `gitCommit(vault, message) -> {committed, warning}` — tolerates "nothing to commit"; missing git/.git → warning, never a throw.
  - `foldClaims(records) -> {claims: Map<id, folded>, skippedEvents}` — folded = record + `{status: active|superseded|retracted, supersededBy[], contradictedBy[], events[]}`; `verify` events promote provenance to `externally-verified`.
  - `resolveTerminal(claimsMap, id) -> [terminal active claims]` — follows supersede chains, cycle-safe.

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-lib.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-lib.js
# Run: bash tests/researcher-lib.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/re-searcher/skills/re-searcher/vault-lib.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-lib tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"; mkdir -p "$V"
echo "vault-lib tests"

# 1. frontmatter roundtrip incl JSON arrays
node -e '
const lib = require(process.argv[1]);
const { fields, body } = lib.parseFrontmatter("---\ntopic: mcp-auth\naliases: [\"a b\", \"c\"]\nn: 3\n---\nBody here");
if (fields.topic !== "mcp-auth") process.exit(1);
if (!Array.isArray(fields.aliases) || fields.aliases[0] !== "a b") process.exit(2);
if (fields.n !== 3) process.exit(3);
if (body.trim() !== "Body here") process.exit(4);
' "$LIB" && ok "parseFrontmatter" || no "parseFrontmatter" "rc=$?"

# 2. readJsonl skips bad lines with a count
printf '{"a":1}\nnot json\n{"a":2}\n' > "$W/x.jsonl"
node -e '
const lib = require(process.argv[1]);
const r = lib.readJsonl(process.argv[2]);
process.exit(r.records.length === 2 && r.skipped === 1 && !r.missing ? 0 : 1);
' "$LIB" "$W/x.jsonl" 2>/dev/null && ok "readJsonl skip-dont-abort" || no "readJsonl" ""

# 3. fold: supersede chain resolves to terminal; retract kills; contradict flags both; verify promotes
node -e '
const lib = require(process.argv[1]);
const recs = [
  {id:"clm_a", statement:"old", topic:"t"},
  {id:"clm_b", statement:"mid", topic:"t"},
  {id:"clm_c", statement:"new", topic:"t"},
  {id:"clm_d", statement:"dead", topic:"t"},
  {id:"clm_e", statement:"x", topic:"t"},
  {id:"clm_f", statement:"y", topic:"t"},
  {op:"supersede", claim:"clm_a", by:"clm_b"},
  {op:"supersede", claim:"clm_b", by:"clm_c"},
  {op:"retract", claim:"clm_d", by:"human"},
  {op:"contradict", claim:"clm_e", by:"clm_f"},
  {op:"verify", claim:"clm_f", by:"doctor"},
];
const { claims } = lib.foldClaims(recs);
const term = lib.resolveTerminal(claims, "clm_a");
if (term.length !== 1 || term[0].id !== "clm_c") process.exit(1);
if (claims.get("clm_d").status !== "retracted") process.exit(2);
if (!claims.get("clm_e").contradictedBy.includes("clm_f")) process.exit(3);
if (!claims.get("clm_f").contradictedBy.includes("clm_e")) process.exit(4);
if (claims.get("clm_f").provenance !== "externally-verified") process.exit(5);
if (lib.resolveTerminal(claims, "clm_d").length !== 0) process.exit(6);
' "$LIB" && ok "foldClaims + resolveTerminal" || no "fold" "rc=$?"

# 4. resolveTerminal is cycle-safe on corrupt data
node -e '
const lib = require(process.argv[1]);
const recs = [
  {id:"clm_a", statement:"a"}, {id:"clm_b", statement:"b"},
  {op:"supersede", claim:"clm_a", by:"clm_b"},
  {op:"supersede", claim:"clm_b", by:"clm_a"},
];
const { claims } = lib.foldClaims(recs);
process.exit(lib.resolveTerminal(claims, "clm_a").length === 0 ? 0 : 1);
' "$LIB" && ok "terminal cycle-safe" || no "cycle" ""

# 5. newId collision bumps
node -e '
const lib = require(process.argv[1]);
const a = lib.newId("clm", "seed", new Set());
const b = lib.newId("clm", "seed", new Set([a]));
process.exit(a !== b && a.startsWith("clm_") && b.startsWith("clm_") ? 0 : 1);
' "$LIB" && ok "newId collision bump" || no "newId" ""

# 6. withLock serializes two concurrent writers
node -e '
const lib = require(process.argv[1]); const fs = require("fs");
lib.withLock(process.argv[2], () => {
  fs.appendFileSync(process.argv[2] + "/log.txt", process.argv[3] + "-start\n");
  lib.msleep(250);
  fs.appendFileSync(process.argv[2] + "/log.txt", process.argv[3] + "-end\n");
});' "$LIB" "$V" a & P1=$!
node -e '
const lib = require(process.argv[1]); const fs = require("fs");
lib.withLock(process.argv[2], () => {
  fs.appendFileSync(process.argv[2] + "/log.txt", process.argv[3] + "-start\n");
  lib.msleep(250);
  fs.appendFileSync(process.argv[2] + "/log.txt", process.argv[3] + "-end\n");
});' "$LIB" "$V" b & P2=$!
wait $P1; R1=$?; wait $P2; R2=$?
node -e '
const lines = require("fs").readFileSync(process.argv[1] + "/log.txt", "utf8").trim().split("\n");
if (lines.length !== 4) process.exit(1);
// no interleaving: line 0/1 share a prefix, line 2/3 share the other
const p0 = lines[0][0], p1 = lines[1][0], p2 = lines[2][0], p3 = lines[3][0];
process.exit(p0 === p1 && p2 === p3 && p0 !== p2 ? 0 : 2);
' "$V" && [ $R1 -eq 0 ] && [ $R2 -eq 0 ] && ok "lock serializes writers" || no "lock" "$(cat "$V/log.txt" 2>/dev/null)"
[ -d "$V/.lock" ] && no "lock released" "still held" || ok "lock released"

# 7. stale lock is stolen
mkdir "$V/.lock"
touch -t 202001010000 "$V/.lock"
node -e '
const lib = require(process.argv[1]);
lib.withLock(process.argv[2], () => {});' "$LIB" "$V" 2>"$W/steal.err" && ok "stale lock stolen" || no "stale steal" "$(cat "$W/steal.err")"
grep -q "stale" "$W/steal.err" && ok "steal is loud" || no "steal loud" "$(cat "$W/steal.err")"

# 8. gitCommit outside a repo warns, never throws
node -e '
const lib = require(process.argv[1]);
const r = lib.gitCommit(process.argv[2], "test");
process.exit(!r.committed && /git/.test(r.warning || "") ? 0 : 1);
' "$LIB" "$V" && ok "gitCommit non-repo warns" || no "gitCommit" ""

echo; echo "vault-lib: $pass passed, $fail failed"; [ $fail -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/researcher-lib.test.sh`
Expected: FAIL — cannot find module vault-lib.js.

- [ ] **Step 3: Write the implementation**

Create `plugins/re-searcher/skills/re-searcher/vault-lib.js`:

```js
#!/usr/bin/env node
'use strict';
// vault-lib — shared core for the re-searcher vault scripts (module only).
// Deliberately boring: vault resolution that fails loud, atomic writes,
// skip-don't-abort JSONL, ONE advisory mkdir lock for all mutation, git
// auto-commit, and the event fold that turns the append-only claims file
// into effective statuses. Scripts import this; nothing re-implements it.
//
// Module API:
//   resolveVault(cliVal, {mustExist}) atomicWrite(file, data)
//   readJsonl(file) appendJsonl(file, obj) parseFrontmatter(text)
//   slugify(s) sha8(s) newId(prefix, seed, taken) msleep(ms)
//   withLock(vault, fn) gitCommit(vault, message)
//   foldClaims(records) resolveTerminal(claimsMap, id)

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

function resolveVault(cliVal, opts) {
  const o = opts || {};
  const vault = cliVal || process.env.RESEARCH_VAULT_DIR || null;
  if (!vault) {
    process.stderr.write('vault not configured — pass --vault or set RESEARCH_VAULT_DIR (suggestion: ~/research-vault)\n');
    process.exit(1);
  }
  const abs = path.resolve(vault);
  if (o.mustExist !== false && !fs.existsSync(abs)) {
    process.stderr.write('vault missing at ' + abs + ' — run vault-init.js or set RESEARCH_VAULT_DIR (a missing vault must never look like an empty one)\n');
    process.exit(1);
  }
  return abs;
}

function atomicWrite(file, data) {
  const tmp = file + '.tmp' + process.pid;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}

function readJsonl(file) {
  if (!fs.existsSync(file)) return { records: [], skipped: 0, missing: true };
  const records = [];
  let skipped = 0;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try { records.push(JSON.parse(line)); } catch (_e) { skipped++; }
  }
  if (skipped) process.stderr.write('vault-lib: skipped ' + skipped + ' unparseable line(s) in ' + path.basename(file) + '\n');
  return { records, skipped, missing: false };
}

function appendJsonl(file, obj) {
  fs.appendFileSync(file, JSON.stringify(obj) + '\n');
}

// Minimal frontmatter: --- delimited key: value lines; values that parse as
// JSON (arrays, numbers, booleans) are parsed, everything else is a string.
function parseFrontmatter(text) {
  const m = String(text).match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return { fields: {}, body: String(text) };
  const fields = {};
  for (const line of m[1].split('\n')) {
    const km = line.match(/^([A-Za-z_][\w-]*):\s*(.*)$/);
    if (!km) continue;
    const raw = km[2].trim();
    let val = raw;
    if (raw !== '') { try { val = JSON.parse(raw); } catch (_e) { val = raw; } }
    fields[km[1]] = val;
  }
  return { fields, body: m[2] };
}

function slugify(s) {
  return String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'topic';
}

function sha8(s) { return crypto.createHash('sha256').update(String(s), 'utf8').digest('hex').slice(0, 10); }

function newId(prefix, seed, taken) {
  let id = prefix + '_' + sha8(seed);
  let n = 2;
  while (taken && taken.has(id)) { id = prefix + '_' + sha8(seed) + '-' + n; n++; }
  return id;
}

function msleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

const LOCK_STALE_MS = 5 * 60 * 1000;
const LOCK_WAIT_MS = 10 * 1000;

function withLock(vault, fn) {
  const lockDir = path.join(vault, '.lock');
  const deadline = Date.now() + LOCK_WAIT_MS;
  for (;;) {
    try { fs.mkdirSync(lockDir); break; }
    catch (e) {
      if (e.code !== 'EEXIST') throw e;
      let age = null;
      try { age = Date.now() - fs.statSync(lockDir).mtimeMs; } catch (_e) { continue; } // vanished — retry now
      if (age > LOCK_STALE_MS) {
        process.stderr.write('vault-lib: stealing stale lock (' + Math.round(age / 1000) + 's old) at ' + lockDir + '\n');
        try { fs.rmdirSync(lockDir); } catch (_e) {}
        continue;
      }
      if (Date.now() > deadline) {
        throw new Error('vault is locked (' + lockDir + ', ' + Math.round(age / 1000) + 's old) — another process is writing; retry, or remove the dir if you know it is dead');
      }
      msleep(200);
    }
  }
  try { return fn(); }
  finally { try { fs.rmdirSync(lockDir); } catch (_e) {} }
}

function gitCommit(vault, message) {
  try { execFileSync('git', ['-C', vault, 'rev-parse', '--git-dir'], { stdio: 'pipe' }); }
  catch (_e) { return { committed: false, warning: 'vault is not a git repo — run vault-init.js to enable auto-commits' }; }
  try {
    execFileSync('git', ['-C', vault, 'add', '-A'], { stdio: 'pipe' });
    execFileSync('git', ['-C', vault, 'commit', '-q', '-m', message], { stdio: 'pipe' });
    return { committed: true, warning: null };
  } catch (e) {
    const out = ((e.stdout || '') + (e.stderr || '')).toString();
    if (/nothing to commit|nothing added/.test(out)) return { committed: false, warning: null };
    return { committed: false, warning: 'git auto-commit failed: ' + (out.trim().split('\n')[0] || e.message) };
  }
}

// Fold the append-only claims file: claim records (id, no op) get a derived
// status; event records (op) mutate ONLY the folded view, never the file.
function foldClaims(records) {
  const claims = new Map();
  let skippedEvents = 0;
  for (const r of records) {
    if (r && r.id && !r.op) {
      claims.set(r.id, Object.assign({}, r, { status: 'active', supersededBy: [], contradictedBy: [], events: [] }));
    }
  }
  for (const r of records) {
    if (!r || !r.op) continue;
    const c = claims.get(r.claim);
    if (!c) { skippedEvents++; continue; }
    c.events.push(r);
    if (r.op === 'retract') c.status = 'retracted';
    else if (r.op === 'supersede') {
      if (c.status !== 'retracted') c.status = 'superseded';
      if (r.by) c.supersededBy.push(r.by);
    } else if (r.op === 'contradict') {
      if (r.by) {
        c.contradictedBy.push(r.by);
        const other = claims.get(r.by);
        if (other) other.contradictedBy.push(r.claim);
      }
    } else if (r.op === 'verify') c.provenance = 'externally-verified';
  }
  return { claims, skippedEvents };
}

function resolveTerminal(claims, id, seen) {
  const s = seen || new Set();
  if (s.has(id)) return [];
  s.add(id);
  const c = claims.get(id);
  if (!c) return [];
  if (c.status === 'active') return [c];
  if (c.status === 'superseded' && c.supersededBy.length) {
    const out = [];
    for (const nxt of c.supersededBy) {
      for (const t of resolveTerminal(claims, nxt, s)) if (!out.includes(t)) out.push(t);
    }
    return out;
  }
  return [];
}

module.exports = { resolveVault, atomicWrite, readJsonl, appendJsonl, parseFrontmatter, slugify, sha8, newId, msleep, withLock, gitCommit, foldClaims, resolveTerminal };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/researcher-lib.test.sh`
Expected: `0 failed`, exit 0. The lock test takes ~0.5s (two 250ms critical sections serialized).

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-lib.js tests/researcher-lib.test.sh
git commit -m "feat: re-searcher vault-lib — lock, jsonl, frontmatter, event folding, git auto-commit"
```

---

### Task 4: vault-init.js — skeleton, git lifecycle, templates, allowlist

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/vault-init.js`
- Test: `tests/researcher-init.test.sh`

**Interfaces:**
- Consumes: `require('./vault-lib')` → `resolveVault`, `atomicWrite`, `gitCommit`.
- Produces (used by the skill and Tasks 5–10's tests):
  - CLI: `node vault-init.js [--vault <dir>]` — idempotent create/repair; prints one JSON line `{status: created|exists, vault, git: initialized|already|absent}`; exit 0/1. The ONLY command allowed to create the vault dir.
  - `node vault-init.js --template plan|task-spec|finding` — template on stdout (no vault needed). The plan template contains the machine-readable ```manifest fenced block Tasks 5/8 parse.
  - `node vault-init.js --allowlist` — permissions snippet on stdout.

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-init.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-init.js
# Run: bash tests/researcher-init.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
I="$ROOT/plugins/re-searcher/skills/re-searcher/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-init tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
echo "vault-init tests"

# 1. creates skeleton + git repo
OUT=$(node "$I" --vault "$V" 2>/dev/null); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"created"'; } && ok "creates vault" || no "create" "rc=$rcode $OUT"
ALL=1
for d in topics sources/raw attachments profiles; do [ -d "$V/$d" ] || ALL=0; done
for f in index.jsonl claims.jsonl metrics.jsonl inbox.jsonl wayback-queue.jsonl INDEX.md DASHBOARD.md; do [ -f "$V/$f" ] || ALL=0; done
[ $ALL -eq 1 ] && ok "skeleton complete" || no "skeleton" "$(ls -R "$V")"
[ -d "$V/.git" ] && ok "git repo initialized" || no "git" ""
git -C "$V" log --oneline 2>/dev/null | grep -q "vault init" && ok "initial auto-commit" || no "initial commit" "$(git -C "$V" log --oneline 2>&1)"
[ -f "$V/.obsidian/app.json" ] && ok "obsidian ignore config" || no "obsidian" ""

# 2. idempotent second run
OUT=$(node "$I" --vault "$V" 2>/dev/null); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"exists"'; } && ok "idempotent re-run" || no "idempotent" "rc=$rcode $OUT"

# 3. templates
OUT=$(node "$I" --template plan)
{ has "$OUT" 'manifest' && has "$OUT" 'topic:' && has "$OUT" 'aliases:' && has "$OUT" 'questions:'; } && ok "plan template" || no "plan tpl" "$OUT"
OUT=$(node "$I" --template task-spec)
{ has "$OUT" 'ROLE:' && has "$OUT" 'vault-fetch.js' && has "$OUT" '500 bytes'; } && ok "task-spec template" || no "task-spec tpl" "$OUT"
OUT=$(node "$I" --template finding)
{ has "$OUT" 'role:' && has "$OUT" '## Sources' && has "$OUT" '## Gaps'; } && ok "finding template" || no "finding tpl" "$OUT"
node "$I" --template nope >/dev/null 2>&1; [ $? -eq 1 ] && ok "unknown template fails" || no "tpl fail" "$?"

# 4. allowlist snippet
OUT=$(node "$I" --allowlist)
has "$OUT" 'Write(' && has "$OUT" 'vault-save.js' && ok "allowlist snippet" || no "allowlist" "$OUT"

echo; echo "vault-init: $pass passed, $fail failed"; [ $fail -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/researcher-init.test.sh`
Expected: FAIL — vault-init.js not found.

- [ ] **Step 3: Write the implementation**

Create `plugins/re-searcher/skills/re-searcher/vault-init.js`:

```js
#!/usr/bin/env node
'use strict';
// vault-init — idempotent vault skeleton + git lifecycle + templates.
// Creates the directory layout, seed files, Obsidian ignore config, and a
// git repo with a commit identity, then prints one JSON line. Also emits the
// plan / task-spec / finding templates (--template) and a permissions
// allowlist snippet (--allowlist) so first contact isn't a prompt storm.
//
//   node vault-init.js [--vault <dir>]                 # create/repair skeleton
//   node vault-init.js --template plan|task-spec|finding
//   node vault-init.js --allowlist
//
// exit 0 ok / 1 error. Init is the ONLY command allowed to create the vault
// dir — every other script fails loud on a missing vault.

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const lib = require('./vault-lib');

const TEMPLATES = {
  plan: `---
topic: <slug>
title: <human title>
scope: general
classification: straightforward|breadth-first|depth-first
session: <session-id-or-anon>
aliases: ["<synonym>", "<synonym>"]
questions: ["<anticipated future question>", "<another>"]
date: <YYYY-MM-DD>
---

# Plan — <human title>

## Question

<the research question, verbatim>

## Decomposition

<one line per agent: role — core objective>

\`\`\`manifest
[{"role": "<agent-role>", "file": "findings/<agent-role>.md"}]
\`\`\`

## Budget & stop criteria

<N agents, ~M tool calls each; stop when ...>
`,
  'task-spec': `You are one research agent in a fan-out. Do exactly this and nothing else.

ROLE: <agent-role>
OBJECTIVE: <one core objective>
SCOPE: <in-scope> / NOT: <out-of-scope>
SOURCES: prefer official docs and primary sources; fetch pages with
  node <skill-dir>/vault-fetch.js <url> --vault <vault-dir>
  (exit 2 = low confidence: try a better URL or note the gap; record every
  sourceId the fetch prints — claims will need them)
OUTPUT: Write (one Write tool call) your full raw findings to
  <run-dir>/findings/<agent-role>.md
  using the finding template (node <skill-dir>/vault-init.js --template finding),
  at least 500 bytes of real content. Then return ONLY a summary of at most
  2000 characters plus the file path.
`,
  finding: `---
role: <agent-role>
run: <run-id>
task: <one-line task restatement>
date: <YYYY-MM-DD>
---

# Findings — <agent-role>

## Summary

<3-6 sentences>

## Details

<the full raw findings: quotes, data, URLs, dead ends — everything>

## Sources

- <sourceId or URL> — <one line on what it contributed>

## Gaps

- <what you could not establish, and why>
`,
};

const ALLOWLIST = `Add to ~/.claude/settings.json under "permissions" > "allow" (adjust the vault path if you moved it):
  "Write(~/research-vault/**)",
  "Bash(node *vault-init.js*)",
  "Bash(node *vault-fetch.js*)",
  "Bash(node *vault-save.js*)",
  "Bash(node *vault-search.js*)"
`;

function arg(name, dflt) {
  const i = process.argv.indexOf(name);
  return i !== -1 ? process.argv[i + 1] : dflt;
}

function main() {
  if (process.argv.includes('--allowlist')) { process.stdout.write(ALLOWLIST); return; }
  if (process.argv.includes('--template')) {
    const tpl = arg('--template', null);
    if (!tpl || !TEMPLATES[tpl]) { process.stderr.write('unknown template: ' + tpl + ' (plan | task-spec | finding)\n'); process.exit(1); }
    process.stdout.write(TEMPLATES[tpl]);
    return;
  }

  const vault = lib.resolveVault(arg('--vault', null), { mustExist: false });
  const created = !fs.existsSync(path.join(vault, 'index.jsonl'));
  for (const d of ['topics', 'sources/raw', 'attachments', 'profiles', '.obsidian']) {
    fs.mkdirSync(path.join(vault, d), { recursive: true });
  }
  for (const f of ['index.jsonl', 'claims.jsonl', 'metrics.jsonl', 'inbox.jsonl', 'wayback-queue.jsonl']) {
    const p = path.join(vault, f);
    if (!fs.existsSync(p)) fs.writeFileSync(p, '');
  }
  const indexMd = path.join(vault, 'INDEX.md');
  if (!fs.existsSync(indexMd)) lib.atomicWrite(indexMd, '# Research vault\n\n_No topics yet — run /research <question>._\n');
  const dash = path.join(vault, 'DASHBOARD.md');
  if (!fs.existsSync(dash)) lib.atomicWrite(dash, '# Dashboard\n\n_Generated by the librarian (stage 3). Nothing here yet._\n\nSee [INDEX](INDEX.md).\n');
  const obs = path.join(vault, '.obsidian', 'app.json');
  if (!fs.existsSync(obs)) lib.atomicWrite(obs, JSON.stringify({ userIgnoreFilters: ['sources/raw/', '.lock/', 'attachments/'] }, null, 2) + '\n');

  let git = 'absent';
  try {
    execFileSync('git', ['--version'], { stdio: 'pipe' });
    if (!fs.existsSync(path.join(vault, '.git'))) {
      execFileSync('git', ['-C', vault, 'init', '-q'], { stdio: 'pipe' });
      git = 'initialized';
    } else git = 'already';
    // auto-commits need an identity; set a repo-local one only if none resolves
    try { execFileSync('git', ['-C', vault, 'config', 'user.email'], { stdio: 'pipe' }); }
    catch (_e) {
      execFileSync('git', ['-C', vault, 'config', 'user.name', 're-searcher'], { stdio: 'pipe' });
      execFileSync('git', ['-C', vault, 'config', 'user.email', 're-searcher@local'], { stdio: 'pipe' });
    }
    const c = lib.gitCommit(vault, created ? 'research: vault init' : 'research: vault repair');
    if (c.warning) process.stderr.write('vault-init: ' + c.warning + '\n');
  } catch (_e) {
    process.stderr.write('vault-init: git not found — vault works, but auto-commit history is disabled\n');
  }

  process.stdout.write(JSON.stringify({ status: created ? 'created' : 'exists', vault, git }) + '\n');
  process.stderr.write('tip: node vault-init.js --allowlist prints a permissions snippet for smoother runs\n');
}

main();
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/researcher-init.test.sh`
Expected: `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-init.js tests/researcher-init.test.sh
git commit -m "feat: re-searcher vault-init — skeleton, git lifecycle, templates, allowlist"
```

---

### Task 5: vault-save.js — `--new-run` allocation + `--check-staging` completeness

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/vault-save.js` (persist mode arrives in Task 8; this task ships the file with a loud stub for it)
- Test: `tests/researcher-save.test.sh`

**Interfaces:**
- Consumes: vault-lib (`resolveVault`, `slugify`, `parseFrontmatter`).
- Produces (used by the skill, Task 8, Task 10):
  - CLI `node vault-save.js --new-run --topic <slug> [--session <id>] [--vault <dir>]` → atomic run-folder allocation: bare `mkdir` (never `-p` for the leaf) of `topics/<slug>/runs/<YYYY-MM-DD><letter>-<sess4>/` (letters a–z on collision), plus its `findings/` subdir. Prints `{runId, runDir, topic}`. Exit 0/1.
  - CLI `node vault-save.js --check-staging <run-dir>` → parses plan.md's ```manifest fenced block (JSON array of `{role, file}`), checks each file: exists, ≥500 bytes, finding frontmatter has `role:`. Prints `{ok, agents, missing, stubs, badHeader}`. Exit 0 complete / 2 incomplete / 1 error (no plan.md, no/bad manifest).
  - Internal helpers Task 8 reuses verbatim: `getFlag`, `getAll`, `die`, `today`, `readManifest(runDir)`, `stagingReport(runDir)`, `MIN_FINDING_BYTES = 500`.

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-save.test.sh`:

````bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-save.js
# Run: bash tests/researcher-save.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/plugins/re-searcher/skills/re-searcher/vault-save.js"
I="$ROOT/plugins/re-searcher/skills/re-searcher/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-save tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1
echo "vault-save tests"

# --- --new-run ---

# 1. allocates a run folder with findings/ and a date+letter+session id
OUT=$(node "$S" --new-run --topic "MCP Auth Landscape" --session 9f3c2ab1 --vault "$V"); rcode=$?
RUN1=$(node -e 'console.log(JSON.parse(process.argv[1]).runDir)' "$OUT")
{ [ $rcode -eq 0 ] && [ -d "$RUN1/findings" ]; } && ok "new-run allocates" || no "new-run" "rc=$rcode $OUT"
case "$RUN1" in "$V/topics/mcp-auth-landscape/runs/"*a-9f3c) ok "run id shape date+letter+sess4" ;; *) no "run id shape" "$RUN1" ;; esac

# 2. same-day second run gets the next letter
OUT=$(node "$S" --new-run --topic "MCP Auth Landscape" --session 9f3c2ab1 --vault "$V")
RUN2=$(node -e 'console.log(JSON.parse(process.argv[1]).runDir)' "$OUT")
case "$RUN2" in *b-9f3c) ok "collision -> next letter" ;; *) no "letter bump" "$RUN2" ;; esac

# 3. missing --topic fails loud
node "$S" --new-run --vault "$V" >/dev/null 2>&1; [ $? -eq 1 ] && ok "new-run without topic fails" || no "topic required" "$?"

# --- --check-staging ---

# 4. no plan.md -> exit 1 loud
mkdir -p "$W/norun"
ERR=$(node "$S" --check-staging "$W/norun" 2>&1 >/dev/null); rcode=$?
{ [ $rcode -eq 1 ] && has "$ERR" "plan.md"; } && ok "no plan.md fails loud" || no "no plan" "rc=$rcode $ERR"

# 5. manifest vs files: missing, stub, bad header, then complete
cat > "$RUN1/plan.md" <<'EOF'
---
topic: mcp-auth-landscape
title: MCP Auth Landscape
aliases: ["mcp oauth", "model context protocol auth"]
questions: ["does mcp require oauth 2.1?"]
scope: general
session: 9f3c2ab1
---

# Plan

## Question
What is the MCP auth landscape?

```manifest
[{"role": "spec-reader", "file": "findings/spec-reader.md"},
 {"role": "ecosystem", "file": "findings/ecosystem.md"}]
```
EOF
OUT=$(node "$S" --check-staging "$RUN1"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" '"ok":false' && has "$OUT" 'spec-reader.md' && has "$OUT" 'ecosystem.md'; } \
  && ok "missing findings detected" || no "missing" "rc=$rcode $OUT"

cat > "$RUN1/findings/spec-reader.md" <<EOF
---
role: spec-reader
run: $(basename "$RUN1")
task: read the auth spec
date: 2026-07-05
---

# Findings — spec-reader

## Summary
$(printf 'The spec requires OAuth 2.1 with PKCE for remote servers. %.0s' 1 2 3 4 5 6 7 8 9 10)

## Details
$(printf 'Detail sentence about token endpoints and dynamic client registration. %.0s' 1 2 3 4 5 6 7 8)

## Sources
- src_test — the spec page
EOF
printf -- '---\nrole: ecosystem\n---\ntoo small' > "$RUN1/findings/ecosystem.md"
OUT=$(node "$S" --check-staging "$RUN1"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" 'stubs' && has "$OUT" 'ecosystem.md'; } && ok "stub finding detected" || no "stub" "rc=$rcode $OUT"

node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[1], "no frontmatter here\n" + "Filler sentence for size requirements in the staging check. ".repeat(12));
' "$RUN1/findings/ecosystem.md"
OUT=$(node "$S" --check-staging "$RUN1"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" 'badHeader' && has "$OUT" 'ecosystem.md'; } && ok "bad header detected" || no "bad header" "rc=$rcode $OUT"

cat > "$RUN1/findings/ecosystem.md" <<EOF
---
role: ecosystem
run: $(basename "$RUN1")
task: survey server implementations
date: 2026-07-05
---

# Findings — ecosystem

## Summary
$(printf 'Most public MCP servers ship bearer-token auth and defer OAuth to gateways. %.0s' 1 2 3 4 5 6 7 8)

## Details
$(printf 'Detail sentence about gateway adapters and session tokens in the wild. %.0s' 1 2 3 4 5 6 7 8)
EOF
OUT=$(node "$S" --check-staging "$RUN1"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"ok":true' && has "$OUT" '"agents":2'; } && ok "complete staging passes" || no "complete" "rc=$rcode $OUT"

echo; echo "vault-save: $pass passed, $fail failed"; [ $fail -eq 0 ]
````

**Note to implementer:** the node -e writer above produces the bad-header fixture: no frontmatter, >500 bytes.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/researcher-save.test.sh`
Expected: FAIL — vault-save.js not found.

- [ ] **Step 3: Write the implementation**

Create `plugins/re-searcher/skills/re-searcher/vault-save.js`:

```js
#!/usr/bin/env node
'use strict';
// vault-save — the persist gate. Layered so bookkeeping can never hold a run
// hostage: tier 1 (plan/findings/synthesis registration, lineage, transcript
// copies, index append, view regen) always lands; tier 2 validates claims
// PER RECORD and quarantines rejects to the run's claims-rejected.jsonl.
// All mutation happens under the advisory vault lock; every save auto-commits.
//
//   node vault-save.js <run-dir> [--vault <dir>] [--session <id>]
//                      [--transcript <path>]... [--light]        # persist (Task 8)
//   node vault-save.js --new-run --topic <slug> [--session <id>] [--vault <dir>]
//   node vault-save.js --check-staging <run-dir>
//   node vault-save.js --events <file.jsonl> [--vault <dir>]     # Task 8
//
// stdout: one JSON line always. exit 0 ok (complete or partial claims),
// 2 staging incomplete (--check-staging), 1 hard error.

const fs = require('fs');
const path = require('path');
const lib = require('./vault-lib');

const MIN_FINDING_BYTES = 500;

function getFlag(name) { const i = process.argv.indexOf(name); return i !== -1 ? process.argv[i + 1] : null; }
function getAll(name) {
  const out = [];
  process.argv.forEach((x, i) => { if (x === name && process.argv[i + 1]) out.push(process.argv[i + 1]); });
  return out;
}
function die(msg) { process.stderr.write('vault-save: ' + msg + '\n'); process.exit(1); }

function today() {
  const d = new Date();
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
}

function newRun() {
  const vault = lib.resolveVault(getFlag('--vault'));
  const rawTopic = getFlag('--topic');
  if (!rawTopic) die('usage: vault-save.js --new-run --topic <slug> [--session <id>] [--vault <dir>]');
  const topic = lib.slugify(rawTopic);
  const sess = (getFlag('--session') || 'anon').replace(/[^a-z0-9]/gi, '').slice(0, 4).toLowerCase() || 'anon';
  const runsDir = path.join(vault, 'topics', topic, 'runs');
  fs.mkdirSync(runsDir, { recursive: true });
  for (const letter of 'abcdefghijklmnopqrstuvwxyz') {
    const id = today() + letter + '-' + sess;
    const dir = path.join(runsDir, id);
    try { fs.mkdirSync(dir); } catch (e) { if (e.code === 'EEXIST') continue; throw e; }
    fs.mkdirSync(path.join(dir, 'findings'));
    process.stdout.write(JSON.stringify({ runId: id, runDir: dir, topic }) + '\n');
    return;
  }
  die('could not allocate a run folder (26 same-day runs with the same session suffix)');
}

function readManifest(runDir) {
  const planFile = path.join(runDir, 'plan.md');
  if (!fs.existsSync(planFile)) die('no plan.md in ' + runDir + ' — the plan must be persisted before fan-out');
  const plan = fs.readFileSync(planFile, 'utf8');
  const m = plan.match(/```manifest\s*\n([\s\S]*?)```/);
  if (!m) die('plan.md has no ```manifest block — start from: node vault-init.js --template plan');
  let manifest;
  try { manifest = JSON.parse(m[1]); } catch (e) { die('manifest block is not valid JSON: ' + e.message); }
  if (!Array.isArray(manifest) || !manifest.length || manifest.some((e) => !e || !e.role || !e.file)) {
    die('manifest must be a non-empty JSON array of {role, file}');
  }
  return { manifest, plan };
}

function stagingReport(runDir) {
  const { manifest, plan } = readManifest(runDir);
  const missing = [], stubs = [], badHeader = [];
  for (const entry of manifest) {
    const f = path.join(runDir, entry.file);
    if (!fs.existsSync(f)) { missing.push(entry.file); continue; }
    const st = fs.statSync(f);
    if (st.size < MIN_FINDING_BYTES) stubs.push(entry.file + ' (' + st.size + 'B < ' + MIN_FINDING_BYTES + 'B)');
    const fm = lib.parseFrontmatter(fs.readFileSync(f, 'utf8'));
    if (!fm.fields.role) badHeader.push(entry.file + ' (missing finding frontmatter: role)');
  }
  return { manifest, plan, missing, stubs, badHeader, ok: !missing.length && !stubs.length && !badHeader.length };
}

function checkStaging(runDir) {
  const r = stagingReport(path.resolve(runDir));
  process.stdout.write(JSON.stringify({ ok: r.ok, agents: r.manifest.length, missing: r.missing, stubs: r.stubs, badHeader: r.badHeader }) + '\n');
  process.exit(r.ok ? 0 : 2);
}

function main() {
  if (process.argv.includes('--new-run')) return newRun();
  const cs = getFlag('--check-staging');
  if (cs) return checkStaging(cs);
  const ev = getFlag('--events');
  if (ev) return die('--events mode is not built yet (arrives with persist)'); // replaced in Task 8
  const runDir = process.argv[2];
  if (!runDir || runDir.startsWith('--')) {
    die('usage: vault-save.js <run-dir> [--vault <dir>] [--session <id>] [--transcript <p>]... [--light] | --new-run --topic <slug> | --check-staging <run-dir> | --events <file>');
  }
  die('persist mode is not built yet (Task 8 of the stage-1 plan)'); // replaced in Task 8
}

main();
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/researcher-save.test.sh`
Expected: `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-save.js tests/researcher-save.test.sh
git commit -m "feat: re-searcher vault-save --new-run + --check-staging (atomic runs, manifest completeness)"
```

---

### Task 6: claim-validate.js — per-record claim/event validation + DAG check

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/claim-validate.js`
- Test: `tests/researcher-claims.test.sh`

**Interfaces:**
- Consumes: vault-lib (`parseFrontmatter`, `newId`), quote-verify (`verify` — Task 2 behavior).
- Produces (used by Task 8 — exact signatures):
  - `validateClaim(rec, ctx) -> {ok:true, record, downgraded, quoteMethod} | {ok:false, reason}` where `ctx = {vault, runId, topic, date, takenIds:Set, knownIds:Set, supersedeEdges:Map}`. Enforces spec Pillar 3 field rules; assigns `id` (adds it to `ctx.takenIds`); preserves unknown fields; `verbatim-grounded` quotes are verified against `sources/<source>.md` body — verified → quote rewritten to exact source bytes + `quote_method`; miss → provenance downgraded to `model-asserted` + `note`, never rejected. Staged `externally-verified` is rejected (doctor-only).
  - `validateEvent(rec, ctx) -> {ok:true, record} | {ok:false, reason}` — ops `supersede|contradict|retract` stageable (`verify` rejected); `claim` (and `by` for supersede/contradict) must exist in `ctx.knownIds`; supersede runs the cycle check and registers the accepted edge in `ctx.supersedeEdges`.
  - `createsCycle(edgesMap, claimId, byId) -> boolean`.

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-claims.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/claim-validate.js
# Run: bash tests/researcher-claims.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CV="$ROOT/plugins/re-searcher/skills/re-searcher/claim-validate.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-claims tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"; mkdir -p "$V/sources"
cat > "$V/sources/src_fix1.md" <<'EOF'
---
v: 1
kind: web
title: "Fixture"
---
The **MCP spec** requires [OAuth 2.1](https://spec.example/auth) with PKCE for all remote servers as of the June revision.
Bearer tokens remain acceptable for local stdio servers only.
EOF
CTX='{"vault":"'"$V"'","runId":"2026-07-05a-9f3c","topic":"mcp-auth","date":"2026-07-05"}'
vc(){ node -e '
const cv = require(process.argv[1]);
const base = JSON.parse(process.argv[2]);
const ctx = Object.assign(base, { takenIds: new Set(), knownIds: new Set(JSON.parse(process.argv[4] || "[]")), supersedeEdges: new Map() });
const rec = JSON.parse(process.argv[3]);
const res = typeof rec.op === "string" ? cv.validateEvent(rec, ctx) : cv.validateClaim(rec, ctx);
console.log(JSON.stringify(res));
' "$CV" "$CTX" "$1" "${2:-[]}"; }
echo "claim-validate tests"

# 1. empty statement rejected
OUT=$(vc '{"statement":"  "}')
echo "$OUT" | grep -q '"ok":false' && ok "empty statement rejected" || no "empty stmt" "$OUT"

# 2. bad enums rejected; externally-verified not stageable
OUT=$(vc '{"statement":"s","confidence":"certain"}')
echo "$OUT" | grep -q '"ok":false' && ok "bad confidence rejected" || no "bad conf" "$OUT"
OUT=$(vc '{"statement":"s","provenance":"externally-verified"}')
echo "$OUT" | grep -q 'doctor' && ok "externally-verified not stageable" || no "ext-verified" "$OUT"

# 3. defaults + unknown fields preserved + script id
OUT=$(vc '{"statement":"MCP uses OAuth","customField":"kept"}')
node -e '
const r = JSON.parse(process.argv[1]);
const c = r.record;
process.exit(r.ok && c.id.startsWith("clm_") && c.v === 1 && c.run === "2026-07-05a-9f3c"
  && c.topic === "mcp-auth" && c.type === "finding" && c.confidence === "medium"
  && c.provenance === "model-asserted" && c.quantity === null && c.found_by === "unknown"
  && c.customField === "kept" ? 0 : 1);
' "$OUT" && ok "defaults, id, unknown fields" || no "defaults" "$OUT"

# 4. verbatim-grounded: exact quote accepted, transcribed quote REWRITTEN to source bytes
Q='{"statement":"OAuth 2.1 is required","quote":"requires OAuth 2.1 with PKCE for all remote servers","source":"src_fix1","provenance":"verbatim-grounded"}'
OUT=$(vc "$Q")
node -e '
const r = JSON.parse(process.argv[1]);
process.exit(r.ok && r.record.provenance === "verbatim-grounded" && !r.downgraded
  && r.record.quote.includes("[OAuth 2.1](https://spec.example/auth)") ? 0 : 1);
' "$OUT" && ok "verbatim quote verified + rewritten to source bytes" || no "verbatim rewrite" "$OUT"

# 5. fabricated quote -> downgraded to model-asserted, never rejected
Q='{"statement":"x","quote":"The spec forbids bearer tokens everywhere always and forever","source":"src_fix1","provenance":"verbatim-grounded"}'
OUT=$(vc "$Q")
node -e '
const r = JSON.parse(process.argv[1]);
process.exit(r.ok && r.downgraded && r.record.provenance === "model-asserted" && /downgraded/.test(r.record.note) ? 0 : 1);
' "$OUT" && ok "fabricated quote downgraded" || no "downgrade" "$OUT"

# 6. verbatim-grounded with missing source -> rejected
OUT=$(vc '{"statement":"x","quote":"q","source":"src_nope","provenance":"verbatim-grounded"}')
echo "$OUT" | grep -q '"ok":false' && ok "missing source rejected" || no "missing source" "$OUT"
OUT=$(vc '{"statement":"x","quote":"q","provenance":"verbatim-grounded"}')
echo "$OUT" | grep -q '"ok":false' && ok "grounded without source rejected" || no "no source" "$OUT"

# 7. events: vocab + referential integrity
OUT=$(vc '{"op":"promote","claim":"clm_a"}' '["clm_a"]')
echo "$OUT" | grep -q '"ok":false' && ok "bad op rejected" || no "bad op" "$OUT"
OUT=$(vc '{"op":"verify","claim":"clm_a"}' '["clm_a"]')
echo "$OUT" | grep -q 'doctor' && ok "verify event not stageable" || no "verify event" "$OUT"
OUT=$(vc '{"op":"retract","claim":"clm_zz","by":"human"}' '["clm_a"]')
echo "$OUT" | grep -q '"ok":false' && ok "unknown claim rejected" || no "unknown claim" "$OUT"
OUT=$(vc '{"op":"retract","claim":"clm_a","by":"human","reason":"bad research"}' '["clm_a"]')
echo "$OUT" | grep -q '"ok":true' && ok "retract accepted" || no "retract" "$OUT"
OUT=$(vc '{"op":"contradict","claim":"clm_a"}' '["clm_a"]')
echo "$OUT" | grep -q '"ok":false' && ok "contradict needs by" || no "contradict by" "$OUT"

# 8. supersede DAG: self-cycle and batch cycle rejected
node -e '
const cv = require(process.argv[1]);
const ctx = { date: "2026-07-05", knownIds: new Set(["clm_a", "clm_b"]), supersedeEdges: new Map() };
const r1 = cv.validateEvent({ op: "supersede", claim: "clm_a", by: "clm_b" }, ctx);
if (!r1.ok) process.exit(1);
const r2 = cv.validateEvent({ op: "supersede", claim: "clm_b", by: "clm_a" }, ctx);
if (r2.ok) process.exit(2);            // would close the cycle a<-b<-a
if (!/cycle/.test(r2.reason)) process.exit(3);
const r3 = cv.validateEvent({ op: "supersede", claim: "clm_a", by: "clm_a" }, ctx);
process.exit(r3.ok ? 4 : 0);           // self-supersede is a cycle
' "$CV" && ok "supersede cycles rejected" || no "dag" "rc=$?"

# 9. validator-owned fields cannot be smuggled by staged records
OUT=$(vc '{"statement":"clean claim","quote_method":"forged","note":"forged note"}')
node -e '
const r = JSON.parse(process.argv[1]);
process.exit(r.ok && !("quote_method" in r.record) && !("note" in r.record) ? 0 : 1);
' "$OUT" && ok "quote_method/note smuggling blocked" || no "smuggle" "$OUT"

# 10. a claim smuggling a non-string op is still registered as a foldable claim
OUT=$(vc '{"statement":"op smuggle","op":5}')
node -e '
const r = JSON.parse(process.argv[1]);
process.exit(r.ok && !("op" in r.record) ? 0 : 1);
' "$OUT" && ok "non-string op stripped from claims" || no "op strip" "$OUT"

echo; echo "claim-validate: $pass passed, $fail failed"; [ $fail -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/researcher-claims.test.sh`
Expected: FAIL — claim-validate.js not found.

- [ ] **Step 3: Write the implementation**

Create `plugins/re-searcher/skills/re-searcher/claim-validate.js`:

```js
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/researcher-claims.test.sh && bash tests/researcher-quote.test.sh`
Expected: both `0 failed`, exit 0 (test 4's markup-bearing fixture exercises the Task 2 stripped tier through the validator).

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/claim-validate.js tests/researcher-claims.test.sh
git commit -m "feat: re-searcher claim-validate — schema enforcement, quote verify/rewrite/downgrade, DAG check"
```

---

### Task 7: vault-views.js — generated topic.md + INDEX.md, human notes preserved

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/vault-views.js`
- Test: `tests/researcher-views.test.sh`

**Interfaces:**
- Consumes: vault-lib (`readJsonl`, `foldClaims`, `atomicWrite`, `resolveVault`).
- Produces (used by Task 8):
  - `regenTopic(vault, slug) -> topicFilePath` — regenerates `topics/<slug>/topic.md` entirely from the index record, folded claims, run folders and the latest run's synthesis.md. Everything above the literal heading `## Notes (human)` is script-owned; that section (to EOF) is preserved verbatim if present.
  - `regenIndex(vault)` — regenerates `INDEX.md` from index.jsonl (last-record-per-slug wins), newest first.
  - CLI: `node vault-views.js --vault <dir> [--topic <slug>]` — regen one topic (or all) + INDEX.

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-views.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-views.js
# Run: bash tests/researcher-views.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VW="$ROOT/plugins/re-searcher/skills/re-searcher/vault-views.js"
I="$ROOT/plugins/re-searcher/skills/re-searcher/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-views tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1
echo "vault-views tests"

# seed: index record, run with synthesis, claims incl. superseded + contradicted
cat >> "$V/index.jsonl" <<'EOF'
{"v":1,"slug":"mcp-auth","title":"MCP Auth Landscape","aliases":["mcp oauth"],"questions":["is oauth required?"],"scope":"general","run":"2026-07-05a-9f3c","date":"2026-07-05"}
EOF
mkdir -p "$V/topics/mcp-auth/runs/2026-07-05a-9f3c/findings"
cat > "$V/topics/mcp-auth/runs/2026-07-05a-9f3c/plan.md" <<'EOF'
---
topic: mcp-auth
---
# Plan
EOF
printf '# Synthesis\n\nOAuth 2.1 is required for remote MCP servers.\n' > "$V/topics/mcp-auth/runs/2026-07-05a-9f3c/synthesis.md"
cat >> "$V/claims.jsonl" <<'EOF'
{"v":1,"id":"clm_old","topic":"mcp-auth","statement":"OAuth 2.0 is required","provenance":"verbatim-grounded","confidence":"high","date":"2026-06-01","source":"src_a"}
{"v":1,"id":"clm_new","topic":"mcp-auth","statement":"OAuth 2.1 is required","provenance":"verbatim-grounded","confidence":"high","date":"2026-07-05","source":"src_b"}
{"v":1,"id":"clm_x","topic":"mcp-auth","statement":"Device flow is mandatory","provenance":"model-asserted","confidence":"medium","date":"2026-07-05"}
{"v":1,"id":"clm_y","topic":"mcp-auth","statement":"Device flow is optional","provenance":"verbatim-grounded","confidence":"high","date":"2026-07-05","source":"src_c"}
{"v":1,"id":"clm_dead","topic":"mcp-auth","statement":"Retracted thing","provenance":"model-asserted","confidence":"medium","date":"2026-07-05"}
{"v":1,"op":"supersede","claim":"clm_old","by":"clm_new","date":"2026-07-05"}
{"v":1,"op":"contradict","claim":"clm_x","by":"clm_y","date":"2026-07-05"}
{"v":1,"op":"retract","claim":"clm_dead","by":"human","date":"2026-07-05"}
EOF

node "$VW" --vault "$V" --topic mcp-auth >/dev/null 2>&1 || no "regen runs" "$?"
T="$V/topics/mcp-auth/topic.md"
[ -f "$T" ] && ok "topic.md generated" || no "topic.md" ""
grep -q 'OAuth 2.1 is required for remote MCP servers' "$T" && ok "synthesis embedded" || no "synthesis" "$(cat "$T")"
grep -q 'clm_new' "$T" || grep -q 'OAuth 2.1 is required' "$T" && ok "live claim listed" || no "live claim" ""
grep -q 'contradicted by' "$T" && ok "contradiction flagged" || no "contradiction" ""
grep -q 'OAuth 2.0 is required' "$T" && grep -q 'Superseded' "$T" && ok "superseded history preserved" || no "superseded" ""
grep -q 'Retracted thing' "$T" && no "retracted hidden" "retracted claim leaked" || ok "retracted never serves"
grep -q '## Notes (human)' "$T" && ok "notes section present" || no "notes section" ""

# human notes survive regeneration
printf 'my precious annotation\n' >> "$T"
node "$VW" --vault "$V" --topic mcp-auth >/dev/null 2>&1
grep -q 'my precious annotation' "$T" && ok "human notes preserved" || no "notes preserved" "$(tail -5 "$T")"

# regeneration is idempotent: repeated regens never duplicate sections
node "$VW" --vault "$V" --topic mcp-auth >/dev/null 2>&1
node "$VW" --vault "$V" --topic mcp-auth >/dev/null 2>&1
{ [ "$(grep -c '^## Latest synthesis' "$T")" = "1" ] && [ "$(grep -c '^## Notes (human)' "$T")" = "1" ] \
  && grep -q 'my precious annotation' "$T"; } && ok "repeated regen stays clean" || no "regen idempotent" "$(grep -c '^## Latest synthesis' "$T") synthesis headings"

# an empty newer run (allocated, no synthesis yet) must not blank the synthesis
mkdir -p "$V/topics/mcp-auth/runs/2026-07-05b-zzzz/findings"
node "$VW" --vault "$V" --topic mcp-auth >/dev/null 2>&1
grep -q 'Latest synthesis (run 2026-07-05a-9f3c)' "$T" && grep -q 'OAuth 2.1 is required for remote MCP servers' "$T" \
  && ok "synthesis survives an empty newer run" || no "empty newer run" "$(grep 'Latest synthesis' "$T")"

# INDEX.md lists the topic
grep -q 'MCP Auth Landscape' "$V/INDEX.md" && grep -q 'topics/mcp-auth/topic.md' "$V/INDEX.md" \
  && ok "INDEX.md lists topic" || no "INDEX" "$(cat "$V/INDEX.md")"

echo; echo "vault-views: $pass passed, $fail failed"; [ $fail -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/researcher-views.test.sh`
Expected: FAIL — vault-views.js not found.

- [ ] **Step 3: Write the implementation**

Create `plugins/re-searcher/skills/re-searcher/vault-views.js`:

```js
#!/usr/bin/env node
'use strict';
// vault-views — regenerate the script-owned views: topics/<slug>/topic.md and
// INDEX.md. Views are ALWAYS safe to regenerate — everything in them derives
// from the index, the folded claims registry, and immutable run artifacts —
// EXCEPT the '## Notes (human)' section of topic.md, which is preserved
// verbatim (one clobbered annotation ends human browsing forever).
//
//   node vault-views.js --vault <dir> [--topic <slug>]
//
// Module API: regenTopic(vault, slug), regenIndex(vault)

const fs = require('fs');
const path = require('path');
const lib = require('./vault-lib');

const NOTES_HEADING = '## Notes (human)';

function lastPerSlug(records) {
  const m = new Map();
  for (const r of records) if (r && r.slug) m.set(r.slug, r);
  return m;
}

function listRuns(vault, slug) {
  const dir = path.join(vault, 'topics', slug, 'runs');
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((d) => {
    try { return fs.statSync(path.join(dir, d)).isDirectory(); } catch (_e) { return false; }
  }).sort();
}

function claimLine(c) {
  const meta = [c.provenance, c.confidence, c.date].filter(Boolean).join(' · ');
  const src = c.source ? ' — ' + c.source : '';
  let line = '- [' + meta + '] ' + c.statement + src + ' (' + c.id + ')';
  if (c.contradictedBy.length) {
    line += '\n  - ⚠ contradicted by ' + c.contradictedBy.join(', ') + ' — both stand until a human resolves (/research correct)';
  }
  return line;
}

function regenTopic(vault, slug) {
  const topicDir = path.join(vault, 'topics', slug);
  fs.mkdirSync(topicDir, { recursive: true });
  const topicFile = path.join(topicDir, 'topic.md');

  let notes = NOTES_HEADING + '\n';
  if (fs.existsSync(topicFile)) {
    const old = fs.readFileSync(topicFile, 'utf8');
    // The real notes section is the LAST line-anchored occurrence — the
    // generated boilerplate mentions the heading mid-sentence, and synthesis
    // text could echo it; first-match indexOf would slice from there and
    // duplicate the whole body on every regen.
    const re = /^## Notes \(human\)/gm;
    let m, i = -1;
    while ((m = re.exec(old)) !== null) i = m.index;
    if (i !== -1) notes = old.slice(i);
  }

  const idx = lastPerSlug(lib.readJsonl(path.join(vault, 'index.jsonl')).records).get(slug) || {};
  const { claims } = lib.foldClaims(lib.readJsonl(path.join(vault, 'claims.jsonl')).records);
  const live = [], superseded = [];
  for (const c of claims.values()) {
    if (c.topic !== slug) continue;
    if (c.status === 'active') live.push(c);
    else if (c.status === 'superseded') superseded.push(c);
  }
  live.sort((a, b) => String(a.date).localeCompare(String(b.date)) || String(a.id).localeCompare(String(b.id)));

  const runs = listRuns(vault, slug);
  // "Latest synthesis" = the newest run that HAS one — a freshly allocated or
  // aborted run without synthesis.md must not blank the topic view.
  let latest = null;
  let synthesis = '_No synthesis yet._';
  for (let i = runs.length - 1; i >= 0; i--) {
    const sp = path.join(topicDir, 'runs', runs[i], 'synthesis.md');
    if (fs.existsSync(sp)) { latest = runs[i]; synthesis = fs.readFileSync(sp, 'utf8').trim(); break; }
  }

  const out = [
    '# ' + (idx.title || slug),
    '',
    '_Generated by re-searcher — everything above "' + NOTES_HEADING + '" is regenerated; edit only that section._',
    '',
    '**Scope:** ' + (idx.scope || 'general') + ' · **Updated:** ' + (idx.date || 'unknown') + ' · **Runs:** ' + runs.length,
    '',
    '## Latest synthesis' + (latest ? ' (run ' + latest + ')' : ''),
    '',
    synthesis,
    '',
    '## Live claims',
    '',
    live.length ? live.map(claimLine).join('\n') : '_None registered._',
    '',
  ];
  if (superseded.length) {
    out.push('## Superseded (history preserved)', '',
      superseded.map((c) => '- ~~' + c.statement + '~~ (' + c.id + ' → ' + c.supersededBy.join(', ') + ')').join('\n'), '');
  }
  out.push('## Runs', '',
    runs.length ? runs.map((r) => '- [' + r + '](runs/' + r + '/plan.md)').join('\n') : '_None._',
    '', notes.trimEnd(), '');
  lib.atomicWrite(topicFile, out.join('\n'));
  return topicFile;
}

function regenIndex(vault) {
  const idx = lastPerSlug(lib.readJsonl(path.join(vault, 'index.jsonl')).records);
  const rows = Array.from(idx.values()).sort((a, b) => String(b.date).localeCompare(String(a.date)));
  const lines = ['# Research vault', ''];
  if (!rows.length) lines.push('_No topics yet — run /research <question>._');
  for (const r of rows) {
    lines.push('- [' + (r.title || r.slug) + '](topics/' + r.slug + '/topic.md) — ' + (r.date || '')
      + (r.scope && r.scope !== 'general' ? ' · ' + r.scope : ''));
  }
  lib.atomicWrite(path.join(vault, 'INDEX.md'), lines.join('\n') + '\n');
}

function main() {
  const vi = process.argv.indexOf('--vault');
  const vault = lib.resolveVault(vi !== -1 ? process.argv[vi + 1] : null);
  const ti = process.argv.indexOf('--topic');
  const topicsDir = path.join(vault, 'topics');
  const slugs = ti !== -1 ? [process.argv[ti + 1]]
    : (fs.existsSync(topicsDir) ? fs.readdirSync(topicsDir).filter((s) => !s.startsWith('.')) : []);
  for (const s of slugs) if (s) regenTopic(vault, s);
  regenIndex(vault);
  process.stdout.write(JSON.stringify({ regenerated: slugs.filter(Boolean).length, index: true }) + '\n');
}

if (require.main === module) main();
module.exports = { regenTopic, regenIndex };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/researcher-views.test.sh`
Expected: `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-views.js tests/researcher-views.test.sh
git commit -m "feat: re-searcher vault-views — generated topic/INDEX views, human notes preserved"
```

---

### Task 8: vault-save.js — layered persist + `--events`

**Files:**
- Modify: `plugins/re-searcher/skills/re-searcher/vault-save.js` (replace the two Task 5 stubs)
- Modify: `tests/researcher-save.test.sh` (append before the final `echo; echo "vault-save: ..."` line)

**Interfaces:**
- Consumes: Task 5 helpers (`getFlag`, `getAll`, `die`, `today`, `readManifest`, `stagingReport`), vault-lib (`withLock`, `readJsonl`, `appendJsonl`, `atomicWrite`, `foldClaims`, `gitCommit`, `slugify`, `resolveVault`, `parseFrontmatter`), claim-validate (`validateClaim`, `validateEvent`), vault-views (`regenTopic`, `regenIndex`), `zlib` (transcript gzip).
- Produces (used by the skill and Task 10):
  - CLI persist: `node vault-save.js <run-dir> [--vault <dir>] [--session <id>] [--transcript <path>]... [--light]` → one JSON line `{status: complete|partial, run, topic, light, claims: {accepted, rejected, downgraded, events, duplicates, ids}, transcripts, warnings, provenanceLine}`. Exit 0 (even on partial claims — layered persist), 1 hard error (no plan/manifest, topic mismatch, vault missing, lock timeout).
  - Tier 1 (never blocked by claims): transcripts gzip-copied into `<run-dir>/transcripts/`, `lineage.json` written, index.jsonl appended (aliases/questions merged with the topic's previous record), views regenerated, metrics appended, auto-commit `research: persist run <id> <topic>`.
  - Tier 2 (per-record): reads `<run-dir>/claims-staged.jsonl` (claim records and event records mixed, one JSON object per line) in TWO passes — claims first, then events — so a staged claim carrying a batch-local `"ref": "<name>"` handle (stripped before registration) can be targeted by staged events via `"claim"/"by": "ref:<name>"` even though real ids are only assigned at persist. Accepted → append to vault `claims.jsonl` (accepted ids returned in `claims.ids`); rejected → `<run-dir>/claims-rejected.jsonl` with reasons. Re-persisting the same run skips claims already registered for that run (same statement) as `duplicates` — persist is safely re-runnable.
  - CLI events: `node vault-save.js --events <file.jsonl> [--vault <dir>]` → validates + appends event records only (for `/research correct`), regenerates views, auto-commits. Prints `{applied, rejected: [...]}`. Exit 0 if anything applied or nothing staged, 1 if all staged events were rejected.

- [ ] **Step 1: Append failing tests**

Append to `tests/researcher-save.test.sh` immediately **before** the final `echo; echo "vault-save: ..."` line:

````bash
# --- persist (Task 8) ---

# seed a cached source the claims can ground against
cat > "$V/sources/src_fix1.md" <<'EOF'
---
v: 1
kind: web
title: "Fixture spec page"
---
The **MCP spec** requires [OAuth 2.1](https://spec.example/auth) with PKCE for all remote servers as of the June revision.
Bearer tokens remain acceptable for local stdio servers only.
EOF

printf '# Synthesis\n\nOAuth 2.1 with PKCE is required for remote servers.\n\n## Gaps\n\n- none\n' > "$RUN1/synthesis.md"
cat > "$RUN1/claims-staged.jsonl" <<'EOF'
{"statement":"Remote MCP servers must use OAuth 2.1","quote":"requires OAuth 2.1 with PKCE for all remote servers","source":"src_fix1","provenance":"verbatim-grounded","confidence":"high","found_by":"spec-reader"}
{"statement":"Bearer tokens are fine for local stdio servers","quote":"Bearer tokens remain acceptable for local stdio servers only.","source":"src_fix1","provenance":"verbatim-grounded"}
{"statement":"The spec bans API keys outright","quote":"API keys are prohibited in every deployment mode","source":"src_fix1","provenance":"verbatim-grounded"}
{"statement":"bad record","confidence":"certain"}
{"statement":"No MCP server supports SAML as of 2026-07","type":"absence","found_by":"ecosystem","tool":"websearch"}
{"statement":"Source A says device flow is mandatory","ref":"a","provenance":"model-asserted"}
{"statement":"Source B says device flow is optional","ref":"b","provenance":"model-asserted"}
{"op":"contradict","claim":"ref:a","by":"ref:b"}
EOF
printf '{"fake":"transcript line 1"}\n{"fake":"transcript line 2"}\n' > "$W/session.jsonl"

OUT=$(node "$S" "$RUN1" --vault "$V" --session 9f3c2ab1 --transcript "$W/session.jsonl"); rcode=$?
[ $rcode -eq 0 ] && ok "persist exits 0" || no "persist rc" "rc=$rcode $OUT"
has "$OUT" '"status":"partial"' && ok "partial status (1 reject)" || no "status" "$OUT"
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.claims.accepted===6 && r.claims.rejected===1 && r.claims.downgraded===1 && r.claims.events===1 && r.claims.ids.length===6 ? 0 : 1)' "$OUT" \
  && ok "claim tallies: 6 accepted / 1 rejected / 1 downgraded / 1 event" || no "tallies" "$OUT"
has "$OUT" 'fresh run · 2 agents' && ok "provenance line" || no "prov line" "$OUT"

# tier-1 artifacts
[ -f "$RUN1/lineage.json" ] && grep -q '9f3c2ab1' "$RUN1/lineage.json" && ok "lineage written" || no "lineage" ""
[ -f "$RUN1/transcripts/session.jsonl.gz" ] && ok "transcript gzipped into run" || no "transcript" "$(ls "$RUN1")"
node -e '
const zlib=require("zlib"),fs=require("fs");
const t=zlib.gunzipSync(fs.readFileSync(process.argv[1])).toString();
process.exit(t.includes("transcript line 2") ? 0 : 1);
' "$RUN1/transcripts/session.jsonl.gz" && ok "transcript roundtrips" || no "gunzip" ""
grep -q '"slug":"mcp-auth-landscape"' "$V/index.jsonl" && ok "index appended" || no "index" "$(cat "$V/index.jsonl")"

# tier-2 artifacts: registry, quarantine, quote rewrite, ref resolution
grep -c '"id":"clm_' "$V/claims.jsonl" | grep -q '^6$' && ok "6 claims registered" || no "registry" "$(cat "$V/claims.jsonl")"
grep -q '\[OAuth 2.1\](https://spec.example/auth)' "$V/claims.jsonl" && ok "quote rewritten to source bytes" || no "rewrite" ""
grep -q 'downgraded: quote not found' "$V/claims.jsonl" && ok "fabricated quote downgraded in registry" || no "downgrade note" ""
[ -f "$RUN1/claims-rejected.jsonl" ] && grep -q 'bad confidence' "$RUN1/claims-rejected.jsonl" && ok "reject quarantined with reason" || no "quarantine" ""
node -e '
const recs = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map(JSON.parse);
const ev = recs.find((r) => r.op === "contradict");
process.exit(ev && ev.claim.startsWith("clm_") && ev.by.startsWith("clm_") ? 0 : 1);
' "$V/claims.jsonl" && ok "batch refs resolved to real ids" || no "ref resolve" "$(grep contradict "$V/claims.jsonl")"

# views + git
grep -q 'OAuth 2.1 with PKCE is required' "$V/topics/mcp-auth-landscape/topic.md" && ok "topic view regenerated" || no "topic view" ""
grep -q 'mcp-auth-landscape' "$V/INDEX.md" && ok "INDEX regenerated" || no "INDEX" ""
git -C "$V" log --oneline | grep -q "persist run" && ok "auto-commit" || no "git" "$(git -C "$V" log --oneline 2>&1)"
grep -q '"kind":"save"' "$V/metrics.jsonl" && ok "metrics logged" || no "metrics" ""

# human notes survive a re-persist; re-persist must not duplicate claims,
# must not re-append events, and must not report phantom rejects
printf 'precious-note-9000\n' >> "$V/topics/mcp-auth-landscape/topic.md"
OUT=$(node "$S" "$RUN1" --vault "$V" --session 9f3c2ab1)
grep -q 'precious-note-9000' "$V/topics/mcp-auth-landscape/topic.md" && ok "human notes preserved on re-persist" || no "notes" ""
grep -c '"id":"clm_' "$V/claims.jsonl" | grep -q '^6$' && ok "re-persist dedupes claims" || no "dedupe" "$(grep -c '"id":"clm_' "$V/claims.jsonl")"
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.claims.rejected===1 && r.claims.events===0 && r.claims.duplicates===7 ? 0 : 1)' "$OUT" \
  && ok "re-persist: only the still-invalid record re-rejects, event deduped" || no "re-persist tallies" "$OUT"
grep -q 'unknown claim: ref:' "$RUN1/claims-rejected.jsonl" && no "phantom ref reject" "$(grep 'unknown claim' "$RUN1/claims-rejected.jsonl")" || ok "no phantom ref rejects"
grep -c '"op":"contradict"' "$V/claims.jsonl" | grep -q '^1$' && ok "contradict registered exactly once" || no "event dup" "$(grep -c '"op":"contradict"' "$V/claims.jsonl")"

# topic mismatch fails loud
mkdir -p "$V/topics/other-topic/runs/2026-07-05a-zzzz/findings"
cp "$RUN1/plan.md" "$V/topics/other-topic/runs/2026-07-05a-zzzz/plan.md"
node "$S" "$V/topics/other-topic/runs/2026-07-05a-zzzz" --vault "$V" >/dev/null 2>&1
[ $? -eq 1 ] && ok "topic/folder mismatch fails loud" || no "mismatch" "$?"

# --light: no claims file is fine, provenance line says light
OUT=$(node "$S" --new-run --topic quick-check --session 9f3c2ab1 --vault "$V")
RUNL=$(node -e 'console.log(JSON.parse(process.argv[1]).runDir)' "$OUT")
cat > "$RUNL/plan.md" <<'EOF'
---
topic: quick-check
title: Quick check
aliases: []
questions: []
scope: general
---
# Plan

```manifest
[{"role": "solo", "file": "findings/solo.md"}]
```
EOF
node -e '
const fs=require("fs");
fs.writeFileSync(process.argv[1] + "/findings/solo.md", "---\nrole: solo\nrun: x\n---\n\n# Findings\n\n" + "A light-path finding sentence with enough real content to pass the size floor. ".repeat(8));
' "$RUNL"
OUT=$(node "$S" "$RUNL" --vault "$V" --light --session 9f3c2ab1); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"complete"' && has "$OUT" 'light run'; } && ok "light path persists clean" || no "light" "rc=$rcode $OUT"

# --- --events (Task 8) ---

C1=$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(JSON.parse).filter(r=>r.id && r.statement.includes("OAuth 2.1"));console.log(l[0].id)' "$V/claims.jsonl")
C2=$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(JSON.parse).filter(r=>r.id && r.statement.includes("Bearer tokens"));console.log(l[0].id)' "$V/claims.jsonl")
printf '{"op":"supersede","claim":"%s","by":"%s","reason":"newer revision"}\n{"op":"supersede","claim":"%s","by":"%s","reason":"would cycle"}\n' "$C1" "$C2" "$C2" "$C1" > "$W/events.jsonl"
OUT=$(node "$S" --events "$W/events.jsonl" --vault "$V"); rcode=$?
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.applied===1 && r.rejected.length===1 && /cycle/.test(r.rejected[0].reason) ? 0 : 1)' "$OUT" \
  && ok "events: apply + cycle reject" || no "events" "rc=$rcode $OUT"
git -C "$V" log --oneline -1 | grep -q "event" && ok "events auto-commit" || no "events git" "$(git -C "$V" log --oneline -1)"
grep -q 'Superseded' "$V/topics/mcp-auth-landscape/topic.md" && ok "views reflect supersession" || no "views supersede" ""

# an unexpected throw inside the locked region still emits structured JSON + exit 1
OUT=$(node "$S" --new-run --topic err-topic --session errr1234 --vault "$V")
RUNE=$(node -e 'console.log(JSON.parse(process.argv[1]).runDir)' "$OUT")
cat > "$RUNE/plan.md" <<'EOF'
---
topic: err-topic
title: Err
aliases: []
questions: []
scope: general
---
# Plan

```manifest
[{"role": "solo", "file": "findings/solo.md"}]
```
EOF
mkdir -p "$V/topics/err-topic/topic.md"
OUT=$(node "$S" "$RUNE" --vault "$V" --light 2>/dev/null); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" '"status":"error"'; } && ok "throw inside lock emits error JSON" || no "error json" "rc=$rcode $OUT"
[ -d "$V/.lock" ] && no "lock released after throw" "still held" || ok "lock released after throw"
rm -rf "$V/topics/err-topic"
````

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/researcher-save.test.sh`
Expected: Task 5's assertions still PASS; everything from "persist exits 0" on FAILs (stub says "persist mode is not built yet").

- [ ] **Step 3: Implement persist + events**

In `plugins/re-searcher/skills/re-searcher/vault-save.js`:

3a. Add to the requires at the top:

```js
const zlib = require('zlib');
const cv = require('./claim-validate');
const views = require('./vault-views');
```

3b. Replace the two stub lines in `main()`:

```js
function main() {
  if (process.argv.includes('--new-run')) return newRun();
  const cs = getFlag('--check-staging');
  if (cs) return checkStaging(cs);
  const ev = getFlag('--events');
  if (ev) return saveEvents(ev);
  const runDir = process.argv[2];
  if (!runDir || runDir.startsWith('--')) {
    die('usage: vault-save.js <run-dir> [--vault <dir>] [--session <id>] [--transcript <p>]... [--light] | --new-run --topic <slug> | --check-staging <run-dir> | --events <file>');
  }
  return persist(path.resolve(runDir));
}
```

3c. Add the persist implementation (before `main`):

```js
function claimCtx(vault, runId, topic, date) {
  const records = lib.readJsonl(path.join(vault, 'claims.jsonl')).records;
  const { claims: registry } = lib.foldClaims(records);
  const runClaims = Array.from(registry.values()).filter((c) => c.run === runId);
  return {
    vault, runId, topic, date,
    takenIds: new Set(registry.keys()),
    knownIds: new Set(registry.keys()),
    supersedeEdges: new Map(Array.from(registry.values()).map((c) => [c.id, c.supersededBy.slice()])),
    // re-persist guards: claims this run already registered (kept with their
    // ids so batch refs still resolve on a re-save) and events already present
    runStatements: new Set(runClaims.map((c) => String(c.statement))),
    runClaimIdByStatement: new Map(runClaims.map((c) => [String(c.statement), c.id])),
    eventKeys: new Set(records.filter((r) => r && r.op).map((r) => r.op + '|' + r.claim + '|' + (r.by || ''))),
  };
}

function persist(runDir) {
  const vault = lib.resolveVault(getFlag('--vault'));
  if (!fs.existsSync(runDir)) die('run dir missing: ' + runDir);
  const { manifest, plan } = readManifest(runDir);
  const fm = lib.parseFrontmatter(plan).fields;
  const topic = lib.slugify(String(fm.topic || ''));
  if (!fm.topic) die('plan.md frontmatter needs topic: <slug>');
  const folderTopic = path.basename(path.dirname(path.dirname(runDir)));
  if (folderTopic !== topic) die('plan topic "' + topic + '" does not match run folder topic "' + folderTopic + '" — fix plan.md or move the run');
  const runId = path.basename(runDir);
  const light = process.argv.includes('--light');
  const date = today();
  const warnings = [];

  const result = lib.withLock(vault, () => {
    // ---- tier 1: registration that can never be held hostage by claims ----
    const staging = stagingReport(runDir);
    if (!staging.ok) {
      warnings.push('staging incomplete: missing=' + JSON.stringify(staging.missing)
        + ' stubs=' + JSON.stringify(staging.stubs) + ' badHeader=' + JSON.stringify(staging.badHeader));
    }
    if (!light && !fs.existsSync(path.join(runDir, 'synthesis.md'))) {
      warnings.push('no synthesis.md — run persisted without a synthesis');
    }

    const copied = [];
    for (const t of getAll('--transcript')) {
      try {
        fs.mkdirSync(path.join(runDir, 'transcripts'), { recursive: true });
        const gz = zlib.gzipSync(fs.readFileSync(t));
        lib.atomicWrite(path.join(runDir, 'transcripts', path.basename(t) + '.gz'), gz);
        copied.push(path.basename(t) + '.gz');
      } catch (e) { warnings.push('transcript copy failed for ' + t + ': ' + (e.code || e.message)); }
    }

    const uniq = (arr) => Array.from(new Set(arr.filter((x) => typeof x === 'string' && x.trim())));
    const prevIdx = lib.readJsonl(path.join(vault, 'index.jsonl')).records.filter((r) => r && r.slug === topic).pop();
    lib.appendJsonl(path.join(vault, 'index.jsonl'), {
      v: 1, slug: topic, title: String(fm.title || topic),
      aliases: uniq([].concat((prevIdx && prevIdx.aliases) || [], fm.aliases || [])),
      questions: uniq([].concat((prevIdx && prevIdx.questions) || [], fm.questions || [])),
      scope: String(fm.scope || 'general'), run: runId, date,
    });

    lib.atomicWrite(path.join(runDir, 'lineage.json'), JSON.stringify({
      v: 1, session: getFlag('--session') || String(fm.session || 'unknown'),
      run: runId, topic, light, saved: new Date().toISOString(),
      transcripts: copied, agents: manifest.length,
    }, null, 2) + '\n');

    // ---- tier 2: per-record claim validation (quarantine, never abort) ----
    // Two passes: claims land first so staged events can reference ids that
    // don't exist until now. A staged claim may carry "ref": "<local-name>"
    // (a batch-local handle, stripped before registration); staged events may
    // then use "claim": "ref:<local-name>" / "by": "ref:<local-name>".
    let accepted = 0, rejected = 0, downgraded = 0, events = 0, duplicates = 0;
    const ids = [];
    const stagedFile = path.join(runDir, 'claims-staged.jsonl');
    if (fs.existsSync(stagedFile)) {
      const ctx = claimCtx(vault, runId, topic, date);
      const rejFile = path.join(runDir, 'claims-rejected.jsonl');
      const reject = (reason, rec) => { lib.appendJsonl(rejFile, { reason, record: rec }); rejected++; };
      const claimsStaged = [], eventsStaged = [];
      for (const line of fs.readFileSync(stagedFile, 'utf8').split('\n')) {
        if (!line.trim()) continue;
        try {
          const rec = JSON.parse(line);
          (typeof rec.op === 'string' ? eventsStaged : claimsStaged).push(rec);
        } catch (_e) { lib.appendJsonl(rejFile, { reason: 'unparseable JSON', line: line.slice(0, 500) }); rejected++; }
      }
      const refMap = new Map();
      for (const rec of claimsStaged) {
        if (ctx.runStatements.has(String(rec.statement))) {
          // re-persist: already registered — refs must still resolve so
          // staged events don't produce phantom rejects on a re-save
          duplicates++;
          if (rec.ref) refMap.set(String(rec.ref), ctx.runClaimIdByStatement.get(String(rec.statement)));
          continue;
        }
        const ref = rec.ref;
        const clean = Object.assign({}, rec);
        delete clean.ref;
        const res = cv.validateClaim(clean, ctx);
        if (!res.ok) { reject(res.reason, rec); continue; }
        lib.appendJsonl(path.join(vault, 'claims.jsonl'), res.record);
        accepted++; ids.push(res.record.id); ctx.knownIds.add(res.record.id);
        if (res.downgraded) downgraded++;
        if (ref) refMap.set(String(ref), res.record.id);
      }
      const deref = (v) => (typeof v === 'string' && v.startsWith('ref:')) ? (refMap.get(v.slice(4)) || v) : v;
      for (const rec of eventsStaged) {
        const resolved = Object.assign({}, rec, { claim: deref(rec.claim) },
          rec.by !== undefined ? { by: deref(rec.by) } : {});
        const key = resolved.op + '|' + resolved.claim + '|' + (resolved.by || '');
        if (ctx.eventKeys.has(key)) { duplicates++; continue; } // re-persist: event already registered
        const res = cv.validateEvent(resolved, ctx);
        if (!res.ok) { reject(res.reason, rec); continue; }
        lib.appendJsonl(path.join(vault, 'claims.jsonl'), res.record);
        ctx.eventKeys.add(key);
        events++;
      }
    } else if (!light) {
      warnings.push('no claims-staged.jsonl — full-path runs usually stage claims (see references/claims.md)');
    }

    // ---- views + metrics + auto-commit ----
    views.regenTopic(vault, topic);
    views.regenIndex(vault);
    lib.appendJsonl(path.join(vault, 'metrics.jsonl'), {
      v: 1, kind: 'save', ts: new Date().toISOString(), run: runId, topic, light,
      accepted, rejected, downgraded, events, warnings: warnings.length,
    });
    const c = lib.gitCommit(vault, 'research: persist run ' + runId + ' ' + topic);
    if (c.warning) warnings.push(c.warning);

    return {
      status: rejected ? 'partial' : 'complete', run: runId, topic, light,
      claims: { accepted, rejected, downgraded, events, duplicates, ids }, transcripts: copied.length, warnings,
      provenanceLine: light
        ? 'light run · saved to topics/' + topic + '/runs/' + runId
        : 'fresh run · ' + manifest.length + ' agents · saved to topics/' + topic + '/runs/' + runId,
    };
  });

  process.stdout.write(JSON.stringify(result) + '\n');
}

function saveEvents(file) {
  const vault = lib.resolveVault(getFlag('--vault'));
  if (!fs.existsSync(file)) die('events file missing: ' + file);
  const out = lib.withLock(vault, () => {
    const ctx = claimCtx(vault, 'events', null, today());
    let applied = 0;
    const rejectedList = [];
    for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
      if (!line.trim()) continue;
      let rec;
      try { rec = JSON.parse(line); }
      catch (_e) { rejectedList.push({ reason: 'unparseable JSON', line: line.slice(0, 200) }); continue; }
      const key = rec.op + '|' + rec.claim + '|' + (rec.by || '');
      if (ctx.eventKeys.has(key)) continue; // already registered — re-runs must not duplicate events
      const res = cv.validateEvent(rec, ctx);
      if (!res.ok) { rejectedList.push({ reason: res.reason, record: rec }); continue; }
      lib.appendJsonl(path.join(vault, 'claims.jsonl'), res.record);
      ctx.eventKeys.add(key);
      applied++;
    }
    // regenerate every topic that has events (over-broad but always correct)
    const { claims } = lib.foldClaims(lib.readJsonl(path.join(vault, 'claims.jsonl')).records);
    const touched = new Set();
    for (const c of claims.values()) if (c.events.length && c.topic) touched.add(c.topic);
    for (const t of touched) views.regenTopic(vault, t);
    views.regenIndex(vault);
    const c = lib.gitCommit(vault, 'research: apply ' + applied + ' event(s)');
    return { applied, rejected: rejectedList, commitWarning: c.warning };
  });
  process.stdout.write(JSON.stringify(out) + '\n');
  process.exit(out.rejected.length && !out.applied ? 1 : 0);
}
```

3d. Update the usage-header comment: remove "(Task 8)" markers — all four modes are live now.

3e. Enforce the "one JSON line always" contract against unexpected throws: replace the bare `main();` call at the bottom of vault-save.js with

```js
function emitFatal(e) {
  process.stdout.write(JSON.stringify({ status: 'error', error: String((e && e.message) || e) }) + '\n');
  process.stderr.write('vault-save: failed — the vault may hold partial, uncommitted writes: ' + ((e && e.stack) || e) + '\n');
  process.exit(1);
}

try { main(); } catch (e) { emitFatal(e); }
```

(`die()` paths still print usage errors to stderr and exit 1 before any mutation; this guard covers exceptions escaping the locked region, where tier-1 writes may already be on disk.) Also add a one-line comment at `claimCtx(vault, 'events', null, today())` in `saveEvents` noting runId/topic are inert for event-only validation.

- [ ] **Step 4: Run tests to verify all pass**

Run: `bash tests/researcher-save.test.sh && bash tests/researcher-views.test.sh && bash tests/researcher-claims.test.sh`
Expected: all `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-save.js tests/researcher-save.test.sh
git commit -m "feat: re-searcher vault-save layered persist — lock, transcripts, index merge, per-record claims, events, auto-commit"
```

---

### Task 9: vault-search.js — recall with folding, near-misses, metrics

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/vault-search.js`
- Test: `tests/researcher-search.test.sh`

**Interfaces:**
- Consumes: vault-lib (`resolveVault`, `readJsonl`, `appendJsonl`, `foldClaims`, `resolveTerminal`, `withLock`, `gitCommit`).
- Produces (the skill's recall interface):
  - CLI: `node vault-search.js <terms...> [--vault <dir>] [--project <slug>] [--json]` — multi-probe over index.jsonl (slug/title +3, aliases +2, questions +1, last-record-per-slug) AND folded claim statements (+2, retracted excluded, superseded resolved to terminal claims with a `supersedes` note). `--project <slug>` bumps `scope: project:<slug>` topics +5 so they rank first. Exit 0 hit(s) / 2 miss (near-misses by trigram similarity printed) / 1 vault missing or usage.
  - Human output per hit: `== title (slug) ==`, one provenance line `vault · <slug> · researched <date> · <freshness>` (freshness: `fresh (Nd)` ≤30 days, else `aging (Nd) — spot-check before trusting`), optional cross-project scope note, matched claims as "claims to spot-check", supersession `↳` and contradiction `⚠` annotations, `full topic:` path. `--json` emits the same as one JSON line.
  - Every recall appends a `{kind: "recall"}` metrics record; misses also append `{kind: "near-miss"}` — full audit detail lives in metrics.jsonl, chat output stays minimal.
  - CLI: `node vault-search.js --add-alias <slug> <alias> [--vault <dir>]` — appends an updated index record (last-record-wins) under the lock, auto-commits. Real-time alias learning for recovered near-misses.

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-search.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-search.js
# Run: bash tests/researcher-search.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SR="$ROOT/plugins/re-searcher/skills/re-searcher/vault-search.js"
I="$ROOT/plugins/re-searcher/skills/re-searcher/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-search tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1
echo "vault-search tests"

OLD=$(node -e 'const d=new Date(Date.now()-60*86400000); console.log(d.toISOString().slice(0,10))')
cat >> "$V/index.jsonl" <<EOF
{"v":1,"slug":"mcp-auth","title":"MCP Auth Landscape","aliases":["mcp oauth","model context protocol auth"],"questions":["is oauth required for mcp?"],"scope":"general","run":"r1","date":"$OLD"}
{"v":1,"slug":"react-router-migration","title":"React Router v7 migration","aliases":["remix router"],"questions":["how to migrate loaders?"],"scope":"project:alpha","run":"r2","date":"2026-07-05"}
EOF
cat >> "$V/claims.jsonl" <<'EOF'
{"v":1,"id":"clm_old","topic":"mcp-auth","statement":"MCP requires OAuth 2.0 for remote servers","provenance":"verbatim-grounded","confidence":"high","date":"2026-05-01","source":"src_a"}
{"v":1,"id":"clm_new","topic":"mcp-auth","statement":"MCP requires OAuth 2.1 for remote servers","provenance":"verbatim-grounded","confidence":"high","date":"2026-07-01","source":"src_b"}
{"v":1,"id":"clm_x","topic":"mcp-auth","statement":"Device flow is mandatory for MCP clients","provenance":"model-asserted","confidence":"medium","date":"2026-07-01"}
{"v":1,"id":"clm_y","topic":"mcp-auth","statement":"Device flow is optional for MCP clients","provenance":"verbatim-grounded","confidence":"high","date":"2026-07-01","source":"src_c"}
{"v":1,"id":"clm_gone","topic":"mcp-auth","statement":"MCP mandates SAML everywhere","provenance":"model-asserted","confidence":"medium","date":"2026-07-01"}
{"v":1,"op":"supersede","claim":"clm_old","by":"clm_new","date":"2026-07-01"}
{"v":1,"op":"contradict","claim":"clm_x","by":"clm_y","date":"2026-07-01"}
{"v":1,"op":"retract","claim":"clm_gone","by":"human","date":"2026-07-02"}
EOF

# 1. title/alias hit with provenance line + staleness
OUT=$(node "$SR" mcp oauth --vault "$V"); rcode=$?
[ $rcode -eq 0 ] && ok "hit exits 0" || no "hit rc" "rc=$rcode"
has "$OUT" 'vault · mcp-auth · researched' && ok "provenance line" || no "prov" "$OUT"
has "$OUT" 'aging (60d)' && ok "staleness announced" || no "staleness" "$OUT"

# 2. supersede folding: probing the OLD statement serves the terminal claim
OUT=$(node "$SR" "OAuth 2.0" --vault "$V")
has "$OUT" 'clm_new' && has "$OUT" 'supersedes clm_old' && ok "supersede folded to terminal" || no "fold" "$OUT"
has "$OUT" 'OAuth 2.0 for remote' && no "old claim served as live" "$OUT" || ok "old claim not served as live"

# 3. contradiction: both served, flagged
OUT=$(node "$SR" "device flow" --vault "$V")
has "$OUT" 'contradicted by' && ok "contradiction flagged" || no "contradict" "$OUT"

# 4. retracted claims never serve
OUT=$(node "$SR" SAML --vault "$V"); rcode=$?
{ [ $rcode -eq 2 ] || ! has "$OUT" 'clm_gone'; } && ok "retracted never serves" || no "retracted" "$OUT"

# 5. --project ranks project topic first + cross-project scope note
OUT=$(node "$SR" router migration --vault "$V" --project alpha)
node -e '
const lines = process.argv[1].split("\n").filter(l => l.startsWith("=="));
process.exit(lines.length && lines[0].includes("react-router-migration") ? 0 : 1);
' "$OUT" && ok "--project ranks first" || no "project rank" "$OUT"
OUT=$(node "$SR" router migration --vault "$V")
has "$OUT" 'project:alpha' && ok "cross-project scope note" || no "scope note" "$OUT"

# 6. miss -> near-misses + exit 2 + metrics
OUT2=$(node "$SR" kubernetes ingress --vault "$V"); rcode=$?
[ $rcode -eq 2 ] && ok "miss exits 2" || no "miss rc" "rc=$rcode $OUT2"
OUT=$(node "$SR" "mcp-authz" --vault "$V"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" 'closest:' && has "$OUT" 'mcp-auth'; } && ok "near-miss disclosure" || no "near-miss" "rc=$rcode $OUT"
grep -q '"kind":"recall"' "$V/metrics.jsonl" && grep -q '"kind":"near-miss"' "$V/metrics.jsonl" && ok "metrics logged" || no "metrics" ""

# 7. --add-alias learns, then hits
node "$SR" --add-alias mcp-auth "authz" --vault "$V" >/dev/null 2>&1 || no "add-alias runs" "$?"
OUT=$(node "$SR" authz --vault "$V"); rcode=$?
[ $rcode -eq 0 ] && has "$OUT" 'mcp-auth' && ok "learned alias hits" || no "alias hit" "rc=$rcode $OUT"
git -C "$V" log --oneline -1 | grep -q "alias" && ok "alias learning auto-commits" || no "alias git" ""

# add-alias with unknown slug fails loud and must NOT leak the lock
node "$SR" --add-alias no-such-topic "x" --vault "$V" >/dev/null 2>&1; rcode=$?
{ [ $rcode -eq 1 ] && [ ! -d "$V/.lock" ]; } && ok "unknown slug: exit 1, no lock leak" || no "lock leak" "rc=$rcode lock=$([ -d "$V/.lock" ] && echo held || echo free)"

# 8. missing vault fails loud (never 0 hits)
ERR=$(RESEARCH_VAULT_DIR= node "$SR" anything --vault "$W/novault" 2>&1 >/dev/null); rcode=$?
{ [ $rcode -eq 1 ] && has "$ERR" 'vault-init'; } && ok "missing vault fails loud" || no "missing vault" "rc=$rcode $ERR"

# 9. --json emits parseable structure
OUT=$(node "$SR" mcp --vault "$V" --json)
node -e 'const r=JSON.parse(process.argv[1]); process.exit(Array.isArray(r.hits) && r.hits[0].provenanceLine ? 0 : 1)' "$OUT" \
  && ok "--json output" || no "json" "$OUT"

echo; echo "vault-search: $pass passed, $fail failed"; [ $fail -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/researcher-search.test.sh`
Expected: FAIL — vault-search.js not found.

- [ ] **Step 3: Write the implementation**

Create `plugins/re-searcher/skills/re-searcher/vault-search.js`:

```js
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
  // validate OUTSIDE the lock (reads are lock-free) — process.exit inside
  // withLock's fn would skip its finally and leak the lock dir for 5 minutes
  const probe = lastPerSlug(lib.readJsonl(path.join(vault, 'index.jsonl')).records).get(slug);
  if (!probe) { process.stderr.write('vault-search: no topic "' + slug + '" in the index\n'); process.exit(1); }
  lib.withLock(vault, () => {
    // re-read INSIDE the lock: a concurrent persist may have appended a newer
    // record for this slug; last-record-wins must not lose its merges
    const prev = lastPerSlug(lib.readJsonl(path.join(vault, 'index.jsonl')).records).get(slug) || probe;
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/researcher-search.test.sh`
Expected: `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-search.js tests/researcher-search.test.sh
git commit -m "feat: re-searcher vault-search — multi-probe recall, event folding, near-misses, alias learning, metrics"
```

---

### Task 10: contract E2E — seeded staging → save → registry/index/views → recall

**Files:**
- Test: `tests/researcher-e2e.test.sh`

**Interfaces:**
- Consumes: every CLI shipped in Tasks 1–9, exactly as specified there. This is the spec's "contract E2E" — it tests the persist/recall contract without an LLM.

- [ ] **Step 1: Write the test**

Create `tests/researcher-e2e.test.sh`:

````bash
#!/usr/bin/env bash
# Contract E2E (spec Testing tier 1): seeded fake staging -> vault-save ->
# assert registry/index/views -> vault-search folds events. No LLM, no network.
# Run: bash tests/researcher-e2e.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/plugins/re-searcher/skills/re-searcher"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-e2e tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
echo "re-searcher contract E2E"

# 1. init
node "$SK/vault-init.js" --vault "$V" >/dev/null 2>&1 && ok "vault-init" || no "init" "$?"

# 2. allocate a run
OUT=$(node "$SK/vault-save.js" --new-run --topic "MCP Auth Landscape" --session e2e12345 --vault "$V")
RUN=$(node -e 'console.log(JSON.parse(process.argv[1]).runDir)' "$OUT")
[ -d "$RUN/findings" ] && ok "run allocated" || no "new-run" "$OUT"

# 3. seed a cached source (what vault-fetch would have stored)
cat > "$V/sources/src_e2e.md" <<'EOF'
---
v: 1
kind: web
title: "Auth spec"
---
Remote servers **must** use [OAuth 2.1](https://spec.example/a) with PKCE enabled by default.
Local stdio servers may keep bearer tokens.
EOF

# 4. plan with manifest — BEFORE findings exist, staging must be incomplete
cat > "$RUN/plan.md" <<'EOF'
---
topic: mcp-auth-landscape
title: MCP Auth Landscape
aliases: ["mcp oauth", "mcp authorization"]
questions: ["is oauth 2.1 required for mcp servers?"]
scope: general
session: e2e12345
---

# Plan — MCP Auth Landscape

## Question
Is OAuth 2.1 required for MCP servers?

```manifest
[{"role": "spec-reader", "file": "findings/spec-reader.md"},
 {"role": "ecosystem", "file": "findings/ecosystem.md"}]
```
EOF
node "$SK/vault-save.js" --check-staging "$RUN" >/dev/null 2>&1
[ $? -eq 2 ] && ok "staging gate blocks before findings" || no "gate open" "$?"

for role in spec-reader ecosystem; do
  node -e '
const fs = require("fs");
const role = process.argv[2];
fs.writeFileSync(process.argv[1] + "/findings/" + role + ".md",
  "---\nrole: " + role + "\nrun: e2e\ntask: " + role + " sweep\ndate: 2026-07-05\n---\n\n# Findings — " + role + "\n\n## Summary\n\n"
  + ("A finding sentence from the " + role + " agent with enough substance to pass the size floor. ").repeat(8)
  + "\n\n## Sources\n\n- src_e2e — the auth spec\n");
' "$RUN" "$role"
done
node "$SK/vault-save.js" --check-staging "$RUN" >/dev/null 2>&1
[ $? -eq 0 ] && ok "staging complete after findings" || no "gate closed" "$?"

# 5. synthesis + staged claims (one transcribed-with-markup, one exact, one absence)
printf '# Synthesis\n\n## Verdict\nOAuth 2.1 is required for remote MCP servers.\n\n## Gaps\n- none\n' > "$RUN/synthesis.md"
cat > "$RUN/claims-staged.jsonl" <<'EOF'
{"statement":"Remote MCP servers must use OAuth 2.1 with PKCE","quote":"Remote servers must use OAuth 2.1 with PKCE enabled by default.","source":"src_e2e","provenance":"verbatim-grounded","confidence":"high","found_by":"spec-reader"}
{"statement":"Local stdio servers may keep bearer tokens","quote":"Local stdio servers may keep bearer tokens.","source":"src_e2e","provenance":"verbatim-grounded","found_by":"spec-reader"}
{"statement":"No MCP server advertises SAML support as of 2026-07","type":"absence","found_by":"ecosystem","tool":"websearch"}
EOF
printf '{"role":"assistant","content":"fake transcript"}\n' > "$W/sess.jsonl"

# 6. persist
OUT=$(node "$SK/vault-save.js" "$RUN" --vault "$V" --session e2e12345 --transcript "$W/sess.jsonl"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"complete"'; } && ok "persist complete" || no "persist" "rc=$rcode $OUT"
has "$OUT" 'fresh run · 2 agents' && ok "provenance line" || no "prov" "$OUT"
grep -c '"id":"clm_' "$V/claims.jsonl" | grep -q '^3$' && ok "3 claims registered" || no "registry" ""
grep -q '\*\*must\*\* use \[OAuth 2.1\]' "$V/claims.jsonl" && ok "quote rewritten to markup source bytes" || no "rewrite" "$(cat "$V/claims.jsonl")"
[ -f "$RUN/lineage.json" ] && [ -f "$RUN/transcripts/sess.jsonl.gz" ] && ok "lineage + transcript copied" || no "lineage" "$(ls "$RUN")"
grep -q 'OAuth 2.1 is required for remote MCP servers' "$V/topics/mcp-auth-landscape/topic.md" && ok "topic view has synthesis" || no "topic view" ""
grep -q 'mcp-auth-landscape' "$V/INDEX.md" && ok "INDEX lists topic" || no "INDEX" ""
git -C "$V" log --oneline | grep -q 'persist run' && ok "vault auto-commit" || no "git" "$(git -C "$V" log --oneline 2>&1)"

# 7. recall hits and serves claims-to-spot-check
OUT=$(node "$SK/vault-search.js" mcp oauth --vault "$V"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" 'vault · mcp-auth-landscape · researched' && has "$OUT" 'spot-check'; } \
  && ok "recall hit + provenance line" || no "recall" "rc=$rcode $OUT"

# 8. supersede via --events, then recall folds to the terminal claim
IDS=$(node -e '
const recs = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map(JSON.parse);
console.log(recs.filter((r) => r.id).map((r) => r.id).join(" "));
' "$V/claims.jsonl")
OLD_ID=$(echo "$IDS" | cut -d' ' -f1); NEW_ID=$(echo "$IDS" | cut -d' ' -f2)
printf '{"op":"supersede","claim":"%s","by":"%s","reason":"e2e correction"}\n' "$OLD_ID" "$NEW_ID" > "$W/ev.jsonl"
node "$SK/vault-save.js" --events "$W/ev.jsonl" --vault "$V" >/dev/null 2>&1 && ok "events applied" || no "events" "$?"
OUT=$(node "$SK/vault-search.js" PKCE --vault "$V")
{ has "$OUT" "$NEW_ID" && has "$OUT" "supersedes $OLD_ID"; } && ok "recall folds supersession" || no "fold" "$OUT"
grep -q 'Superseded' "$V/topics/mcp-auth-landscape/topic.md" && ok "topic view shows history" || no "history" ""

# 9. near-miss disclosure + loud missing vault
OUT=$(node "$SK/vault-search.js" "mcp-authz" --vault "$V"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" 'closest:'; } && ok "near-miss disclosure" || no "near-miss" "rc=$rcode $OUT"
ERR=$(node "$SK/vault-search.js" anything --vault "$W/nope" 2>&1 >/dev/null); rcode=$?
{ [ $rcode -eq 1 ] && has "$ERR" 'vault-init'; } && ok "missing vault fails loud" || no "loud" "rc=$rcode $ERR"
grep -q '"kind":"recall"' "$V/metrics.jsonl" && ok "recall metrics logged" || no "metrics" ""

echo; echo "e2e: $pass passed, $fail failed"; [ $fail -eq 0 ]
````

- [ ] **Step 2: Run the test**

Run: `bash tests/researcher-e2e.test.sh`
Expected: `0 failed`, exit 0. This should pass immediately if Tasks 1–9 are correct — any failure here is a real integration bug in a prior task: fix the task's implementation, never this test's assertions.

- [ ] **Step 3: Commit**

```bash
git add tests/researcher-e2e.test.sh
git commit -m "test: re-searcher contract E2E — staging gate, layered persist, recall folding"
```

---

### Task 11: SKILL.md + references + command routing

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/SKILL.md`
- Create: `plugins/re-searcher/skills/re-searcher/references/full-path.md`
- Create: `plugins/re-searcher/skills/re-searcher/references/claims.md`
- Create: `plugins/re-searcher/skills/re-searcher/references/correct.md`
- Create: `plugins/re-searcher/commands/research.md`
- Test: `tests/researcher-skill.test.sh`

**Interfaces:**
- Consumes: every CLI from Tasks 1–9 (calls them by exact filename and flags).
- Produces: the user-facing `/research` behavior. SKILL.md is the state machine ONLY (≤200 lines, test-enforced); schema/procedure detail lives in the scripts' output and `references/*.md`.

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-skill.test.sh`:

```bash
#!/usr/bin/env bash
# Packaging checks for the re-searcher skill: SKILL.md line budget, script
# references resolve, progressive-disclosure files exist, command routes.
# Run: bash tests/researcher-skill.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/plugins/re-searcher/skills/re-searcher"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
echo "re-searcher skill packaging tests"

[ -f "$SK/SKILL.md" ] && ok "SKILL.md exists" || no "SKILL.md" ""
LINES=$(wc -l < "$SK/SKILL.md" | tr -d ' ')
[ "$LINES" -le 200 ] && ok "SKILL.md within 200-line budget ($LINES)" || no "line budget" "$LINES lines"
head -1 "$SK/SKILL.md" | grep -q '^---$' && ok "frontmatter opens" || no "frontmatter" ""
grep -q '^name: re-searcher$' "$SK/SKILL.md" && ok "name set" || no "name" ""
grep -q '^description: .' "$SK/SKILL.md" && ok "description set" || no "description" ""

# every script the skill calls must exist and be mentioned
ALL=1
for s in vault-init.js vault-fetch.js vault-save.js vault-search.js; do
  grep -q "$s" "$SK/SKILL.md" || { ALL=0; echo "    not referenced: $s"; }
  [ -f "$SK/$s" ] || { ALL=0; echo "    missing file: $s"; }
done
[ $ALL -eq 1 ] && ok "script references resolve" || no "script refs" ""

# state machine beats present, recall first
grep -qi 'recall' "$SK/SKILL.md" && grep -q 'check-staging' "$SK/SKILL.md" && grep -qi 'provenance' "$SK/SKILL.md" \
  && ok "state machine beats present" || no "state machine" ""
grep -q -- '--light' "$SK/SKILL.md" && ok "light path documented" || no "light" ""

ALL=1
for r in full-path claims correct; do
  [ -f "$SK/references/$r.md" ] || { ALL=0; echo "    missing: references/$r.md"; }
  grep -q "references/$r.md" "$SK/SKILL.md" || { ALL=0; echo "    unreferenced: references/$r.md"; }
done
[ $ALL -eq 1 ] && ok "progressive disclosure wired" || no "references" ""

C="$ROOT/plugins/re-searcher/commands/research.md"
[ -f "$C" ] && ok "command file exists" || no "command" ""
head -1 "$C" | grep -q '^---$' && grep -q '^description:' "$C" && ok "command frontmatter" || no "cmd fm" ""
grep -q -- '--fresh' "$C" && grep -q 'correct' "$C" && ok "command routes subcommands" || no "routing" ""
grep -qi 'stage 2' "$C" && ok "honest not-built-yet stubs" || no "stubs" ""

echo; echo "skill: $pass passed, $fail failed"; [ $fail -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/researcher-skill.test.sh`
Expected: FAIL — SKILL.md missing.

- [ ] **Step 3: Write SKILL.md**

Create `plugins/re-searcher/skills/re-searcher/SKILL.md`:

````markdown
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
````

- [ ] **Step 4: Write references/full-path.md**

Create `plugins/re-searcher/skills/re-searcher/references/full-path.md`:

````markdown
# Full path — fan-out mechanics

## plan.md (persist BEFORE fan-out)

Start from `node "$SKILL_DIR/vault-init.js" --template plan`. The frontmatter feeds the index — it is
the grep-bait future recall depends on:
- `topic:` the slug (MUST match the run folder's topic segment; vault-save enforces it)
- `aliases:` 3–5 synonyms someone might probe with later; `questions:` 3–5 anticipated
  future questions, phrased the way they'd actually be asked
- `scope:` `general` or `project:<name>` — cross-project recall announces itself
The ```manifest fenced block is the completeness contract: a JSON array with one
`{"role": ..., "file": "findings/<role>.md"}` per agent. `--check-staging` compares it
against reality; a manifest you didn't write means capture can't be checked by anyone —
including a resumed session after compaction.

## Briefing agents

Emit `node "$SKILL_DIR/vault-init.js" --template task-spec` and fill it per agent: ONE core objective,
an explicit scope boundary, the output file from the manifest, the run-dir path, and the
vault dir. Budgets (Anthropic's): straightforward 1 agent / 3–10 calls; comparisons 2–4
agents; open landscape 5–10 with an explicit stop-at-diminishing-returns line. Agents:
- fetch via vault-fetch so sources are cached and sourceIds exist for claims; on exit 2
  (low confidence) escalate: better URL → browser MCP if available → WebFetch, stored
  labeled `provenance: extraction` — never fake grounding
- Write findings with the finding template (≥500 bytes of real content, frontmatter
  `role:` matching the manifest)
- return ONLY a ≤2k summary + the file path (full findings live on disk, not in context)

## After fan-out

1. `node "$SKILL_DIR/vault-save.js" --check-staging <run-dir>` — exit 2: re-request the missing/stub
   finding from that agent once; still missing → record it under Gaps in synthesis.md
   and move on (a visible gap beats a fake completion).
2. Read the findings FILES before synthesizing — never synthesize from return blurbs.
3. synthesis.md sections: Verdict · Key claims · Gaps · How to re-verify · Related.
4. Stage claims (see references/claims.md), then persist:
   `node "$SKILL_DIR/vault-save.js" <run-dir> --session <session-id> --transcript <path>...`
   Transcript paths: `~/.claude/projects/<cwd-slug>/<session-id>.jsonl` (plus subagent
   transcript files if you can identify them). Copies are gzipped into the run folder so
   provenance survives Claude Code's retention window; a missing path is a warning, not
   a failure.
5. Read the persist JSON: `status: "partial"` → quarantined records are in the run's
   claims-rejected.jsonl with reasons; say "claims: partial (N quarantined)" in the
   answer. `claims.ids` lists the assigned claim ids (useful for follow-up events).
````

- [ ] **Step 5: Write references/claims.md**

Create `plugins/re-searcher/skills/re-searcher/references/claims.md`:

````markdown
# Staging claims — claims-staged.jsonl

One JSON object per line, written into the run dir before persist. Two record shapes.

## Claim records

```json
{"statement": "Remote MCP servers must use OAuth 2.1", "quote": "requires OAuth 2.1 with PKCE",
 "source": "3f9a12cd--spec-example--auth-page", "provenance": "verbatim-grounded", "confidence": "high",
 "type": "finding", "found_by": "spec-reader", "tool": "websearch",
 "locator": "https://spec.example/auth#section-2", "ref": "c1"}
```

Rules (enforced by vault-save; rejects land in claims-rejected.jsonl with reasons):
- `statement` (required): one falsifiable sentence. The claim IS the statement; the
  quote is its evidence.
- `provenance`: `verbatim-grounded | model-asserted | human-asserted`. Never stage
  `externally-verified` — the doctor grants that (stage 3), staging it is rejected.
- `verbatim-grounded` requires `source` (the sourceId vault-fetch prints — shaped <hash8>--<host>--<slug>, the filename stem under sources/)
  AND `quote`. The quote is verified mechanically against the cached extraction:
  found → rewritten to exact source bytes; not found → the claim is KEPT but downgraded
  to model-asserted with a note. So: copy quotes from the extraction text you actually
  read — never compose them from memory.
- `confidence`: `high | medium | speculation` (default medium).
  `type`: `finding | absence` (default finding).
- **absence claims** record "searched X, found nothing as of <date>": put the null
  result in the statement and add `"queries": [...]` with what you tried — exhaustive
  null results should never be silently re-run.
- `ref` (optional): a batch-local handle so staged events can point at this claim before
  its real id exists. Stripped before registration.
- `v`, `id`, `run`, `date`, `topic` are script-assigned — do not stage them. Unknown
  extra fields are preserved verbatim.

## Event records (same file; or standalone via `vault-save.js --events`)

```json
{"op": "supersede", "claim": "clm_abc123", "by": "ref:c1", "reason": "newer spec revision"}
{"op": "contradict", "claim": "ref:c1", "by": "ref:c2", "reason": "sources disagree"}
{"op": "retract", "claim": "clm_abc123", "by": "human", "reason": "wrong research"}
```

- `claim`/`by` accept real ids (`clm_…`) or batch refs (`ref:<name>`).
- `supersede`: `by` is the replacing claim. Cycle-creating edges are rejected (DAG
  check). Superseded claims are preserved as history; recall serves the terminal claim.
- `contradict`: symmetric — BOTH claims keep serving, flagged, until a human resolves
  with an explicit supersede.
- `verify` is doctor-granted (stage 3); staging it is rejected.

## When sources conflict within a run

Record BOTH claims (each with its own source), add a mutual contradict event via refs,
and state in synthesis.md which source tier won and why. Never silently pick a winner.
````

- [ ] **Step 6: Write references/correct.md**

Create `plugins/re-searcher/skills/re-searcher/references/correct.md`:

````markdown
# /research correct — fixing the record

The registry is append-only: corrections are EVENTS, never edits.

1. Find the claim ids: `node "$SKILL_DIR/vault-search.js" "<topic terms>" --vault "$VAULT"` prints
   ids per served claim, or read `topics/<slug>/topic.md` (ids are on every line).
2. Write the events to a temp file with the Write tool (never inline shell), one JSON
   object per line:
   - replace: `{"op":"supersede","claim":"clm_OLD","by":"clm_NEW","reason":"..."}`
     — if the correct claim doesn't exist yet, run the research (or stage it in a run)
     first; supersede needs a real registered target.
   - withdraw: `{"op":"retract","claim":"clm_BAD","by":"human","reason":"..."}`
   - mark conflict: `{"op":"contradict","claim":"clm_A","by":"clm_B","reason":"..."}`
3. Apply: `node "$SKILL_DIR/vault-save.js" --events <file> --vault "$VAULT"` — cycle-creating
   supersedes are rejected by the DAG check; rejects print with reasons.
4. Views regenerate and the vault auto-commits. Verify with a fresh vault-search: the
   old claim should now appear only as `↳ supersedes` history, never as live.

Contradictions stay double-served and flagged until a supersede resolves them —
resolution is a human decision, never a silent one.
````

- [ ] **Step 7: Write the command file**

Create `plugins/re-searcher/commands/research.md`:

```markdown
---
description: Vault-first research — recall prior claims, run light/full research, persist plans, findings, sources and verified claims. Runs the re-searcher skill.
allowed-tools: Bash(node:*), Write, Read, Agent, Grep, Glob, WebSearch, WebFetch
---
Run the **re-searcher** skill with this input: `$ARGUMENTS`

Routing:
- Empty or a question → the full state machine (recall first, always).
- `--fresh <question>` → skip recall, research fresh, still persist to the vault.
- `correct …` → the correction flow (skill references/correct.md): supersede/retract/
  contradict events applied via vault-save.js --events.
- `save` / `harvest` → NOT BUILT YET (stage 2 — the harvester). Say so honestly; offer
  to keep findings in a run dir manually if the user needs capture right now.
- `doctor` → NOT BUILT YET (stage 3 — the librarian). Say so honestly.

As a plugin install this command is namespaced — `/re-searcher:research` — bare
`/research` exists for install.sh copies. Plain-language research asks ("research X",
"have we looked into Y") trigger the skill either way.

Note on allowed-tools: the skill's bash blocks start with a `SKILL_DIR=...` assignment,
which the `Bash(node:*)` prefix matcher does not recognize — expect a permission prompt
on those lines even with this list (same known quirk as /route).
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `bash tests/researcher-skill.test.sh`
Expected: `0 failed`, exit 0. If the line-budget check fails, cut prose from SKILL.md — never raise the budget.

- [ ] **Step 9: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/SKILL.md plugins/re-searcher/skills/re-searcher/references plugins/re-searcher/commands/research.md tests/researcher-skill.test.sh
git commit -m "feat: re-searcher SKILL.md state machine, progressive-disclosure references, /research command"
```

---

### Task 12: registration — marketplace.json, install.sh, README

**Files:**
- Modify: `.claude-plugin/marketplace.json` (add the re-searcher entry to the `plugins` array, after the `route` entry)
- Modify: `install.sh` (chmod for the new scripts + Done-block echo)
- Modify: `README.md` (re-searcher section, after the route section)
- Modify: `tests/researcher-skill.test.sh` (append registration checks before the final `echo; echo "skill: ..."` line)

**Interfaces:**
- Consumes: the file layout shipped in Tasks 1–11.
- Produces: `/research` actually installable — as a plugin (marketplace) and as skill copies (install.sh), exactly like route.

- [ ] **Step 1: Append failing tests**

Append to `tests/researcher-skill.test.sh` immediately **before** the final `echo; echo "skill: ..."` line:

```bash
# --- registration (Task 12) ---
M="$ROOT/.claude-plugin/marketplace.json"
node -e '
const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const p = m.plugins.find((x) => x.name === "re-searcher");
if (!p) process.exit(1);
if (p.source !== "./plugins/re-searcher") process.exit(2);
if (!p.skills.includes("./skills/re-searcher")) process.exit(3);
if (!p.commands.includes("./commands/research.md")) process.exit(4);
' "$M" && ok "marketplace entry valid" || no "marketplace" "rc=$?"
[ -d "$ROOT/plugins/re-searcher/skills/re-searcher" ] && [ -f "$ROOT/plugins/re-searcher/commands/research.md" ] \
  && ok "marketplace paths exist" || no "paths" ""
grep -q 're-searcher' "$ROOT/install.sh" && ok "install.sh knows re-searcher" || no "install.sh" ""
grep -q 're-searcher' "$ROOT/README.md" && ok "README documents re-searcher" || no "README" ""
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/researcher-skill.test.sh`
Expected: Task 11 assertions PASS; the four registration checks FAIL.

- [ ] **Step 3: Add the marketplace entry**

In `.claude-plugin/marketplace.json`, append this object to the `plugins` array (after the `route` entry, comma-separated):

```json
{
  "name": "re-searcher",
  "source": "./plugins/re-searcher",
  "strict": false,
  "version": "0.1.0",
  "description": "A persistent research vault for Claude Code: every research run's plan, per-agent findings, cached sources and quote-verified claims are captured as inspectable markdown with provenance down to the transcript — and future research recalls dated claims to spot-check instead of re-deriving everything.",
  "author": {
    "name": "waltwildwest"
  },
  "license": "MIT",
  "homepage": "https://github.com/waltwildwest/claude-toolkit",
  "repository": "https://github.com/waltwildwest/claude-toolkit",
  "keywords": [
    "research",
    "vault",
    "provenance",
    "claims",
    "citations",
    "sources",
    "recall",
    "knowledge-base"
  ],
  "category": "productivity",
  "skills": [
    "./skills/re-searcher"
  ],
  "commands": [
    "./commands/research.md"
  ]
}
```

Validate: `node -e 'JSON.parse(require("fs").readFileSync(".claude-plugin/marketplace.json","utf8")); console.log("ok")'` → `ok`.

- [ ] **Step 4: Update install.sh**

After the existing route chmod line (`chmod +x "$SKILLS"/route/...`), add:

```bash
chmod +x "$SKILLS"/re-searcher/*.js 2>/dev/null || true
```

In the Done echo block, after the `echo "  Routing:   ..."` line, add:

```bash
echo "  Research:  /research <question> — vault-first research; vault at ~/research-vault (set RESEARCH_VAULT_DIR to move it)."
```

(The generic `plugins/*/skills/*/` and `plugins/*/commands/*.md` copy loops already pick up the new skill and command — no other install.sh changes.)

- [ ] **Step 5: Update README.md**

Insert a section for re-searcher immediately after the route section (match the README's existing heading style for plugins):

```markdown
### re-searcher — research that survives the session

`/research <question>` — recall first: prior claims come back as dated, spot-checkable
claims (never stale verdicts), with near-miss disclosure when nothing matches. New
research runs — light (one agent, cheap) or fan-out — persist the plan, every agent's
raw findings, fetched sources and claims into a git-backed markdown vault
(`~/research-vault`, Obsidian-friendly, `RESEARCH_VAULT_DIR` to relocate).

The honest part: `vault-save` verifies every quoted claim mechanically against the
cached source bytes — verified quotes are rewritten to the source's exact text, unverifiable
ones are downgraded to `model-asserted`, never silently trusted. Corrections are
append-only supersede/retract events; contradicting claims are served flagged, both of
them, until a human resolves the conflict.
```

- [ ] **Step 6: Run tests to verify all pass**

Run: `bash tests/researcher-skill.test.sh && bash install.sh >/dev/null && echo INSTALL-OK`
Expected: `0 failed` + `INSTALL-OK` (install.sh is safe to re-run by design; it copies skills into ~/.claude/skills — acceptable on the dev machine, it's how route is dogfooded).

- [ ] **Step 7: Commit**

```bash
git add .claude-plugin/marketplace.json install.sh README.md tests/researcher-skill.test.sh
git commit -m "feat: register re-searcher plugin — marketplace entry, install.sh, README"
```

---

### Task 13: full-suite verification + manual smoke

**Files:** none created — this is the verify-before-done gate.

- [ ] **Step 1: Full test sweep (all suites, including route/handoff — nothing may regress)**

```bash
for t in tests/*.test.sh; do printf '%-36s ' "$(basename "$t")"; bash "$t" 2>/dev/null | tail -1; done
```

Expected: every line ends `0 failed` (route-learn may be flaky per the handoff — if ONLY route-learn fails, note it and continue; it is explicitly out of scope. Any researcher-* or route-cache/route-detect/route-plan/handoff failure blocks completion).

- [ ] **Step 2: Manual smoke — hand-driven save + search round trip**

```bash
SMOKE=$(mktemp -d)
SK=plugins/re-searcher/skills/re-searcher
node $SK/vault-init.js --vault "$SMOKE/v"
OUT=$(node $SK/vault-save.js --new-run --topic smoke-test --session smoke123 --vault "$SMOKE/v")
echo "$OUT"
```

Then, with the printed runDir: write a minimal plan.md (1-role manifest), one finding
(≥500 bytes), synthesis.md, a claims-staged.jsonl with one verbatim claim against a
hand-seeded `sources/src_smoke.md` — then:

```bash
node $SK/vault-save.js <runDir> --vault "$SMOKE/v" --session smoke123
node $SK/vault-search.js smoke --vault "$SMOKE/v"
git -C "$SMOKE/v" log --oneline
```

Confirm by eye: claims registered with `clm_` ids, topic.md + INDEX.md generated, the
search prints the provenance line and the claim, git log shows `research: vault init`
and `research: persist run …`. Then stage a supersede via `--events` and re-search:
the terminal claim serves with the `↳ supersedes` note.

- [ ] **Step 3: Line-count + zero-dep sanity**

```bash
wc -l plugins/re-searcher/skills/re-searcher/*.js | sort -n
grep -rn "require(" plugins/re-searcher/skills/re-searcher/*.js | grep -v -E "require\('(\./|fs|path|crypto|zlib|child_process|http|https)" || echo ZERO-DEP-OK
```

Expected: every file ≤800 lines; `ZERO-DEP-OK`.

- [ ] **Step 4: Report** — present the suite table, the smoke transcript, and the diff stat to the user. Do NOT merge yet; the final whole-branch review (subagent-driven-development's last gate) happens after this task.

---

## Self-Review (performed at write time)

1. **Spec coverage (Roadmap item 1 + handoff scope):** vault format → vault-init (Task 4) + layout table; `/research` light+full → SKILL.md §3/§4 (Task 11); recall with near-miss disclosure → vault-search (Task 9); staging capture + manifest completeness → `--new-run`/`--check-staging` (Task 5); layered persist → Task 8 tier 1/tier 2; claims registry with events + DAG → Tasks 6+8; transcripts copied → Task 8 (gzip, tested); git lifecycle → vault-init `git init` + `gitCommit` on every mutation (init/save/events/alias, all tested); serve-then-verify staleness announcements → freshness line in vault-search (announcement + skill instruction; the background freshness *agent* is stage 3 by design); five Stage 0 amendments → Tasks 1–2 (a/b/c/e implemented, d test fixture); registration → Task 12. Deliberately out (per handoff): harvester, Stop-hook inbox, doctor/librarian, embeddings, wayback drain, export, --as-of, fork, save-prompt dialogs.
2. **Placeholder scan:** the only free-form spot is Task 13's manual smoke (a hand-driven measurement, like Stage 0 Tasks 6–7 — the exact commands and pass criteria are given). Every code step contains complete code; no TBDs.
3. **Type consistency:** `verify()` result `{verified, method, sourceQuote}` consumed identically in claim-validate (Task 6); `foldClaims` folded shape (`status/supersededBy/contradictedBy/events`) consumed by vault-views (Task 7) and vault-search (Task 9); `stagingReport` shape shared by `--check-staging` and persist warnings (Tasks 5/8); persist JSON `claims.{accepted,rejected,downgraded,events,duplicates,ids}` asserted in Tasks 8/10; index record `{slug,title,aliases,questions,scope,run,date}` written by persist (8), read by views (7) and search (9); `ref:`/`ids` mechanics documented in references/claims.md and full-path.md (Task 11) match the Task 8 implementation.
4. **Known judgment calls (do not "fix" without discussion):** search scoring weights (3/2/1/+2/+5) and the 0.15 trigram near-miss floor are starting values — metrics.jsonl exists precisely to tune them later; `--events` regenerates every event-bearing topic (over-broad, always correct); light-path runs still require plan.md + manifest (uniform staging contract keeps `--check-staging` and the doctor's orphan sweep simple).




