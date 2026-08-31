#!/usr/bin/env bash
# Requirement 4 of #30989: client work must not reach the end of a day attributed to an
# internal account without anyone being told.
#
# The per-turn notice (requirement 3) is one line of stderr on one turn. It scrolls, the
# session ends, nobody looks. That is a single point of failure for a guarantee written in
# terms of a whole day, and QA failed the first cut of this task for exactly that: the
# ticket's APPROACH asks to "report it in the session output AND include it in the day's
# audit", and only the first half had been built.
#
# So the recorder keeps a running tally of the hours it sent to the catch-all today, and
# every session start reports it. That is a backstop rather than a single notice: it fires
# again on every new session, all day, until the entries are corrected.
#
# The tally is local. No credentials and no database access ship in this plugin, by design,
# so the day's audit is built from what the recorder itself saw rather than by querying
# Apropos.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
HOOK="$DIR/hooks-handlers/time-track-per-turn.sh"
INIT="$DIR/hooks-handlers/session-init.sh"
WORK="$(mktemp -d)"
export HOME="$WORK"
export APROPOS_WRITER="$WORK/mock-writer.sh"
export WRITER_LOG="$WORK/writer.log"
export APROPOS_OPEN_FILE="$WORK/open-entries.tsv"
export USERNAME="barrettgoldberg"
TT="$WORK/claude-timetrack"; mkdir -p "$TT"
export APROPOS_TRACK_DIR="$TT"
mkdir -p "$HOME/.claude/apropos-time"
TALLY_DIR="$HOME/.claude/apropos-time"
TODAY="$(date -u +%Y-%m-%d)"

cat > "$APROPOS_WRITER" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$WRITER_LOG"
exit 0
EOF
chmod +x "$APROPOS_WRITER"

prompt(){ printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"%s","prompt":"go"}' "$1" "$2" | bash "$HOOK" 2>/dev/null; }
stop(){ printf '{"hook_event_name":"Stop","session_id":"%s"}' "$1" | bash "$HOOK" 2>"$WORK/stderr-$1.txt"; }
turn(){ prompt "$1" "$2"; printf '%s' "$3" > "$TT/description-$1.txt"; printf '13' > "$TT/worktype-$1.txt"; stop "$1"; }
tally_lines(){ [[ -f "$TALLY_DIR/catchall-$TODAY.tsv" ]] && grep -c . "$TALLY_DIR/catchall-$TODAY.tsv" || echo 0; }
run_init(){ bash "$INIT" 2>/dev/null; }

NOMARK="$WORK/scratch/nowhere"; mkdir -p "$NOMARK"
MARKED="$WORK/clients/acme"; mkdir -p "$MARKED"; printf '26137\n' > "$MARKED/.apropos-task"

# 1. An hour that lands on the catch-all is written into today's tally.
: > "$WRITER_LOG"; rm -f "$TALLY_DIR/catchall-$TODAY.tsv"
turn c1 "$NOMARK" "Read through the backlog and picked up the next piece of work."
assert_eq "1" "$(tally_lines)" "an entry booked to the catch-all is recorded in the day's tally"

# 2. An hour that reaches a real task is NOT in the tally. The tally is the list of things
#    to go and fix, so a correctly attributed hour must never appear on it.
: > "$WRITER_LOG"; rm -f "$TALLY_DIR/catchall-$TODAY.tsv"
turn c2 "$MARKED" "Corrected the collection template and verified it on staging."
assert_eq "0" "$(tally_lines)" "a properly attributed entry is not in the tally"

# 3. Several sessions on the same day accumulate into ONE tally, because the question is
#    what the DAY looks like, not what one session did.
: > "$WRITER_LOG"; rm -f "$TALLY_DIR/catchall-$TODAY.tsv"
turn c3a "$NOMARK" "Cleared the stale branches and confirmed the remote matches."
turn c3b "$NOMARK" "Reviewed the open items and put the notes in the right place."
assert_eq "2" "$(tally_lines)" "two sessions on one day accumulate into one tally"

