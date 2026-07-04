#!/usr/bin/env bash
# Tests for skills/route/route-report.js. Run: bash tests/route.test.sh
# Fully isolated: temp HOME, crafted transcripts, no side effects.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$ROOT/skills/route/route-report.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }

# usage: run <flags...>  ; transcript JSONL comes on stdin, lands in one project file
run(){
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.claude/projects/proj-alpha"
  cat > "$home/.claude/projects/proj-alpha/s1.jsonl"
  HOME="$home" node "$REPORT" "$@" 2>&1
  local rc=$?
  rm -rf "$home"
  return $rc
}

# JSONL line helper: entry <model> <msgid> <in> <out> <read> <w5> <w1h> [ts]
entry(){
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"cache_creation":{"ephemeral_5m_input_tokens":%s,"ephemeral_1h_input_tokens":%s}}}}\n' \
    "${8:-2026-07-01T00:00:00Z}" "$2" "$1" "$3" "$4" "$5" "$(( $6 + $7 ))" "$6" "$7"
}

echo "route-report tests"

# 1. single-model cost math: haiku 1M in + 1M out = $1 + $5 = $6.00
OUT=$( entry claude-haiku-4-5 m1 1000000 1000000 0 0 0 | run --json )
has "$OUT" '"actualUSD": 6,' && ok "haiku cost math (1M in + 1M out = \$6)" || no "haiku cost math" "$OUT"

# 2. dedupe: same message.id streamed twice counts once
OUT=$( { entry claude-haiku-4-5 mA 500000 0 0 0 0; entry claude-haiku-4-5 mA 1000000 0 0 0 0; } | run --json )
has "$OUT" '"actualUSD": 1,' && ok "dedupe by message.id (last wins)" || no "dedupe" "$OUT"

# 3. cache read priced at 0.1x input: opus 4.8, 1M cache read = 1M * $5 * 0.1 = $0.50
OUT=$( entry claude-opus-4-8 m1 0 0 1000000 0 0 | run --json )
has "$OUT" '"actualUSD": 0.5,' && ok "cache read at 0.1x (\$0.50)" || no "cache read" "$OUT"

# 4. cache writes: 1M 5m-write on opus = 1.25*$5 = $6.25 ; 1M 1h-write = 2*$5 = $10
OUT=$( entry claude-opus-4-8 m1 0 0 0 1000000 1000000 | run --json )
has "$OUT" '"actualUSD": 16.25' && ok "cache write multipliers (1.25x + 2x)" || no "cache writes" "$OUT"

# 5. naive baseline: haiku 1M in ($1 actual) vs opus-in-data baseline no-cache
#    haiku 1M in + opus 1M cache-read: actual = $1 + $0.50 = $1.50
#    naive (all opus, no cache) = 2M in * $5 = $10 ; savings = 85%
OUT=$( { entry claude-haiku-4-5 m1 1000000 0 0 0 0; entry claude-opus-4-8 m2 0 0 1000000 0 0; } | run --json )
{ has "$OUT" '"naiveNoCache": 10,' && has "$OUT" '"vsNaive": 85'; } && ok "naive baseline + savings pct" || no "naive baseline" "$OUT"

# 6. routing-alone baseline: same tokens on top model WITH cache
#    = 1M in * $5 + 1M read * $0.50 = $5.50 ; actual $1.50 -> 72.73%
OUT=$( { entry claude-haiku-4-5 m1 1000000 0 0 0 0; entry claude-opus-4-8 m2 0 0 1000000 0 0; } | run --json )
{ has "$OUT" '"topModelWithCache": 5.5,' && has "$OUT" '"routingAlone": 72.73'; } && ok "routing-alone baseline" || no "routing-alone" "$OUT"

# 7. --days filters old entries
OUT=$( { entry claude-haiku-4-5 m1 1000000 0 0 0 0 2020-01-01T00:00:00Z; entry claude-haiku-4-5 m2 1000000 0 0 0 0 2999-01-01T00:00:00Z; } | run --days 30 --json )
has "$OUT" '"actualUSD": 1,' && ok "--days filters old entries" || no "--days filter" "$OUT"

# 8. --project filters by path substring
OUT=$( entry claude-haiku-4-5 m1 1000000 0 0 0 0 | run --project proj-alpha --json )
has "$OUT" '"actualUSD": 1,' && ok "--project match includes" || no "--project include" "$OUT"
OUT=$( entry claude-haiku-4-5 m1 1000000 0 0 0 0 | run --project no-such-proj )
has "$OUT" "no transcript usage" && ok "--project mismatch is graceful" || no "--project exclude" "$OUT"

