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

echo; echo "extract: $pass passed, $fail failed"; [ $fail -eq 0 ]
