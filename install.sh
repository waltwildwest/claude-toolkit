#!/usr/bin/env bash
# Install claude-toolkit: skills (work in the CLI *and* the desktop app) + a thin
# CLI command wrapper. Safe to re-run; won't clobber files you've customized.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
SKILLS="$HOME/.claude/skills"
COMMANDS="$HOME/.claude/commands"
mkdir -p "$SKILLS" "$COMMANDS"

# Skills (each is a folder; work in CLI and desktop)
for dir in "$SRC"/skills/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  rm -rf "$SKILLS/$name"
  cp -R "$dir" "$SKILLS/$name"
  echo "+  installed skill: $name"
done
# keep the helper scripts executable
chmod +x "$SKILLS"/handoff/handoff-spawn.js 2>/dev/null || true
chmod +x "$SKILLS"/route/route-report.js 2>/dev/null || true

# Thin CLI command wrapper (CLI only; desktop uses the skill directly)
for cmd in "$SRC"/commands/*.md; do
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
