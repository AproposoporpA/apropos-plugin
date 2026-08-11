#!/usr/bin/env bash
# apropos plugin — per-turn time recording hook. Handles TWO events:
#
#   UserPromptSubmit — stamps the turn's real start time, flushes the queue, and
#                      recovers a description that Stop failed to consume.
#   Stop             — the primary recorder. Runs after the response is complete,
#                      so the model's description for THIS turn already exists.
#
# Always records (or durably queues) exactly one start-marker per turn.
# Credentialed write stays in R: Record-Time.ps1; this layer is local so it
# survives R:/network outages. Exits 0 always.
#
# WHY TWO EVENTS (changed 2026-08-07). The hook previously ran on UserPromptSubmit
# only, which fires at the START of a turn and therefore read the description file
# written at the END of the previous turn. Three consequences, all measured on
# Barrett's machine (person 276) on 2026-08-07:
#   1. Turn 1 of every session had no description file yet, so it recorded the
#      placeholder "[needs description] <cwd basename>". With cwd
#      "R:\Barrett Goldberg\Claude" that literal string was "[needs description]
#      Claude", putting an AI reference on a client-invoice-facing field. 13 of
#      that day's 39 entries.
#   2. The final turn of every session was never recorded, because no further
#      prompt ever arrived to consume its file. 7 orphaned description files were
#      sitting in /tmp/claude-timetrack at worktypes 18, 48, 57 and 86 with zero
#      entries at any of those worktypes in the database.
#   3. Every description that did land was stamped with the NEXT turn's start time.
# Recording on Stop fixes all three: the description is the current turn's, the
# final turn fires, and StartTime comes from the stamp laid down at prompt time.
set +e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/queue.sh"
source "$HERE/lib/writer.sh"

TRACK_DIR="${APROPOS_TRACK_DIR:-/tmp/claude-timetrack}"
QUEUE="${HOME}/.claude/apropos-time/pending.tsv"
mkdir -p "$TRACK_DIR" "${HOME}/.claude/apropos-time" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

# Parse session id + cwd + event (prefer jq; grep fallback).
if command -v jq >/dev/null 2>&1; then
  SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
  EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)"
else
  SID="$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')"
  CWD="$(printf '%s' "$INPUT" | grep -o '"cwd":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')"
  EVENT="$(printf '%s' "$INPUT" | grep -o '"hook_event_name":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')"
fi
SID="${SID:-${CLAUDE_CODE_SESSION_ID:-nosession}}"
# Older payloads / direct invocation carry no event name. Treat as UserPromptSubmit
# so an un-migrated hooks.json keeps the previous single-event behaviour.
EVENT="${EVENT:-UserPromptSubmit}"

# Opt out of time recording entirely. Scheduled and headless runs are nobody's
# working time: a `claude -p` job fired by Task Scheduler has no human at the keyboard
# and never writes a description file, so every one of them booked a
# "[needs description] <cwd>" placeholder against Barrett. Over the 2026-08-08 weekend
# that was 7 scheduled runs, which the queue defect then multiplied into 239 rows.
#
# Two ways to opt out, because the launchers and the agent directories are maintained
# by different people:
#   APROPOS_TIME_TRACKING=off   (or APROPOS_SKIP=1) in the scheduled launcher's env
#   a .apropos-notime file in the working directory, which covers that agent however
#   it is started, including a manual run
case "$(printf '%s' "${APROPOS_TIME_TRACKING:-}" | tr '[:upper:]' '[:lower:]')" in
  off|0|false|no|disabled) exit 0 ;;
esac
case "$(printf '%s' "${APROPOS_SKIP:-}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) exit 0 ;;
esac
# Stamp the working directory before the marker check, not after. The Stop payload
# carries no cwd, so without this an opted-out session would exit at UserPromptSubmit
# having recorded nothing, and then Stop would have no cwd to test the marker against
# and would record anyway.
[[ -n "$CWD" ]] && printf '%s' "$CWD" > "$TRACK_DIR/cwd-$SID.txt" 2>/dev/null
_optout_dir="$CWD"; [[ -z "$_optout_dir" && -s "$TRACK_DIR/cwd-$SID.txt" ]] && _optout_dir="$(cat "$TRACK_DIR/cwd-$SID.txt")"
if [[ -n "$_optout_dir" ]]; then
  _d="${_optout_dir//\\//}"
  # Walk up from the working directory so a marker at an agent root covers its subdirs.
  while [[ -n "$_d" && "$_d" != "/" && "$_d" != "." ]]; do
    if [[ -e "$_d/.apropos-notime" ]]; then exit 0; fi
    _parent="$(dirname "$_d")"; [[ "$_parent" == "$_d" ]] && break; _d="$_parent"
  done
fi

# Person resolution (cannot record without it — not a transient failure).
u="$(printf '%s' "${USERNAME:-${USER:-}}" | tr '[:upper:]' '[:lower:]')"
case "$u" in
  ericbarone) PERSON=321 ;; joelperez) PERSON=344 ;;
  barrettgoldberg) PERSON=276 ;; calebbarone) PERSON=1298 ;;
  *) exit 0 ;;
esac

descf="$TRACK_DIR/description-$SID.txt"
wtf="$TRACK_DIR/worktype-$SID.txt"
taskf="$TRACK_DIR/task-$SID.txt"
projf="$TRACK_DIR/project-$SID.txt"
lastf="$TRACK_DIR/last-entry-$SID.txt"
startf="$TRACK_DIR/turnstart-$SID.txt"
cwdf="$TRACK_DIR/cwd-$SID.txt"

NOW="$(date -u +%s)"

