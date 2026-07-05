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
