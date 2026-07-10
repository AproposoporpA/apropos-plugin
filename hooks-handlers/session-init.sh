#!/usr/bin/env bash
# apropos plugin — SessionStart hook. Injects the per-turn convention. Exit 0.
P="${CLAUDE_PLUGIN_ROOT:-}"; P="${P//\\//}"
if [[ -z "$P" || ! -f "$P/hooks-handlers/convention.md" ]]; then
  P="$(find "${HOME}/.claude/plugins" -path "*apropos*/hooks-handlers/convention.md" 2>/dev/null | head -1 | sed 's|/hooks-handlers/convention.md$||')"
fi
[[ -n "$P" && -f "$P/hooks-handlers/convention.md" ]] && cat "$P/hooks-handlers/convention.md"
exit 0
