#!/usr/bin/env bash
# Installs the cross-model skills into Claude Code.
#   ~/.claude/cross-model/codex-run.sh   the runner (the skills call it at this path)
#   ~/.claude/skills/<name>/SKILL.md     the skills
#
# Usage: ./install.sh          copy the files (stable install)
#        ./install.sh --link   symlink to this checkout, so edits here take
#                              effect immediately (for working on the skills)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"   # the skills hardcode ~/.claude/cross-model
MODE="copy"
case "${1:-}" in
  "") ;;
  --link) MODE="link" ;;
  *) echo "usage: $0 [--link]" >&2; exit 64 ;;
esac

# Refuse to replace a real directory: it may hold something other than an install.
place() { # place <source> <target>
  local src="$1" dst="$2"
  if [ -e "$dst" ] && [ ! -L "$dst" ] && [ -d "$dst" ] && [ "$MODE" = "link" ]; then
    echo "error: $dst is a real directory; move it aside first" >&2; exit 1
  fi
  [ -L "$dst" ] && rm "$dst"
  if [ "$MODE" = "link" ]; then
    ln -s "$src" "$dst"
  else
    mkdir -p "$dst"
    cp -R "$src/." "$dst/"
  fi
}

mkdir -p "$CLAUDE_DIR/skills"
if [ "$MODE" = "link" ]; then
  place "$HERE" "$CLAUDE_DIR/cross-model"
else
  [ -L "$CLAUDE_DIR/cross-model" ] && rm "$CLAUDE_DIR/cross-model"
  mkdir -p "$CLAUDE_DIR/cross-model"
  install -m 755 "$HERE/codex-run.sh" "$CLAUDE_DIR/cross-model/codex-run.sh"
fi

for skill in crossarch crossplan crossreview; do
  place "$HERE/skills/$skill" "$CLAUDE_DIR/skills/$skill"
  echo "installed /$skill ($MODE)"
done

if ! command -v codex >/dev/null 2>&1; then
  echo "note: codex CLI not found on PATH. Install it, then run: codex login" >&2
fi