# Description cap. The DB column is nvarchar(500) but the downstream Intervals
# import truncates at 255, which was cutting real entries mid-sentence with no
# signal. Cap here so the boundary is visible and consistent.
DESC_MAX=255

_hash() {
  # Short fingerprint of the description, so dedup can tell "same activity
  # re-marked" from "new work at the same worktype/task".
  if command -v md5sum >/dev/null 2>&1; then printf '%s' "$1" | md5sum | cut -c1-10
  elif command -v cksum >/dev/null 2>&1; then printf '%s' "$1" | cksum | tr -d ' '
  else printf '%s' "${#1}"; fi
}

# Cap how far back a turn-start stamp may drag an entry. The stamp is written at
# UserPromptSubmit and consumed when the response ends, so a session left idle keeps a
# stale stamp: observed 2026-08-11, work done at 07:13 PT was stamped 21:06 PT the
# previous evening, a 607-minute backdate that moved it onto the wrong day. Beyond this
# window the stamp is not a credible start time, so fall back to now-60s.
APROPOS_MAX_BACKDATE_SECS="${APROPOS_MAX_BACKDATE_SECS:-7200}"

# start_from_stamp <stampfile> -> echoes a UTC "YYYY-MM-DD HH:MM:SS"
start_from_stamp() {
  local f="$1" ts age
  if [[ -s "$f" ]]; then
    ts="$(tr -d '[:space:]' < "$f")"
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
      age=$(( NOW - ts ))
      if (( age >= 0 && age <= APROPOS_MAX_BACKDATE_SECS )); then
        date -u -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
        return 0
      fi
    fi
  fi
  date -u -d '1 minute ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -v-1M '+%Y-%m-%d %H:%M:%S' 2>/dev/null
}

record_turn() {
  # $1 = start time as UTC "YYYY-MM-DD HH:MM:SS"
  local START="$1"

  # Description: model-written file is the good path. If absent, use a uniformly
  # FLAGGED, project-tagged placeholder — filterable + carries context — never the
  # raw prompt (which describes the request, not the work done).
  local DESC=""
  [[ -s "$descf" ]] && DESC="$(cat "$descf")"
  if [[ -z "${DESC//[[:space:]]/}" ]]; then
    local basecwd="$CWD"
    [[ -z "$basecwd" && -s "$cwdf" ]] && basecwd="$(cat "$cwdf")"
    local proj; proj="$(basename "$basecwd" 2>/dev/null)"
    if [[ -n "$proj" && "$proj" != "." && "$proj" != "/" ]]; then
      DESC="[needs description] $proj"
    else
      DESC="[needs description]"
    fi
  fi
  DESC="${DESC:0:$DESC_MAX}"

  # Worktype: numeric model file -> default 13.
  local WT="13"
  [[ -s "$wtf" ]] && { local v; v="$(tr -d '[:space:]' < "$wtf")"; [[ "$v" =~ ^[0-9]+$ ]] && WT="$v"; }

  # Optional sticky task/project.
  local TASK="0"; [[ -s "$taskf" ]] && TASK="$(tr -d '[:space:]#' < "$taskf")"; [[ "$TASK" =~ ^[0-9]+$ ]] || TASK="0"
  local PROJ="0"; [[ -s "$projf" ]] && PROJ="$(tr -d '[:space:]' < "$projf")"; [[ "$PROJ" =~ ^[0-9]+$ ]] || PROJ="0"

  # Dedup key now includes the description fingerprint. Previously the key was
  # worktype|task|project only, so two consecutive turns of different work on the
  # same task deduped — and because the file deletion below used to run
  # unconditionally, the second turn's real description was DELETED rather than
  # merely left unmarked. The plugin spec (§5.1) says dedup is "de-duplicate only,
  # never a reason to record nothing"; keying on the description honours that.
  local SEG="$WT|$TASK|$PROJ|$(_hash "$DESC")"
  local DEDUP=0
  if [[ -f "$lastf" ]]; then
    local line lt lk
    line="$(head -1 "$lastf")"; lt="${line%%|*}"; lk="${line#*|}"
    if [[ "$lt" =~ ^[0-9]+$ && "$lk" == "$SEG" && $((NOW - lt)) -lt 900 ]]; then DEDUP=1; fi
  fi

  if [[ $DEDUP -eq 0 ]]; then
    q_enqueue "$QUEUE" "$PERSON" "$DESC" "$WT" "$TASK" "$PROJ" "$START"
    printf '%s|%s\n' "$NOW" "$SEG" > "$lastf"
  fi

  # Consume the one-shot model files. Safe here because this line is reached only
  # after the entry was enqueued, or after it was confirmed a true duplicate
  # (identical description AND segment within 15 min). Nothing unrecorded is lost.
  rm -f "$descf" "$wtf" 2>/dev/null || true
}

case "$EVENT" in
  Stop)
    # Primary recorder. Use the start time stamped when the prompt came in, so the
    # marker sits at the real beginning of the work rather than at its end.
    START="$(start_from_stamp "$startf")"
    record_turn "$START"
    rm -f "$startf" 2>/dev/null || true
    ;;
  *)
    # UserPromptSubmit. Recovery first: a leftover description file means Stop did
    # not run for the previous turn (crash, kill, Stop not registered). Record it
    # with that turn's stamped start so the work is not lost.
    if [[ -s "$descf" ]]; then
      record_turn "$(start_from_stamp "$startf")"
    fi
    # Stamp this turn's start for the Stop hook to use.
    printf '%s' "$NOW" > "$startf"
    [[ -n "$CWD" ]] && printf '%s' "$CWD" > "$cwdf"
    ;;
esac

# Always attempt to flush (delivers this entry and any prior queued ones).
q_flush "$QUEUE" write_entry
exit 0