# 9. synthetic/unknown handling: <synthetic> skipped; unknown model priced at baseline
OUT=$( { entry '<synthetic>' m1 9000000 0 0 0 0; entry claude-haiku-4-5 m2 1000000 0 0 0 0; } | run --json )
has "$OUT" '"actualUSD": 1,' && ok "<synthetic> model skipped" || no "synthetic skip" "$OUT"
OUT=$( { entry weird-model-x m1 1000000 0 0 0 0; entry claude-opus-4-8 m2 1000000 0 0 0 0; } | run --json )
has "$OUT" 'unknown, priced as baseline' && ok "unknown model flagged" || no "unknown model" "$OUT"

# 10. empty scope exits 0 with message
OUT=$( printf '' | run )
{ [ $? -eq 0 ] && has "$OUT" "no transcript usage"; } && ok "empty scope graceful" || no "empty scope" "$OUT"

# 11. human output shows all three baselines
OUT=$( { entry claude-haiku-4-5 m1 1000000 0 0 0 0; entry claude-opus-4-8 m2 1000000 0 0 0 0; } | run )
{ has "$OUT" "naive baseline (no cache)" && has "$OUT" "routing alone saved" && has "$OUT" "caching alone saved"; } && ok "human output: three baselines" || no "human output" "$OUT"

# 12. bad flag errors cleanly
OUT=$( printf '' | run --nope ); rc=$?
{ [ $rc -eq 1 ] && has "$OUT" "unknown flag"; } && ok "unknown flag -> exit 1" || no "bad flag" "$OUT"

# 13. prices-as-of line appears in human output
OUT=$( entry claude-haiku-4-5 m1 1000000 0 0 0 0 | run )
has "$OUT" "token prices as of" && ok "human output: prices-as-of line" || no "prices-as-of human" "$OUT"

# 14. pricesAsOf field appears in json output
OUT=$( entry claude-haiku-4-5 m1 1000000 0 0 0 0 | run --json )
has "$OUT" "pricesAsOf" && ok "json output: pricesAsOf field" || no "pricesAsOf json" "$OUT"

# 15. honesty footnote present in human output
OUT=$( entry claude-haiku-4-5 m1 1000000 0 0 0 0 | run )
has "$OUT" "conservative" && ok "human output: honesty footnote" || no "footnote" "$OUT"

# 16. mtime pre-filter: file content is recent but file mtime is old -> skipped by --days
run_mtime_stale(){
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.claude/projects/proj-alpha"
  cat > "$home/.claude/projects/proj-alpha/s1.jsonl"
  touch -t 202001010000 "$home/.claude/projects/proj-alpha/s1.jsonl"
  HOME="$home" node "$REPORT" --days 30 2>&1
  local rc=$?
  rm -rf "$home"
  return $rc
}
OUT=$( entry claude-haiku-4-5 m1 1000000 0 0 0 0 2999-01-01T00:00:00Z | run_mtime_stale )
has "$OUT" "no transcript usage" && ok "mtime pre-filter skips stale files" || no "mtime pre-filter" "$OUT"

# 17. --project matches the RELATIVE path, not an absolute-path/HOME substring
#     (fix 1): a filter that is a substring of the scan root/HOME must not
#     select everything. Two real projects; filtering by one name's substring
#     of the root path itself must yield nothing.
run_two_projects(){
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.claude/projects/proj-one" "$home/.claude/projects/proj-two"
  # proj-one gets 1M in (haiku, $1); proj-two gets 2M in (haiku, $2)
  entry claude-haiku-4-5 m1 1000000 0 0 0 0 > "$home/.claude/projects/proj-one/s1.jsonl"
  entry claude-haiku-4-5 m2 2000000 0 0 0 0 > "$home/.claude/projects/proj-two/s2.jsonl"
  HOME="$home" node "$REPORT" "$@" 2>&1
  local rc=$?
  rm -rf "$home"
  return $rc
}
OUT=$( run_two_projects --project proj-one --json )
has "$OUT" '"actualUSD": 1,' && ok "--project isolates by relative path (proj-one only)" || no "--project relative isolation" "$OUT"
OUT=$( run_two_projects --project .claude/projects --json )
has "$OUT" '"actualUSD": 0,' && ok "--project substring-of-root matches nothing (critical fix)" || no "--project root substring" "$OUT"

# 18. --project normalizes dash-encoded transcript dir names (fix 8): a filter
#     containing '.', '_', space, or '/' should still match a dash-flattened
#     directory name via normalization.
run_dash_encoded(){
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.claude/projects/-Users-me-my-project"
  entry claude-haiku-4-5 m1 1000000 0 0 0 0 > "$home/.claude/projects/-Users-me-my-project/s1.jsonl"
  HOME="$home" node "$REPORT" "$@" 2>&1
  local rc=$?
  rm -rf "$home"
  return $rc
}
OUT=$( run_dash_encoded --project my.project --json )
has "$OUT" '"actualUSD": 1,' && ok "--project normalizes dots/slashes to match dash-encoded dirs" || no "--project normalization" "$OUT"

