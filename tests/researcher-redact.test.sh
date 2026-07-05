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
REDACT_OUT="$OUT"
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"redacted"' && has "$OUT" '"downgraded":["clm_dep"]' && has "$OUT" 'filter-repo'; } \
  && ok "source redacted with downgrade list" || no "redact" "rc=$rcode $OUT"
[ ! -f "$V/sources/$SID.md" ] && [ ! -f "$V/sources/raw/aaaa1111.html" ] && ok "source files deleted" || no "files" ""
node -e '
const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.exit(t.v === 1 && t.reason === "leaked credential" && t.removed.length === 2 ? 0 : 1);
' "$V/sources/$SID.tombstone.json" && ok "tombstone written" || no "tombstone" "$(cat "$V/sources/$SID.tombstone.json" 2>/dev/null)"
# fetch-log is left append-only (no destructive rewrite that would race a concurrent fetch);
# the tombstone is what makes a refetch skip the dedupe (asserted in the fetch suite)
[ "$(grep -c . "$V/sources/fetch-log.jsonl")" = "1" ] && ok "fetch-log left append-only (tombstone gates refetch)" || no "fetch-log" "$(cat "$V/sources/fetch-log.jsonl")"
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

# 5. path traversal in source id is refused before any fs op
CANARY="$W/canary-outside.md"; echo secret > "$CANARY"
node "$R" "../../canary-outside" --vault "$V" >/dev/null 2>&1; rc=$?
{ [ $rc -eq 1 ] && [ -f "$CANARY" ]; } && ok "redact refuses ../ traversal, canary intact" || no "traversal" "rc=$rc exists=$([ -f "$CANARY" ] && echo y || echo n)"

# residual reporting: redact is honest that quote text survives in the append-only claim
node -e '
const o = JSON.parse(process.argv[1]);
if (!o.residual || !Array.isArray(o.residual.quotedInClaims) || !o.residual.quotedInClaims.includes("clm_dep")) process.exit(1);
if (!/claim quotes/.test(o.note)) process.exit(2);
' "$REDACT_OUT" && ok "redact reports residual quote copies" || no "residual" "rc=$? $REDACT_OUT"

echo; echo "vault-redact: $pass passed, $fail failed"; [ $fail -eq 0 ]
