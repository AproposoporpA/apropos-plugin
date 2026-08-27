#!/usr/bin/env bash
# The worktype must survive the turn (#30986).
#
# Before this, record_turn defaulted to 13 and then deleted worktype-$SID.txt at the end
# of every turn, while the task and project files were left in place. So a session that
# set its worktype once got Engineering on every turn after the first. Measured on
# Barrett's 2026-08-27: 14 entries carried the wrong worktype, including a MerchSource
# client email review booked as Engineering.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
HOOK="$DIR/hooks-handlers/time-track-per-turn.sh"
WORK="$(mktemp -d)"
export HOME="$WORK"
export APROPOS_WRITER="$DIR/tests/mocks/mock-writer.sh"
export WRITER_LOG="$WORK/writer.log"
export USERNAME="barrettgoldberg"
TT="$WORK/claude-timetrack"; mkdir -p "$TT"
export APROPOS_TRACK_DIR="$TT"
chmod +x "$DIR/tests/mocks/mock-writer.sh"

prompt(){ printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"%s","prompt":"go"}' "$1" "${2:-/home/b/projects/thing}" | bash "$HOOK"; }
stop(){ printf '{"hook_event_name":"Stop","session_id":"%s"}' "$1" | bash "$HOOK"; }
# turn <session> <desc> [worktype] — omit the worktype to simulate a turn that wrote none
turn(){
  prompt "$1"
  printf '%s' "$2" > "$TT/description-$1.txt"
  [[ -n "${3:-}" ]] && printf '%s' "$3" > "$TT/worktype-$1.txt"
  stop "$1"
}
# The field layout the mock writer logs is person|desc|worktype|task|project|start
wt_of(){ printf '%s' "$1" | awk -F'|' '{print $3}'; }

# 1. A worktype set once carries to the next turn that sets none.
: > "$WRITER_LOG"
printf '28765' > "$TT/task-s1.txt"
turn s1 "Answered the support request on the fill logic." 30
turn s1 "Placed the test order the customer asked for."
lines="$(grep -c . "$WRITER_LOG")"
assert_eq "2" "$lines" "both turns recorded"
second="$(tail -1 "$WRITER_LOG")"
assert_eq "30" "$(wt_of "$second")" "the worktype carried to the next turn ($(wt_of "$second"))"

# 2. An explicit worktype overrides for that turn, and then becomes the carried value.
#    On its own task, so it cannot disturb what case 3 reads back.
: > "$WRITER_LOG"
printf '30717' > "$TT/task-s1.txt"
turn s1 "Wrote the runbook for the cutover." 23
assert_eq "23" "$(wt_of "$(tail -1 "$WRITER_LOG")")" "an explicit worktype wins for its own turn"
: > "$WRITER_LOG"
turn s1 "Finished the runbook and filed it."
assert_eq "23" "$(wt_of "$(tail -1 "$WRITER_LOG")")" "the newest explicit worktype is the one carried"

# 3. A fresh session with no worktype of its own inherits the one last used on that task.
#    This is the case that produced the wrong worktypes: a new session on known work.
: > "$WRITER_LOG"
printf '28765' > "$TT/task-s2.txt"
turn s2 "Reviewed the latest request from the customer."
assert_eq "30" "$(wt_of "$(tail -1 "$WRITER_LOG")")" "a new session inherits the task's last worktype"

# 4. No worktype anywhere still records, at the documented default, and says so.
: > "$WRITER_LOG"
printf '29999' > "$TT/task-s3.txt"
OUT="$(turn s3 "Started on something with no history at all." 2>&1)"
assert_eq "13" "$(wt_of "$(tail -1 "$WRITER_LOG")")" "an unknown task falls back to the default"
assert_contains "$OUT" "worktype" "the fallback to the default is reported"

# 5. The carried worktype is per activity, not global: a different task keeps its own.
: > "$WRITER_LOG"
printf '30306' > "$TT/task-s4.txt"
turn s4 "Corrected the API documentation for the release." 23
printf '28765' > "$TT/task-s4.txt"
turn s4 "Back on the customer request."
assert_eq "30" "$(wt_of "$(tail -1 "$WRITER_LOG")")" "switching task picks up that task's worktype, not the last one used"

finish
