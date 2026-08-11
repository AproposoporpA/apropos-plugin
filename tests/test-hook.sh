#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
HOOK="$DIR/hooks-handlers/time-track-per-turn.sh"
WORK="$(mktemp -d)"
export HOME="$WORK"                 # queue lands in $HOME/.claude/apropos-time
export APROPOS_WRITER="$DIR/tests/mocks/mock-writer.sh"
export WRITER_LOG="$WORK/writer.log"
export WRITER_FAIL="$WORK/FAIL"
export USERNAME="ericbarone"
TT="$WORK/claude-timetrack"; mkdir -p "$TT"
export APROPOS_TRACK_DIR="$TT"
chmod +x "$DIR/tests/mocks/mock-writer.sh"

# prompt <session> [cwd]  — simulate UserPromptSubmit
prompt(){ printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"%s","prompt":"go"}' "$1" "${2:-/home/eric/projects/apropos-plugin}" | bash "$HOOK"; }
# stop <session>          — simulate Stop (end of the assistant response)
stop(){ printf '{"hook_event_name":"Stop","session_id":"%s"}' "$1" | bash "$HOOK"; }
# turn <session> <desc> <wt> — a complete turn: prompt, model writes files, response ends
turn(){ prompt "$1"; printf '%s' "$2" > "$TT/description-$1.txt"; printf '%s' "$3" > "$TT/worktype-$1.txt"; stop "$1"; }

# 1. A turn where the model wrote nothing -> flagged, project-tagged placeholder at 13
prompt s1; stop s1
L="$(cat "$WRITER_LOG" 2>/dev/null)"
assert_contains "$L" "321|[needs description] apropos-plugin|13|" "fallback uses flagged placeholder + project"
assert_not_contains "$L" "|go|" "raw prompt is NOT used as description"

# 2. Model files are used
rm -f "$WRITER_LOG"
turn s2 'Refactored auth module' 50
assert_contains "$(cat "$WRITER_LOG")" "321|Refactored auth module|50|" "model files used over prompt"

# 3. REGRESSION (2026-08-07): the FIRST turn of a session must not be a placeholder.
#    The hook used to read the description at UserPromptSubmit, before the model had
#    written one, so every session's opening turn recorded "[needs description] <cwd>".
rm -f "$WRITER_LOG"
turn s3 'Diagnosed the nightly inventory rejection' 13
assert_not_contains "$(cat "$WRITER_LOG")" "needs description" "first turn of a session is not a placeholder"
assert_contains "$(cat "$WRITER_LOG")" "Diagnosed the nightly inventory rejection" "first turn records its own description"

# 4. REGRESSION (2026-08-07): consecutive turns at the SAME worktype/task must each
#    record. The old dedup key was worktype|task|project only, and the file deletion
#    ran unconditionally, so turn 2's real description was deleted, never recorded.
rm -f "$WRITER_LOG"
turn s4 'First piece of work' 13
turn s4 'Second, different piece of work' 13
assert_eq "2" "$(grep -c '321|' "$WRITER_LOG")" "two different descriptions at the same worktype both record"
assert_contains "$(cat "$WRITER_LOG")" "Second, different piece of work" "second description is not silently dropped"

# 5. Dedup still suppresses a genuine repeat (identical description AND segment)
rm -f "$WRITER_LOG"
turn s5 'seg work' 13
turn s5 'seg work' 13
assert_eq "1" "$(grep -c '321|' "$WRITER_LOG")" "identical description at same segment records once"

# 6. REGRESSION (2026-08-07): the LAST turn of a session must be recorded. Under the
#    old UserPromptSubmit-only design nothing consumed it, so it was silently dropped.
rm -f "$WRITER_LOG"
turn s6 'Final turn of the session' 23
assert_contains "$(cat "$WRITER_LOG")" "Final turn of the session" "final turn is recorded without a following prompt"