# 19. all-unknown-models: baseline falls back to top PRICING tier; report
#     still prints and exits 0 in both human and --json modes (fix 2).
OUT=$( entry claude-nova-99 m1 1000000 0 0 0 0 | run --json ); rc=$?
{ [ $rc -eq 0 ] && has "$OUT" 'unknown, priced as baseline' && has "$OUT" '"actualUSD"'; } && ok "all-unknown-models: --json exits 0 and reports" || no "all-unknown-models json" "$OUT"
OUT=$( entry claude-nova-99 m1 1000000 0 0 0 0 | run ); rc=$?
{ [ $rc -eq 0 ] && has "$OUT" "actual cost"; } && ok "all-unknown-models: human exits 0 and reports" || no "all-unknown-models human" "$OUT"

# 20. Haiku 3.5 real model id prices correctly: claude-3-5-haiku-20241022,
#     1M in + 1M out = $0.80 + $4.00 = $4.80 (fix 4).
OUT=$( entry claude-3-5-haiku-20241022 m1 1000000 1000000 0 0 0 | run --json )
{ has "$OUT" '"actualUSD": 4.8,' && has "$OUT" 'Haiku 3.5'; } && ok "Haiku 3.5 real model id prices at \$4.80" || no "haiku-3.5 real id" "$OUT"

# 21. --json with empty scope is valid, parseable JSON (fix 5).
OUT=$( printf '' | run --json )
printf '%s' "$OUT" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' >/dev/null 2>&1
{ [ $? -eq 0 ]; } && ok "--json empty scope is valid JSON" || no "--json empty scope parse" "$OUT"

# 22. non-string message.model is skipped, not fatal; next valid line counts
#     (fix 6). One entry with a numeric model, one valid haiku entry.
BAD_LINE='{"type":"assistant","timestamp":"2026-07-01T00:00:00Z","message":{"id":"mBad","model":123,"usage":{"input_tokens":999,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}'
OUT=$( { printf '%s\n' "$BAD_LINE"; entry claude-haiku-4-5 m2 1000000 0 0 0 0; } | run --json ); rc=$?
{ [ $rc -eq 0 ] && has "$OUT" '"actualUSD": 1,'; } && ok "non-string model line skipped, next line still counts" || no "non-string model" "$OUT"

# 23. sonnet-5 clock injection via ROUTE_REPORT_NOW (fix 9): intro pricing
#     before 2026-09-01 ($2/$10; 1M in + 2M out = $22), standard pricing at/
#     after 2026-09-01 ($3/$15; 1M in + 2M out = $33).
OUT=$( entry claude-sonnet-5-x m1 1000000 2000000 0 0 0 | ROUTE_REPORT_NOW=2026-08-01T00:00:00Z run --json )
{ has "$OUT" '"actualUSD": 22,' && has "$OUT" 'intro pricing'; } && ok "sonnet-5 intro pricing before cutover" || no "sonnet-5 intro" "$OUT"
OUT=$( entry claude-sonnet-5-x m1 1000000 2000000 0 0 0 | ROUTE_REPORT_NOW=2026-09-02T00:00:00Z run --json )
{ has "$OUT" '"actualUSD": 33,' && ! has "$OUT" 'intro pricing'; } && ok "sonnet-5 standard pricing after cutover" || no "sonnet-5 standard" "$OUT"

# 24. --json schema: exact top-level key set and perModel[0] key set, so a
#     silent field rename breaks this test.
OUT=$( entry claude-haiku-4-5 m1 1000000 1000000 0 0 0 | run --json )
SCHEMA_CHECK=$(printf '%s' "$OUT" | node -e '
  const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const topKeys = Object.keys(data).sort().join(",");
  const expectedTop = ["scope","baseline","pricesAsOf","perModel","actualUSD","baselinesUSD","savingsPct"].sort().join(",");
  const modelKeys = Object.keys(data.perModel[0]).sort().join(",");
  const expectedModel = ["label","calls","tokens","costUSD"].sort().join(",");
  if (topKeys !== expectedTop) { console.log("FAIL top:" + topKeys); process.exit(1); }
  if (modelKeys !== expectedModel) { console.log("FAIL model:" + modelKeys); process.exit(1); }
  console.log("OK");
' 2>&1 )
has "$SCHEMA_CHECK" "OK" && ok "--json schema: top-level and perModel[0] key sets" || no "--json schema" "$SCHEMA_CHECK"

echo
echo "route: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
