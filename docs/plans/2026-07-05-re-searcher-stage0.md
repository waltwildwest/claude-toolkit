# Re:Searcher Stage 0 (Prototype Slice) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and benchmark the two components the whole Re:Searcher design stands on — the raw-fetch/extraction pipeline (`vault-fetch`) and the deterministic quote verifier — and produce the go/no-go number: **% of claims that can earn `verbatim-grounded`** against ~20 real research URLs.

**Architecture:** Three small zero-dep Node scripts under `plugins/re-searcher/skills/re-searcher/`: `html-extract.js` (readability-style HTML→markdown + extraction-confidence scoring), `quote-verify.js` (normalize/locate/rewrite quotes against cached extractions), `vault-fetch.js` (curl-class fetcher composing the other two, storing sources with dual hashes and dedupe). A bench harness runs the live-URL benchmark. No SKILL.md, no marketplace/install.sh registration in Stage 0 — this is a measurement instrument that carries forward into Stage 1 unchanged.

**Tech Stack:** Node core only (`https`, `zlib`, `crypto`, `fs`, `path`, `child_process`). Bash test harness in house style (`tests/*.test.sh`, `ok`/`no` counters, temp dirs, no network in CI tests).

**Reference spec:** `docs/specs/2026-07-05-re-searcher-design.md` (v2, locked). This plan implements the spec's "Roadmap → 0. Prototype-first slice".

## Global Constraints

- Zero npm dependencies; Node core modules only; every script starts `#!/usr/bin/env node` + `'use strict';` + a usage-header comment (house style: see `plugins/route/skills/route/route-cache.js`).
- CI tests never touch the live network — fixture HTML served by an inline local HTTP server or read from files.
- Files ≤800 lines; functions <50 lines where practical.
- Atomic writes: temp file + rename for anything under the vault dir.
- Fail loud: unusable input → non-zero exit + actionable message on stderr; never store garbage silently (spec: extraction-confidence gate).
- Vault dir comes from `--vault <dir>` arg or `RESEARCH_VAULT_DIR` env; missing → exit 1 with "vault missing at <path> — pass --vault or set RESEARCH_VAULT_DIR" (spec: a missing vault must never masquerade as an empty one).
- Commit style: `feat:` / `test:` / `docs:` / `chore:`, no attribution footer.
- Windows: tests skip on MINGW/MSYS/CYGWIN like route-cache tests do.

## File Structure

```
plugins/re-searcher/
├── skills/re-searcher/
│   ├── html-extract.js      # Task 1+2: extraction + confidence (module + CLI)
│   ├── quote-verify.js      # Task 3: normalize/verify/relocate quotes (module + CLI)
│   └── vault-fetch.js       # Task 4: fetch → gate → store (CLI, requires the two above)
├── bench/
│   ├── urls.txt             # Task 5: the 20-URL corpus
│   ├── run-bench.js         # Task 5: fetch benchmark harness
│   └── results/             # Task 6-7 outputs (committed: summary + claims study)
tests/
├── researcher-extract.test.sh
├── researcher-quote.test.sh
└── researcher-fetch.test.sh
docs/superpowers/... (none — this repo uses docs/specs + docs/plans)
```

---

### Task 1: `html-extract.js` — extraction core

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/html-extract.js`
- Test: `tests/researcher-extract.test.sh`

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces (used by Tasks 2, 4):
  - `extract(html: string) -> {title: string, markdown: string, textLength: number, linkDensity: number}` (module export)
  - CLI: `node html-extract.js <file.html>` → JSON of the extract() result on stdout, exit 0. Missing/unreadable file → exit 1, message on stderr.

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-extract.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/html-extract.js
# Run: bash tests/researcher-extract.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
X="$ROOT/plugins/re-searcher/skills/re-searcher/html-extract.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-extract tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"
echo "html-extract tests"

# fixture: a normal SSR article page with chrome to strip
cat > "$W/article.html" <<'EOF'
<!DOCTYPE html><html><head><title>MCP Auth &amp; You</title>
<style>body{color:red}</style><script>var x=1;</script></head>
<body>
<nav><a href="/">Home</a><a href="/about">About</a></nav>
<header><h1>Site Header</h1></header>
<article>
<h1>MCP Auth &amp; You</h1>
<p>OAuth 2.1 is the <strong>required</strong> flow for remote servers &mdash; PKCE included.</p>
<h2>Device flow</h2>
<p>The device flow is optional. See <a href="https://spec.example/auth">the spec</a> for details.</p>
<ul><li>First point</li><li>Second point</li></ul>
<pre><code>GET /authorize?response_type=code</code></pre>
</article>
<footer><p>Copyright links <a href="/a">a</a><a href="/b">b</a><a href="/c">c</a></p></footer>
</body></html>
EOF

OUT=$(node "$X" "$W/article.html")
# 1. title extracted and entity-decoded
has "$OUT" '"title":"MCP Auth & You"' && ok "title decoded" || no "title decoded" "$OUT"
# 2. headings become markdown
has "$OUT" '# MCP Auth & You' && ok "h1 -> #" || no "h1" "$OUT"
has "$OUT" '## Device flow' && ok "h2 -> ##" || no "h2" "$OUT"
# 3. inline markup converts
has "$OUT" '**required**' && ok "strong -> **" || no "strong" "$OUT"
has "$OUT" '[the spec](https://spec.example/auth)' && ok "a -> [text](href)" || no "link" "$OUT"
# 4. lists and code blocks survive
has "$OUT" '- First point' && ok "li -> -" || no "li" "$OUT"
has "$OUT" 'GET /authorize?response_type=code' && ok "pre/code preserved" || no "pre" "$OUT"
# 5. entities decoded in body (mdash)
has "$OUT" 'servers — PKCE' && ok "entities decoded" || no "entities" "$OUT"
# 6. chrome stripped: nav/header/footer/script/style must not leak
if has "$OUT" 'Site Header' || has "$OUT" 'Copyright links' || has "$OUT" 'var x=1' || has "$OUT" 'color:red'; then
  no "chrome stripped" "$OUT"; else ok "chrome stripped"; fi
# 7. metrics present and sane
node -e 'const r=JSON.parse(process.argv[1]); if(r.textLength>100 && r.linkDensity>=0 && r.linkDensity<0.3) process.exit(0); process.exit(1)' "$OUT" \
  && ok "metrics sane" || no "metrics sane" "$OUT"

# fixture: article-less page falls back to <main>, then <body>
cat > "$W/main.html" <<'EOF'
<html><head><title>t</title></head><body>
<main><p>Main region text that should be extracted as the content.</p></main>
</body></html>
EOF
OUT=$(node "$X" "$W/main.html")
has "$OUT" 'Main region text' && ok "main fallback" || no "main fallback" "$OUT"

# 8. missing file -> exit 1 with message
ERR=$(node "$X" "$W/nope.html" 2>&1); rcode=$?
{ [ $rcode -eq 1 ] && has "$ERR" "cannot read"; } && ok "missing file fails loud" || no "missing file" "rc=$rcode $ERR"

echo; echo "extract: $pass passed, $fail failed"; [ $fail -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/researcher-extract.test.sh`
Expected: FAIL (node: cannot find module .../html-extract.js) — the harness itself errors before any PASS.

