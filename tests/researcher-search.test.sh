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

# 8. add-alias with unknown slug fails loud and must NOT leak the lock
node "$SR" --add-alias no-such-topic "x" --vault "$V" >/dev/null 2>&1; rcode=$?
{ [ $rcode -eq 1 ] && [ ! -d "$V/.lock" ]; } && ok "unknown slug: exit 1, no lock leak" || no "lock leak" "rc=$rcode lock=$([ -d "$V/.lock" ] && echo held || echo free)"

# 9. missing vault fails loud (never 0 hits)
ERR=$(RESEARCH_VAULT_DIR= node "$SR" anything --vault "$W/novault" 2>&1 >/dev/null); rcode=$?
{ [ $rcode -eq 1 ] && has "$ERR" 'vault-init'; } && ok "missing vault fails loud" || no "missing vault" "rc=$rcode $ERR"

# 10. --json emits parseable structure
OUT=$(node "$SR" mcp --vault "$V" --json)
node -e 'const r=JSON.parse(process.argv[1]); process.exit(Array.isArray(r.hits) && r.hits[0].provenanceLine ? 0 : 1)' "$OUT" \
  && ok "--json output" || no "json" "$OUT"

# --- Stage 2: lazy-harvest breadcrumbs on miss ---
printf '{"v":1,"kind":"pointer","session":"sessk8s001x","transcript":"/tmp/none.jsonl","cwd":"/Users/w/proj/kubernetes-ingress-study","topicGuess":"kubernetes-ingress-study","ts":"2026-07-05T09:00:00Z","transcript_dies":"2026-08-04"}\n' >> "$V/inbox.jsonl"
OUT=$(node "$SR" kubernetes ingress --vault "$V"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" 'unharvested session sessk8s0' && has "$OUT" 'vault-harvest.js sessk8s001x'; } \
  && ok "miss announces relevant unharvested session" || no "breadcrumb" "rc=$rcode $OUT"
OUT=$(node "$SR" quantum entanglement --vault "$V"); rcode=$?
{ [ $rcode -eq 2 ] && ! has "$OUT" 'unharvested'; } && ok "irrelevant pointers stay silent" || no "silent" "$OUT"
grep -q '"inbox":\["sessk8s001x"\]' "$V/metrics.jsonl" && ok "breadcrumb logged to metrics" || no "metrics inbox" ""

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

# --as-of excludes records with no/empty date (can't be placed in time)
printf '{"v":1,"slug":"dateless-topic","title":"Dateless","aliases":["nodate probe"],"questions":[],"scope":"general","run":"rz"}\n' >> "$V/index.jsonl"
OUT=$(node "$SR" nodate probe --as-of 2020-01-01 --vault "$V"); rc=$?
[ $rc -eq 2 ] && ok "--as-of excludes dateless index records" || no "as-of dateless" "rc=$rc $OUT"
OUT=$(node "$SR" nodate probe --vault "$V"); rc=$?
[ $rc -eq 0 ] && ok "dateless record still visible without --as-of" || no "dateless plain" "rc=$rc"

echo; echo "vault-search: $pass passed, $fail failed"; [ $fail -eq 0 ]
