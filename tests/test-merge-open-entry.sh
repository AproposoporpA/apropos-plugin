#!/usr/bin/env bash
# One open entry per activity, shared across sessions.
#
# Added 2026-08-13. The hook recorded a row per turn: 321 rows over four days on
# Barrett's machine, 185 of 320 under five minutes, 20 of zero length. A turn that
# continues an activity already open now amends that entry instead of inserting beside
# it, and the open entries are shared across sessions because he runs six to eight at
# once and per-session state never merges when two sessions alternate.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
HOOK="$DIR/hooks-handlers/time-track-per-turn.sh"
WORK="$(mktemp -d)"
export HOME="$WORK"
export APROPOS_WRITER="$WORK/mock-writer.sh"
export APROPOS_AMENDER="$WORK/mock-amender.sh"
export WRITER_LOG="$WORK/writer.log"
export AMEND_LOG="$WORK/amend.log"
export APROPOS_OPEN_FILE="$WORK/open-entries.tsv"
export USERNAME="ericbarone"
TT="$WORK/claude-timetrack"; mkdir -p "$TT"
export APROPOS_TRACK_DIR="$TT"

# Mock insert: logs, then reports an id the way Record-Time.ps1 does, so the real
# oe_record path in writer.sh is exercised rather than stubbed.
cat > "$APROPOS_WRITER" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$WRITER_LOG"
n=$(( $(wc -l < "$WRITER_LOG") + 1000 ))
if [[ -n "$4" && "$4" != "0" ]]; then
  printf '%s\t%s\t%s\n' "$3|$4|$5" "$n" "$(date -u +%s)" >> "$APROPOS_OPEN_FILE"
fi
exit 0
EOF
cat > "$APROPOS_AMENDER" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$3" >> "$AMEND_LOG"
exit 0
EOF
chmod +x "$APROPOS_WRITER" "$APROPOS_AMENDER"

prompt(){ printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"/home/eric/p","prompt":"go"}' "$1" | bash "$HOOK"; }
stop(){ printf '{"hook_event_name":"Stop","session_id":"%s"}' "$1" | bash "$HOOK"; }
turn(){ prompt "$1"; printf '%s' "$2" > "$TT/description-$1.txt"; printf '%s' "$3" > "$TT/worktype-$1.txt"; printf '%s' "$4" > "$TT/task-$1.txt"; stop "$1"; }

# 1. Two turns on the same activity: one insert, one amend.
turn s1 'First piece of work' 13 28682
turn s1 'Second piece of the same work' 13 28682
assert_eq "1" "$(wc -l < "$WRITER_LOG" | tr -d ' ')" "same activity inserts once"
assert_eq "1" "$(wc -l < "$AMEND_LOG" | tr -d ' ')" "the second turn amends instead"
assert_contains "$(cat "$AMEND_LOG")" "Second piece of the same work" "the amend carries the newer description"

# 2. A different activity opens its own entry.
turn s1 'Work on another task' 13 30103
assert_eq "2" "$(wc -l < "$WRITER_LOG" | tr -d ' ')" "a new activity inserts"

# 3. Back to the first activity: amends the entry still open for it, does not insert.
turn s1 'More of the first task' 13 28682
assert_eq "2" "$(wc -l < "$WRITER_LOG" | tr -d ' ')" "returning to an open activity does not insert"
assert_eq "2" "$(wc -l < "$AMEND_LOG" | tr -d ' ')" "returning to an open activity amends"

# 4. THE CASE THAT PER-SESSION STATE CANNOT HANDLE. Two sessions alternating on two
#    tasks. Each turn continues an activity already open, so nothing new is inserted.
rm -f "$WRITER_LOG" "$AMEND_LOG"
turn s2 'Session two, task A' 13 29802
turn s3 'Session three, task B' 13 29803
before="$(wc -l < "$WRITER_LOG" | tr -d ' ')"
turn s2 'Session two again, task A' 13 29802
turn s3 'Session three again, task B' 13 29803
assert_eq "$before" "$(wc -l < "$WRITER_LOG" | tr -d ' ')" "alternating sessions do not each open a new entry"
assert_eq "2" "$(wc -l < "$AMEND_LOG" | tr -d ' ')" "both alternating sessions amend their own activity"

# 5. An unattributed turn is never merged; it cannot be amended without losing its task.
rm -f "$WRITER_LOG" "$AMEND_LOG" "$APROPOS_OPEN_FILE"
turn s4 'No task on this one' 13 0
turn s4 'Still no task' 13 0
assert_eq "2" "$(wc -l < "$WRITER_LOG" | tr -d ' ')" "no-task turns still insert every time"
assert_eq "0" "$(cat "$AMEND_LOG" 2>/dev/null | wc -l | tr -d ' ')" "no-task turns are never amended"

# 6. Past the window a fresh entry opens, so one row cannot absorb a whole day.
rm -f "$WRITER_LOG" "$AMEND_LOG" "$APROPOS_OPEN_FILE"
export APROPOS_MERGE_MAX_SECS=1
turn s5 'Inside the window' 13 28682
sleep 2
turn s5 'After the window' 13 28682
assert_eq "2" "$(wc -l < "$WRITER_LOG" | tr -d ' ')" "an aged-out entry is not amended, a new one opens"
unset APROPOS_MERGE_MAX_SECS

# 7. The switch restores a row per turn.
rm -f "$WRITER_LOG" "$AMEND_LOG" "$APROPOS_OPEN_FILE"
export APROPOS_MERGE=off
turn s6 'One' 13 28682
turn s6 'Two' 13 28682
assert_eq "2" "$(wc -l < "$WRITER_LOG" | tr -d ' ')" "APROPOS_MERGE=off inserts per turn"
assert_eq "0" "$(cat "$AMEND_LOG" 2>/dev/null | wc -l | tr -d ' ')" "APROPOS_MERGE=off never amends"
unset APROPOS_MERGE

finish
