#!/usr/bin/env bash
# Tests for lib/handoff-spawn.js. Run: bash tests/handoff.test.sh
# Tier 1 is fully isolated (temp HOME, --dry-run, no side effects).
# Tier 2 exercises real tmux on a private socket, then tears it down.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPAWN="$ROOT/skills/handoff/handoff-spawn.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
# assert substring / absence
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }

# Run a dry-run in a throwaway HOME with a crafted transcript. Echoes stdout.
# usage: dry <sid> <effort> <handoffArgs...>  ; transcript JSONL comes on stdin
dry(){
  local sid="$1" effort="$2"; shift 2
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.claude/projects/proj"
  cat > "$home/.claude/projects/proj/$sid.jsonl"
  local rc
  if [ -n "$effort" ]; then
    env HOME="$home" CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_EFFORT="$effort" node "$SPAWN" "$@" 2>&1
  else
    env -u CLAUDE_EFFORT HOME="$home" CLAUDE_CODE_SESSION_ID="$sid" node "$SPAWN" "$@" 2>&1
  fi
  rc=$?
  rm -rf "$home"
  return $rc
}

echo "TIER 1 — detection, quoting, fallbacks (isolated)"
HF="$(mktemp -d)/h.md"; printf '# Handoff: t\n' > "$HF"   # safe-path handoff file

# 1. full mirror: model + effort + auto
OUT=$(printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-4-8"}}' '{"type":"mode","mode":"auto"}' | dry s1 high --dir /tmp --handoff "$HF" --dry-run)
{ has "$OUT" "--model 'claude-opus-4-8'" && has "$OUT" "--effort 'high'" && has "$OUT" "--permission-mode 'auto'"; } && ok "full mirror (model+effort+auto)" || no "full mirror" "$OUT"

# 2. mode normal -> no permission flag
OUT=$(printf '%s\n' '{"type":"assistant","message":{"model":"m1"}}' '{"type":"mode","mode":"normal"}' | dry s2 high --dir /tmp --handoff "$HF" --dry-run)
has "$OUT" "--permission-mode" && no "normal -> omit permission" "$OUT" || ok "normal mode -> no --permission-mode"

# 3. mode plan -> passed through
OUT=$(printf '%s\n' '{"type":"mode","mode":"plan"}' | dry s3 "" --dir /tmp --handoff "$HF" --dry-run)
has "$OUT" "--permission-mode 'plan'" && ok "plan mode -> --permission-mode plan" || no "plan mode" "$OUT"

# 4. no transcript -> no model, no permission (effort still works)
OUT=$(printf '' | dry s4 medium --dir /tmp --handoff "$HF" --dry-run)
{ ! has "$OUT" "--model" && ! has "$OUT" "--permission-mode" && has "$OUT" "--effort 'medium'"; } && ok "no transcript -> graceful (effort only)" || no "no transcript" "$OUT"

# 5. no effort env -> no --effort
OUT=$(printf '%s\n' '{"type":"assistant","message":{"model":"m5"}}' | dry s5 "" --dir /tmp --handoff "$HF" --dry-run)
has "$OUT" "--effort" && no "no effort -> omit" "$OUT" || ok "no CLAUDE_EFFORT -> no --effort"

# 6. no handoff -> plain claude with flags, no prompt
OUT=$(printf '%s\n' '{"type":"assistant","message":{"model":"m6"}}' | dry s6 high --dir /tmp --dry-run)
{ has "$OUT" "command:  claude --model 'm6' --effort 'high'" && ! has "$OUT" "handed this task off"; } && ok "no handoff -> plain mirrored claude" || no "no handoff" "$OUT"

# 7. top-level model field (not nested in message)
OUT=$(printf '%s\n' '{"type":"x","model":"top-level-model"}' | dry s7 "" --dir /tmp --handoff "$HF" --dry-run)
has "$OUT" "--model 'top-level-model'" && ok "detects top-level model field" || no "top-level model" "$OUT"

# 8. last value wins (model changes mid-session)
OUT=$(printf '%s\n' '{"message":{"model":"old"}}' '{"message":{"model":"new"}}' | dry s8 "" --dir /tmp --handoff "$HF" --dry-run)
{ has "$OUT" "--model 'new'" && ! has "$OUT" "'old'"; } && ok "last model wins" || no "last model wins" "$OUT"

# 9. shell-injection safety: a malicious model string stays quoted, not executed
OUT=$(printf '%s\n' "{\"message\":{\"model\":\"x'; rm -rf ~ #\"}}" | dry s9 "" --dir /tmp --handoff "$HF" --dry-run)
{ has "$OUT" "'x'\\''; rm -rf ~ #'" ; } && ok "injection in model is safely single-quoted" || no "injection safety" "$OUT"

# 10. unsafe handoff path -> reject
OUT=$(printf '' | dry s10 "" --dir /tmp --handoff "/tmp/has space.md" --dry-run); rc=$?
{ [ $rc -ne 0 ] && has "$OUT" "unsafe"; } && ok "unsafe handoff path rejected" || no "unsafe path" "$OUT (rc=$rc)"

# 11. missing dir -> error
OUT=$(printf '' | dry s11 "" --dir /no/such/dir/xyz --handoff "$HF" --dry-run); rc=$?
{ [ $rc -ne 0 ] && has "$OUT" "dir not found"; } && ok "missing dir errors" || no "missing dir" "$OUT (rc=$rc)"

# 12. missing handoff file -> error
OUT=$(printf '' | dry s12 "" --dir /tmp --handoff /tmp/nope-not-here.md --dry-run); rc=$?
{ [ $rc -ne 0 ] && has "$OUT" "handoff file not found"; } && ok "missing handoff file errors" || no "missing handoff" "$OUT (rc=$rc)"

echo ""
echo "TIER 2 — real tmux new-window + send-keys actually runs a command (private socket)"
if command -v tmux >/dev/null 2>&1; then
  SOCK="httest-$$"; MARK="/tmp/toolkit-tier2-$$.out"; rm -f "$MARK"
  tmux -L "$SOCK" new-session -d -s s -x 200 -y 50 2>/dev/null
  # replicate exactly what the script does: new-window -d -P (capture pane), then send-keys
  PANE=$(tmux -L "$SOCK" new-window -d -P -F '#{pane_id}' -c /tmp 2>/dev/null)
  tmux -L "$SOCK" send-keys -t "$PANE" "echo TIER2-RAN > $MARK" C-m 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$MARK" ] && break; sleep 0.3; done
  { [ -n "$PANE" ] && grep -q TIER2-RAN "$MARK" 2>/dev/null; } && ok "tmux new-window + send-keys executed in the new window (pane $PANE)" || no "tmux mechanism" "pane=$PANE mark=$(cat "$MARK" 2>/dev/null)"
  tmux -L "$SOCK" kill-server 2>/dev/null; rm -f "$MARK"
else
  echo "  SKIP  tmux not installed"
fi

echo ""
echo "== $pass passed, $fail failed =="
[ $fail -eq 0 ]
