#!/usr/bin/env bash
# A description corrected after the recorder wrote it must survive (#30988).
#
# While a stretch of work is still open, each new turn on it replaces the description on
# the entry already recorded. So a correction made in the meantime is silently discarded.
# Seen on 2026-08-27: entry 338357 was corrected at 17:30 and had reverted by 18:33, and
# a mid-day review of a day is therefore work that will be undone.
#
# The recorder now remembers the description it last wrote for the open entry and passes
# it with the amend. The writer refuses the amend when the row no longer holds it, and
# the recorder falls back to inserting, so the continuing work is still recorded.
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
export USERNAME="barrettgoldberg"
TT="$WORK/claude-timetrack"; mkdir -p "$TT"
export APROPOS_TRACK_DIR="$TT"

# Mock insert, matching the pattern the merge test uses: log, then record the entry as
# open the way write_entry does, including the description it wrote (4th field).
cat > "$APROPOS_WRITER" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$WRITER_LOG"
n=$(( $(wc -l < "$WRITER_LOG") + 1000 ))
if [[ -n "$4" && "$4" != "0" ]]; then
  printf '%s\t%s\t%s\t%s\n' "$3|$4|$5" "$n" "$(date -u +%s)" "$(printf '%s' "$2" | base64 | tr -d '\n')" >> "$APROPOS_OPEN_FILE"
fi
exit 0
EOF

# The amender stands in for the database. $CORRECTED holds what the row actually says
# now; when the recorder's expectation does not match it, the amend is refused, which is
# what Update-TimeDescription.ps1 does with -ExpectDescription.
cat > "$APROPOS_AMENDER" <<'EOF'
#!/usr/bin/env bash
# $1 id  $2 person  $3 new description  $4 expected current description
if [[ -s "$CORRECTED" && -n "${4:-}" ]]; then
  if [[ "$4" != "$(cat "$CORRECTED")" ]]; then
    printf 'REFUSED|%s|%s\n' "$1" "$4" >> "$AMEND_LOG"
    exit 1
  fi
fi
printf '%s|%s\n' "$1" "$3" >> "$AMEND_LOG"
exit 0
EOF
chmod +x "$APROPOS_WRITER" "$APROPOS_AMENDER"
export CORRECTED="$WORK/corrected.txt"
: > "$CORRECTED"

prompt(){ printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"%s","prompt":"go"}' "$1" "/home/b/projects/thing" | bash "$HOOK"; }
stop(){ printf '{"hook_event_name":"Stop","session_id":"%s"}' "$1" | bash "$HOOK"; }
turn(){ prompt "$1"; printf '%s' "$2" > "$TT/description-$1.txt"; printf '%s' "${3:-13}" > "$TT/worktype-$1.txt"; printf '%s' "${4:-28682}" > "$TT/task-$1.txt"; stop "$1"; }
writes(){ wc -l < "$WRITER_LOG" 2>/dev/null | tr -d " "; }
amends(){ wc -l < "$AMEND_LOG" 2>/dev/null | tr -d " "; }
reset(){ : > "$WRITER_LOG"; : > "$AMEND_LOG"; : > "$CORRECTED"; rm -f "$APROPOS_OPEN_FILE"; }

# 1. An uncorrected stretch still consolidates onto one entry.
reset
turn a1 "Started the release checks on the package manifest."
turn a1 "Finished the release checks and recorded the outcome."
assert_eq "1" "$(writes)" "an uncorrected stretch records one entry"
assert_eq "1" "$(amends)" "and amends it on the second turn"

# 2. A correction made in between survives, and the continuing work still records.
reset
turn a2 "Started the release checks on the package manifest."
printf 'Corrected by hand during the day.' > "$CORRECTED"   # somebody fixed the row
turn a2 "Finished the release checks and recorded the outcome."
assert_contains "$(cat "$AMEND_LOG")" "REFUSED" "the amend is refused once the row was corrected"
assert_eq "2" "$(writes)" "the continuing work is recorded as a new entry, not lost"

# 3. The guard survives a restart: the expectation lives on disk, not in the session.
reset
turn a3 "Opened the investigation into the failing import."
printf 'Corrected by hand during the day.' > "$CORRECTED"
# a different session, same activity, as happens when a session is restarted
turn a4 "Continued the investigation and found the cause."
assert_contains "$(cat "$AMEND_LOG")" "REFUSED" "a later session also refuses to overwrite the correction"
assert_eq "2" "$(writes)" "and records its own entry"

# 4. An external worktype correction does not split an uncorrected stretch in two.
#    The activity key comes from the session's own files, so a change in the database
#    cannot fragment the day.
reset
turn a5 "Reviewed the customer request and staged the test order."
turn a5 "Placed the test order and sent the confirmation."
assert_eq "1" "$(writes)" "the stretch stays one entry"
assert_eq "1" "$(amends)" "amended rather than recorded twice"

finish
