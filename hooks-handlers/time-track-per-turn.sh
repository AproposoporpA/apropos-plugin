#!/usr/bin/env bash
# apropos plugin — UserPromptSubmit reliability hook.
# Always records (or durably queues) exactly one start-marker per turn.
# Credentialed write stays in R: Record-Time.ps1; this layer is local so it
# survives R:/network outages. Exits 0 always.
set +e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/queue.sh"
source "$HERE/lib/writer.sh"

TRACK_DIR="${APROPOS_TRACK_DIR:-/tmp/claude-timetrack}"
QUEUE="${HOME}/.claude/apropos-time/pending.tsv"
mkdir -p "$TRACK_DIR" "${HOME}/.claude/apropos-time" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

# Parse session id + cwd (prefer jq; grep fallback for session id).
if command -v jq >/dev/null 2>&1; then
  SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
  TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
else
  SID="$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')"
  CWD=""
  TRANSCRIPT=""
fi
SID="${SID:-${CLAUDE_CODE_SESSION_ID:-nosession}}"
TRANSCRIPT="${TRANSCRIPT//\\//}"   # normalize Windows backslashes for bash

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

# Description priority:
#   1. Model-written file (best — specific).
#   2. Last assistant message from the transcript — the real record of what was
#      just done (Claude always has this context, so entries are never "naked").
#   3. Project-tagged placeholder ONLY if the transcript can't be read.
# Never the raw prompt (that's the request, not the work). Trim to 500.
DESC=""
[[ -s "$descf" ]] && DESC="$(cat "$descf")"
if [[ -z "${DESC//[[:space:]]/}" ]]; then
  ctx=""
  if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] && command -v jq >/dev/null 2>&1; then
    ctx="$(tac "$TRANSCRIPT" 2>/dev/null | jq -rc 'select(.type=="assistant") | (.message.content // []) | map(select(.type=="text") | .text) | join(" ")' 2>/dev/null | grep -m1 .)"
    ctx="$(printf '%s' "$ctx" | tr '\n\t' '  ' | sed 's/  */ /g')"
  fi
  if [[ -n "${ctx// /}" ]]; then
    DESC="${ctx:0:255}"
  else
    proj="$(basename "$CWD" 2>/dev/null)"
    if [[ -n "$proj" && "$proj" != "." && "$proj" != "/" ]]; then
      DESC="[needs description] $proj"
    else
      DESC="[needs description]"
    fi
  fi
fi
# Strip AI-tell punctuation (em/en dashes -> hyphen, curly quotes -> straight,
# ellipsis -> ...) so entries never look machine-written.
DESC="$(printf '%s' "$DESC" | sed -e 's/\xe2\x80\x94/-/g' -e 's/\xe2\x80\x93/-/g' -e 's/\xe2\x80\xa6/.../g' -e 's/\xe2\x80\x9c/"/g' -e 's/\xe2\x80\x9d/"/g' -e "s/\xe2\x80\x98/'/g" -e "s/\xe2\x80\x99/'/g")"
DESC="${DESC:0:255}"   # Apropos varchar limit

# Worktype: numeric model file -> default 13.
WT="13"; [[ -s "$wtf" ]] && { v="$(tr -d '[:space:]' < "$wtf")"; [[ "$v" =~ ^[0-9]+$ ]] && WT="$v"; }

# Optional sticky task/project.
TASK="0"; [[ -s "$taskf" ]] && TASK="$(tr -d '[:space:]#' < "$taskf")"; [[ "$TASK" =~ ^[0-9]+$ ]] || TASK="0"
PROJ="0"; [[ -s "$projf" ]] && PROJ="$(tr -d '[:space:]' < "$projf")"; [[ "$PROJ" =~ ^[0-9]+$ ]] || PROJ="0"

SEG="$WT|$TASK|$PROJ"
NOW="$(date -u +%s)"
IDLE_GAP="${APROPOS_IDLE_GAP:-900}"   # seconds of silence that starts a new entry (15 min)

# Record ONE start-marker per contiguous work block. Fire a new entry when the
# segment changes (new worktype/task/project) or after an idle gap since the last
# turn; skip while the same work continues. Also skip an exact-duplicate
# description+segment. last-entry file: line1 "<last-turn-epoch>|<segment>",
# line2 "<description of the block's first entry>".
FIRE=1
LASTDESC=""
if [[ -f "$lastf" ]]; then
  l1="$(sed -n '1p' "$lastf")"; lt="${l1%%|*}"; lk="${l1#*|}"
  LASTDESC="$(sed -n '2p' "$lastf")"
  if [[ "$lk" == "$SEG" ]]; then
    if [[ "$lt" =~ ^[0-9]+$ && $((NOW - lt)) -lt $IDLE_GAP ]]; then
      FIRE=0                               # same work, still active -> continuous block
    fi
    [[ "$DESC" == "$LASTDESC" ]] && FIRE=0 # never repeat an identical entry
  fi
fi

# Consume one-shot model files regardless (rewritten next turn).
rm -f "$descf" "$wtf" 2>/dev/null || true

if [[ $FIRE -eq 1 ]]; then
  START="$(date -u -d '1 minute ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -v-1M '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  q_enqueue "$QUEUE" "$PERSON" "$DESC" "$WT" "$TASK" "$PROJ" "$START"
  printf '%s|%s\n%s\n' "$NOW" "$SEG" "$DESC" > "$lastf"
else
  # Same block, still active: refresh the activity time so the idle window
  # measures silence since the last turn; keep the block's original description.
  printf '%s|%s\n%s\n' "$NOW" "$SEG" "$LASTDESC" > "$lastf"
fi

# Always attempt to flush (delivers this entry and any prior queued ones).
q_flush "$QUEUE" write_entry
exit 0
