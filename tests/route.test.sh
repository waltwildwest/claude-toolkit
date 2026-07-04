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
has "$OUT" '"actualUSD": 6' && ok "haiku cost math (1M in + 1M out = \$6)" || no "haiku cost math" "$OUT"

# 2. dedupe: same message.id streamed twice counts once
OUT=$( { entry claude-haiku-4-5 mA 500000 0 0 0 0; entry claude-haiku-4-5 mA 1000000 0 0 0 0; } | run --json )
has "$OUT" '"actualUSD": 1' && ok "dedupe by message.id (last wins)" || no "dedupe" "$OUT"

# 3. cache read priced at 0.1x input: opus 4.8, 1M cache read = 1M * $5 * 0.1 = $0.50
OUT=$( entry claude-opus-4-8 m1 0 0 1000000 0 0 | run --json )
has "$OUT" '"actualUSD": 0.5' && ok "cache read at 0.1x (\$0.50)" || no "cache read" "$OUT"

# 4. cache writes: 1M 5m-write on opus = 1.25*$5 = $6.25 ; 1M 1h-write = 2*$5 = $10
OUT=$( entry claude-opus-4-8 m1 0 0 0 1000000 1000000 | run --json )
has "$OUT" '"actualUSD": 16.25' && ok "cache write multipliers (1.25x + 2x)" || no "cache writes" "$OUT"

# 5. naive baseline: haiku 1M in ($1 actual) vs opus-in-data baseline no-cache
#    haiku 1M in + opus 1M cache-read: actual = $1 + $0.50 = $1.50
#    naive (all opus, no cache) = 2M in * $5 = $10 ; savings = 85%
OUT=$( { entry claude-haiku-4-5 m1 1000000 0 0 0 0; entry claude-opus-4-8 m2 0 0 1000000 0 0; } | run --json )
{ has "$OUT" '"naiveNoCache": 10' && has "$OUT" '"vsNaive": 85'; } && ok "naive baseline + savings pct" || no "naive baseline" "$OUT"

# 6. routing-alone baseline: same tokens on top model WITH cache
#    = 1M in * $5 + 1M read * $0.50 = $5.50 ; actual $1.50 -> 72.73%
OUT=$( { entry claude-haiku-4-5 m1 1000000 0 0 0 0; entry claude-opus-4-8 m2 0 0 1000000 0 0; } | run --json )
{ has "$OUT" '"topModelWithCache": 5.5' && has "$OUT" '"routingAlone": 72.73'; } && ok "routing-alone baseline" || no "routing-alone" "$OUT"

# 7. --days filters old entries
OUT=$( { entry claude-haiku-4-5 m1 1000000 0 0 0 0 2020-01-01T00:00:00Z; entry claude-haiku-4-5 m2 1000000 0 0 0 0 2999-01-01T00:00:00Z; } | run --days 30 --json )
has "$OUT" '"actualUSD": 1' && ok "--days filters old entries" || no "--days filter" "$OUT"

# 8. --project filters by path substring
OUT=$( entry claude-haiku-4-5 m1 1000000 0 0 0 0 | run --project proj-alpha --json )
has "$OUT" '"actualUSD": 1' && ok "--project match includes" || no "--project include" "$OUT"
OUT=$( entry claude-haiku-4-5 m1 1000000 0 0 0 0 | run --project no-such-proj )
has "$OUT" "no transcript usage" && ok "--project mismatch is graceful" || no "--project exclude" "$OUT"

# 9. synthetic/unknown handling: <synthetic> skipped; unknown model priced at baseline
OUT=$( { entry '<synthetic>' m1 9000000 0 0 0 0; entry claude-haiku-4-5 m2 1000000 0 0 0 0; } | run --json )
has "$OUT" '"actualUSD": 1' && ok "<synthetic> model skipped" || no "synthetic skip" "$OUT"
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

echo
echo "route: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
