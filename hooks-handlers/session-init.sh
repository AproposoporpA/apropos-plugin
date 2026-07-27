#!/usr/bin/env bash
# apropos plugin — SessionStart hook. Injects the per-turn convention. Exit 0.
P="${CLAUDE_PLUGIN_ROOT:-}"; P="${P//\\//}"
if [[ -z "$P" || ! -f "$P/hooks-handlers/convention.md" ]]; then
  P="$(find "${HOME}/.claude/plugins" -path "*apropos*/hooks-handlers/convention.md" 2>/dev/null | head -1 | sed 's|/hooks-handlers/convention.md$||')"
fi

QUEUE="${HOME}/.claude/apropos-time/pending.tsv"

# Deliver any entries stranded by a prior offline/crashed session (silent -
# must not pollute the injected context). Best-effort; never blocks startup.
if [[ -n "$P" && -f "$P/hooks-handlers/lib/queue.sh" && -f "$P/hooks-handlers/lib/writer.sh" ]]; then
  (
    source "$P/hooks-handlers/lib/queue.sh"
    source "$P/hooks-handlers/lib/writer.sh"
    q_flush "$QUEUE" write_entry "${APROPOS_FLUSH_MAX_START:-25}"
  ) >/dev/null 2>&1 || true
fi

[[ -n "$P" && -f "$P/hooks-handlers/convention.md" ]] && cat "$P/hooks-handlers/convention.md"

# Visibility: if entries are still undelivered, surface it so time loss is never
# silent again. This is the signal that was missing during the weekend outage.
if [[ -f "$QUEUE" ]]; then
  pending=$(grep -c . "$QUEUE" 2>/dev/null || echo 0)
  if [[ "$pending" =~ ^[0-9]+$ && "$pending" -gt 0 ]]; then
    echo ""
    echo "APROPOS ALERT: $pending time entr(y/ies) are queued locally and NOT yet in Apropos (~/.claude/apropos-time/pending.tsv). The write path may be failing - investigate before more time is lost."
  fi
fi
exit 0
