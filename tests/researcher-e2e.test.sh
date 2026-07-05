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
