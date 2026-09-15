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

# Once-a-day repair pass over every flagged entry on the machine, not just this
# session's earlier turns. The per-turn hook owns sweep_due/sweep_prune/repair_pending/
# sweep_mark; this runs it as a real subprocess with its event piped in as JSON, rather
# than sourcing it, because that file reads its event from stdin (not an env var, see
# its own header comment) and ends by exiting, which would exit this hook too if sourced.
# sweep_due inside it keeps this to once per machine per day even though every
# concurrent session's start asks for it. Best-effort and silent, like the flush above.
if [[ -n "$P" && -f "$P/hooks-handlers/time-track-per-turn.sh" ]]; then
  ( printf '{"hook_event_name":"Sweep"}' | bash "$P/hooks-handlers/time-track-per-turn.sh" ) >/dev/null 2>&1 || true
fi

[[ -n "$P" && -f "$P/hooks-handlers/convention.md" ]] && cat "$P/hooks-handlers/convention.md"

# Visibility: if entries are still undelivered, surface it so time loss is never
# silent again. This is the signal that was missing during the weekend outage.
# The day's audit for the catch-all (#30989 requirement 4). The recorder warns on the turn
# it happens, but that is one line of stderr on one turn: it scrolls, the session ends,
# nobody looks. Reporting the running tally at every session start makes it a backstop
# instead of a single notice, so client work cannot reach the end of a day booked to an
# internal account without somebody having been told, repeatedly.
#
# Yesterday's tallies are pruned here rather than by a scheduled job, because this hook is
# the only thing guaranteed to run. Kept for a week so a Monday can still see Friday.
CATCHALL_DIR="${HOME}/.claude/apropos-time"
CATCHALL_TODAY="$CATCHALL_DIR/catchall-$(date -u +%Y-%m-%d).tsv"
if [[ -d "$CATCHALL_DIR" ]]; then
  find "$CATCHALL_DIR" -maxdepth 1 -name 'catchall-*.tsv' -mtime +7 -delete 2>/dev/null || true
fi
if [[ -s "$CATCHALL_TODAY" ]]; then
  n=$(grep -c . "$CATCHALL_TODAY" 2>/dev/null || echo 0)
  if [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]]; then
    echo ""
    echo "APROPOS: $n time entr(y/ies) today went to your catch-all task because no task was stated and no .apropos-task marker was found. Client work booked as internal overhead under-bills the customer and misreports the day, so correct these before the day closes. The folders they came from:"
    awk -F'	' '{print $2}' "$CATCHALL_TODAY" 2>/dev/null | sort -u | sed 's/^/  - /'
    echo "  Put a .apropos-task file holding the task number at the top of a folder and everything under it attributes itself."
  fi
fi

if [[ -f "$QUEUE" ]]; then
  pending=$(grep -c . "$QUEUE" 2>/dev/null || echo 0)
  if [[ "$pending" =~ ^[0-9]+$ && "$pending" -gt 0 ]]; then
    echo ""
    echo "APROPOS ALERT: $pending time entr(y/ies) are queued locally and NOT yet in Apropos (~/.claude/apropos-time/pending.tsv). The write path may be failing - investigate before more time is lost."
  fi
fi
exit 0
