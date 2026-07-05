#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-harvest.js
# CI-safe: transcripts live in a fake CLAUDE_PROJECTS_DIR. Run: bash tests/researcher-harvest.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/plugins/re-searcher/skills/re-searcher/vault-harvest.js"
I="$ROOT/plugins/re-searcher/skills/re-searcher/vault-init.js"
SR="$ROOT/plugins/re-searcher/skills/re-searcher/vault-search.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-harvest tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"; P="$W/projects"
export CLAUDE_PROJECTS_DIR="$P"
node "$I" --vault "$V" >/dev/null 2>&1
PDIR="$P/-Users-w-proj-mcp-auth-research"
mkdir -p "$PDIR"
T="$PDIR/sessharv0001.jsonl"
cat > "$T" <<'EOF'
{"type":"queue-operation","operation":"enqueue","sessionId":"sessharv0001"}
{"type":"assistant","sessionId":"sessharv0001","cwd":"/Users/w/proj/mcp-auth-research","version":"2.1.197","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/tmp/x/findings/landscape.md","content":"# Findings — landscape\n\nOAuth 2.1 required for remote MCP servers per the June spec revision. Enough real sentences here to make the harvested digest carry substance past the staging floor without padding."}}]}}
{"type":"assistant","sessionId":"sessharv0001","version":"2.1.197","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"WebSearch","input":{"query":"mcp oauth requirements"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"FINAL: remote MCP servers need OAuth 2.1 with PKCE; local stdio servers may keep bearer tokens. Harvested-summary sentence for the synthesis file."}]}}
EOF
echo "vault-harvest tests"

# 1. harvest by explicit path
OUT=$(node "$H" "$T" --vault "$V"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"harvested"'; } && ok "harvest by path" || no "path" "rc=$rcode $OUT"
node -e '
const r = JSON.parse(process.argv[1]);
process.exit(r.session === "sessharv0001" && r.topic === "mcp-auth-research" && r.writes === 1 && r.sources === 1 && /light run/.test(r.provenanceLine) ? 0 : 1);
' "$OUT" && ok "harvest JSON (session, topic guess, counts, light provenance)" || no "json" "$OUT"
RUN=$(ls -d "$V/topics/mcp-auth-research/runs/"*/ | head -1)
grep -q 'OAuth 2.1 required' "$RUN/findings/harvest.md" && grep -q 'transcript:2' "$RUN/findings/harvest.md" \
  && ok "digest embeds .md payload with line pointer" || no "digest" "$(head -30 "$RUN/findings/harvest.md")"
grep -q 'WebSearch — mcp oauth requirements' "$RUN/findings/harvest.md" && ok "digest lists source events" || no "sources" ""
grep -q 'FINAL: remote MCP servers need OAuth 2.1' "$RUN/synthesis.md" && ok "synthesis = harvested summary" || no "synthesis" ""
grep -q '"session": "sessharv0001"' "$RUN/lineage.json" && ok "lineage carries session" || no "lineage" "$(cat "$RUN/lineage.json")"
[ -f "$RUN"/transcripts/sessharv0001.jsonl.gz ] && ok "transcript gzipped into run" || no "gz" "$(ls "$RUN")"
git -C "$V" log --oneline | grep -q 'persist run' && ok "vault auto-commit" || no "git" ""

# 2. idempotent: second harvest of the same session -> already-harvested, no new run
N1=$(ls -d "$V/topics/mcp-auth-research/runs/"*/ | wc -l | tr -d ' ')
OUT=$(node "$H" "$T" --vault "$V"); rcode=$?
N2=$(ls -d "$V/topics/mcp-auth-research/runs/"*/ | wc -l | tr -d ' ')
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"already-harvested"' && [ "$N1" = "$N2" ]; } \
  && ok "idempotent re-harvest" || no "idempotent" "rc=$rcode $N1->$N2 $OUT"

# 3. recall finds the harvested topic
OUT=$(node "$SR" mcp oauth --vault "$V"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" 'mcp-auth-research'; } && ok "harvested run is recallable" || no "recall" "rc=$rcode $OUT"

# 4. resolve by session id (fresh vault)
V2="$W/vault2"; node "$I" --vault "$V2" >/dev/null 2>&1
OUT=$(node "$H" sessharv0001 --vault "$V2" --topic override-topic); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"topic":"override-topic"'; } && ok "session-id lookup + --topic override" || no "session id" "rc=$rcode $OUT"

# 5. --latest picks the newest transcript for the cwd
T2="$PDIR/sessharv0002.jsonl"
sed 's/sessharv0001/sessharv0002/g' "$T" > "$T2"
touch -t 203001011200 "$T2"   # far future mtime -> newest
V3="$W/vault3"; node "$I" --vault "$V3" >/dev/null 2>&1
OUT=$(node "$H" --latest --cwd "/Users/w/proj/mcp-auth-research" --vault "$V3"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"session":"sessharv0002"'; } && ok "--latest resolves newest" || no "latest" "rc=$rcode $OUT"

# 6. --from-inbox removes the session's pointer
V4="$W/vault4"; node "$I" --vault "$V4" >/dev/null 2>&1
printf '{"v":1,"kind":"pointer","session":"sessharv0001","transcript":"%s","cwd":"/Users/w/proj/mcp-auth-research","topicGuess":"mcp-auth-research","ts":"2026-07-05T10:00:00Z","transcript_dies":"2026-08-04"}\n' "$T" >> "$V4/inbox.jsonl"
node "$H" "$T" --vault "$V4" --from-inbox >/dev/null 2>&1
[ "$(grep -c 'sessharv0001' "$V4/inbox.jsonl")" = "0" ] && ok "--from-inbox removes pointer" || no "from-inbox" "$(cat "$V4/inbox.jsonl")"

# 7. --inbox bulk drain: one live pointer, one dead-transcript pointer
V5="$W/vault5"; node "$I" --vault "$V5" >/dev/null 2>&1
printf '{"v":1,"kind":"pointer","session":"sessharv0002","transcript":"%s","cwd":"/Users/w/proj/mcp-auth-research","topicGuess":"mcp-auth-research","ts":"2026-07-05T10:00:00Z","transcript_dies":"2026-08-04"}\n' "$T2" >> "$V5/inbox.jsonl"
printf '{"v":1,"kind":"pointer","session":"sessdead0001","transcript":"%s/gone.jsonl","cwd":"/x","topicGuess":"gone","ts":"2026-07-05T10:00:00Z","transcript_dies":"2026-08-04"}\n' "$W" >> "$V5/inbox.jsonl"
OUT=$(node "$H" --inbox --vault "$V5"); rcode=$?
node -e '
const r = JSON.parse(process.argv[1]);
process.exit(r.drained === 2 && r.harvested === 1 && r.missing === 1 ? 0 : 1);
' "$OUT" && [ $rcode -eq 0 ] && ok "bulk drain tallies" || no "bulk" "rc=$rcode $OUT"
[ "$(grep -c 'pointer' "$V5/inbox.jsonl")" = "0" ] && ok "drained pointers removed" || no "drain removal" "$(cat "$V5/inbox.jsonl")"
git -C "$V5" log --oneline -1 | grep -q 'drain inbox' && ok "drain auto-commit" || no "drain git" "$(git -C "$V5" log --oneline -1)"

# 8. hard failures are loud
node "$H" /nope/missing.jsonl --vault "$V" >/dev/null 2>&1; [ $? -eq 1 ] && ok "unresolvable transcript fails loud" || no "loud" "$?"
RESEARCH_VAULT_DIR= node "$H" "$T" >/dev/null 2>&1
[ $? -eq 1 ] && ok "missing vault fails loud" || no "vault loud" "$?"

# 9. persist failure surfaces the orphaned staged run instead of hiding it
V6="$W/vault6"; node "$I" --vault "$V6" >/dev/null 2>&1
mkdir -p "$V6/topics/mcp-auth-research/topic.md"
OUT=$(node "$H" "$T" --vault "$V6" 2>/dev/null); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" '"status":"error"' && has "$OUT" 'orphanedRun'; } \
  && ok "persist failure surfaces orphaned run" || no "orphan" "rc=$rcode $OUT"

# 10. --latest slugs non-alphanumeric cwd chars the way Claude Code does
PD2="$P/-Users-w-my-proj-name"
mkdir -p "$PD2"
sed 's/sessharv0001/sessuscre001/g' "$T" > "$PD2/sessuscre001.jsonl"
V7="$W/vault7"; node "$I" --vault "$V7" >/dev/null 2>&1
OUT=$(node "$H" --latest --cwd "/Users/w/my_proj name" --vault "$V7" --topic slug-smoke); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"session":"sessuscre001"'; } && ok "--latest slugs non-alnum cwd chars" || no "cwd slug" "rc=$rcode $OUT"

echo; echo "vault-harvest: $pass passed, $fail failed"; [ $fail -eq 0 ]
