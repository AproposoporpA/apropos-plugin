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
# Cases 6 and 7 exercise the shared task map directly, so source the helpers.
source "$DIR/hooks-handlers/lib/queue.sh"
taskwtf="$TT/task-worktype.tsv"
eval "$(sed -n '/^task_wt_record()/,/^}/p;/^_tw_lock()/,/^}/p' "$DIR/hooks-handlers/time-track-per-turn.sh")"

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


# 6. REGRESSION (QA #30986, 2026-08-28): concurrent writers must not lose the map.
#    The first version called q_lock once and gave up silently, keeping only 2 or 3 of
#    20 writes. Under six to eight concurrent sessions that silently defeats case 3:
#    the next session finds no history and falls back to Engineering.
rm -f "$TT/task-worktype.tsv"
( for i in $(seq 1 20); do ( task_wt_record "$((31000+i))" "$((30+i))" ) & done; wait ) 2>/dev/null
kept="$(grep -c . "$TT/task-worktype.tsv" 2>/dev/null || echo 0)"
assert_eq "20" "$kept" "20 concurrent writers on distinct tasks all kept ($kept survived)"

# 7. The bare default is never recorded as though it were an established category.
rm -f "$TT/task-worktype.tsv"
: > "$WRITER_LOG"
printf '39999' > "$TT/task-s9.txt"
turn s9 "Started on something with no worktype and no history whatsoever."
if grep -q '^39999' "$TT/task-worktype.tsv" 2>/dev/null; then
  echo "  FAIL: the bare default was pinned into the task map"; _TEST_FAILS=$((_TEST_FAILS+1))
else
  pass "the bare default is not recorded as an established category"
fi

finish
