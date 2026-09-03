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
#
# Every case here writes a description and expects it refused, so each one asserts the
# REJECTED flag specifically, not "a flag". Before #31098 they asserted the never-written
# wording, which was the only one that existed and which meant these tests would have
# passed had the screen never run at all. Asserting the cause is what makes them prove
# the screen did the refusing.
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
assert_contains "$(last)" "rewrite description" "second person is refused, not invoiced ($(last))"

# 2. A state report rather than an outcome is refused.
next; said "v$s" "The suite is 35 pass, 15 fail, and 14 of those belong to a later release."
assert_contains "$(last)" "rewrite description" "a state report is refused"

# 3. A bare verdict is refused.
next; said "v$s" "Security review complete, APPROVED, no blocking concerns to report here."
assert_contains "$(last)" "rewrite description" "a bare verdict is refused"

# 4. An internal draft identifier never reaches the field.
next; said "v$s" "Draft r4144661579774780226 to the client, reply-all with the team on it."
assert_contains "$(last)" "rewrite description" "a draft identifier is refused"

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
assert_contains "$(last)" "rewrite description" "a numeral subject is refused"

# 10. Gerund narration rather than a completed outcome.
next; said "v$s" "Retracting Finding 3 as I wrote it, and the picture is now murkier than before."
assert_contains "$(last)" "rewrite description" "gerund narration is refused"

# 11. A condition stated mid sentence, not at the opening.
next; said "v$s" "Correcting the report: there is an attachment on the ticket after all."
assert_contains "$(last)" "rewrite description" "a condition mid sentence is refused"

# 12. First-person analysis.
next; said "v$s" "I had not matched the checks, and doing so shows zero hard blocks on any order."
assert_contains "$(last)" "rewrite description" "first-person analysis is refused"

# 13. A commit hash must never reach an invoice field.
next; said "v$s" "Internal documentation done, committed as 55793a7 on main and pushed."
assert_contains "$(last)" "rewrite description" "a commit hash is refused"

# 14. A lowercase verdict, which the case-sensitive check used to miss.
next; said "v$s" "Security review complete, approved, no blocking concerns to report here."
assert_contains "$(last)" "rewrite description" "a lowercase verdict is refused"

# 15. Parity: a file path from the model-written route, which only the derived route screened.
next; said "v$s" "Corrected the handler at hooks-handlers/time-track-per-turn.sh and verified it."
assert_contains "$(last)" "rewrite description" "a file path is refused on the model-written route too"

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
assert_contains "$(last)" "rewrite description" "a condition after a colon is still refused"

# 21. A partitive opener is not a count report.
next; said "v$s" "One of my entries sat on the fallback task and was corrected to the right one."
assert_contains "$(last)" "One of my entries" "a partitive opener survives"

# 22. An -ing NOUN subject with completed work survives.
next; said "v$s" "Onboarding tasks were reassigned to the new owner and the packet was filed."
assert_contains "$(last)" "Onboarding tasks were" "an -ing noun with past tense survives"

# 23. ...but -ing narration with no completed work is still refused.
next; said "v$s" "Retracting Finding 3 as I wrote it, and the picture is now murkier than before."
assert_contains "$(last)" "rewrite description" "gerund narration is still refused"

# 24. Parity: a UNC path is refused on the model-written route.
next; said "v$s" "Corrected the handler at \\ricoserv02\r\Intranet\thing and verified it."
assert_contains "$(last)" "rewrite description" "a UNC path is refused"

# 25. Parity: a generic unix path is refused on the model-written route.
next; said "v$s" "Corrected the config at /etc/apropos/settings.yaml and verified the result."
assert_contains "$(last)" "rewrite description" "a unix path is refused"


# --- REGRESSION (QA third review #30987, 2026-08-28) -----------------------------
# QA failed the task on Requirement 2 and TEST CASE 3. Two defects, both reproduced
# end to end before these cases were written, plus one false positive of the class
# the second review raised and one claim on the ticket that measured false.

# 26. A bare verdict opening the sentence in lower case. The upper case form was
#     already refused, so TEST CASE 3 passed as literally written while the class it
#     stands for did not: the verdict rule matched only after a comma or a colon, and
#     a verdict opening the sentence has neither in front of it.
next; said "v$s" "approved, no blocking concerns and the branch is clear to merge now."
assert_contains "$(last)" "rewrite description" "a lower case verdict opening the sentence is refused"

