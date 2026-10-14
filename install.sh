#!/usr/bin/env bash
# Installs the cross-model skills into Claude Code.
#   ~/.claude/cross-model/codex-run.sh   the runner (the skills call it at this path)
#   ~/.claude/skills/<name>/SKILL.md     the skills
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

mkdir -p "$CLAUDE_DIR/cross-model"
install -m 755 "$HERE/codex-run.sh" "$CLAUDE_DIR/cross-model/codex-run.sh"

for skill in crossarch crossplan crossreview; do
  mkdir -p "$CLAUDE_DIR/skills/$skill"
  install -m 644 "$HERE/skills/$skill/SKILL.md" "$CLAUDE_DIR/skills/$skill/SKILL.md"
  echo "installed /$skill"
done

if ! command -v codex >/dev/null 2>&1; then
  echo "note: codex CLI not found on PATH. Install it, then run: codex login" >&2
fi
