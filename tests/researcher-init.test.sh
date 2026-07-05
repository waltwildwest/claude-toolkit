#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-init.js
# Run: bash tests/researcher-init.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
I="$ROOT/plugins/re-searcher/skills/re-searcher/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-init tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
echo "vault-init tests"

# 1. creates skeleton + git repo
OUT=$(node "$I" --vault "$V" 2>/dev/null); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"created"'; } && ok "creates vault" || no "create" "rc=$rcode $OUT"
ALL=1
for d in topics sources/raw attachments profiles; do [ -d "$V/$d" ] || ALL=0; done
for f in index.jsonl claims.jsonl metrics.jsonl inbox.jsonl wayback-queue.jsonl INDEX.md DASHBOARD.md; do [ -f "$V/$f" ] || ALL=0; done
[ $ALL -eq 1 ] && ok "skeleton complete" || no "skeleton" "$(ls -R "$V")"
[ -d "$V/.git" ] && ok "git repo initialized" || no "git" ""
git -C "$V" log --oneline 2>/dev/null | grep -q "vault init" && ok "initial auto-commit" || no "initial commit" "$(git -C "$V" log --oneline 2>&1)"
[ -f "$V/.obsidian/app.json" ] && ok "obsidian ignore config" || no "obsidian" ""

# 2. idempotent second run
OUT=$(node "$I" --vault "$V" 2>/dev/null); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"exists"'; } && ok "idempotent re-run" || no "idempotent" "rc=$rcode $OUT"

# 3. templates
OUT=$(node "$I" --template plan)
{ has "$OUT" 'manifest' && has "$OUT" 'topic:' && has "$OUT" 'aliases:' && has "$OUT" 'questions:'; } && ok "plan template" || no "plan tpl" "$OUT"
OUT=$(node "$I" --template task-spec)
{ has "$OUT" 'ROLE:' && has "$OUT" 'vault-fetch.js' && has "$OUT" '500 bytes'; } && ok "task-spec template" || no "task-spec tpl" "$OUT"
OUT=$(node "$I" --template finding)
{ has "$OUT" 'role:' && has "$OUT" '## Sources' && has "$OUT" '## Gaps'; } && ok "finding template" || no "finding tpl" "$OUT"
node "$I" --template nope >/dev/null 2>&1; [ $? -eq 1 ] && ok "unknown template fails" || no "tpl fail" "$?"

# 4. allowlist snippet
OUT=$(node "$I" --allowlist)
has "$OUT" 'Write(' && has "$OUT" 'vault-save.js' && ok "allowlist snippet" || no "allowlist" "$OUT"

echo; echo "vault-init: $pass passed, $fail failed"; [ $fail -eq 0 ]
