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

# 8. missing vault fails loud (never 0 hits)
ERR=$(RESEARCH_VAULT_DIR= node "$SR" anything --vault "$W/novault" 2>&1 >/dev/null); rcode=$?
{ [ $rcode -eq 1 ] && has "$ERR" 'vault-init'; } && ok "missing vault fails loud" || no "missing vault" "rc=$rcode $ERR"

# 9. --json emits parseable structure
OUT=$(node "$SR" mcp --vault "$V" --json)
node -e 'const r=JSON.parse(process.argv[1]); process.exit(Array.isArray(r.hits) && r.hits[0].provenanceLine ? 0 : 1)' "$OUT" \
  && ok "--json output" || no "json" "$OUT"

echo; echo "vault-search: $pass passed, $fail failed"; [ $fail -eq 0 ]
