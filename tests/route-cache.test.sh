#!/usr/bin/env bash
# Tests for skills/route/route-cache.js. Run: bash tests/route-cache.test.sh
# Fully isolated: temp HOME per test group, no side effects.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/plugins/route/skills/route/route-cache.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }

# On native Windows node, os.homedir()/HOME isolation does not hold (USERPROFILE wins),
# so these destructive prune tests would hit the real cache. route-cache.js prefers
# $HOME, but Git Bash native node can still diverge — skip rather than risk it.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) echo "route-cache tests: skipped (HOME isolation unreliable on native Windows node)"; exit 0;;
esac

H="$(mktemp -d)"; W="$(mktemp -d)"   # temp HOME and workdir
rc(){ HOME="$H" node "$CACHE" "$@"; }

echo "route-cache tests"

printf 'alpha content\n' > "$W/a.txt"
printf 'alpha content\n' > "$W/same-as-a.txt"
printf 'beta content\n'  > "$W/b.txt"

# 1. key is deterministic
K1=$(rc key --task "summarize this" --file "$W/a.txt")
K2=$(rc key --task "summarize this" --file "$W/a.txt")
[ -n "$K1" ] && [ "$K1" = "$K2" ] && ok "key deterministic" || no "key deterministic" "$K1 / $K2"

# 2. task text changes the key
K3=$(rc key --task "translate this" --file "$W/a.txt")
[ "$K1" != "$K3" ] && ok "task change -> new key" || no "task change" "$K1 = $K3"

# 3. file content changes the key
K4=$(rc key --task "summarize this" --file "$W/b.txt")
[ "$K1" != "$K4" ] && ok "content change -> new key" || no "content change" "$K1 = $K4"

# 4. rename/path independence: same bytes, different filename -> same key
K5=$(rc key --task "summarize this" --file "$W/same-as-a.txt")
[ "$K1" = "$K5" ] && ok "same content, different path -> same key" || no "path independence" "$K1 / $K5"

# 5. whitespace in the task is normalized
K6=$(rc key --task "  summarize    this " --file "$W/a.txt")
[ "$K1" = "$K6" ] && ok "task whitespace normalized" || no "whitespace" "$K1 / $K6"

# 6. get before put is a miss with exit 1
OUT=$(rc get "$K1" 2>&1); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" "miss"; } && ok "miss -> exit 1" || no "miss" "rc=$rcode $OUT"