# 27. The same shape with the other verdict word.
next; said "v$s" "blocked, waiting on the vendor to return the signed order form."
assert_contains "$(last)" "rewrite description" "a lower case blocked verdict is refused"

# 28. A verdict with no comma at all is still a verdict.
next; said "v$s" "passed with no concerns after the second run through the gate."
assert_contains "$(last)" "rewrite description" "an uncommaed passed verdict is refused"

# 29. And its opposite. Note the comma: a verdict word taking a real object is an
#     action, not a verdict, and case 39a below holds the line on that.
next; said "v$s" "failed, returned to the team for a second fix before it can ship."
assert_contains "$(last)" "rewrite description" "a lower case failed verdict is refused"

# 30-36. State reports the screen let through while refusing the same fact worded
#        another way. "Everything downstream waits on a db owner" was refused; every
#        line below says something of the same kind and was accepted.
next; said "v$s" "Still waiting on the db owner before the migration can be run."
assert_contains "$(last)" "rewrite description" "a still-waiting state report is refused"

next; said "v$s" "Currently blocked on the licence renewal for the staging server."
assert_contains "$(last)" "rewrite description" "a currently-blocked state report is refused"

next; said "v$s" "Not reproducible on the current build after three attempts today."
assert_contains "$(last)" "rewrite description" "a not-reproducible finding is refused"

next; said "v$s" "No blocking concerns after the review of the payment changes."
assert_contains "$(last)" "rewrite description" "a no-concerns finding is refused"

next; said "v$s" "Looks correct after the second pass through the reconciliation."
assert_contains "$(last)" "rewrite description" "a looks-correct finding is refused"

next; said "v$s" "Seems to be resolved now that the cache was cleared on the box."
assert_contains "$(last)" "rewrite description" "a seems-resolved finding is refused"

next; said "v$s" "my read is that the totals are fine and nothing needs restating."
assert_contains "$(last)" "rewrite description" "first person analysis opening with my is refused"

# 37. FALSE POSITIVE. An opening state word in front of genuinely completed work must
#     survive, the same way an -ing noun already does. "both" sat in the opener list
#     with no past-tense discriminator, so a plain record of work was thrown away.
next; said "v$s" "Both files were regenerated and checked against the source system."
assert_contains "$(last)" "Both files were regenerated" "a state opener with past tense survives"

# 38. The ticket claimed this was caught. Measured, it was not: the partitive skip
#     added for "One of my entries..." also swallowed a genuine count report.
next; said "v$s" "Two of three closed out cleanly and the last one was reassigned."
assert_contains "$(last)" "rewrite description" "a count report is refused even in the of form"

# 39. ...but the partitive it was written for still survives.
next; said "v$s" "One of my entries sat on the fallback task and was corrected today."
assert_contains "$(last)" "One of my entries" "the partitive opener still survives"

# 38a. The quantifier discriminator must not go too far the other way. Measured on
#      the record, letting "both" through on any past-tense-looking word newly
#      accepted this real state report, so a present copula in front of the participle
#      ("are connected", "is proven") does not count as completed work the way a past
#      one ("were regenerated") does.
next; said "v$s" "Both programmes are connected and the whole chain is proven end to end."
assert_contains "$(last)" "rewrite description" "a present copula participle is not completed work"

# 39a. A verdict WORD taking a real object is an action and must survive. This is a
#      genuine entry from the record, and it is why the verdict rule cannot simply
#      refuse anything opening with passed or failed.
next; said "v$s" "Passed the release gate through stakeholder QA and handed it off with two documentation recommendations."
assert_contains "$(last)" "Passed the release gate" "a verdict word with an object is an action"

# --- REGRESSION (QA fourth review #30987, 2026-08-29) ---------------------------
# QA failed the task again on Requirement 2. The copula guard added in round 3 only
# looked at the token immediately before the participle, so a single intervening
# adverb defeated it and a present-tense state report reached the invoice field on
# both routes. Case 38a only exercised the zero-gap form, which is why the suite could
# not see it: the same "a suite written alongside the filter proves what its author
# thought of" pattern that failed round 3.

# 40. One adverb between the copula and the participle.
next; said "v$s" "Both changes are now merged and verified into the release branch."
assert_contains "$(last)" "rewrite description" "an adverb between copula and participle is still a state"

