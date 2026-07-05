#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/transcript-mine.js
# Golden fixtures: current 2.1.x shape, legacy 2.0.x envelope, v99 major
# canary, unknown-block canary, torn lines. Run: bash tests/researcher-mine.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/plugins/re-searcher/skills/re-searcher/transcript-mine.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-mine tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"
echo "transcript-mine tests"

# --- golden fixture 1: current (2.1.x) shape with envelope noise ---
cat > "$W/v2.jsonl" <<'EOF'
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-07-05T10:00:00Z","sessionId":"sess-v2-0001"}
{"parentUuid":null,"isSidechain":false,"type":"assistant","sessionId":"sess-v2-0001","cwd":"/Users/w/proj/mcp-auth-research","version":"2.1.197","gitBranch":"main","message":{"role":"assistant","content":[{"type":"text","text":"Short."}]}}
{"type":"assistant","sessionId":"sess-v2-0001","version":"2.1.197","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/tmp/run/findings/landscape.md","content":"# Findings — landscape\n\nOAuth 2.1 required for remote MCP servers per the June spec revision. Additional detail sentences give the digest something real to carry forward."}}]}}
{"type":"assistant","version":"2.1.197","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"WebSearch","input":{"query":"mcp oauth 2.1 requirements"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"mcp__exa__search","input":{"url":"https://spec.example/auth"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"HUGE-RESULT-BLOB-MUST-BE-DROPPED"}]}}
this line is torn and not json at all
{"type":"attachment","content":{"blob":"noise"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"image_ref","source":"x"},{"type":"text","text":"FINAL: The MCP auth landscape requires OAuth 2.1 with PKCE for remote servers; bearer tokens stay acceptable for local stdio servers. That is the session summary."}]}}
EOF
OUT=$(node "$M" "$W/v2.jsonl" 2>"$W/v2.err"); rcode=$?
[ $rcode -eq 0 ] && ok "v2 fixture parses" || no "v2 rc" "rc=$rcode"
node -e '
const r = JSON.parse(process.argv[1]);
if (r.version !== "2.1.197") process.exit(1);
if (r.sessionId !== "sess-v2-0001") process.exit(2);
if (r.cwd !== "/Users/w/proj/mcp-auth-research") process.exit(3);
if (r.writes.length !== 1 || !r.writes[0].file.endsWith("landscape.md")) process.exit(4);
if (!r.writes[0].content.includes("OAuth 2.1 required")) process.exit(5);
if (r.writes[0].line !== 3) process.exit(6);
if (r.sources.length !== 2) process.exit(7);
if (r.sources[0].tool !== "WebSearch" || r.sources[0].detail !== "mcp oauth 2.1 requirements") process.exit(8);
if (r.sources[1].tool !== "mcp__exa__search" || r.sources[1].detail !== "https://spec.example/auth") process.exit(9);
if (!r.summary || !r.summary.startsWith("FINAL:")) process.exit(10);
if (r.skippedLines < 1) process.exit(11);
if (r.unknownBlocks < 1) process.exit(12);
if (r.versionWarning !== null) process.exit(13);
' "$OUT" && ok "v2 extraction complete + pointers" || no "v2 extraction" "rc=$? $OUT"
has "$OUT" 'MUST-BE-DROPPED' && no "tool_result dropped" "leaked" || ok "tool_result dropped"

# --- golden fixture 2: legacy (2.0.x) envelope, same Messages shape ---
cat > "$W/legacy.jsonl" <<'EOF'
{"uuid":"u1","type":"assistant","sessionId":"sess-old-0001","version":"2.0.14","message":{"role":"assistant","content":[{"type":"tool_use","id":"a1","name":"Write","input":{"file_path":"/tmp/r/findings/notes.md","content":"# Notes\n\nLegacy-envelope transcripts must mine identically because we key on the message shape only, never the envelope fields around it."}}]}}
{"uuid":"u2","type":"assistant","sessionId":"sess-old-0001","version":"2.0.14","message":{"role":"assistant","content":[{"type":"text","text":"FINAL legacy: the answer survived an older envelope layout without any parser changes, proving the keying rule."}]}}
EOF
OUT=$(node "$M" "$W/legacy.jsonl" 2>/dev/null); rcode=$?
node -e '
const r = JSON.parse(process.argv[1]);
process.exit(r.writes.length === 1 && r.summary && r.summary.startsWith("FINAL legacy") && r.version === "2.0.14" && r.versionWarning === null ? 0 : 1);
' "$OUT" && [ $rcode -eq 0 ] && ok "legacy envelope mines identically" || no "legacy" "rc=$rcode $OUT"

# --- v99 major canary: loud warning, still parses ---
sed 's/2\.1\.197/99.1.0/g' "$W/v2.jsonl" > "$W/v99.jsonl"
OUT=$(node "$M" "$W/v99.jsonl" 2>"$W/v99.err"); rcode=$?
{ [ $rcode -eq 0 ] && grep -q 'unknown transcript major' "$W/v99.err"; } && ok "v99: loud warning, no abort" || no "v99" "rc=$rcode $(cat "$W/v99.err")"
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.versionWarning && r.writes.length===1 ? 0 : 1)' "$OUT" \
  && ok "v99 still extracts" || no "v99 extract" "$OUT"

# --- pure envelope noise: no Messages records -> loud exit 1 ---
printf '{"type":"queue-operation"}\n{"type":"mode","mode":"x"}\n' > "$W/noise.jsonl"
ERR=$(node "$M" "$W/noise.jsonl" 2>&1 >/dev/null); rcode=$?
{ [ $rcode -eq 1 ] && has "$ERR" 'no Messages-shaped records'; } && ok "envelope-only file fails loud" || no "noise" "rc=$rcode $ERR"

# --- missing file / usage ---
node "$M" "$W/nope.jsonl" >/dev/null 2>&1; [ $? -eq 1 ] && ok "missing file fails loud" || no "missing" "$?"
node "$M" >/dev/null 2>&1; [ $? -eq 1 ] && ok "usage fails loud" || no "usage" "$?"

echo; echo "transcript-mine: $pass passed, $fail failed"; [ $fail -eq 0 ]
