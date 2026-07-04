#!/usr/bin/env bash
# Tests for skills/route/route-detect.js. Run: bash tests/route-detect.test.sh
# Pure function of its input; no side effects.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DET="$ROOT/skills/route/route-detect.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
det(){ node "$DET" --prompt "$1"; }
expl(){ node "$DET" --prompt "$1" --explain; }

echo "route-detect tests"

# --- fires on the right prompts (with the right lead nudge) ---
# 1. wide/parallel job -> fanout nudge
OUT=$(det "Please audit all the files in src/ for unused imports")
{ has "$OUT" 'additionalContext' && has "$OUT" 'fan the independent pieces out'; } && ok "fanout: audit all files" || no "fanout audit" "$OUT"

# 2. for-each phrasing -> fanout
OUT=$(expl "for each endpoint, add a rate-limit test")
has "$OUT" "fanout" && ok "fanout: for each" || no "fanout for-each" "$OUT"

# 3. glob mention -> fanout
OUT=$(expl "convert src/*.ts to use the new logger")
has "$OUT" "fanout" && ok "fanout: glob *.ts" || no "fanout glob" "$OUT"

# 4. mechanical work -> grunt nudge
OUT=$(det "reformat this file and extract the constants")
{ has "$OUT" 'additionalContext' && has "$OUT" 'cheaper model'; } && ok "grunt: reformat/extract" || no "grunt" "$OUT"

# 5. search phrasing -> grunt
OUT=$(expl "grep the repo and find all the callers of doThing")
has "$OUT" "grunt" && ok "grunt: grep/find all (also fanout ok)" || no "grunt grep" "$OUT"

# 6. cost question -> cost nudge, and cost wins the lead over other groups
OUT=$(det "how much am I spending on Claude and can I audit all my costs")
{ has "$OUT" 'additionalContext' && has "$OUT" 'route-report.js' && has "$OUT" 'three honest baselines'; } && ok "cost: leads over fanout" || no "cost lead" "$OUT"

# --- stays silent when it should ---
# 7. ordinary question -> no output
OUT=$(det "what does this function return when x is negative?")
[ -z "$OUT" ] && ok "silent: ordinary question" || no "should be silent" "$OUT"

# 8. explain shows no signals for ordinary text
OUT=$(expl "explain how promises work in javascript")
has "$OUT" "no signals" && ok "explain: no signals on ordinary text" || no "explain silent" "$OUT"

# --- hook payload path (stdin JSON) ---
# 9. reads the prompt out of a UserPromptSubmit JSON payload
OUT=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"refactor every module to ESM"}' | node "$DET")
has "$OUT" 'additionalContext' && ok "stdin: extracts prompt from hook JSON" || no "stdin json" "$OUT"

# 10. bare string on stdin is tolerated
OUT=$(printf 'audit all the tests' | node "$DET")
has "$OUT" 'additionalContext' && ok "stdin: tolerates bare prompt string" || no "stdin bare" "$OUT"

# 11. malformed / empty stdin -> silent, exit 0 (never breaks the prompt)
OUT=$(printf '' | node "$DET"); rc=$?
{ [ $rc -eq 0 ] && [ -z "$OUT" ]; } && ok "empty stdin: silent, exit 0" || no "empty stdin" "rc=$rc $OUT"

# 12. valid JSON emitted (parses, has the right event name)
OUT=$(det "audit all files")
echo "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8"));process.exit(r.hookSpecificOutput.hookEventName==="UserPromptSubmit"?0:1)' \
  && ok "output is valid hook JSON" || no "valid json" "$OUT"

# --- opt-out ---
# 13. ROUTE_DETECT=off silences everything
OUT=$(ROUTE_DETECT=off node "$DET" --prompt "audit all the files"); rc=$?
{ [ $rc -eq 0 ] && [ -z "$OUT" ]; } && ok "ROUTE_DETECT=off: silent" || no "opt-out" "rc=$rc $OUT"

# 14. unknown flag -> stderr but exit 0 (a hook must not fail the prompt)
OUT=$(node "$DET" --nope 2>&1); rc=$?
{ [ $rc -eq 0 ] && has "$OUT" "unknown flag"; } && ok "bad flag: reports but exit 0" || no "bad flag" "rc=$rc $OUT"

echo
echo "route-detect: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