# 7. put/get roundtrip preserves the result byte-for-byte
printf 'line one\nline two\n' | rc put "$K1" --model haiku --task "summarize this" 2>/dev/null
OUT=$(rc get "$K1" 2>/dev/null)
[ "$OUT" = "line one
line two" ] && ok "put/get roundtrip" || no "roundtrip" "$OUT"

# 8. hits are counted
rc get "$K1" >/dev/null 2>&1
OUT=$(rc stats)
has "$OUT" "1 entries" && has "$OUT" "2 hits" && ok "stats: entries + hits" || no "stats" "$OUT"

# 9. empty stdin refuses to cache
OUT=$(printf '' | rc put "$K3" 2>&1); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" "refusing"; } && ok "empty put refused" || no "empty put" "rc=$rcode $OUT"

# 10. prune --days 0 removes everything, prune is idempotent
OUT=$(rc prune --days 0)
has "$OUT" "pruned 1" && ok "prune removes old entries" || no "prune" "$OUT"
OUT=$(rc get "$K1" 2>&1); rcode=$?
[ $rcode -eq 1 ] && ok "pruned entry is gone" || no "pruned gone" "$OUT"

# 11. malformed key rejected
OUT=$(rc get "not-a-key" 2>&1); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" "bad key"; } && ok "malformed key rejected" || no "bad key" "$OUT"

# 12. unknown flag errors cleanly
OUT=$(rc key --task t --nope x 2>&1); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" "unknown flag"; } && ok "unknown flag -> exit 1" || no "unknown flag" "$OUT"

# 13. hit prints metadata on stderr
K7=$(rc key --task "hit metadata task" --file "$W/a.txt")
printf 'hit meta result\n' | rc put "$K7" --model haiku --task "hit metadata task" >/dev/null 2>&1
ERR=$(rc get "$K7" 2>&1 >/dev/null)
{ has "$ERR" "hit (" && has "$ERR" "from haiku"; } && ok "hit prints metadata on stderr" || no "hit metadata" "$ERR"

# 14. no leftover tmp files after a put
TMP_LEFT=$(find "$H/.claude/route-cache" -name '*.tmp-*' 2>/dev/null)
[ -z "$TMP_LEFT" ] && ok "no leftover .tmp- files after put" || no "leftover tmp files" "$TMP_LEFT"

# 15. large result warns on stderr
K8=$(rc key --task "large result task" --file "$W/a.txt")
ERR=$(head -c 70000 /dev/zero | tr '\0' 'x' | rc put "$K8" --model haiku --task "large result task" 2>&1 >/dev/null)
has "$ERR" "large result" && ok "large result warns on stderr" || no "large result warning" "$ERR"

# 16. prune --max-mb 0 removes all remaining entries
OUT=$(rc prune --days 9999 --max-mb 0)
has "$OUT" "pruned" && ok "prune --max-mb ran" || no "prune --max-mb ran" "$OUT"
REMAINING=$(rc stats)
has "$REMAINING" "0 entries" && ok "prune --max-mb 0 removes all remaining entries" || no "prune --max-mb 0" "$REMAINING"

# 17. get still succeeds when cache dir is read-only (chmod 555), unless running as root
if [ "$(id -u)" = 0 ]; then
  ok "skipped: read-only cache dir test (running as root)"
else
  K9=$(rc key --task "readonly dir task" --file "$W/a.txt")
  printf 'readonly result\n' | rc put "$K9" --model haiku --task "readonly dir task" >/dev/null 2>&1
  chmod 555 "$H/.claude/route-cache"
  OUT=$(rc get "$K9" 2>/dev/null); rcode=$?
  chmod 755 "$H/.claude/route-cache"
  { [ $rcode -eq 0 ] && [ "$OUT" = "readonly result" ]; } && ok "get succeeds on read-only cache dir" || no "read-only get" "rc=$rcode $OUT"
fi

# 18. --task-file produces the same key as inline --task (interface parity)
printf 'summarize this' > "$W/task.txt"
KF=$(rc key --task-file "$W/task.txt" --file "$W/a.txt")
KI=$(rc key --task "summarize this" --file "$W/a.txt")
[ "$KF" = "$KI" ] && ok "--task-file == --task key" || no "task-file parity" "$KF / $KI"

# 19. multi-file key: NUL at a boundary does NOT collide (length-framing fix)
printf 'A\0B' > "$W/n1"; printf 'A'   > "$W/n2"; printf '\0B' > "$W/n3"
KN1=$(rc key --task t --file "$W/n1")
KN2=$(rc key --task t --file "$W/n2" --file "$W/n3")
[ "$KN1" != "$KN2" ] && ok "NUL boundary no collision" || no "NUL collision" "$KN1 = $KN2"

# 20. missing flag value fails loudly (no silent task='--file')
OUT=$(rc key --task --file "$W/a.txt" 2>&1); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" "missing value"; } && ok "missing --task value rejected" || no "missing value" "rc=$rcode $OUT"

# 21. --flag=value form is accepted
KEQ=$(rc key --task=summarize --file "$W/a.txt" 2>&1); rcode=$?
{ [ $rcode -eq 0 ] && [ -n "$KEQ" ]; } && ok "--flag=value accepted" || no "equals form" "rc=$rcode $KEQ"

# 22. --result-file put path stores the file's bytes
printf 'from a file\n' > "$W/res.txt"
KRF=$(rc key --task "result-file task" --file "$W/a.txt")
rc put "$KRF" --model haiku --result-file "$W/res.txt" >/dev/null 2>&1
OUT=$(rc get "$KRF" 2>/dev/null)
[ "$OUT" = "from a file" ] && ok "--result-file put/get" || no "result-file" "$OUT"

# 23. binary (non-UTF-8) result round-trips byte-for-byte via base64 encoding
head -c 300 /dev/urandom > "$W/bin.in"
KB=$(rc key --task "binary task" --file "$W/a.txt")
rc put "$KB" --model haiku --result-file "$W/bin.in" >/dev/null 2>&1
rc get "$KB" 2>/dev/null > "$W/bin.out"
cmp -s "$W/bin.in" "$W/bin.out" && ok "binary result round-trips" || no "binary round-trip" "cmp differs"

# 24. CRITICAL: large result is NOT truncated when read through a pipe
KL=$(rc key --task "large pipe task" --file "$W/a.txt")
head -c 300000 /dev/zero | tr '\0' 'x' | rc put "$KL" --model haiku >/dev/null 2>&1
N=$(rc get "$KL" 2>/dev/null | wc -c | tr -d ' ')
[ "$N" = "300000" ] && ok "large result not truncated through pipe ($N)" || no "pipe truncation" "got $N bytes"

# 25. structurally broken entry (no result) is a miss, not a crash, and does not bump hits
KX=$(rc key --task "broken entry" --file "$W/a.txt")
printf 'broken\n' | rc put "$KX" --model haiku >/dev/null 2>&1
ENTRY=$(ls "$H/.claude/route-cache/$KX.json")
printf '{"v":2,"model":"haiku","createdAt":"2026-01-01T00:00:00Z","hits":0}' > "$ENTRY"
OUT=$(rc get "$KX" 2>&1); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" "miss"; } && ok "resultless entry -> miss not crash" || no "broken entry" "rc=$rcode $OUT"

# 26. garbage createdAt survives prune and get without crashing
KG=$(rc key --task "garbage ts" --file "$W/a.txt")
printf 'ts\n' | rc put "$KG" --model haiku >/dev/null 2>&1
GF=$(ls "$H/.claude/route-cache/$KG.json")
printf '{"v":2,"model":"haiku","createdAt":"not-a-date","hits":0,"encoding":"utf8","result":"ts"}' > "$GF"
OUT=$(rc get "$KG" 2>&1); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" "unknown age"; } && ok "garbage createdAt: get shows unknown age" || no "garbage ts get" "rc=$rcode $OUT"
OUT=$(rc prune --days 0 2>&1); rcode=$?
[ $rcode -eq 0 ] && ok "garbage createdAt: prune does not crash" || no "garbage ts prune" "rc=$rcode $OUT"

rm -rf "$H" "$W"
echo
echo "route-cache: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
