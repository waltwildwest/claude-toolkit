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

# 4. path traversal in slug is refused
node "$E" "../../etc" --vault "$V" >/dev/null 2>&1; [ $? -eq 1 ] && ok "export refuses ../ traversal" || no "traversal" ""

echo; echo "vault-export: $pass passed, $fail failed"; [ $fail -eq 0 ]