# 7. StartTime is the turn's real start, not the moment the response ended
rm -f "$WRITER_LOG"
prompt s7
printf '%s' "$(( $(date -u +%s) - 600 ))" > "$TT/turnstart-s7.txt"   # pretend the turn began 10 min ago
printf 'Long running turn' > "$TT/description-s7.txt"; printf '13' > "$TT/worktype-s7.txt"
stop s7
STARTED="$(awk -F'|' '{print $6}' "$WRITER_LOG" | tail -1)"
EXPECT="$(date -u -d '10 minutes ago' '+%Y-%m-%d %H:%M' 2>/dev/null || date -u -v-10M '+%Y-%m-%d %H:%M')"
assert_contains "$STARTED" "$EXPECT" "start marker uses the stamped turn start, not the response end"

# 8. Recovery: Stop never fires (crash / Stop not registered) -> next prompt records it
rm -f "$WRITER_LOG"
prompt s8
printf 'Work from a turn whose Stop never fired' > "$TT/description-s8.txt"; printf '92' > "$TT/worktype-s8.txt"
prompt s8    # no stop() in between
assert_contains "$(cat "$WRITER_LOG")" "Work from a turn whose Stop never fired" "orphaned description recovered on next prompt"

# 9. Description is capped at 255 (the downstream Intervals import limit)
rm -f "$WRITER_LOG"
LONG="$(printf 'x%.0s' $(seq 1 400))"
turn s9 "$LONG" 13
GOT="$(awk -F'|' '{print $2}' "$WRITER_LOG" | tail -1)"
assert_eq "255" "${#GOT}" "description truncated to 255 chars"

# 10. Sticky task is attached
rm -f "$WRITER_LOG"
printf '28682' > "$TT/task-s10.txt"
turn s10 'Internal process work' 59
assert_contains "$(cat "$WRITER_LOG")" "|59|28682|" "sticky task id is attached to the entry"

# 11. Write failure -> queued; next turn (writer restored) -> both delivered
rm -f "$WRITER_LOG"; touch "$WRITER_FAIL"
turn s11 'will fail then queue' 92
[[ -f "$HOME/.claude/apropos-time/pending.tsv" ]] && pass "failed write queued locally" || { echo "  FAIL: not queued"; _TEST_FAILS=$((_TEST_FAILS+1)); }
rm -f "$WRITER_FAIL"; rm -f "$WRITER_LOG"
turn s11 'next turn' 23
assert_contains "$(cat "$WRITER_LOG")" "will fail then queue" "queued entry flushed on recovery"
[[ ! -f "$HOME/.claude/apropos-time/pending.tsv" ]] && pass "queue drained after recovery" || { echo "  FAIL: queue not drained"; _TEST_FAILS=$((_TEST_FAILS+1)); }

# 12. Unknown user -> nothing recorded, exit 0
rm -f "$WRITER_LOG"; export USERNAME="stranger"
prompt s12; RC=$?
assert_eq "0" "$RC" "hook exits 0 for unknown user"
[[ ! -f "$WRITER_LOG" ]] && pass "unknown user records nothing" || { echo "  FAIL: recorded for unknown"; _TEST_FAILS=$((_TEST_FAILS+1)); }

# 13. Backwards compatibility: no hook_event_name (un-migrated hooks.json) still works
export USERNAME="ericbarone"
rm -f "$WRITER_LOG"
printf '{"session_id":"s13","cwd":"/home/eric/projects/apropos-plugin","prompt":"go"}' | bash "$HOOK"
printf 'Work recorded the old way' > "$TT/description-s13.txt"; printf '13' > "$TT/worktype-s13.txt"
printf '{"session_id":"s13","cwd":"/home/eric/projects/apropos-plugin","prompt":"go"}' | bash "$HOOK"
assert_contains "$(cat "$WRITER_LOG")" "Work recorded the old way" "eventless payload falls back to prompt-time recording"

