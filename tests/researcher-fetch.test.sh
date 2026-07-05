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
export WAYBACK=off   # pre-existing tests must never hit live archive.org; wayback tests re-enable per-call

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
  if (req.url.split('?')[0] === '/article') {
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
    if (req.url.includes('wb=save') || req.url.includes('wb%3Dsave')) { res.writeHead(200); return res.end('saved'); }
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

echo; echo "vault-fetch: $pass passed, $fail failed"; [ $fail -eq 0 ]
