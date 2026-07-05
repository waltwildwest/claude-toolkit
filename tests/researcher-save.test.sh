#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-save.js
# Run: bash tests/researcher-save.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/plugins/re-searcher/skills/re-searcher/vault-save.js"
I="$ROOT/plugins/re-searcher/skills/re-searcher/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-save tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1
echo "vault-save tests"

# --- --new-run ---

# 1. allocates a run folder with findings/ and a date+letter+session id
OUT=$(node "$S" --new-run --topic "MCP Auth Landscape" --session 9f3c2ab1 --vault "$V"); rcode=$?
RUN1=$(node -e 'console.log(JSON.parse(process.argv[1]).runDir)' "$OUT")
{ [ $rcode -eq 0 ] && [ -d "$RUN1/findings" ]; } && ok "new-run allocates" || no "new-run" "rc=$rcode $OUT"
case "$RUN1" in "$V/topics/mcp-auth-landscape/runs/"*a-9f3c) ok "run id shape date+letter+sess4" ;; *) no "run id shape" "$RUN1" ;; esac

# 2. same-day second run gets the next letter
OUT=$(node "$S" --new-run --topic "MCP Auth Landscape" --session 9f3c2ab1 --vault "$V")
RUN2=$(node -e 'console.log(JSON.parse(process.argv[1]).runDir)' "$OUT")
case "$RUN2" in *b-9f3c) ok "collision -> next letter" ;; *) no "letter bump" "$RUN2" ;; esac

# 3. missing --topic fails loud
node "$S" --new-run --vault "$V" >/dev/null 2>&1; [ $? -eq 1 ] && ok "new-run without topic fails" || no "topic required" "$?"

# --- --check-staging ---

# 4. no plan.md -> exit 1 loud
mkdir -p "$W/norun"
ERR=$(node "$S" --check-staging "$W/norun" 2>&1 >/dev/null); rcode=$?
{ [ $rcode -eq 1 ] && has "$ERR" "plan.md"; } && ok "no plan.md fails loud" || no "no plan" "rc=$rcode $ERR"

# 5. manifest vs files: missing, stub, bad header, then complete
cat > "$RUN1/plan.md" <<'EOF'
---
topic: mcp-auth-landscape
title: MCP Auth Landscape
aliases: ["mcp oauth", "model context protocol auth"]
questions: ["does mcp require oauth 2.1?"]
scope: general
session: 9f3c2ab1
---

# Plan

## Question
What is the MCP auth landscape?

```manifest
[{"role": "spec-reader", "file": "findings/spec-reader.md"},
 {"role": "ecosystem", "file": "findings/ecosystem.md"}]
```
EOF
OUT=$(node "$S" --check-staging "$RUN1"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" '"ok":false' && has "$OUT" 'spec-reader.md' && has "$OUT" 'ecosystem.md'; } \
  && ok "missing findings detected" || no "missing" "rc=$rcode $OUT"

cat > "$RUN1/findings/spec-reader.md" <<EOF
---
role: spec-reader
run: $(basename "$RUN1")
task: read the auth spec
date: 2026-07-05
---

# Findings — spec-reader

## Summary
$(printf 'The spec requires OAuth 2.1 with PKCE for remote servers. %.0s' 1 2 3 4 5 6 7 8 9 10)

## Details
$(printf 'Detail sentence about token endpoints and dynamic client registration. %.0s' 1 2 3 4 5 6 7 8)

## Sources
- src_test — the spec page
EOF
printf -- '---\nrole: ecosystem\n---\ntoo small' > "$RUN1/findings/ecosystem.md"
OUT=$(node "$S" --check-staging "$RUN1"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" 'stubs' && has "$OUT" 'ecosystem.md'; } && ok "stub finding detected" || no "stub" "rc=$rcode $OUT"

node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[1], "no frontmatter here\n" + "Filler sentence for size requirements in the staging check. ".repeat(12));
' "$RUN1/findings/ecosystem.md"
OUT=$(node "$S" --check-staging "$RUN1"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" 'badHeader' && has "$OUT" 'ecosystem.md'; } && ok "bad header detected" || no "bad header" "rc=$rcode $OUT"

cat > "$RUN1/findings/ecosystem.md" <<EOF
---
role: ecosystem
run: $(basename "$RUN1")
task: survey server implementations
date: 2026-07-05
---

# Findings — ecosystem

## Summary
$(printf 'Most public MCP servers ship bearer-token auth and defer OAuth to gateways. %.0s' 1 2 3 4 5 6 7 8)

## Details
$(printf 'Detail sentence about gateway adapters and session tokens in the wild. %.0s' 1 2 3 4 5 6 7 8)
EOF
OUT=$(node "$S" --check-staging "$RUN1"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"ok":true' && has "$OUT" '"agents":2'; } && ok "complete staging passes" || no "complete" "rc=$rcode $OUT"

echo; echo "vault-save: $pass passed, $fail failed"; [ $fail -eq 0 ]
