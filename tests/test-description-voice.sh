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

# --- REGRESSION (QA #30987, 2026-08-28) -------------------------------------------
# The first version only inspected the first word. Of 12 real entries recorded in the
# hour after it shipped it refused none, and 6 were still defective. Each case below is
# taken verbatim, or near verbatim, from that record.

# 9. A numeral subject.
next; said "v$s" "31018 is closed as not reproducible with its evidence preserved on the ticket."
assert_contains "$(last)" "needs description" "a numeral subject is refused"

# 10. Gerund narration rather than a completed outcome.
next; said "v$s" "Retracting Finding 3 as I wrote it, and the picture is now murkier than before."
assert_contains "$(last)" "needs description" "gerund narration is refused"

# 11. A condition stated mid sentence, not at the opening.
next; said "v$s" "Correcting the report: there is an attachment on the ticket after all."
assert_contains "$(last)" "needs description" "a condition mid sentence is refused"

# 12. First-person analysis.
next; said "v$s" "I had not matched the checks, and doing so shows zero hard blocks on any order."
assert_contains "$(last)" "needs description" "first-person analysis is refused"

# 13. A commit hash must never reach an invoice field.
next; said "v$s" "Internal documentation done, committed as 55793a7 on main and pushed."
assert_contains "$(last)" "needs description" "a commit hash is refused"

# 14. A lowercase verdict, which the case-sensitive check used to miss.
next; said "v$s" "Security review complete, approved, no blocking concerns to report here."
assert_contains "$(last)" "needs description" "a lowercase verdict is refused"

# 15. Parity: a file path from the model-written route, which only the derived route screened.
next; said "v$s" "Corrected the handler at hooks-handlers/time-track-per-turn.sh and verified it."
assert_contains "$(last)" "needs description" "a file path is refused on the model-written route too"

# 16. The verdict check must not fire inside ordinary words.
next; said "v$s" "Bypassed the compass check on the dealer path and verified the outcome."
assert_contains "$(last)" "Bypassed the compass" "BYPASS and COMPASS are not verdicts"

# 17. A real past-tense outcome with a count in it still survives.
next; said "v$s" "Corrected three of the failing checks and deployed after the full suite passed."
assert_contains "$(last)" "Corrected three" "an ordinary outcome mentioning counts survives"

# --- REGRESSION (QA re-review #30987, 2026-08-28) ---------------------------------
# The rework refused real, well-formed entries. Each case below is a genuine production
# description that was wrongly refused, or the defect that must still be caught.

# 18. An obstacle described in ordinary language is not a review verdict.
next; said "v$s" "Determined that the key audit is blocked by database permissions and named the owners."
assert_contains "$(last)" "Determined that the key audit" "ordinary obstacle language is not a verdict"

# 19. A condition as the OBJECT of completed work survives.
next; said "v$s" "Investigated the refunds and confirmed there is no guard for orders already shipped."
assert_contains "$(last)" "Investigated the refunds" "a condition inside completed work survives"

# 20. ...but a condition as the point of the sentence is still refused.
next; said "v$s" "Correcting the report: there is an attachment on the ticket after all."
assert_contains "$(last)" "needs description" "a condition after a colon is still refused"

# 21. A partitive opener is not a count report.
next; said "v$s" "One of my entries sat on the fallback task and was corrected to the right one."
assert_contains "$(last)" "One of my entries" "a partitive opener survives"

# 22. An -ing NOUN subject with completed work survives.
next; said "v$s" "Onboarding tasks were reassigned to the new owner and the packet was filed."
assert_contains "$(last)" "Onboarding tasks were" "an -ing noun with past tense survives"

# 23. ...but -ing narration with no completed work is still refused.
next; said "v$s" "Retracting Finding 3 as I wrote it, and the picture is now murkier than before."
assert_contains "$(last)" "needs description" "gerund narration is still refused"

# 24. Parity: a UNC path is refused on the model-written route.
next; said "v$s" "Corrected the handler at \\ricoserv02\r\Intranet\thing and verified it."
assert_contains "$(last)" "needs description" "a UNC path is refused"

# 25. Parity: a generic unix path is refused on the model-written route.
next; said "v$s" "Corrected the config at /etc/apropos/settings.yaml and verified the result."
assert_contains "$(last)" "needs description" "a unix path is refused"

finish
