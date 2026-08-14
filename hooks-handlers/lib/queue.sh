#!/usr/bin/env bash
# Durable local time-entry queue. TSV lines:
#   person <TAB> descB64 <TAB> worktype <TAB> task <TAB> project <TAB> startUtc [<TAB> attempts]
# Description is base64-encoded so it may contain tabs/newlines/quotes safely.
# The 7th field (attempts) is optional; lines written by older versions are read as 0.
#
# TWO DEFECTS FIXED 2026-08-10, both observed live on Barrett's machine.
#
# 1. NO MUTUAL EXCLUSION. q_flush read the queue, delivered every line, then rewrote
#    the file from its own snapshot. With several Claude Code sessions open, two flushes
#    would run at once and deliver every queued entry once each, and a flush that
#    retained entries could write its stale snapshot over a newer file, restoring
#    entries that had already been delivered so they were delivered again. Measured
#    2026-08-08 to 08-10: 239 rows in Apropos from only 7 real moments, all at zero
#    duration ("onboarding-status" 106 rows from 3 timestamps, "Temp" 102 from 3,
#    "subscriber-health" 31 from 1). Proof it was re-delivery and not re-recording: the
#    queue still held 31 entries and all 8 of the non-placeholder ones were already in
#    the database. Reproduced with two concurrent q_flush calls, which delivered every
#    entry exactly twice.
#
# 2. HEAD-OF-LINE BLOCKING. A single undeliverable entry set stopped=1, which retained
#    that entry AND every entry behind it, forever, with no attempt limit. One bad row
#    silently froze all later time recording. This is what produced the two archived
#    backlogs on this machine, 383 entries on 2026-07-28 and 212 on 2026-08-05, the
#    second marked DO-NOT-FLUSH because it could no longer be trusted.
#
# The lock is a directory, not flock: flock is not present in Git Bash on Windows, and
# mkdir is atomic on every filesystem we run on.

Q_LOCK_STALE_SECS="${Q_LOCK_STALE_SECS:-120}"
Q_MAX_ATTEMPTS="${Q_MAX_ATTEMPTS:-5}"

_q_now() { date -u +%s; }

# Acquire the queue mutex. Returns 0 on success, 1 if another process holds it.
# A lock older than Q_LOCK_STALE_SECS is treated as abandoned and broken, so a process
# killed mid-flush cannot wedge time recording permanently.
q_lock() {
  local qf="$1" lock="$1.lock" age start
  mkdir -p "$(dirname "$qf")" 2>/dev/null || true
  if mkdir "$lock" 2>/dev/null; then _q_now > "$lock/ts" 2>/dev/null; return 0; fi
  start="$(cat "$lock/ts" 2>/dev/null)"
  if [[ "$start" =~ ^[0-9]+$ ]]; then
    age=$(( $(_q_now) - start ))
    if (( age > Q_LOCK_STALE_SECS )); then
      rm -rf "$lock" 2>/dev/null || true
      if mkdir "$lock" 2>/dev/null; then _q_now > "$lock/ts" 2>/dev/null; return 0; fi
    fi
  else
    # No usable timestamp: treat as abandoned rather than block forever.
    rm -rf "$lock" 2>/dev/null || true
    if mkdir "$lock" 2>/dev/null; then _q_now > "$lock/ts" 2>/dev/null; return 0; fi
  fi
  return 1
}

q_unlock() { rm -rf "$1.lock" 2>/dev/null || true; }

q_enqueue() {
  local qf="$1" person="$2" desc="$3" wt="$4" task="$5" proj="$6" start="$7"
  mkdir -p "$(dirname "$qf")" 2>/dev/null || true
  local b64; b64=$(printf '%s' "$desc" | base64 | tr -d '\n')
  # A single short line appended with >> is atomic enough on the filesystems we use, but
  # take the lock when it is free so an append can never interleave with a flush rewrite.
  if q_lock "$qf"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t0\n' "$person" "$b64" "$wt" "$task" "$proj" "$start" >> "$qf"
    q_unlock "$qf"
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t0\n' "$person" "$b64" "$wt" "$task" "$proj" "$start" >> "$qf"
  fi
}

