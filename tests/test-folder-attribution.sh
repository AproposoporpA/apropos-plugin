#!/usr/bin/env bash
# Client work must reach the client, without the session having to remember (#30989).
#
# The recorder keys attribution on task-$SID.txt, which the session has to write. When it
# does not, TASK stays "0", the writer applies the person's fallback task, and nothing says
# so. On 2026-08-27 that took 28 of 40 entries and 3.33 of 5.08 hours onto Barrett's
# catch-all, including a customer go-live confirmation and a client dashboard republish. The
# information was available every time, because the work was happening inside the client's
# own folder.
#
# So a folder carries its own attribution, in .apropos-task and .apropos-project, and it
# inherits down to every subfolder. A session that states its own task still wins. Where
# neither exists the catch-all is still used, but it announces itself.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
HOOK="$DIR/hooks-handlers/time-track-per-turn.sh"
WORK="$(mktemp -d)"
export HOME="$WORK"
export APROPOS_WRITER="$WORK/mock-writer.sh"
export WRITER_LOG="$WORK/writer.log"
export APROPOS_OPEN_FILE="$WORK/open-entries.tsv"
export USERNAME="barrettgoldberg"
TT="$WORK/claude-timetrack"; mkdir -p "$TT"
export APROPOS_TRACK_DIR="$TT"

cat > "$APROPOS_WRITER" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$WRITER_LOG"
exit 0
EOF
chmod +x "$APROPOS_WRITER"

# A client tree: the marker sits at the client root, the work happens two levels down.
CLIENT="$WORK/clients/faoschwarz"
mkdir -p "$CLIENT/theme/sections"
printf '26137\n' > "$CLIENT/.apropos-task"

prompt(){ printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"%s","prompt":"go"}' "$1" "$2" | bash "$HOOK" 2>/dev/null; }
stop(){ printf '{"hook_event_name":"Stop","session_id":"%s"}' "$1" | bash "$HOOK" 2>"$WORK/stderr-$1.txt"; }
# turn <session> <cwd> <description>
turn(){ prompt "$1" "$2"; printf '%s' "$3" > "$TT/description-$1.txt"; printf '13' > "$TT/worktype-$1.txt"; stop "$1"; }
task_of(){ awk -F'|' '{print $4}' "$WRITER_LOG" | tail -1; }
proj_of(){ awk -F'|' '{print $5}' "$WRITER_LOG" | tail -1; }

# Each block clears the shared open-entry map as well as the writer log. Blocks 1 and 7
# use the same activity key, and a claim left in that map by the first makes the second
# wait 25 seconds on an id the mock writer never resolves. QA caught this: the file took
# 40 seconds for 17 assertions that touch nothing but local files. (#30989 QA round 1)
# 1. Work in a SUBFOLDER of a folder carrying a task marker records against that task.
: > "$WRITER_LOG"; rm -f "$APROPOS_OPEN_FILE"
turn f1 "$CLIENT/theme/sections" "Corrected the collection template and verified it on staging."
assert_eq "26137" "$(task_of)" "a subfolder inherits the task marker from the client root"

# 2. A session that states its own task wins over the folder marker.
: > "$WRITER_LOG"; rm -f "$APROPOS_OPEN_FILE"
prompt f2 "$CLIENT/theme/sections"
printf 'Reviewed the release notes for the upcoming version.' > "$TT/description-f2.txt"
printf '23'    > "$TT/worktype-f2.txt"
printf '30717' > "$TT/task-f2.txt"
stop f2
assert_eq "30717" "$(task_of)" "a session-stated task beats the folder marker"

# 3. No marker anywhere and no stated task still records, and says the catch-all was used.
: > "$WRITER_LOG"; rm -f "$APROPOS_OPEN_FILE"
NOMARK="$WORK/scratch/somewhere"; mkdir -p "$NOMARK"
turn f3 "$NOMARK" "Read through the backlog and picked the next piece of work."
assert_eq "0" "$(task_of)" "with no marker and no stated task the entry still records"
assert_eq "1" "$(wc -l < "$WRITER_LOG" | tr -d ' ')" "and the time is not lost"
assert_contains "$(cat "$WORK/stderr-f3.txt" 2>/dev/null)" "catch-all" "the catch-all announces itself"

# 4. The NEAREST marker wins when markers exist at two levels of the tree.
: > "$WRITER_LOG"; rm -f "$APROPOS_OPEN_FILE"
printf '29802\n' > "$CLIENT/theme/.apropos-task"
turn f4 "$CLIENT/theme/sections" "Adjusted the section spacing and checked it at three widths."
assert_eq "29802" "$(task_of)" "the nearest marker wins over one further up"
rm -f "$CLIENT/theme/.apropos-task"

# 5. A project marker works the same way, and independently of the task marker.
: > "$WRITER_LOG"; rm -f "$APROPOS_OPEN_FILE"
PROJDIR="$WORK/clients/acme"; mkdir -p "$PROJDIR/docs"
printf '1229358\n' > "$PROJDIR/.apropos-project"
turn f5 "$PROJDIR/docs" "Rewrote the integration notes and filed them with the project."
assert_eq "1229358" "$(proj_of)" "a project marker is inherited the same way"
assert_eq "0" "$(task_of)" "and does not invent a task"

# 6. A malformed marker is ignored rather than recorded as garbage. An unreadable id would
#    otherwise be passed to the writer and land the hour somewhere unpredictable.
: > "$WRITER_LOG"; rm -f "$APROPOS_OPEN_FILE"
BADDIR="$WORK/clients/bad"; mkdir -p "$BADDIR"
printf 'not-a-task-id\n' > "$BADDIR/.apropos-task"
turn f6 "$BADDIR" "Cleared the stale branches and confirmed the remote matches."
assert_eq "0" "$(task_of)" "a malformed marker is ignored, not passed through"
assert_eq "1" "$(wc -l < "$WRITER_LOG" | tr -d ' ')" "and the turn is still recorded"

# 6a. A number far too long to be a real id is rejected rather than passed to the writer.
#     "Plain number" is not the same as "plausible id": a corrupted marker should fail here,
#     locally and visibly, rather than travel to the API and land the hour nowhere findable.
#     (#30989 QA round 1)
: > "$WRITER_LOG"; rm -f "$APROPOS_OPEN_FILE"
HUGE="$WORK/clients/huge"; mkdir -p "$HUGE"
printf '123456789012345678901234
' > "$HUGE/.apropos-task"
turn f6a "$HUGE" "Reconciled the vendor statement and filed the difference."
assert_eq "0" "$(task_of)" "an implausibly long marker is rejected, not passed to the writer"

# 7. The marker is read from the STAMPED cwd on Stop, not just when cwd is in the payload.
#    The Stop payload carries no cwd at all, so if the walk only ran on UserPromptSubmit the
#    attribution would be lost on the event that actually records.
: > "$WRITER_LOG"; rm -f "$APROPOS_OPEN_FILE"
turn f7 "$CLIENT" "Confirmed the vendor feed lands with the right handling code."
assert_eq "26137" "$(task_of)" "the marker still resolves on Stop, which carries no cwd"

# 8. Break, meal and end of day are recorded by their own commands straight through the time
#    writer and never enter this hook, so a folder marker cannot reach them. Asserted
#    structurally, because there is no code path to exercise.
for cmd in break lunch out; do
  assert_not_contains "$(cat "$DIR/commands/$cmd.md")" "apropos-task" "$cmd does not consult the folder task marker"
  assert_not_contains "$(cat "$DIR/commands/$cmd.md")" "time-track-per-turn" "$cmd does not go through the per-turn recorder"
done

rm -rf "$WORK"
finish
