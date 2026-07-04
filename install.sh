#!/usr/bin/env bash
# Install claude-toolkit commands into ~/.claude/commands.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/commands"
mkdir -p "$DEST/lib"

installed=0
for cmd in "$SRC"/commands/*.md; do
  [ -e "$cmd" ] || continue
  name="$(basename "$cmd")"
  if [ -e "$DEST/$name" ] && ! cmp -s "$cmd" "$DEST/$name"; then
    echo "!  $name already exists in ~/.claude/commands and differs — leaving yours in place."
    echo "   (to overwrite: cp '$cmd' '$DEST/$name')"
    continue
  fi
  cp "$cmd" "$DEST/$name"
  echo "+  installed /$name"
  installed=$((installed + 1))
done

for lib in "$SRC"/lib/*.js; do
  [ -e "$lib" ] || continue
  cp "$lib" "$DEST/lib/$(basename "$lib")"
done

echo ""
echo "Done. $installed command(s) installed. Try /handoff in a Claude Code session."
