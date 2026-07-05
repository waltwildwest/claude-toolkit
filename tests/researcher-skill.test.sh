#!/usr/bin/env bash
# Packaging checks for the re-searcher skill: SKILL.md line budget, script
# references resolve, progressive-disclosure files exist, command routes.
# Run: bash tests/researcher-skill.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/plugins/re-searcher/skills/re-searcher"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
echo "re-searcher skill packaging tests"

[ -f "$SK/SKILL.md" ] && ok "SKILL.md exists" || no "SKILL.md" ""
LINES=$(wc -l < "$SK/SKILL.md" | tr -d ' ')
[ "$LINES" -le 200 ] && ok "SKILL.md within 200-line budget ($LINES)" || no "line budget" "$LINES lines"
head -1 "$SK/SKILL.md" | grep -q '^---$' && ok "frontmatter opens" || no "frontmatter" ""
grep -q '^name: re-searcher$' "$SK/SKILL.md" && ok "name set" || no "name" ""
grep -q '^description: .' "$SK/SKILL.md" && ok "description set" || no "description" ""

# every script the skill calls must exist and be mentioned
ALL=1
for s in vault-init.js vault-fetch.js vault-save.js vault-search.js vault-harvest.js; do
  grep -q "$s" "$SK/SKILL.md" || { ALL=0; echo "    not referenced: $s"; }
  [ -f "$SK/$s" ] || { ALL=0; echo "    missing file: $s"; }
done
[ $ALL -eq 1 ] && ok "script references resolve" || no "script refs" ""

# state machine beats present, recall first
grep -qi 'recall' "$SK/SKILL.md" && grep -q 'check-staging' "$SK/SKILL.md" && grep -qi 'provenance' "$SK/SKILL.md" \
  && ok "state machine beats present" || no "state machine" ""
grep -q -- '--light' "$SK/SKILL.md" && ok "light path documented" || no "light" ""

ALL=1
for r in full-path claims correct harvest; do
  [ -f "$SK/references/$r.md" ] || { ALL=0; echo "    missing: references/$r.md"; }
  grep -q "references/$r.md" "$SK/SKILL.md" || { ALL=0; echo "    unreferenced: references/$r.md"; }
done
[ $ALL -eq 1 ] && ok "progressive disclosure wired" || no "references" ""

C="$ROOT/plugins/re-searcher/commands/research.md"
[ -f "$C" ] && ok "command file exists" || no "command" ""
head -1 "$C" | grep -q '^---$' && grep -q '^description:' "$C" && ok "command frontmatter" || no "cmd fm" ""
grep -q -- '--fresh' "$C" && grep -q 'correct' "$C" && ok "command routes subcommands" || no "routing" ""
grep -qi 'stage 3' "$C" && ok "honest stage-3 stub (doctor)" || no "stubs" ""
grep -q 'vault-harvest.js' "$C" && ok "command routes harvest" || no "cmd harvest" ""

# --- registration (Task 12) ---
M="$ROOT/.claude-plugin/marketplace.json"
node -e '
const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const p = m.plugins.find((x) => x.name === "re-searcher");
if (!p) process.exit(1);
if (p.source !== "./plugins/re-searcher") process.exit(2);
if (!p.skills.includes("./skills/re-searcher")) process.exit(3);
if (!p.commands.includes("./commands/research.md")) process.exit(4);
' "$M" && ok "marketplace entry valid" || no "marketplace" "rc=$?"
[ -d "$ROOT/plugins/re-searcher/skills/re-searcher" ] && [ -f "$ROOT/plugins/re-searcher/commands/research.md" ] \
  && ok "marketplace paths exist" || no "paths" ""
grep -q 're-searcher' "$ROOT/install.sh" && ok "install.sh knows re-searcher" || no "install.sh" ""
grep -q 're-searcher' "$ROOT/README.md" && ok "README documents re-searcher" || no "README" ""

# --- stage 2 registration ---
HK="$ROOT/plugins/re-searcher/hooks/hooks.json"
node -e '
const h = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const stop = h.hooks.Stop[0].hooks[0];
process.exit(stop.type === "command" && /inbox-note\.js/.test(stop.command) && /CLAUDE_PLUGIN_ROOT/.test(stop.command) ? 0 : 1);
' "$HK" && ok "Stop hook registered" || no "hook" ""
[ -f "$ROOT/plugins/re-searcher/skills/re-searcher/inbox-note.js" ] && ok "hook target exists" || no "hook target" ""
node -e '
const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const p = m.plugins.find((x) => x.name === "re-searcher");
process.exit(p.version === "0.2.0" ? 0 : 1);
' "$ROOT/.claude-plugin/marketplace.json" && ok "marketplace bumped to 0.2.0" || no "version" ""
grep -q 'inbox-note' "$ROOT/install.sh" && ok "install.sh documents the hook" || no "install hook" ""
grep -qi 'harvest' "$ROOT/README.md" && ok "README documents harvest" || no "README harvest" ""

echo; echo "skill: $pass passed, $fail failed"; [ $fail -eq 0 ]
