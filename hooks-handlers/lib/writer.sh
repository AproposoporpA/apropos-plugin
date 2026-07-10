#!/usr/bin/env bash
# Shared writer callback for q_flush. Delivers ONE queued entry to Apropos via
# the internal R: Record-Time.ps1 (or the $APROPOS_WRITER mock in tests).
# Args: person desc worktype task project startUtc. Returns 0 on success.
write_entry() {
  if [[ -n "${APROPOS_WRITER:-}" ]]; then "$APROPOS_WRITER" "$@"; return $?; fi
  local person="$1" desc="$2" wt="$3" task="$4" proj="$5" start="$6"
  local entry="${APROPOS_SKILL_DIR:-R:/Intranet/ClaudeAI/skills/work-management/time}/Record-Time.ps1"
  [[ -f "$entry" ]] || return 1
  local args=(-PersonID "$person" -Description "$desc" -WorkTypeID "$wt" -StartTimeUTC "$start")
  if [[ -n "$task" && "$task" != "0" ]]; then args+=(-TaskID "$task")
  elif [[ -n "$proj" && "$proj" != "0" ]]; then args+=(-ProjectID "$proj"); fi
  pwsh -NoProfile -ExecutionPolicy Bypass -File "$entry" "${args[@]}" >/dev/null 2>&1
}