# ---------------------------------------------------------------------------
# REGRESSION (2026-08-10): scheduled and headless runs must record nothing.
# Every `claude -p` job fired by Task Scheduler used to book a
# "[needs description] <cwd>" placeholder against the person who owns the machine.
# ---------------------------------------------------------------------------
export USERNAME="ericbarone"
rm -f "$WRITER_LOG"
APROPOS_TIME_TRACKING=off prompt s20
APROPOS_TIME_TRACKING=off stop s20
[[ ! -f "$WRITER_LOG" ]] && pass "APROPOS_TIME_TRACKING=off records nothing" || { echo "  FAIL: recorded despite opt-out"; _TEST_FAILS=$((_TEST_FAILS+1)); }

rm -f "$WRITER_LOG"
APROPOS_SKIP=1 prompt s21
APROPOS_SKIP=1 stop s21
[[ ! -f "$WRITER_LOG" ]] && pass "APROPOS_SKIP=1 records nothing" || { echo "  FAIL: recorded despite APROPOS_SKIP"; _TEST_FAILS=$((_TEST_FAILS+1)); }

# .apropos-notime marker in the working directory
rm -f "$WRITER_LOG"
AGENTDIR="$WORK/agents/onboarding-status"; mkdir -p "$AGENTDIR/sub"; touch "$AGENTDIR/.apropos-notime"
prompt s22 "$AGENTDIR"; stop s22
[[ ! -f "$WRITER_LOG" ]] && pass ".apropos-notime marker records nothing" || { echo "  FAIL: recorded despite marker"; _TEST_FAILS=$((_TEST_FAILS+1)); }

# the marker covers subdirectories of the agent root
rm -f "$WRITER_LOG"
prompt s23 "$AGENTDIR/sub"; stop s23
[[ ! -f "$WRITER_LOG" ]] && pass "marker at agent root covers subdirectories" || { echo "  FAIL: subdir not covered"; _TEST_FAILS=$((_TEST_FAILS+1)); }

# a normal interactive session in a directory with no marker still records
rm -f "$WRITER_LOG"
turn s24 'Ordinary interactive work' 13
assert_contains "$(cat "$WRITER_LOG")" "Ordinary interactive work" "opt-out does not suppress normal sessions"

# REGRESSION (2026-08-11): a stale turn-start stamp must not drag an entry backwards.
# A session left idle overnight kept its stamp, so work done at 07:13 PT was recorded
# with a start of 21:06 PT the previous evening, landing it on the wrong day.
rm -f "$WRITER_LOG"
prompt s30
printf '%s' "$(( $(date -u +%s) - 36000 ))" > "$TT/turnstart-s30.txt"   # stamp 10 hours old
printf 'Work done just now' > "$TT/description-s30.txt"; printf '13' > "$TT/worktype-s30.txt"
stop s30
GOT="$(awk -F'|' '{print $6}' "$WRITER_LOG" | tail -1)"
NOWISH="$(date -u -d '1 minute ago' '+%Y-%m-%d %H:%M' 2>/dev/null || date -u -v-1M '+%Y-%m-%d %H:%M')"
assert_contains "$GOT" "$NOWISH" "stale stamp (10h) is ignored, start falls back to now"

# ...but a stamp inside the window is still honoured.
rm -f "$WRITER_LOG"
prompt s31
printf '%s' "$(( $(date -u +%s) - 1800 ))" > "$TT/turnstart-s31.txt"    # 30 min old
printf 'Half hour turn' > "$TT/description-s31.txt"; printf '13' > "$TT/worktype-s31.txt"
stop s31
GOT="$(awk -F'|' '{print $6}' "$WRITER_LOG" | tail -1)"
EXP="$(date -u -d '30 minutes ago' '+%Y-%m-%d %H:%M' 2>/dev/null || date -u -v-30M '+%Y-%m-%d %H:%M')"
assert_contains "$GOT" "$EXP" "stamp within the window is still used"

rm -rf "$WORK"
finish