# 41. The same shape with a different adverb and quantifier.
next; said "v$s" "Both PRs are already approved and merged ahead of the release."
assert_contains "$(last)" "rewrite description" "already between copula and participle is still a state"

# 42. And through the gerund opener, which shares the same helper.
next; said "v$s" "Testing is essentially finished and the last case is still running."
assert_contains "$(last)" "rewrite description" "a gerund opener with an adverbial copula is a state"

# 43. The verdict-with-no-object rule missed common prepositions, so a bare verdict
#     dressed in one slipped through.
next; said "v$s" "approved by the client over email after the second review round."
assert_contains "$(last)" "rewrite description" "a bare verdict behind any preposition is refused"

# 44. Second person in its contracted form was not caught by the token check.
next; said "v$s" "Y'all should check the totals before Monday morning arrives."
assert_contains "$(last)" "rewrite description" "contracted second person is refused"

# --- REGRESSION (QA fifth review #30987, 2026-08-29) ----------------------------
# QA failed Requirement 2 again. Round 4's copula guard was only ever REACHED from two
# gates, a "both"/"all" opener or an "-ing" opener, so any other subject skipped it
# entirely. And "being" satisfies the -ing gate itself, so a fourth adverb walked past
# the three-token lookback.
#
# The fix is general rather than another opener on a denylist: a present tense copula
# in the opening clause, with nothing completed in front of it, is a state report
# whatever the subject is. This also closes the noun-subject gap that had been
# disclosed and accepted since round 1.

# 45. A noun subject with a present copula, which reached no gate at all before.
next; said "v$s" "Status is now completely thoroughly resolved for the affected merchant."
assert_contains "$(last)" "rewrite description" "a noun subject with a present copula is a state"

# 46. The same with no adverbs at all, so it cannot be read as a lookback problem.
next; said "v$s" "Coverage is largely adequate across the reporting period."
assert_contains "$(last)" "rewrite description" "a bare noun-subject state report is refused"

# 47. "being" satisfies the gerund gate itself, so it outran the three-token lookback.
next; said "v$s" "Being now really fully resolved, the ticket needs no further action."
assert_contains "$(last)" "rewrite description" "a being opener beyond the lookback is refused"

# 48. A subordinate opener, which is in no opener list either.
next; said "v$s" "Although the change is now fully approved, deployment awaits sign-off."
assert_contains "$(last)" "rewrite description" "a subordinate clause opener does not bypass the copula"

# 49. GUARD. A past tense verb in front of the copula means completed work, and the
#     copula is then reporting on what was found rather than standing in for the work.
next; said "v$s" "Determined that the key audit is blocked by database permissions."
assert_contains "$(last)" "Determined that the key audit" "past tense in front of a copula survives"

# 50. GUARD. The short real entries the house rules explicitly bless must not be caught.
next; said "v$s" "Call with Blake."
assert_contains "$(last)" "Call with Blake" "a short real entry survives"

# 51. GUARD. An infinitive "to be" is not a state report.
next; said "v$s" "Rebuilt the Klaviyo template to be responsive and verified it at five widths."
assert_contains "$(last)" "Rebuilt the Klaviyo template" "an infinitive to be survives"

# --- REGRESSION (QA sixth review #30987, 2026-08-29) ----------------------------
# The past-tense check matched irregular verbs as whole tokens, so every prefixed form
# was invisible: "rebuilt" is not "built", "rewrote" is not "wrote", "resent" is not
# "sent", "reset" is not "set". A real record of work opening with one of those and
# carrying a copula in its opening clause was refused as a state report. All four
# openers appear in the real record, so this is a live false positive, not a synthetic
# one. Found while measuring, and reported by QA in the same round.

# 52. A prefixed irregular past tense is still past tense.
next; said "v$s" "Rewrote the config, is now live and serving traffic."
assert_contains "$(last)" "Rewrote the config" "a re- prefixed irregular past tense survives"

# 53. Another prefix, another base verb.
next; said "v$s" "Rebuilt the queue, is now draining normally again."
assert_contains "$(last)" "Rebuilt the queue" "rebuilt is recognised as past tense"

# 54. And a third.
next; said "v$s" "Resent the invoice, it is now delivered to the client."
assert_contains "$(last)" "Resent the invoice" "resent is recognised as past tense"

# 55. GUARD. Widening the past-tense check must not let a real state report through.
next; said "v$s" "Status is now resolved for the affected merchant."
assert_contains "$(last)" "rewrite description" "a state report is still refused"

finish
