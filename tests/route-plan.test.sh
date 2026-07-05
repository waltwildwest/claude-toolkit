#!/usr/bin/env bash
# Tests for skills/route/route-plan.js. Run: bash tests/route-plan.test.sh
# Isolated: uses --model override and a temp HOME, no side effects.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAN="$ROOT/plugins/route/skills/route/route-plan.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }

rp(){ node "$PLAN" "$@"; }

echo "route-plan tests"

# 1. top model (Fable) delegates grunt->haiku, standard->sonnet, reviews on itself
OUT=$(rp --model claude-fable-5 --json)
{ has "$OUT" '"grunt": "haiku"' && has "$OUT" '"standard": "sonnet"' && has "$OUT" '"reviewer": "claude-fable-5"'; } && ok "fable: grunt+standard delegated, reviews self" || no "fable plan" "$OUT"

# 2. Opus delegates the same (both tiers strictly below it)
OUT=$(rp --model claude-opus-4-8 --json)
{ has "$OUT" '"grunt": "haiku"' && has "$OUT" '"standard": "sonnet"'; } && ok "opus: grunt+standard delegated" || no "opus plan" "$OUT"

# 3. Sonnet brain: grunt->haiku, but NO standard tier (never route up to sonnet/itself)
OUT=$(rp --model claude-sonnet-4-6 --json)
{ has "$OUT" '"grunt": "haiku"' && has "$OUT" '"standard": null'; } && ok "sonnet: grunt only, no route-up" || no "sonnet plan" "$OUT"

# 4. Haiku brain: cheapest tier, delegates NOTHING (no routing up)
OUT=$(rp --model claude-haiku-4-5 --json)
{ has "$OUT" '"grunt": null' && has "$OUT" '"standard": null' && has "$OUT" '"delegates": false'; } && ok "haiku: delegates nothing" || no "haiku plan" "$OUT"

# 5. Haiku human output tells you to do it yourself
OUT=$(rp --model claude-haiku-4-5)
has "$OUT" "do delegable work yourself" && ok "haiku: human tells you to self-do" || no "haiku human" "$OUT"

# 6. unknown/new model assumed top -> delegates grunt+standard downward
OUT=$(rp --model some-new-model-9 --json)
{ has "$OUT" '"grunt": "haiku"' && has "$OUT" '"standard": "sonnet"' && has "$OUT" '"brainKnown": false'; } && ok "unknown model assumed top, delegates" || no "unknown plan" "$OUT"

# 7. reviewer always equals the brain (never a cheaper model)
OUT=$(rp --model claude-opus-4-8 --json)
has "$OUT" '"reviewer": "claude-opus-4-8"' && ok "reviewer == brain (never downgraded)" || no "reviewer" "$OUT"

# 8. detection from a session transcript (no --model): reads last model in the JSONL
H="$(mktemp -d)"; SID="sess-test-1"
mkdir -p "$H/.claude/projects/proj"
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-opus-4-8"}}' \
  '{"type":"assistant","message":{"model":"claude-fable-5"}}' \
  > "$H/.claude/projects/proj/$SID.jsonl"
OUT=$(HOME="$H" CLAUDE_CODE_SESSION_ID="$SID" node "$PLAN" --json)
has "$OUT" '"brain": "claude-fable-5"' && ok "detects last model from transcript" || no "transcript detect" "$OUT"
rm -rf "$H"

# 9. no session / no transcript -> undetected, assumed top, still returns a plan (exit 0)
OUT=$(env -u CLAUDE_CODE_SESSION_ID node "$PLAN" --json); rc=$?
{ [ $rc -eq 0 ] && has "$OUT" '"brain": null' && has "$OUT" '"grunt": "haiku"'; } && ok "no session: graceful assumed-top plan" || no "no session" "rc=$rc $OUT"

# 10. bad flag -> exit 1
OUT=$(rp --nope 2>&1); rc=$?
{ [ $rc -eq 1 ] && has "$OUT" "unknown flag"; } && ok "bad flag -> exit 1" || no "bad flag" "$OUT"

# 11. --model '' (empty string) is rejected outright rather than silently
#     falling through to transcript detection (fix 1: layers must agree).
OUT=$(rp --model '' 2>&1); rc=$?
{ [ $rc -eq 1 ] && has "$OUT" "non-empty value"; } && ok "--model '' rejected, not silently mis-detected" || no "empty --model" "rc=$rc $OUT"

# 12. --model '<synthetic>' is treated as assumed-top (fix 2: explicit
#     override gets the same synthetic/blank-model normalization as detection).
#     Isolated from any real session/transcript so a synthetic override can't
#     fall through to detection and pick up an unrelated real model.
OUT=$(env -u CLAUDE_CODE_SESSION_ID node "$PLAN" --model '<synthetic>' --json)
{ has "$OUT" '"brain": null' && has "$OUT" '"brainKnown": false' && has "$OUT" '"grunt": "haiku"' && has "$OUT" '"standard": "sonnet"'; } && ok "--model '<synthetic>' treated as assumed-top" || no "synthetic --model" "$OUT"

echo
echo "route-plan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
