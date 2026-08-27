#!/usr/bin/env bash
# A time entry description is read by a customer on an invoice (#30987).
#
# The derived fallback lifts the closing text of the last reply, and that text is written
# TO Barrett, so it arrives in the second person, in the present tense, and often as a
# verdict rather than an outcome. Real examples that reached the record between 24 and 27
# August: "your three tasks are marked complete", "You were right - passed Dev QA moves
# into Delivery Queue", "Security review complete - APPROVED, no blocking concerns",
# "The suite is 35 pass, 15 fail". 47 descriptions had to be rewritten by hand.
#
# The same screen applies to the description the model writes, so neither route bypasses
# it. Punctuation the house rules ban is normalised rather than rejected: an em dash in
# an otherwise good sentence should not cost the whole description.
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
# said <session> <text> — the model wrote this description for the turn
said(){ prompt "$1"; printf '%s' "$2" > "$TT/description-$1.txt"; stop "$1"; }
desc_of(){ printf '%s' "$1" | awk -F'|' '{print $2}'; }
last(){ desc_of "$(tail -1 "$WRITER_LOG")"; }

s=0
next(){ s=$((s+1)); : > "$WRITER_LOG"; printf '28682' > "$TT/task-v$s.txt"; printf '59' > "$TT/worktype-v$s.txt"; }

# 1. Second person never reaches the field.
next; said "v$s" "The date moved to a tentative 9/8 and your three tasks are marked complete."
assert_contains "$(last)" "needs description" "second person is refused, not invoiced ($(last))"

# 2. A state report rather than an outcome is refused.
next; said "v$s" "The suite is 35 pass, 15 fail, and 14 of those belong to a later release."
assert_contains "$(last)" "needs description" "a state report is refused"

# 3. A bare verdict is refused.
next; said "v$s" "Security review complete, APPROVED, no blocking concerns to report here."
assert_contains "$(last)" "needs description" "a bare verdict is refused"

# 4. An internal draft identifier never reaches the field.
next; said "v$s" "Draft r4144661579774780226 to the client, reply-all with the team on it."
assert_contains "$(last)" "needs description" "a draft identifier is refused"

# 5. Banned punctuation is normalised, not thrown away with the sentence.
next; said "v$s" "Rebuilt the plates full bleed — restored the menu bar and added the badge."
L="$(last)"
assert_not_contains "$L" "—" "no em dash reaches the field"
assert_contains "$L" "Rebuilt the plates" "the sentence survives normalisation"

# 6. A well-formed past-tense outcome is recorded unchanged.
next; said "v$s" "Corrected the skipped orders view on the dashboard and deployed it."
assert_eq "Corrected the skipped orders view on the dashboard and deployed it." "$(last)" "a good description is untouched"

# 7. First person about the work is fine. "my" is not second person.
next; said "v$s" "Set up my machine to build from a clean checkout and verified the result."
assert_contains "$(last)" "Set up my machine" "first person is not refused"

# 8. The refusal is visible, not silent, so the entry can be corrected.
next
OUT="$(said "v$s" "You were right, passed Dev QA moves into the Delivery Queue instead." 2>&1)"
assert_contains "$OUT" "description" "the refusal is reported"

finish