- [ ] **Step 3: Write the implementation**

Create `plugins/re-searcher/skills/re-searcher/html-extract.js`:

```js
#!/usr/bin/env node
'use strict';
// html-extract — zero-dep readability-style HTML -> markdown extraction.
// Regex-based (no DOM): strips chrome, prefers <article>/<main>/<body>,
// converts block + inline markup, decodes entities, reports text metrics.
// Good on SSR pages (docs, blogs, GitHub, wikis); SPA shells and challenge
// pages come out thin — that is what the confidence scorer (assess) is for.
//
//   node html-extract.js <file.html>          # JSON {title, markdown, textLength, linkDensity}
//
// Module API: extract(html), assess(html, extracted)  [assess added in Task 2]

const fs = require('fs');

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
  mdash: '—', ndash: '–', hellip: '…', rsquo: '’', lsquo: '‘',
  rdquo: '”', ldquo: '“', copy: '©', reg: '®', trade: '™',
  laquo: '«', raquo: '»', times: '×', middot: '·' };

function decodeEntities(s) {
  return s
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => safeCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => safeCodePoint(parseInt(d, 10)))
    .replace(/&([a-z]+);/gi, (m, n) => ENTITIES[n.toLowerCase()] !== undefined ? ENTITIES[n.toLowerCase()] : m);
}
function safeCodePoint(n) {
  try { return String.fromCodePoint(n); } catch (_e) { return ''; }
}

function stripTagBlocks(html, tags) {
  let out = html;
  for (const t of tags) out = out.replace(new RegExp('<' + t + '\\b[^>]*>[\\s\\S]*?<\\/' + t + '>', 'gi'), ' ');
  return out;
}

// Convert inline markup inside a block's inner HTML to markdown text.
function inline(s) {
  let t = s;
  t = t.replace(/<a\b[^>]*href=["']([^"']*)["'][^>]*>([\s\S]*?)<\/a>/gi,
    (_, href, text) => {
      const label = plain(text).trim();
      if (!label) return '';
      return href && !/^\s*(#|javascript:)/i.test(href) ? '[' + label + '](' + href + ')' : label;
    });
  t = t.replace(/<(strong|b)\b[^>]*>([\s\S]*?)<\/\1>/gi, (_, _t, x) => '**' + plain(x).trim() + '**');
  t = t.replace(/<(em|i)\b[^>]*>([\s\S]*?)<\/\1>/gi, (_, _t, x) => '*' + plain(x).trim() + '*');
  t = t.replace(/<code\b[^>]*>([\s\S]*?)<\/code>/gi, (_, x) => '`' + plain(x).trim() + '`');
  return plain(t);
}
// Strip any remaining tags, decode entities, collapse intra-block whitespace.
function plain(s) {
  return decodeEntities(s.replace(/<[^>]+>/g, ' ')).replace(/[ \t\r\f]+/g, ' ');
}

function extract(html) {
  let h = String(html).replace(/<!--[\s\S]*?-->/g, ' ');
  const titleM = h.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i);
  const title = titleM ? plain(titleM[1]).trim() : '';
  h = stripTagBlocks(h, ['script', 'style', 'noscript', 'svg', 'iframe', 'template', 'canvas']);

  // Region: prefer semantic content containers, largest-first among articles.
  let region = null;
  const articles = h.match(/<article\b[^>]*>[\s\S]*?<\/article>/gi);
  if (articles && articles.length) region = articles.sort((a, b) => b.length - a.length)[0];
  if (!region) { const m = h.match(/<main\b[^>]*>([\s\S]*?)<\/main>/i); if (m) region = m[1]; }
  if (!region) { const m = h.match(/<body\b[^>]*>([\s\S]*?)<\/body>/i); if (m) region = m[1]; }
  if (!region) region = h;
  region = stripTagBlocks(region, ['nav', 'footer', 'header', 'aside', 'form', 'button', 'select', 'dialog']);

  // Protect code blocks from inline processing.
  const fences = [];
  region = region.replace(/<pre\b[^>]*>([\s\S]*?)<\/pre>/gi, (_, body) => {
    const code = decodeEntities(body.replace(/<[^>]+>/g, '')).replace(/^\n+|\s+$/g, '');
    fences.push(code);
    return '\n\n FENCE' + (fences.length - 1) + ' \n\n';
  });

  // Link-density accounting BEFORE tags are consumed.
  let linkChars = 0;
  region.replace(/<a\b[^>]*>([\s\S]*?)<\/a>/gi, (_, text) => { linkChars += plain(text).trim().length; return ''; });

  let md = region;
  md = md.replace(/<h([1-6])\b[^>]*>([\s\S]*?)<\/h\1>/gi,
    (_, lvl, text) => '\n\n' + '#'.repeat(Number(lvl)) + ' ' + inline(text).trim() + '\n\n');
  md = md.replace(/<li\b[^>]*>([\s\S]*?)<\/li>/gi, (_, text) => '\n- ' + inline(text).trim());
  md = md.replace(/<(ul|ol)\b[^>]*>/gi, '\n').replace(/<\/(ul|ol)>/gi, '\n');
  md = md.replace(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi, (_, row) => {
    const cells = [];
    row.replace(/<(td|th)\b[^>]*>([\s\S]*?)<\/\1>/gi, (_m, _t, c) => { cells.push(inline(c).trim()); return ''; });
    return cells.length ? '\n| ' + cells.join(' | ') + ' |' : '';
  });
  md = md.replace(/<blockquote\b[^>]*>([\s\S]*?)<\/blockquote>/gi, (_, q) => '\n\n> ' + inline(q).trim() + '\n\n');
  md = md.replace(/<(p|div|section)\b[^>]*>/gi, '\n\n').replace(/<br\s*\/?>/gi, '\n');
  md = inline(md);

  md = md.replace(/ FENCE(\d+) /g, (_, i) => '```\n' + fences[Number(i)] + '\n```');
  md = md.split('\n').map((l) => l.replace(/[ \t]+$/g, '')).join('\n')
    .replace(/\n{3,}/g, '\n\n').trim();

  const textLength = md.replace(/\s+/g, ' ').length;
  const linkDensity = textLength > 0 ? Math.min(1, linkChars / textLength) : 0;
  return { title, markdown: md, textLength, linkDensity: Number(linkDensity.toFixed(3)) };
}

function main() {
  const file = process.argv[2];
  if (!file) { process.stderr.write('usage: html-extract.js <file.html>\n'); process.exit(1); }
  let html;
  try { html = fs.readFileSync(file, 'utf8'); }
  catch (err) { process.stderr.write('cannot read ' + file + ': ' + (err.code || err.message) + '\n'); process.exit(1); }
  process.stdout.write(JSON.stringify(extract(html)) + '\n');
}

if (require.main === module) main();
module.exports = { extract, decodeEntities, plain };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/researcher-extract.test.sh`
Expected: `extract: 11 passed, 0 failed` (exit 0). If individual conversions fail, fix the corresponding regex — do not weaken the test.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/html-extract.js tests/researcher-extract.test.sh
git commit -m "feat: re-searcher html-extract — zero-dep readability-style extraction"
```

---

### Task 2: extraction-confidence scoring (`assess`)

**Files:**
- Modify: `plugins/re-searcher/skills/re-searcher/html-extract.js` (add `assess`, extend CLI)
- Modify: `tests/researcher-extract.test.sh` (append assess tests)

**Interfaces:**
- Produces (used by Task 4):
  - `assess(html: string, extracted: {markdown, textLength, linkDensity}) -> {score: number 0..1, usable: boolean, signals: string[]}`
  - `usable === (score >= 0.5)`. Signals vocabulary (exact strings, Task 4's output relies on them): `challenge-page`, `thin-text`, `link-farm`, `script-shell`.
  - CLI gains `--assess` flag: `node html-extract.js <file.html> --assess` → JSON `{title, markdown, textLength, linkDensity, score, usable, signals}`.

- [ ] **Step 1: Append failing tests**

Append to `tests/researcher-extract.test.sh` **before** the final `echo; echo "extract: ..."` line:

```bash
# --- assess (Task 2) ---

