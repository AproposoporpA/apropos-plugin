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
  local qf="$1" cb="$2"
  [[ -f "$qf" ]] || return 0
  local tmp; tmp="$(mktemp)"
  local stopped=0
  while IFS=$'\t' read -r person b64 wt task proj start; do
    [[ -z "$person" ]] && continue
    if [[ $stopped -eq 1 ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$person" "$b64" "$wt" "$task" "$proj" "$start" >> "$tmp"
      continue
    fi
    local desc; desc="$(printf '%s' "$b64" | base64 -d 2>/dev/null)"
    if "$cb" "$person" "$desc" "$wt" "$task" "$proj" "$start"; then
      :   # delivered — drop
    else
      stopped=1
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$person" "$b64" "$wt" "$task" "$proj" "$start" >> "$tmp"
    fi
  done < "$qf"
  mv "$tmp" "$qf"
  [[ -s "$qf" ]] || rm -f "$qf"
  return 0
}