# 4. Session start reports the tally, so the day is audited again on every new session
#    rather than only at the moment the hour was booked.
OUT="$(run_init)"
assert_contains "$OUT" "catch-all" "session start reports the day's catch-all entries"
assert_contains "$OUT" "2" "and says how many there are"

# 5. Nothing to report means nothing said. An alert that fires on a clean day is noise, and
#    noise is how the queued-entry alert above it would stop being read.
rm -f "$TALLY_DIR/catchall-$TODAY.tsv"
OUT="$(run_init)"
assert_not_contains "$OUT" "catch-all" "a clean day says nothing"

# 6. Yesterday's tally does not raise today's alarm, and does not accumulate forever.
rm -f "$TALLY_DIR"/catchall-*.tsv
YDAY="$(date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)"
printf '%s\t%s\n' "09:00:00" "/some/old/folder" > "$TALLY_DIR/catchall-$YDAY.tsv"
OUT="$(run_init)"
assert_not_contains "$OUT" "catch-all" "yesterday's tally does not raise today's alarm"

# 7. The tally names WHERE the work was, because a count alone does not tell you which
#    hours to go and fix.
rm -f "$TALLY_DIR"/catchall-*.tsv
turn c7 "$NOMARK" "Worked through the support queue and answered the open threads."
assert_contains "$(cat "$TALLY_DIR/catchall-$TODAY.tsv")" "nowhere" "the tally records the folder the work was in"

# 8. A tally that cannot be written never costs the time entry. Recording the hour matters
#    more than auditing it.
rm -f "$TALLY_DIR"/catchall-*.tsv
: > "$WRITER_LOG"
chmod 500 "$TALLY_DIR" 2>/dev/null || true
turn c8 "$NOMARK" "Checked the overnight run and confirmed it completed cleanly."
chmod 700 "$TALLY_DIR" 2>/dev/null || true
assert_eq "1" "$(wc -l < "$WRITER_LOG" | tr -d ' ')" "an unwritable tally does not cost the time entry"

# 9. A turn that is deduped as an exact repeat creates no entry, so it must add no tally
#    line either. QA round 2 caught the tally being written before the dedup decision. An
#    audit that reports more entries than exist is an audit people stop reading.
rm -f "$TALLY_DIR"/catchall-*.tsv; : > "$WRITER_LOG"
turn c9 "$NOMARK" "Swept the queue and confirmed nothing was left outstanding."
turn c9 "$NOMARK" "Swept the queue and confirmed nothing was left outstanding."
assert_eq "1" "$(wc -l < "$WRITER_LOG" | tr -d ' ')" "an exact repeat inside the window records one entry"
assert_eq "1" "$(tally_lines)" "and adds one tally line, not two"

# 10. The day's tally is re-surfaced from the per-turn hook, not only at session start. A
#     single unbroken session that never restarts would otherwise see the day's total once
#     and never again, which is the hole QA round 2 asked about. Driven with the throttle
#     at zero so the behaviour is proven rather than waited for.
rm -f "$TALLY_DIR"/catchall-*.tsv "$TALLY_DIR"/catchall-last-report
APROPOS_CATCHALL_REPORT_SECS=0 turn ca "$NOMARK" "Reviewed the overnight output and noted what to follow up."
APROPOS_CATCHALL_REPORT_SECS=0 turn cb "$NOMARK" "Checked the second batch and confirmed it matched the first."
assert_contains "$(cat "$WORK/stderr-cb.txt" 2>/dev/null)" "so far today" "a later turn re-surfaces the running total"
assert_contains "$(cat "$WORK/stderr-cb.txt" 2>/dev/null)" "2 entries" "and the total is the day's, not the session's"

# 11. ...but not on every turn. A reminder that fires constantly is one people learn to
#     scroll past, which is how it would quietly stop working. At the shipped throttle the
#     very next turn says nothing.
turn cc "$NOMARK" "Filed the remaining notes and closed the loop on the request."
assert_not_contains "$(cat "$WORK/stderr-cc.txt" 2>/dev/null)" "so far today" "the reminder is throttled, not repeated every turn"

rm -rf "$WORK"
finish
