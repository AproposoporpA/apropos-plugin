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

# Where the currently-open entry for each activity is remembered, shared by every
# session on this machine. Lines are: activityKey <TAB> entryId <TAB> openedEpoch
APROPOS_OPEN_FILE="${APROPOS_OPEN_FILE:-${HOME}/.claude/apropos-time/open-entries.tsv}"

# How long one entry may keep absorbing turns before a fresh one is started. Without a
# cap a long stretch on one task would end up described only by whatever the last turn
# happened to be.
APROPOS_MERGE_MAX_SECS="${APROPOS_MERGE_MAX_SECS:-1800}"

# The open-entry file is read-modify-written by every session on this machine, so it
# needs the same mutual exclusion the queue has. Without it two sessions flushing at the
# same moment each read the file, each rewrite it, and the second silently drops the
# first's line. Observed 2026-08-14 on Barrett's entries: 336753 was the same activity as
# 336751 and written 8 minutes later, well inside the window, but a third insert landed
# 2 seconds earlier and the 23953|84 line went missing, so it inserted instead of
# amending and both rows carry the same description.
#
# Reuses q_lock from lib/queue.sh, which is always sourced before this file. mkdir is the
# primitive because flock is absent from Git Bash on Windows. If the lock is unavailable
# the callers degrade rather than corrupt: see each one below.
_oe_lock() {
  command -v q_lock >/dev/null 2>&1 || return 1
  local i=0
  while (( i < 50 )); do
    q_lock "$APROPOS_OPEN_FILE" && return 0
    sleep 0.1
    i=$((i+1))
  done
  return 1
}
_oe_unlock() { command -v q_unlock >/dev/null 2>&1 && q_unlock "$APROPOS_OPEN_FILE"; }

# oe_lookup <activityKey> -> prints "id epoch" when an entry is open for that activity
# and still inside the window; otherwise prints nothing and returns 1.
oe_lookup() {
  local key="$1" line id epoch now locked=0
  [[ -s "$APROPOS_OPEN_FILE" ]] || return 1
  _oe_lock && locked=1     # read-only, so proceed unlocked rather than lose the merge
  now="$(date -u +%s)"
  # Compare the first field exactly, in bash, with no regex at all. Two earlier attempts
  # were wrong: an unanchored grep -F let key "3|28682|26" match a "13|28682|26" line,
  # and anchoring it with an escaped key was worse, because activity keys contain "|"
  # and in a basic regex "\|" is alternation, so "^3\|28682\|26" matched any line
  # containing 28682. Field comparison sidesteps both.
  id=""; epoch=""; local d=""
  while IFS=$'\t' read -r k i e b; do
    if [[ "$k" == "$key" ]]; then id="$i"; epoch="$e"; d="$b"; break; fi
  done < "$APROPOS_OPEN_FILE"
  (( locked )) && _oe_unlock
  [[ -n "$id" ]] || return 1
  [[ "$id" =~ ^[0-9]+$ && "$epoch" =~ ^[0-9]+$ ]] || return 1
  (( now - epoch > APROPOS_MERGE_MAX_SECS )) && return 1
  # Third field is the description this recorder last wrote for the entry, base64 so it
  # cannot break the tab layout. The caller passes it back with the amend so a row that
  # somebody has corrected since is not silently overwritten. (#30988)
  printf '%s %s %s' "$id" "$epoch" "$d"
}

# oe_record <activityKey> <entryId>  — remember this entry as the open one for the
# activity, and drop any line that has aged out so the file cannot grow without bound.
oe_record() {
  local key="$1" id="$2" descb64="${3:-}" now tmp
  [[ "$id" =~ ^[0-9]+$ ]] || return 0
  # This one is a read-modify-write and MUST be exclusive. Failing to get the lock means
  # not recording the entry as open, so the next turn inserts instead of amending. That
  # is an untidy timesheet, which is a great deal better than clobbering another
  # session's line and losing its entry from the map entirely.
  _oe_lock || return 0
  now="$(date -u +%s)"
  mkdir -p "$(dirname "$APROPOS_OPEN_FILE")" 2>/dev/null || true
  tmp="$APROPOS_OPEN_FILE.tmp.$$"
  {
    if [[ -s "$APROPOS_OPEN_FILE" ]]; then
      while IFS=$'\t' read -r k i e b; do
        [[ "$k" == "$key" ]] && continue
        [[ "$e" =~ ^[0-9]+$ ]] || continue
        (( now - e > APROPOS_MERGE_MAX_SECS )) && continue
        printf '%s\t%s\t%s\t%s\n' "$k" "$i" "$e" "$b"
      done < "$APROPOS_OPEN_FILE"
    fi
    printf '%s\t%s\t%s\t%s\n' "$key" "$id" "$now" "$descb64"
  } > "$tmp" 2>/dev/null && mv "$tmp" "$APROPOS_OPEN_FILE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  _oe_unlock
}

# amend_entry <entryId> <person> <desc> — rewrite an open entry's description instead of
# inserting a second row beside it. Returns non-zero so the caller can fall back to a
# normal insert; losing the amend must never lose the time.
amend_entry() {
  if [[ -n "${APROPOS_AMENDER:-}" ]]; then "$APROPOS_AMENDER" "$@"; return $?; fi
  local id="$1" person="$2" desc="$3" expect="${4:-}"
  local script="${APROPOS_SKILL_DIR:-R:/Intranet/ClaudeAI/skills/work-management/time}/Update-TimeDescription.ps1"
  [[ -f "$script" ]] || return 1
  local ps; ps="$(apropos_ps_exe)" || return 1
  # -ExpectDescription makes the writer refuse the amend when the row no longer holds
  # what this recorder last wrote, which means somebody corrected it. Returning non-zero
  # sends the caller down the insert path, so the continuing work is still recorded.
  # Omitted when there is nothing to compare, so an older writer still works. (#30988)
  if [[ -n "$expect" ]]; then
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" \
      -TimeEntryID "$id" -Description "$desc" -PersonID "$person" -ExpectDescription "$expect" >/dev/null 2>&1
  else
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" \
      -TimeEntryID "$id" -Description "$desc" -PersonID "$person" >/dev/null 2>&1
  fi
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
  local out rc
  out="$("$ps" -NoProfile -ExecutionPolicy Bypass -File "$entry" "${args[@]}" 2>/dev/null)"
  rc=$?
  (( rc != 0 )) && return $rc
  # Remember the row just written, so the next turn on this activity amends it. Only
  # entries with a task qualify: the amend path cannot touch a row with no task without
  # clearing its attribution.
  if [[ -n "$task" && "$task" != "0" ]]; then
    local newId
    newId="$(printf '%s' "$out" | grep -o 'APROPOS_ENTRY_ID=[0-9]*' | head -1 | cut -d= -f2)"
    [[ -n "$newId" ]] && oe_record "$wt|$task|$proj" "$newId" "$(printf '%s' "$desc" | base64 | tr -d '\n')"
  fi
  return 0
}
