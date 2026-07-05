#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/inbox-note.js (Stop hook).
# Run: bash tests/researcher-inbox.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
N="$ROOT/plugins/re-searcher/skills/re-searcher/inbox-note.js"
I="$ROOT/plugins/re-searcher/skills/re-searcher/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-inbox tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1
HOOK='{"session_id":"sess-hook-0001","transcript_path":"/tmp/t/sess-hook-0001.jsonl","cwd":"/Users/w/proj/alpha-research"}'
echo "inbox-note tests"

# 1. appends a pointer; stdout stays EMPTY
OUT=$(printf '%s' "$HOOK" | RESEARCH_VAULT_DIR="$V" node "$N"); rcode=$?
{ [ $rcode -eq 0 ] && [ -z "$OUT" ]; } && ok "silent exit 0" || no "silent" "rc=$rcode out=$OUT"
node -e '
const fs = require("fs");
const lines = fs.readFileSync(process.argv[1] + "/inbox.jsonl", "utf8").split("\n").filter(Boolean);
if (lines.length !== 1) process.exit(1);
const p = JSON.parse(lines[0]);
if (p.kind !== "pointer" || p.session !== "sess-hook-0001") process.exit(2);
if (p.topicGuess !== "alpha-research") process.exit(3);
if (!p.subagents.endsWith("/sess-hook-0001/subagents")) process.exit(4);
if (!/^\d{4}-\d{2}-\d{2}$/.test(p.transcript_dies)) process.exit(5);
' "$V" && ok "pointer shape (session, topicGuess, subagents, dies)" || no "pointer" "rc=$? $(cat "$V/inbox.jsonl")"

# 2. same session twice -> still one pointer
printf '%s' "$HOOK" | RESEARCH_VAULT_DIR="$V" node "$N"
[ "$(grep -c . "$V/inbox.jsonl")" = "1" ] && ok "session deduped" || no "dedupe" "$(cat "$V/inbox.jsonl")"

# 3. RESEARCH_INBOX=off -> no-op
printf '%s' "${HOOK/sess-hook-0001/sess-hook-0002}" | RESEARCH_INBOX=off RESEARCH_VAULT_DIR="$V" node "$N"
[ "$(grep -c . "$V/inbox.jsonl")" = "1" ] && ok "RESEARCH_INBOX=off disables" || no "off" ""

# 4. missing vault -> silent no-op, nothing created
OUT=$(printf '%s' "$HOOK" | RESEARCH_VAULT_DIR="$W/novault" node "$N" 2>&1); rcode=$?
{ [ $rcode -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$W/novault" ]; } && ok "missing vault: silent, never created" || no "novault" "rc=$rcode $OUT"

# 5. garbage / empty stdin -> silent exit 0
printf 'not json' | RESEARCH_VAULT_DIR="$V" node "$N" 2>/dev/null; [ $? -eq 0 ] && ok "garbage stdin tolerated" || no "garbage" "$?"
printf '{"cwd":"/x"}' | RESEARCH_VAULT_DIR="$V" node "$N"; [ "$(grep -c . "$V/inbox.jsonl")" = "1" ] && ok "missing session/transcript -> no-op" || no "partial stdin" ""

# 6. garbage TTL env var degrades to the default instead of dropping the pointer
printf '%s' "${HOOK/sess-hook-0001/sess-hook-0003}" | RESEARCH_TRANSCRIPT_TTL_DAYS=banana RESEARCH_VAULT_DIR="$V" node "$N"
grep -q 'sess-hook-0003' "$V/inbox.jsonl" && ok "NaN TTL clamps to default" || no "ttl clamp" "$(cat "$V/inbox.jsonl")"

echo; echo "inbox-note: $pass passed, $fail failed"; [ $fail -eq 0 ]
