#!/usr/bin/env bash
# Durable local time-entry queue. TSV lines:
#   person <TAB> descB64 <TAB> worktype <TAB> task <TAB> project <TAB> startUtc
# Description is base64-encoded so it may contain tabs/newlines/quotes safely.

q_enqueue() {
  local qf="$1" person="$2" desc="$3" wt="$4" task="$5" proj="$6" start="$7"
  mkdir -p "$(dirname "$qf")" 2>/dev/null || true
  local b64; b64=$(printf '%s' "$desc" | base64 | tr -d '\n')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$person" "$b64" "$wt" "$task" "$proj" "$start" >> "$qf"
}

q_flush() {
  # $1 queuefile, $2 write callback, $3 optional max deliveries per call (0 = unlimited).
  # CRASH-SAFE: each entry is removed from the queue the instant its insert
  # succeeds, so a process killed mid-flush can never re-insert an already
  # committed row. The old code rewrote the queue only at the end, so a timeout
  # kill before that rewrite left committed rows queued and they were re-inserted
  # on the next run (the duplicate-billing defect). Stops at the first failure
  # and leaves that entry and the rest queued, in order.
  local qf="$1" cb="$2" maxn="${3:-0}"
  [[ -f "$qf" ]] || return 0
  local delivered=0
  while [[ -s "$qf" ]]; do
    local line; line="$(head -n 1 "$qf")"
    if [[ -z "$line" ]]; then
      tail -n +2 "$qf" > "$qf.tmp" 2>/dev/null && mv "$qf.tmp" "$qf"
      continue
    fi
    local person b64 wt task proj start
    IFS=$'\t' read -r person b64 wt task proj start <<< "$line"
    local desc; desc="$(printf '%s' "$b64" | base64 -d 2>/dev/null)"
    if "$cb" "$person" "$desc" "$wt" "$task" "$proj" "$start"; then
      tail -n +2 "$qf" > "$qf.tmp" 2>/dev/null && mv "$qf.tmp" "$qf"   # drop delivered row immediately
      delivered=$((delivered+1))
      [[ $maxn -gt 0 && $delivered -ge $maxn ]] && break
    else
      break
    fi
  done
  [[ -f "$qf" && ! -s "$qf" ]] && rm -f "$qf"
  return 0
}