# SPA shell: big HTML, no text
cat > "$W/spa.html" <<'EOF'
<html><head><title>App</title></head><body><div id="root"></div>
<script src="/bundle.js"></script></body></html>
EOF
OUT=$(node "$X" "$W/spa.html" --assess)
node -e 'const r=JSON.parse(process.argv[1]); process.exit(!r.usable && r.signals.includes("thin-text") ? 0 : 1)' "$OUT" \
  && ok "spa shell -> not usable, thin-text" || no "spa shell" "$OUT"

# Cloudflare-style challenge page
cat > "$W/challenge.html" <<'EOF'
<html><head><title>Just a moment...</title></head><body>
<h1>Just a moment...</h1><p>Checking your browser before accessing example.com.</p>
<p>Ray ID: 8a2b3c4d5e6f</p></body></html>
EOF
OUT=$(node "$X" "$W/challenge.html" --assess)
node -e 'const r=JSON.parse(process.argv[1]); process.exit(!r.usable && r.signals.includes("challenge-page") ? 0 : 1)' "$OUT" \
  && ok "challenge page detected" || no "challenge" "$OUT"

# Link farm: text dominated by link labels
cat > "$W/links.html" <<'EOF'
<html><head><title>Links</title></head><body><main>
<p><a href="/1">alpha beta gamma</a> <a href="/2">delta epsilon zeta</a>
<a href="/3">eta theta iota</a> <a href="/4">kappa lambda mu</a> x</p>
</main></body></html>
EOF
OUT=$(node "$X" "$W/links.html" --assess)
node -e 'const r=JSON.parse(process.argv[1]); process.exit(!r.usable && r.signals.includes("link-farm") ? 0 : 1)' "$OUT" \
  && ok "link farm -> not usable" || no "link farm" "$OUT"

# The good article from Task 1 must be usable with no signals
OUT=$(node "$X" "$W/article.html" --assess)
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.usable && r.score>=0.7 && r.signals.length===0 ? 0 : 1)' "$OUT" \
  && ok "real article -> usable, clean" || no "article usable" "$OUT"
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/researcher-extract.test.sh`
Expected: prior 11 still PASS; the 4 new ones FAIL (`--assess` output lacks `usable`).

- [ ] **Step 3: Implement `assess`**

In `html-extract.js`, add after `extract`:

```js
const CHALLENGE_RE = /just a moment|checking your browser|attention required|cf-ray|ray id:|enable javascript and cookies|access denied|captcha/i;

function assess(html, ext) {
  const signals = [];
  let score = 1.0;
  if (CHALLENGE_RE.test(String(html))) { signals.push('challenge-page'); score -= 0.6; }
  if (ext.textLength < 400) { signals.push('thin-text'); score -= 0.4; }
  if (ext.linkDensity > 0.5) { signals.push('link-farm'); score -= 0.3; }
  const rawLen = String(html).length;
  if (rawLen > 20000 && ext.textLength < rawLen / 200) { signals.push('script-shell'); score -= 0.3; }
  score = Math.max(0, Math.min(1, Number(score.toFixed(2))));
  return { score, usable: score >= 0.5, signals };
}
```

Update `main()` to honor the flag and `module.exports`:

```js
function main() {
  const file = process.argv[2];
  const wantAssess = process.argv.includes('--assess');
  if (!file || file.startsWith('--')) { process.stderr.write('usage: html-extract.js <file.html> [--assess]\n'); process.exit(1); }
  let html;
  try { html = fs.readFileSync(file, 'utf8'); }
  catch (err) { process.stderr.write('cannot read ' + file + ': ' + (err.code || err.message) + '\n'); process.exit(1); }
  const ext = extract(html);
  const out = wantAssess ? Object.assign({}, ext, assess(html, ext)) : ext;
  process.stdout.write(JSON.stringify(out) + '\n');
}
```

```js
module.exports = { extract, assess, decodeEntities, plain };
```

- [ ] **Step 4: Run tests to verify all pass**

Run: `bash tests/researcher-extract.test.sh`
Expected: `extract: 15 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/html-extract.js tests/researcher-extract.test.sh
git commit -m "feat: re-searcher extraction-confidence gate (assess)"
```

---

### Task 3: `quote-verify.js` — the verbatim-grounded verifier

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/quote-verify.js`
- Test: `tests/researcher-quote.test.sh`

**Interfaces:**
- Consumes: nothing (leaf module; operates on plain text/markdown strings).
- Produces (used by Task 7 and by Stage 1's vault-save):
  - `normalize(s: string) -> string` — NFKC, curly quotes → straight, en/em-dash → `-`, whitespace runs → single space, trim. Case-preserving.
  - `verify(quote: string, source: string) -> {verified: boolean, method: 'exact'|'normalized'|'fuzzy'|'none', sourceQuote: string|null}` — `sourceQuote` is always **exact bytes from `source`** when verified (spec: on fuzzy match, rewrite the quote to source bytes; source is ground truth).
  - CLI: `node quote-verify.js --quote-file <q.txt> --source-file <s.md>` → JSON result on stdout; exit 0 if verified, 1 if not, 2 on usage/IO error. Files, never shell args, carry quote text (house rule: untrusted text never interpolates into command lines).

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-quote.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/quote-verify.js
# Run: bash tests/researcher-quote.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
Q="$ROOT/plugins/re-searcher/skills/re-searcher/quote-verify.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-quote tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"
qv(){ node "$Q" --quote-file "$W/q.txt" --source-file "$W/s.md"; }
echo "quote-verify tests"

cat > "$W/s.md" <<'EOF'
# The report

Subagents call tools to store their work in external systems, then pass
lightweight references back to the coordinator. This prevents information
loss during multi-stage processing — and reduces token overhead from copying
large outputs through conversation history.

Token usage by itself explains 80% of the variance.
EOF

# 1. exact substring -> exact
printf 'Token usage by itself explains 80%% of the variance.' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"method":"exact"'; } && ok "exact match" || no "exact" "rc=$rcode $OUT"

# 2. whitespace/linebreak differences -> normalized, sourceQuote has source's line break
printf 'Subagents call tools to store their work in external systems, then pass lightweight references back to the coordinator.' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"method":"normalized"'; } && ok "normalized whitespace match" || no "normalized" "rc=$rcode $OUT"
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.sourceQuote.includes("then pass\nlightweight") ? 0 : 1)' "$OUT" \
  && ok "sourceQuote is exact source bytes" || no "source bytes" "$OUT"