# q_flush <queuefile> <callback>
# Delivers each entry via the callback. Entries that fail are retried on later flushes
# until Q_MAX_ATTEMPTS, then moved to <queuefile>.dead so they stop blocking the queue.
# A failure no longer stops the run: every entry gets its own attempt each flush.
# Quarantine entries whose start time is older than Q_STALE_DAYS. A queue that has
# been stuck for weeks is not a backlog worth delivering: those entries are almost
# certainly in the database already, from earlier passes of the pre-fix flush, and
# re-delivering them just adds more copies. Joel's machine kept replaying the same
# ten 2026-07-13 and 07-15 entries every session for three weeks, which is what
# grew one entry to 122 copies. Nobody should have to know to go move a file, so
# the plugin retires the stale ones itself, into <queuefile>.stale for inspection.
Q_STALE_DAYS="${Q_STALE_DAYS:-3}"

q_quarantine_stale() {
  local qf="$1" cutoff keep stale line start ts moved=0
  [[ -f "$qf" ]] || return 0
  cutoff=$(( $(_q_now) - Q_STALE_DAYS * 86400 ))
  keep="$qf.keep"; stale="$qf.stale"
  : > "$keep"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    start="$(printf '%s' "$line" | cut -f6)"
    ts="$(date -u -d "$start" +%s 2>/dev/null)"
    if [[ -n "$ts" && "$ts" -lt "$cutoff" ]]; then
      printf '%s\n' "$line" >> "$stale"; moved=$((moved+1))
    else
      printf '%s\n' "$line" >> "$keep"
    fi
  done < "$qf"
  if (( moved > 0 )); then mv "$keep" "$qf"; else rm -f "$keep"; fi
  [[ -f "$qf" && ! -s "$qf" ]] && rm -f "$qf"
  return 0
}

q_flush() {
  local qf="$1" cb="$2"
  [[ -f "$qf" ]] || return 0
  # Only one flush at a time. If another holds the lock, do nothing; the next turn
  # flushes. Skipping is always safe because the queue is durable.
  q_lock "$qf" || return 0
  q_quarantine_stale "$qf"
  [[ -f "$qf" ]] || { q_unlock "$qf"; return 0; }
  local retry dead line person b64 wt task proj start attempts desc
  retry="$qf.retry"; dead="$qf.dead"
  rm -f "$retry" 2>/dev/null || true
  # COMMIT AFTER EACH ENTRY, never once at the end (defect fixed 2026-07-31,
  # re-fixed here after the batch rewrite came back). The old code wrote survivors
  # to a temp file and only ran mv after the loop, so when the hook hit its timeout
  # mid-loop the queue file was left untouched and every entry already delivered in
  # that pass was inserted again on the next pass. That is what inserted one of
  # Joel's 2026-07-15 entries 42 times and four of Barrett's 37 times each.
  # Here the delivered line is dropped from the live queue immediately, so a kill
  # can only ever lose the in-flight line, never replay a committed one.
  while [[ -s "$qf" ]]; do
    line="$(head -n 1 "$qf")"
    if [[ -z "$line" ]]; then
      tail -n +2 "$qf" > "$qf.tmp" 2>/dev/null && mv "$qf.tmp" "$qf"
      continue
    fi
    IFS=$'\t' read -r person b64 wt task proj start attempts <<< "$line"
    [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
    desc="$(printf '%s' "$b64" | base64 -d 2>/dev/null)"
    if "$cb" "$person" "$desc" "$wt" "$task" "$proj" "$start"; then
      tail -n +2 "$qf" > "$qf.tmp" 2>/dev/null && mv "$qf.tmp" "$qf"   # commit the delivery
    else
      attempts=$((attempts+1))
      # Park or retain FIRST, then drop from the live queue, so a kill between the
      # two can only duplicate a failed (undelivered) entry, never lose one.
      if (( attempts >= Q_MAX_ATTEMPTS )); then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$person" "$b64" "$wt" "$task" "$proj" "$start" "$attempts" >> "$dead"
      else
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$person" "$b64" "$wt" "$task" "$proj" "$start" "$attempts" >> "$retry"
      fi
      tail -n +2 "$qf" > "$qf.tmp" 2>/dev/null && mv "$qf.tmp" "$qf"
    fi
  done
  # Put the entries that failed this pass back, in their original order.
  if [[ -s "$retry" ]]; then
    if [[ -s "$qf" ]]; then cat "$qf" >> "$retry"; fi
    mv "$retry" "$qf"
  fi
  rm -f "$retry" 2>/dev/null || true
  [[ -f "$qf" && ! -s "$qf" ]] && rm -f "$qf"
  q_unlock "$qf"
  return 0
}
