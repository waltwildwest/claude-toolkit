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

# INDEX.md lists the topic
grep -q 'MCP Auth Landscape' "$V/INDEX.md" && grep -q 'topics/mcp-auth/topic.md' "$V/INDEX.md" \
  && ok "INDEX.md lists topic" || no "INDEX" "$(cat "$V/INDEX.md")"

echo; echo "vault-views: $pass passed, $fail failed"; [ $fail -eq 0 ]