# 3. curly quotes / em-dash in the LLM transcription -> normalized
printf 'loss during multi-stage processing - and reduces token overhead' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"method":"normalized"'; } && ok "dash normalization" || no "dash" "rc=$rcode $OUT"

# 4. paraphrase with high word overlap -> fuzzy, returns real source span
printf 'Subagents store their work in external systems and pass lightweight references to the coordinator' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"method":"fuzzy"'; } && ok "fuzzy relocation" || no "fuzzy" "rc=$rcode $OUT"
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.sourceQuote && r.sourceQuote.includes("external systems") ? 0 : 1)' "$OUT" \
  && ok "fuzzy sourceQuote from source" || no "fuzzy bytes" "$OUT"

# 5. fabricated quote -> none, exit 1
printf 'The coordinator always re-reads every transcript before synthesis begins.' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" '"method":"none"'; } && ok "fabrication rejected" || no "fabrication" "rc=$rcode $OUT"

# 6. usage error -> exit 2
node "$Q" --quote-file "$W/q.txt" >/dev/null 2>&1; [ $? -eq 2 ] && ok "usage error -> exit 2" || no "usage exit" "$?"

echo; echo "quote-verify: $pass passed, $fail failed"; [ $fail -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/researcher-quote.test.sh`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the implementation**

Create `plugins/re-searcher/skills/re-searcher/quote-verify.js`:

```js
#!/usr/bin/env node
'use strict';
// quote-verify — the deterministic half of "verbatim-grounded".
// Checks that a claim's quote actually appears in a cached source extraction.
// Match ladder: exact substring -> normalized substring (NFKC, straight
// quotes, dashes, collapsed whitespace) -> fuzzy word-window relocation.
// On any verified match the returned sourceQuote is EXACT SOURCE BYTES —
// the source is ground truth, not the model's transcription of it.
//
//   node quote-verify.js --quote-file <q.txt> --source-file <s.md>
//   exit 0 verified / 1 not verified / 2 usage or IO error
//
// Module API: normalize(s), verify(quote, source)

const fs = require('fs');

function normChar(c) {
  if (c === '‘' || c === '’' || c === '‛') return "'";
  if (c === '“' || c === '”') return '"';
  if (c === '–' || c === '—') return '-';
  return c.normalize('NFKC');
}

// Normalize while keeping a map from normalized index -> original index,
// so a normalized-space match can be sliced back out of the original bytes.
function buildNormalized(s) {
  const chars = [];
  const map = [];
  let pendingSpace = false;
  for (let i = 0; i < s.length; i++) {
    const n = normChar(s[i]);
    if (/\s/.test(n)) { pendingSpace = chars.length > 0; continue; }
    if (pendingSpace) { chars.push(' '); map.push(i); pendingSpace = false; }
    for (const ch of n) { chars.push(ch); map.push(i); }
  }
  return { text: chars.join(''), map };
}

function normalize(s) { return buildNormalized(String(s)).text; }

function sliceOriginal(source, map, start, endIncl) {
  return source.slice(map[start], map[endIncl] + 1);
}

function verify(quote, source) {
  const q = String(quote), src = String(source);
  if (q.trim().length === 0) return { verified: false, method: 'none', sourceQuote: null };
  if (src.includes(q)) return { verified: true, method: 'exact', sourceQuote: q };

  const nq = buildNormalized(q), ns = buildNormalized(src);
  const idx = ns.text.indexOf(nq.text);
  if (idx !== -1) {
    return { verified: true, method: 'normalized',
      sourceQuote: sliceOriginal(src, ns.map, idx, idx + nq.text.length - 1) };
  }

  // Fuzzy: anchor on quote word n-grams found in the source word stream,
  // require >=70% of quote words inside the located window.
  const qWords = nq.text.toLowerCase().split(' ').filter(Boolean);
  const sWords = ns.text.toLowerCase().split(' ');
  if (qWords.length < 6) return { verified: false, method: 'none', sourceQuote: null };
  // word start offsets in normalized source
  const offsets = [];
  { let pos = 0;
    for (const w of sWords) { offsets.push(pos); pos += w.length + 1; } }
  const N = Math.min(5, qWords.length);
  const firstGram = qWords.slice(0, N).join(' ');
  const lastGram = qWords.slice(-N).join(' ');
  const lowerNs = ns.text.toLowerCase();
  let start = lowerNs.indexOf(firstGram);
  let endAnchor = lowerNs.lastIndexOf(lastGram);
  if (start === -1 && endAnchor === -1) {
    // last resort: any interior 5-gram
    for (let i = 1; i + N <= qWords.length - 1 && start === -1; i++) {
      start = lowerNs.indexOf(qWords.slice(i, i + N).join(' '));
    }
    if (start === -1) return { verified: false, method: 'none', sourceQuote: null };
  }
  if (start === -1) start = Math.max(0, endAnchor - nq.text.length * 2);
  let end = endAnchor !== -1 && endAnchor >= start
    ? endAnchor + lastGram.length - 1
    : Math.min(ns.text.length - 1, start + Math.floor(nq.text.length * 1.5));
  const windowWords = new Set(lowerNs.slice(start, end + 1).split(' ').filter(Boolean));
  const covered = qWords.filter((w) => windowWords.has(w)).length / qWords.length;
  if (covered < 0.7) return { verified: false, method: 'none', sourceQuote: null };
  return { verified: true, method: 'fuzzy', sourceQuote: sliceOriginal(src, ns.map, start, end) };
}

function arg(name) {
  const i = process.argv.indexOf(name);
  return i !== -1 ? process.argv[i + 1] : null;
}

function main() {
  const qf = arg('--quote-file'), sf = arg('--source-file');
  if (!qf || !sf) { process.stderr.write('usage: quote-verify.js --quote-file <q> --source-file <s>\n'); process.exit(2); }
  let q, s;
  try { q = fs.readFileSync(qf, 'utf8'); s = fs.readFileSync(sf, 'utf8'); }
  catch (err) { process.stderr.write('cannot read input: ' + (err.code || err.message) + '\n'); process.exit(2); }
  const res = verify(q, s);
  process.stdout.write(JSON.stringify(res) + '\n');
  process.exit(res.verified ? 0 : 1);
}

if (require.main === module) main();
module.exports = { normalize, verify };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/researcher-quote.test.sh`
Expected: `quote-verify: 9 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/quote-verify.js tests/researcher-quote.test.sh
git commit -m "feat: re-searcher quote-verify — deterministic verbatim-grounding check"
```

---

### Task 4: `vault-fetch.js` — fetch, gate, store

**Files:**
- Create: `plugins/re-searcher/skills/re-searcher/vault-fetch.js`
- Test: `tests/researcher-fetch.test.sh`

**Interfaces:**
- Consumes: `require('./html-extract')` → `extract(html)`, `assess(html, ext)` (Tasks 1–2 signatures).
- Produces (used by Task 5's bench; by Stage 1's agents):
  - CLI: `node vault-fetch.js <url> [--vault <dir>] [--timeout <ms>] [--max-bytes <n>]`
  - stdout: one JSON line `{status, url, finalUrl, sourceId, sourcePath, rawPath, title, textLength, score, signals, extractionHash}`; on non-stored statuses irrelevant fields are null.
  - `status` ∈ `stored | duplicate | low-confidence | fetch-error`. Exit codes: 0 (stored/duplicate), 2 (low-confidence — caller escalates to browser/WebFetch), 1 (fetch-error or bad usage).
  - Storage: `sources/<hash8>--<host>--<slug>.md` (frontmatter: `v: 1`, url, final_url, fetched (ISO), kind: web, raw_sha256, extraction_sha256, score, signals, title; body = extraction markdown), raw bytes at `sources/raw/<hash8>.html`, and one JSON line appended to `sources/fetch-log.jsonl` (the Stage 0 dedupe lookup). `hash8` = first 8 hex of sha256(raw bytes).
  - Dedupe rule (spec): normalized URL (lowercase host, strip fragment + utm_*) + `extraction_sha256` both seen in fetch-log → `duplicate`.

- [ ] **Step 1: Write the failing test**

Create `tests/researcher-fetch.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-fetch.js
# CI-safe: serves fixtures from a local node http server; no live network.
# Run: bash tests/researcher-fetch.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/plugins/re-searcher/skills/re-searcher/vault-fetch.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-fetch tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"; mkdir -p "$V"

# Fixture server: /article (also gzip if asked), /redirect -> /article,
# /challenge, /big (over cap), /slow (never responds)
cat > "$W/server.js" <<'EOF'
'use strict';
const http = require('http'), zlib = require('zlib');
const article = `<html><head><title>Fixture Article</title></head><body><article>
<h1>Fixture Article</h1>
<p>${'A perfectly ordinary paragraph of research content. '.repeat(20)}</p>
</article></body></html>`;
const challenge = '<html><head><title>Just a moment...</title></head><body><p>Checking your browser. Ray ID: abc</p></body></html>';
const srv = http.createServer((req, res) => {
  if (req.url === '/redirect') { res.writeHead(302, { location: '/article' }); return res.end(); }
  if (req.url === '/article') {
    const gz = /gzip/.test(req.headers['accept-encoding'] || '');
    const body = gz ? zlib.gzipSync(article) : Buffer.from(article);
    res.writeHead(200, gz ? { 'content-type': 'text/html', 'content-encoding': 'gzip' } : { 'content-type': 'text/html' });
    return res.end(body);
  }
  if (req.url === '/challenge') { res.writeHead(200, { 'content-type': 'text/html' }); return res.end(challenge); }
  if (req.url === '/big') { res.writeHead(200, { 'content-type': 'text/html' }); return res.end('x'.repeat(2 * 1024 * 1024)); }
  if (req.url === '/slow') return; // hang
  res.writeHead(404); res.end('nope');
});
srv.listen(0, '127.0.0.1', () => console.log(srv.address().port));
EOF
node "$W/server.js" > "$W/port.txt" & SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$W/port.txt" ] && break; sleep 0.2; done
PORT=$(cat "$W/port.txt"); BASE="http://127.0.0.1:$PORT"
echo "vault-fetch tests (fixture server on :$PORT)"

# 1. stored: article fetch stores extraction + raw + log line
OUT=$(node "$F" "$BASE/article" --vault "$V"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"stored"'; } && ok "stores article" || no "store" "rc=$rcode $OUT"
SRCPATH=$(node -e 'console.log(JSON.parse(process.argv[1]).sourcePath)' "$OUT")
[ -f "$SRCPATH" ] && grep -q 'Fixture Article' "$SRCPATH" && ok "extraction written" || no "extraction file" "$SRCPATH"
grep -q 'raw_sha256' "$SRCPATH" && grep -q 'extraction_sha256' "$SRCPATH" && ok "frontmatter has dual hashes" || no "frontmatter" "$(head -15 "$SRCPATH")"
RAWPATH=$(node -e 'console.log(JSON.parse(process.argv[1]).rawPath)' "$OUT")
[ -f "$RAWPATH" ] && ok "raw bytes kept" || no "raw" "$RAWPATH"
[ -f "$V/sources/fetch-log.jsonl" ] && ok "fetch-log appended" || no "fetch-log" ""

# 2. duplicate: same URL again -> duplicate, no second source file
N1=$(ls "$V/sources/"*.md | wc -l | tr -d ' ')
OUT=$(node "$F" "$BASE/article" --vault "$V"); rcode=$?
N2=$(ls "$V/sources/"*.md | wc -l | tr -d ' ')
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"duplicate"' && [ "$N1" = "$N2" ]; } && ok "dedupe on url+extraction hash" || no "dedupe" "rc=$rcode $N1->$N2 $OUT"

# 3. redirect followed, finalUrl recorded
OUT=$(node "$F" "$BASE/redirect" --vault "$V")
has "$OUT" '"finalUrl":"'"$BASE"'/article"' && ok "redirect followed" || no "redirect" "$OUT"

# 4. challenge page -> low-confidence, exit 2, nothing stored for it
OUT=$(node "$F" "$BASE/challenge" --vault "$V"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" '"status":"low-confidence"' && has "$OUT" 'challenge-page'; } \
  && ok "confidence gate refuses challenge page" || no "gate" "rc=$rcode $OUT"

# 5. size cap -> fetch-error
OUT=$(node "$F" "$BASE/big" --vault "$V" --max-bytes 100000); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" '"status":"fetch-error"'; } && ok "size cap enforced" || no "size cap" "rc=$rcode $OUT"

# 6. timeout -> fetch-error (fast)
START=$(date +%s)
OUT=$(node "$F" "$BASE/slow" --vault "$V" --timeout 1500); rcode=$?
EL=$(( $(date +%s) - START ))
{ [ $rcode -eq 1 ] && has "$OUT" '"status":"fetch-error"' && [ $EL -le 5 ]; } && ok "timeout enforced" || no "timeout" "rc=$rcode ${EL}s $OUT"

# 7. missing vault -> loud failure, exit 1, mentions RESEARCH_VAULT_DIR
ERR=$(node "$F" "$BASE/article" 2>&1 >/dev/null); rcode=$?
{ [ $rcode -eq 1 ] && has "$ERR" 'RESEARCH_VAULT_DIR'; } && ok "missing vault fails loud" || no "vault missing" "rc=$rcode $ERR"

echo; echo "vault-fetch: $pass passed, $fail failed"; [ $fail -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/researcher-fetch.test.sh`
Expected: server starts, then FAIL — vault-fetch.js not found.

- [ ] **Step 3: Write the implementation**

Create `plugins/re-searcher/skills/re-searcher/vault-fetch.js`:

```js
#!/usr/bin/env node
'use strict';
// vault-fetch — raw fetch -> extraction -> confidence gate -> store.
// The vault's sources must be actually raw: this fetches real bytes (no AI
// extraction), converts with html-extract, and REFUSES to store garbage —
// low confidence exits 2 so the caller escalates to a browser or WebFetch
// (which is then stored labeled as an extraction, by the Stage 1 flow).
//
//   node vault-fetch.js <url> [--vault <dir>] [--timeout <ms>] [--max-bytes <n>]
//
// stdout: one JSON line {status, url, finalUrl, sourceId, sourcePath, rawPath,
//         title, textLength, score, signals, extractionHash}
// status: stored | duplicate | low-confidence | fetch-error
// exit:   0 stored/duplicate, 2 low-confidence, 1 fetch-error/usage
//
// Storage: sources/<hash8>--<host>--<slug>.md (+ raw at sources/raw/<hash8>.html)
// and an append to sources/fetch-log.jsonl (Stage 0 dedupe lookup).

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const zlib = require('zlib');
const { extract, assess } = require('./html-extract');

const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) re-searcher-vault-fetch/0.1';
const MAX_REDIRECTS = 5;

function arg(name, dflt) {
  const i = process.argv.indexOf(name);
  return i !== -1 ? process.argv[i + 1] : dflt;
}

function normalizeUrl(u) {
  try {
    const url = new URL(u);
    url.hash = '';
    url.hostname = url.hostname.toLowerCase();
    for (const k of Array.from(url.searchParams.keys())) if (/^utm_/i.test(k)) url.searchParams.delete(k);
    return url.toString();
  } catch (_e) { return u; }
}

function fetchRaw(u, timeoutMs, maxBytes, redirects, cb) {
  let mod;
  try { mod = new URL(u).protocol === 'http:' ? require('http') : require('https'); }
  catch (e) { return cb(new Error('bad url: ' + u)); }
  const req = mod.get(u, { headers: { 'user-agent': UA, 'accept': 'text/html,*/*', 'accept-encoding': 'gzip' } }, (res) => {
    const loc = res.headers.location;
    if (res.statusCode >= 300 && res.statusCode < 400 && loc) {
      res.resume();
      if (redirects >= MAX_REDIRECTS) return cb(new Error('too many redirects'));
      return fetchRaw(new URL(loc, u).toString(), timeoutMs, maxBytes, redirects + 1, cb);
    }
    if (res.statusCode !== 200) { res.resume(); return cb(new Error('http ' + res.statusCode)); }
    const gz = /gzip/.test(res.headers['content-encoding'] || '');
    const chunks = []; let size = 0; let done = false;
    res.on('data', (c) => {
      size += c.length;
      if (size > maxBytes && !done) { done = true; req.destroy(); return cb(new Error('response exceeds --max-bytes ' + maxBytes)); }
      chunks.push(c);
    });
    res.on('end', () => {
      if (done) return;
      let buf = Buffer.concat(chunks);
      if (gz) { try { buf = zlib.gunzipSync(buf); } catch (e) { return cb(new Error('gunzip failed: ' + e.message)); } }
      cb(null, { body: buf, finalUrl: u });
    });
    res.on('error', (e) => { if (!done) cb(e); });
  });
  req.setTimeout(timeoutMs, () => { req.destroy(new Error('timeout after ' + timeoutMs + 'ms')); });
  req.on('error', (e) => cb(e));
}

function slugify(s) {
  return String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'page';
}

function atomicWrite(file, data) {
  const tmp = file + '.tmp' + process.pid;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}

function emit(obj, code) { process.stdout.write(JSON.stringify(obj) + '\n'); process.exit(code); }

function main() {
  const url = process.argv[2];
  if (!url || url.startsWith('--')) { process.stderr.write('usage: vault-fetch.js <url> [--vault <dir>] [--timeout <ms>] [--max-bytes <n>]\n'); process.exit(1); }
  const vault = arg('--vault', process.env.RESEARCH_VAULT_DIR || null);
  if (!vault || !fs.existsSync(vault)) {
    process.stderr.write('vault missing at ' + (vault || '(unset)') + ' — pass --vault or set RESEARCH_VAULT_DIR (a missing vault must never look like an empty one)\n');
    process.exit(1);
  }
  const timeoutMs = Number(arg('--timeout', 10000));
  const maxBytes = Number(arg('--max-bytes', 5 * 1024 * 1024));
  const base = { status: null, url, finalUrl: null, sourceId: null, sourcePath: null, rawPath: null, title: null, textLength: null, score: null, signals: [], extractionHash: null };

  fetchRaw(url, timeoutMs, maxBytes, 0, (err, res) => {
    if (err) return emit(Object.assign(base, { status: 'fetch-error', signals: [String(err.message)] }), 1);
    const html = res.body.toString('utf8');
    const ext = extract(html);
    const conf = assess(html, ext);
    const rawSha = crypto.createHash('sha256').update(res.body).digest('hex');
    const extSha = crypto.createHash('sha256').update(ext.markdown, 'utf8').digest('hex');
    const filled = Object.assign(base, { finalUrl: res.finalUrl, title: ext.title, textLength: ext.textLength, score: conf.score, signals: conf.signals, extractionHash: extSha });
    if (!conf.usable) return emit(Object.assign(filled, { status: 'low-confidence' }), 2);

    const srcDir = path.join(vault, 'sources');
    const rawDir = path.join(srcDir, 'raw');
    fs.mkdirSync(rawDir, { recursive: true });
    const logFile = path.join(srcDir, 'fetch-log.jsonl');
    const normUrl = normalizeUrl(res.finalUrl);

    if (fs.existsSync(logFile)) {
      for (const line of fs.readFileSync(logFile, 'utf8').split('\n')) {
        if (!line.trim()) continue;
        let rec; try { rec = JSON.parse(line); } catch (_e) { continue; } // skip-don't-abort (spec)
        if (rec.norm_url === normUrl && rec.extraction_sha256 === extSha) {
          return emit(Object.assign(filled, { status: 'duplicate', sourceId: rec.source_id, sourcePath: rec.source_path }), 0);
        }
      }
    }

    const hash8 = rawSha.slice(0, 8);
    let host = 'unknown'; try { host = new URL(res.finalUrl).hostname.replace(/^www\./, ''); } catch (_e) {}
    const id = hash8 + '--' + slugify(host) + '--' + slugify(ext.title || url);
    const sourcePath = path.join(srcDir, id + '.md');
    const rawPath = path.join(rawDir, hash8 + '.html');
    const fetched = new Date().toISOString();
    const fm = ['---', 'v: 1', 'kind: web', 'url: ' + url, 'final_url: ' + res.finalUrl,
      'fetched: ' + fetched, 'title: ' + JSON.stringify(ext.title), 'raw_sha256: ' + rawSha,
      'extraction_sha256: ' + extSha, 'score: ' + conf.score,
      'signals: ' + JSON.stringify(conf.signals), 'auth_context: public', '---', ''].join('\n');
    atomicWrite(sourcePath, fm + ext.markdown + '\n');
    atomicWrite(rawPath, res.body);
    fs.appendFileSync(logFile, JSON.stringify({ v: 1, source_id: id, source_path: sourcePath, norm_url: normUrl, url, final_url: res.finalUrl, raw_sha256: rawSha, extraction_sha256: extSha, fetched, score: conf.score }) + '\n');
    emit(Object.assign(filled, { status: 'stored', sourceId: id, sourcePath, rawPath }), 0);
  });
}

main();
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/researcher-fetch.test.sh`
Expected: `vault-fetch: 10 passed, 0 failed`. Also re-run the other two suites to confirm nothing regressed: `bash tests/researcher-extract.test.sh && bash tests/researcher-quote.test.sh`.

- [ ] **Step 5: Commit**

```bash
git add plugins/re-searcher/skills/re-searcher/vault-fetch.js tests/researcher-fetch.test.sh
git commit -m "feat: re-searcher vault-fetch — raw fetch, confidence gate, dual-hash store"
```

---

### Task 5: benchmark harness + URL corpus

**Files:**
- Create: `plugins/re-searcher/bench/urls.txt`
- Create: `plugins/re-searcher/bench/run-bench.js`
- Create: `plugins/re-searcher/bench/results/.gitkeep`

**Interfaces:**
- Consumes: `vault-fetch.js` CLI (Task 4 statuses/exit codes, exactly as specified there).
- Produces: `node plugins/re-searcher/bench/run-bench.js --vault <dir>` → writes `bench/results/fetch-results.jsonl` (one line per URL: `{url, status, score, signals, textLength, sourcePath, ms}`) and prints a summary table + the headline `usable-rate` percentage. Exit 0 always (a benchmark that errors per-URL still reports).

- [ ] **Step 1: Create the URL corpus**

Create `plugins/re-searcher/bench/urls.txt` — 20 research-typical URLs, deliberately including 3 expected-hard cases (marked `#hard`) to test the gate's honesty, not to pad the score:

```
https://www.anthropic.com/engineering/multi-agent-research-system
https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/302
https://en.wikipedia.org/wiki/Model_Context_Protocol
https://github.com/anthropics/claude-cookbooks
https://raw.githubusercontent.com/anthropics/claude-cookbooks/main/README.md
https://arxiv.org/abs/2210.03629
https://nodejs.org/api/https.html
https://docs.python.org/3/library/json.html
https://react.dev/learn
https://doc.rust-lang.org/book/ch01-00-getting-started.html
https://stackoverflow.com/questions/643699/how-can-i-split-a-string-into-segments-of-n-characters
https://news.ycombinator.com/item?id=1
https://paulgraham.com/ds.html
https://overreacted.io/a-complete-guide-to-useeffect/
https://www.theverge.com/tech
https://simonwillison.net/2025/Jun/
https://modelcontextprotocol.io/introduction
https://x.com/AnthropicAI  #hard js-shell expected
https://www.youtube.com/watch?v=dQw4w9WgXcQ  #hard js-shell expected
https://medium.com/@anthropic  #hard paywall/challenge expected
```

- [ ] **Step 2: Write the harness**

Create `plugins/re-searcher/bench/run-bench.js`:

```js
#!/usr/bin/env node
'use strict';
// run-bench — Stage 0 fetch benchmark. LIVE NETWORK, on-demand only (never CI).
// Runs vault-fetch over bench/urls.txt, records per-URL outcomes, prints the
// headline number: usable-rate on non-#hard URLs (feasibility predicted 60-75%).
//
//   node run-bench.js --vault <dir>

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const HERE = __dirname;
const FETCH = path.join(HERE, '..', 'skills', 're-searcher', 'vault-fetch.js');

function arg(name, dflt) {
  const i = process.argv.indexOf(name);
  return i !== -1 ? process.argv[i + 1] : dflt;
}

const vault = arg('--vault', process.env.RESEARCH_VAULT_DIR || null);
if (!vault) { process.stderr.write('usage: run-bench.js --vault <dir>\n'); process.exit(1); }
fs.mkdirSync(vault, { recursive: true });
const resultsDir = path.join(HERE, 'results');
fs.mkdirSync(resultsDir, { recursive: true });
const outFile = path.join(resultsDir, 'fetch-results.jsonl');
fs.writeFileSync(outFile, '');

const lines = fs.readFileSync(path.join(HERE, 'urls.txt'), 'utf8').split('\n')
  .map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));

const rows = [];
for (const line of lines) {
  const hard = /#hard/.test(line);
  const url = line.split(/\s+/)[0];
  const t0 = Date.now();
  let rec;
  try {
    const out = execFileSync('node', [FETCH, url, '--vault', vault, '--timeout', '15000'], { encoding: 'utf8' });
    rec = JSON.parse(out.trim().split('\n').pop());
  } catch (err) {
    const out = (err.stdout || '').toString().trim();
    try { rec = JSON.parse(out.split('\n').pop()); }
    catch (_e) { rec = { url, status: 'fetch-error', signals: [String(err.message).slice(0, 120)], score: null, textLength: null, sourcePath: null }; }
  }
  const row = { url, hard, status: rec.status, score: rec.score, signals: rec.signals, textLength: rec.textLength, sourcePath: rec.sourcePath, ms: Date.now() - t0 };
  rows.push(row);
  fs.appendFileSync(outFile, JSON.stringify(row) + '\n');
  process.stdout.write(row.status.padEnd(15) + String(row.score).padEnd(7) + url + '\n');
}

const normal = rows.filter((r) => !r.hard);
const usable = normal.filter((r) => r.status === 'stored' || r.status === 'duplicate');
const hardCaught = rows.filter((r) => r.hard && r.status !== 'stored');
process.stdout.write('\n== summary ==\n');
process.stdout.write('usable-rate (non-hard): ' + usable.length + '/' + normal.length +
  ' = ' + Math.round((usable.length / normal.length) * 100) + '%  (feasibility prediction: 60-75%)\n');
process.stdout.write('hard URLs correctly gated: ' + hardCaught.length + '/' + rows.filter((r) => r.hard).length + '\n');
process.stdout.write('results: ' + outFile + '\n');
```

- [ ] **Step 3: Sanity-run the harness offline**

Run: `node plugins/re-searcher/bench/run-bench.js` (no `--vault`)
Expected: exits 1 with the usage line — proves arg handling without touching the network.

- [ ] **Step 4: Commit**

```bash
git add plugins/re-searcher/bench/urls.txt plugins/re-searcher/bench/run-bench.js plugins/re-searcher/bench/results/.gitkeep
git commit -m "feat: re-searcher stage-0 fetch benchmark harness + URL corpus"
```

---

### Task 6: run the live benchmark, record extraction results

**Files:**
- Create: `plugins/re-searcher/bench/results/fetch-results.jsonl` (generated)
- Create: `plugins/re-searcher/bench/results/STAGE0-REPORT.md` (started here, finished in Task 7)

This task uses the live network (on-demand tier of the test pyramid) — it is a measurement, not a CI test.

- [ ] **Step 1: Run the benchmark**

```bash
mkdir -p /tmp/re-searcher-bench-vault
node plugins/re-searcher/bench/run-bench.js --vault /tmp/re-searcher-bench-vault
```

Expected: 20 result lines + summary. Record the two numbers: usable-rate (non-hard) and hard-URLs-gated.

- [ ] **Step 2: Eyeball extraction quality (not just status)**

For 5 stored sources spanning different site types, open the extraction and judge: is the article text present, readable, and mostly free of chrome? Record a per-source `quality: good|degraded|garbage` judgment:

```bash
ls /tmp/re-searcher-bench-vault/sources/*.md
# read each with your editor / Read tool; judge content vs the live page
```

A `stored` status with garbage content is a **false pass of the confidence gate** — record it as such; that number matters as much as usable-rate.

- [ ] **Step 3: Start the report**

Create `plugins/re-searcher/bench/results/STAGE0-REPORT.md`:

```markdown
# Stage 0 benchmark report — Re:Searcher prototype slice

Date: <fill: run date>
Spec: docs/specs/2026-07-05-re-searcher-design.md (Roadmap item 0)

## Fetch/extraction benchmark (Task 6)

- usable-rate (17 non-hard URLs): <N>/17 = <P>%   (prediction: 60-75%)
- hard URLs correctly gated: <N>/3
- confidence-gate false passes (stored but garbage on inspection): <N>
- notes per problem URL: <bullet list>

## Claims study (Task 7)

<filled by Task 7>

## Go/No-Go

<filled by Task 7>
```

- [ ] **Step 4: Commit results**

```bash
git add plugins/re-searcher/bench/results/fetch-results.jsonl plugins/re-searcher/bench/results/STAGE0-REPORT.md
git commit -m "docs: stage-0 fetch benchmark results"
```

---

### Task 7: hand-driven claims study + go/no-go

**Files:**
- Create: `plugins/re-searcher/bench/results/claims-study.jsonl`
- Modify: `plugins/re-searcher/bench/results/STAGE0-REPORT.md` (fill Claims study + Go/No-Go)

This is the decisive measurement: can real research claims, written the way a research agent writes them, earn `verbatim-grounded` against these extractions via `quote-verify`? The operator here is Claude (acting as the research lead) + the user reviewing.

- [ ] **Step 1: Produce claims from the stored extractions**

Procedure (exact):
1. Pick 5 stored sources from the benchmark vault covering ≥4 different domains.
2. For each source, read ONLY the extraction markdown (`sources/*.md` body — never the live page; the extraction is what agents will see) and write 6 claims in the spec's claim shape: `statement` + `quote` (transcribed the way an LLM naturally transcribes — do not copy-paste; type the quote from reading, so realistic transcription noise like straightened quotes/collapsed whitespace occurs).
3. Save all 30 as `plugins/re-searcher/bench/results/claims-study.jsonl`, one JSON object per line: `{"source": "<sourcePath>", "statement": "...", "quote": "..."}`.

- [ ] **Step 2: Verify every claim mechanically**

Run each claim's quote through quote-verify against its source extraction:

```bash
cd plugins/re-searcher/bench/results
node -e '
const fs = require("fs"), path = require("path"), os = require("os");
const { execFileSync } = require("child_process");
const QV = path.resolve(__dirname, "../../skills/re-searcher/quote-verify.js");
const lines = fs.readFileSync("claims-study.jsonl", "utf8").split("\n").filter(Boolean);
const tally = { exact: 0, normalized: 0, fuzzy: 0, none: 0 };
const out = [];
for (const line of lines) {
  const c = JSON.parse(line);
  const qf = path.join(os.tmpdir(), "q.txt");
  // strip frontmatter so quotes are only sought in the body
  const src = fs.readFileSync(c.source, "utf8").replace(/^---[\s\S]*?---\n/, "");
  const sf = path.join(os.tmpdir(), "s.md");
  fs.writeFileSync(qf, c.quote); fs.writeFileSync(sf, src);
  let res;
  try { res = JSON.parse(execFileSync("node", [QV, "--quote-file", qf, "--source-file", sf], { encoding: "utf8" })); }
  catch (err) { res = JSON.parse((err.stdout || "{}").toString() || "{\"method\":\"none\",\"verified\":false}"); }
  tally[res.method] = (tally[res.method] || 0) + 1;
  out.push(Object.assign({}, c, { method: res.method, verified: res.verified }));
}
fs.writeFileSync("claims-study.jsonl", out.map((o) => JSON.stringify(o)).join("\n") + "\n");
const total = out.length, v = total - (tally.none || 0);
console.log(tally);
console.log("verbatim-grounded rate: " + v + "/" + total + " = " + Math.round((v / total) * 100) + "%");
'
```

Expected output: the tally by method + the headline `verbatim-grounded rate`.

- [ ] **Step 3: Inspect every `fuzzy` and `none` result**

For each `fuzzy`: confirm the returned `sourceQuote` genuinely supports the `statement` (a fuzzy match that changed meaning is a **false grounding** — count it against the rate, note it in the report). For each `none`: classify why — transcription too loose / quote from frontmatter or stripped chrome / extractor mangled that passage — each cause points at a different fix.

- [ ] **Step 4: Fill the report and apply the go/no-go rule**

Complete `STAGE0-REPORT.md`'s remaining sections:

```markdown
## Claims study (Task 7)

- claims: 30 across 5 sources / <N> domains
- exact: <N>  normalized: <N>  fuzzy: <N> (of which false groundings: <N>)  none: <N>
- verbatim-grounded rate (exact+normalized+honest fuzzy): <P>%
- failure causes for none/false-fuzzy: <bullets>

## Go/No-Go (per spec Roadmap item 0)

Rule agreed in the plan:
- >=60% verbatim-grounded AND usable-rate >=60% -> GO: build Stage 1 as designed.
- 40-59% verbatim-grounded -> GO WITH AMENDMENT: provenance model stands, but the spec's
  positioning softens ("most claims grounded" not "claims are grounded"); consider quote
  capture at research time (agent copies exact extraction spans) as a Stage 1 requirement.
- <40% verbatim-grounded OR usable-rate <50% -> NO-GO as designed: revisit Pillar 2/3
  (likely: agents must select quotes by copying from extraction text they actually read,
  and/or extraction needs a real parser dependency — a spec change either way).

Result: <GO | GO WITH AMENDMENT | NO-GO> — <one-paragraph justification>
```

- [ ] **Step 5: Commit and report back**

```bash
git add plugins/re-searcher/bench/results/claims-study.jsonl plugins/re-searcher/bench/results/STAGE0-REPORT.md
git commit -m "docs: stage-0 claims study + go/no-go verdict"
```

Then present the two headline numbers + verdict to the user. **The Stage 1 plan is written only after this verdict.**

---

## Self-Review (performed at write time)

1. **Spec coverage:** This plan implements exactly the spec's Roadmap item 0 (vault-fetch: curl + extractor + confidence gate; vault-save's quote verifier as its own module — Stage 1's `vault-save` will import `quote-verify.js`; ~20 real URLs; the % verbatim-grounded number). Deliberately out of scope, per staging: SKILL.md, vault-save/search/init/doctor, claims registry, git lifecycle, wayback, browser fallback, harvester. ✅
2. **Placeholder scan:** the `<fill>` markers exist only inside the two *measurement report templates*, where values are produced by executing Tasks 6–7 — they are the deliverable, not deferred work. No TBDs in any code step. ✅
3. **Type consistency:** `extract()` shape `{title, markdown, textLength, linkDensity}` is consumed identically in Tasks 2 and 4; `assess()` signals vocabulary matches Task 4's gate test (`challenge-page`); `verify()` result `{verified, method, sourceQuote}` matches Task 7's tally keys; vault-fetch statuses/exit codes match the bench harness's handling (stdout JSON parsed even on non-zero exit via `err.stdout`). ✅
```
