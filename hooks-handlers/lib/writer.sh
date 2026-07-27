#!/usr/bin/env bash
# Shared writer callback for q_flush. Delivers ONE queued entry to Apropos via
# the internal R: Record-Time.ps1 (or the $APROPOS_WRITER mock in tests).
# Args: person desc worktype task project startUtc. Returns 0 on success.

# Resolve a PowerShell executable WITHOUT relying on PATH. Claude Code runs hooks
# with a minimal PATH that often lacks pwsh (PowerShell 7); if we depend on PATH
# every write fails silently and entries pile up in the queue. Try PATH first,
# then Windows PowerShell (always in System32), then common full paths.
apropos_ps_exe() {
  local c
  for c in pwsh powershell.exe pwsh.exe; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  for c in \
    "/c/Program Files/PowerShell/7/pwsh.exe" \
    "$SYSTEMROOT/System32/WindowsPowerShell/v1.0/powershell.exe" \
    "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

write_entry() {
  if [[ -n "${APROPOS_WRITER:-}" ]]; then "$APROPOS_WRITER" "$@"; return $?; fi
  local person="$1" desc="$2" wt="$3" task="$4" proj="$5" start="$6"
  local entry="${APROPOS_SKILL_DIR:-R:/Intranet/ClaudeAI/skills/work-management/time}/Record-Time.ps1"
  [[ -f "$entry" ]] || return 1
  local ps; ps="$(apropos_ps_exe)" || return 1
  local args=(-PersonID "$person" -Description "$desc" -WorkTypeID "$wt" -StartTimeUTC "$start")
  if [[ -n "$task" && "$task" != "0" ]]; then args+=(-TaskID "$task")
  elif [[ -n "$proj" && "$proj" != "0" ]]; then args+=(-ProjectID "$proj"); fi
  "$ps" -NoProfile -ExecutionPolicy Bypass -File "$entry" "${args[@]}" >/dev/null 2>&1
}
