#!/usr/bin/env bash
# apropos plugin — SessionStart hook. Injects the per-turn convention. Exit 0.
P="${CLAUDE_PLUGIN_ROOT:-}"; P="${P//\\//}"
if [[ -z "$P" || ! -f "$P/hooks-handlers/convention.md" ]]; then
  P="$(find "${HOME}/.claude/plugins" -path "*apropos*/hooks-handlers/convention.md" 2>/dev/null | head -1 | sed 's|/hooks-handlers/convention.md$||')"
fi

# Deliver any entries stranded by a prior offline/crashed session (silent —
# must not pollute the injected context). Best-effort; never blocks startup.
if [[ -n "$P" && -f "$P/hooks-handlers/lib/queue.sh" && -f "$P/hooks-handlers/lib/writer.sh" ]]; then
  (
    source "$P/hooks-handlers/lib/queue.sh"
    source "$P/hooks-handlers/lib/writer.sh"
    q_flush "${HOME}/.claude/apropos-time/pending.tsv" write_entry
  ) >/dev/null 2>&1 || true
fi

[[ -n "$P" && -f "$P/hooks-handlers/convention.md" ]] && cat "$P/hooks-handlers/convention.md"
exit 0
