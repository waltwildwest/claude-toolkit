#!/usr/bin/env bash
# Install claude-toolkit: skills (work in the CLI *and* the desktop app) + a thin
# CLI command wrapper. Safe to re-run; won't clobber files you've customized.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
SKILLS="$HOME/.claude/skills"
COMMANDS="$HOME/.claude/commands"
mkdir -p "$SKILLS" "$COMMANDS"

# Skills live under plugins/<plugin>/skills/ (each is a folder; work in CLI and desktop)
for dir in "$SRC"/plugins/*/skills/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  rm -rf "$SKILLS/$name"
  cp -R "$dir" "$SKILLS/$name"
  echo "+  installed skill: $name"
done
# keep the helper scripts executable
chmod +x "$SKILLS"/handoff/handoff-spawn.js 2>/dev/null || true
chmod +x "$SKILLS"/route/route-report.js "$SKILLS"/route/route-cache.js "$SKILLS"/route/route-plan.js "$SKILLS"/route/route-detect.js "$SKILLS"/route/route-learn.js 2>/dev/null || true
chmod +x "$SKILLS"/re-searcher/*.js 2>/dev/null || true

# Thin CLI command wrappers (CLI only; desktop uses the skill directly)
for cmd in "$SRC"/plugins/*/commands/*.md; do
  [ -e "$cmd" ] || continue
  name="$(basename "$cmd")"
  if [ -e "$COMMANDS/$name" ] && ! cmp -s "$cmd" "$COMMANDS/$name"; then
    echo "!  /$name already exists in ~/.claude/commands and differs — leaving yours in place."
    echo "   (to overwrite: cp '$cmd' '$COMMANDS/$name')"
    continue
  fi
  cp "$cmd" "$COMMANDS/$name"
  echo "+  installed command: /${name%.md}"
done

echo ""
echo "Done."
echo "  Terminal:  /handoff  (or ask to 'hand this off to a fresh session')"
echo "  Desktop:   run the 'handoff' skill; in the new session, run 'pickup'."
echo "  Routing:   /route <task> to size+dispatch, /route report for the savings math."
echo "  Research:  /research <question> — vault-first research; vault at ~/research-vault (set RESEARCH_VAULT_DIR to move it)."
echo ""
echo "  Optional — smarter activation (the plugin install gets these automatically):"
echo "    route ships two hooks: a UserPromptSubmit hook that nudges routing on"
echo "    cost-routable prompts, and a Stop hook that reminds you to run route-learn"
echo "    review when verdicts accumulate. Copy-install doesn't auto-load them; to"
echo "    enable, add both to ~/.claude/settings.json under \"hooks\":"
echo '      "UserPromptSubmit": [ { "hooks": [ { "type": "command",'
echo "        \"command\": \"node '$SKILLS/route/route-detect.js'\" } ] } ],"
echo '      "Stop": [ { "hooks": [ { "type": "command",'
echo "        \"command\": \"node '$SKILLS/route/route-learn.js' nudge\" } ] } ]"
echo "    Both are silent unless relevant. Disable with ROUTE_DETECT=off / ROUTE_LEARN=off."
echo "    re-searcher ships a Stop hook that notes each session in the research vault's"
echo "    inbox for lazy harvest (silent; pointers only; needs an initialized vault). To"
echo "    enable it with a copy install, add to \"hooks\" > \"Stop\" alongside route's:"
echo "      { \"type\": \"command\", \"command\": \"node '$SKILLS/re-searcher/inbox-note.js'\" }"
echo "    Disable with RESEARCH_INBOX=off. Plugin installs load it automatically."

# route's cache and report need a system Node.js; Claude Code does not put node
# on PATH itself. Warn, don't fail — everything else in this repo works without it.
command -v node >/dev/null 2>&1 || {
  echo ""
  echo "!  node not found on PATH: route's cache and report will skip themselves"
  echo "   until you install a system Node.js (any recent version). Everything"
  echo "   else here (handoff, pickup, route's sizing/fan-out) works without it."
}
