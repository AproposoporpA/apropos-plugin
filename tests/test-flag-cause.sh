#!/usr/bin/env bash
# A flagged entry has two causes and they call for opposite responses (#31098).
#
# The recorder writes a placeholder when it cannot produce a usable description. That
# happens for two completely different reasons: the session wrote a description and the
# screen judged it unfit for a customer invoice, or the session wrote nothing and there
# was nothing to judge. The first is the cost of protecting the invoice; the second is a
# session that did not do its job. Both used to record the same words, so once the entry
# was in the record nobody could tell which had happened, and 26 hours of already-sized
# work (#31065, #31068) sat behind a number that could not be checked.
#
# These cases are written to the SHAPE of the defect, not to one example sentence. Two
# QA rounds on #30987 were failed by regression tests pinned to a single string, so
# every case below either sweeps a set of inputs or asserts a property.
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

prompt(){
  jq -nc --arg sid "$1" --arg cwd "${2:-/home/b/projects/thing}" \
    '{hook_event_name:"UserPromptSubmit", session_id:$sid, cwd:$cwd, prompt:"go"}' | bash "$HOOK"
}
stop(){ printf '{"hook_event_name":"Stop","session_id":"%s"}' "$1" | bash "$HOOK"; }
# said <session> <text> - the session wrote this description for the turn
said(){ prompt "$1"; printf '%s' "$2" > "$TT/description-$1.txt"; stop "$1"; }
# silent <session> [cwd] - the session wrote no description at all
silent(){ prompt "$1" "$2"; stop "$1"; }
field(){ printf '%s' "$1" | awk -F'|' -v n="$2" '{print $n}'; }
last(){ field "$(tail -1 "$WRITER_LOG")" 2; }

# A skip is not a pass. finish() prints "ALL TESTS PASSED" and exits 0, so calling it here
# reported a green file that had asserted nothing at all, which is the shape of a test that
# quietly stops protecting anything. Exit non-zero instead and say what was not run.
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP: jq not present, so NOTHING in this file ran. Not a pass."
  echo "TESTS FAILED (1)"; exit 1
fi

# The fast harness first. It fires adversarial text straight at the constants and the
# predicate in milliseconds, and on this codebase that is where text defects are actually
# found: five QA rounds on #30987 ran with the suite green while the screen was broken.
# Running it here means the suite covers it too, rather than relying on someone
# remembering to run it by hand.
echo "  -- standalone harness --"
if bash "$DIR/tests/harness-flag-cause.sh" > "$WORK/harness.log" 2>&1; then
  pass "standalone flag harness passes ($(grep -c '^  ok:' "$WORK/harness.log") checks)"
else
  grep '^  FAIL:' "$WORK/harness.log"
  echo "  FAIL: standalone flag harness failed"
  _TEST_FAILS=$((_TEST_FAILS+1))
fi

s=0
next(){ s=$((s+1)); : > "$WRITER_LOG"; printf '31098' > "$TT/task-c$s.txt"; printf '13' > "$TT/worktype-c$s.txt"; }

# The two wordings under test, read out of the handler so the test cannot drift from it
# and a rename has one place to change rather than forty.
PH_NONE="$(sed -n 's/^DESC_PH_NONE="\(.*\)"$/\1/p' "$HOOK" | head -1)"
PH_REJ="$(sed -n 's/^DESC_PH_REJECTED="\(.*\)"$/\1/p' "$HOOK" | head -1)"
if [[ -z "$PH_NONE" || -z "$PH_REJ" ]]; then
  echo "  FAIL: the handler does not define both placeholders (DESC_PH_NONE / DESC_PH_REJECTED)"
  echo "TESTS FAILED (1)"; exit 1
fi
assert_eq "0" "$( [[ "$PH_NONE" == "$PH_REJ" ]] && echo 1 || echo 0 )" "the two placeholders are different strings"

# ---------------------------------------------------------------------------
# 1. A rejected description is distinguishable, by its text alone, from a turn
#    that wrote nothing. Swept across the refusal shapes the screen actually
#    uses, so the distinction is not pinned to one sentence.
# ---------------------------------------------------------------------------
rejected_inputs=(
  "The date moved to a tentative 9/8 and your three tasks are marked complete."
  "Security review complete, approved, no blocking concerns raised anywhere."
  "There is no guard on the nightly push and it has never been added."
  "Retracting the third finding because the count was read off the wrong column."
  "Still waiting on the database owner before the audit can be finished."
  "31018 is closed as not reproducible after a second look at the log."
)
for r in "${rejected_inputs[@]}"; do
  next; said "c$s" "$r"
  D="$(last)"
  assert_contains "$D" "$PH_REJ" "rejected description flags the rejected cause: ${r:0:34}"
  assert_not_contains "$D" "$PH_NONE" "rejected cause is not recorded as never-written: ${r:0:34}"
done

# ---------------------------------------------------------------------------
# 2. A turn that writes no description at all records the EXISTING placeholder,
#    unchanged. This is the case the record is already full of; changing it
#    would rewrite the meaning of every historical entry.
# ---------------------------------------------------------------------------
next; silent "c$s" "/home/b/projects/thing"
assert_eq "$PH_NONE thing" "$(last)" "no description written keeps the existing placeholder, project-tagged"

next; silent "c$s" "R:\\Barrett Goldberg\\Claude"
assert_eq "$PH_NONE" "$(last)" "AI-named project still dropped from the never-written placeholder"

# A whitespace-only description file is nothing written, not something rejected.
next; prompt "c$s"; printf '    ' > "$TT/description-c$s.txt"; stop "c$s"
assert_contains "$(last)" "$PH_NONE" "a blank description file counts as never written"
assert_not_contains "$(last)" "$PH_REJ" "a blank description file is not counted against the screen"

# ---------------------------------------------------------------------------
# 3. Both causes still record the time, against the right task and worktype,
#    and both still read as asking for correction.
# ---------------------------------------------------------------------------
next; said "c$s" "Your review is done and the tasks are closed."
LINE="$(tail -1 "$WRITER_LOG")"
assert_eq "13" "$(field "$LINE" 3)" "rejected cause still records the worktype"
assert_eq "31098" "$(field "$LINE" 4)" "rejected cause still records the task"

next; silent "c$s"
LINE="$(tail -1 "$WRITER_LOG")"
assert_eq "13" "$(field "$LINE" 3)" "never-written cause still records the worktype"
assert_eq "31098" "$(field "$LINE" 4)" "never-written cause still records the task"

# The prompt for correction is on the error stream, and requirement 3 is to PRESERVE it.
# Pinned to the rejected branch specifically: the flag alone tells the person reading the
# timesheet what happened, and this tells the session what to do about it in the moment.
next
prompt "c$s"
printf '%s' "Your review is complete and approved without concerns." > "$TT/description-c$s.txt"
ERRTXT="$(stop "c$s" 2>&1 >/dev/null)"
assert_contains "$ERRTXT" "was not used" "a rejected description still prompts the session to rewrite it"
assert_contains "$(last)" "$PH_REJ" "and the same turn still records the rejected flag"

# The AI-name guard drops the project tag on BOTH branches. It was only ever exercised on
# the never-written branch, so the rejected branch could have shipped "[rewrite
# description] Claude" onto a field that reaches a customer invoice.
next
prompt "c$s" "R:\\Barrett Goldberg\\Claude"
printf '%s' "Your review is complete and approved without concerns." > "$TT/description-c$s.txt"
stop "c$s"
assert_eq "$PH_REJ" "$(last)" "AI-named project is dropped from the REJECTED flag too"

for ph in "$PH_NONE" "$PH_REJ"; do
  if printf '%s' "$ph" | grep -Eq '^\[[^]]+\]$'; then
    pass "placeholder is bracketed so it is visible on a timesheet: $ph"
  else
    echo "  FAIL: placeholder is not bracketed: $ph"
  fi
  # Both must name an action the reader is being asked to take.
  if printf '%s' "$ph" | grep -Eqi 'needs|rewrite|correct|missing'; then
    pass "placeholder reads as asking for correction: $ph"
  else
    echo "  FAIL: placeholder does not ask for a correction: $ph"
  fi
  # Neither may name the tooling: these reach a customer invoice.
  if printf '%s' "$ph" | grep -Eqi 'claude|anthropic|\bai\b|assistant|agent'; then
    echo "  FAIL: placeholder names the tooling: $ph"
  else
    pass "placeholder does not name the tooling: $ph"
  fi
done

# ---------------------------------------------------------------------------
# 4. SHAPE REGRESSION. The dedup guard exempts the placeholder because a
#    placeholder is an admission that we do not know what the work was, not
#    evidence that two turns were the same (#30987 QA round 3). That exemption
#    was written against the literal string "[needs description]". A second
#    wording that does not share that prefix silently falls back INTO dedup and
#    the second rejected turn inside 15 minutes loses its time outright.
#    Asserted for every placeholder, in every order, rather than for one string.
# ---------------------------------------------------------------------------
next
said "c$s" "Your first review is complete and everything is approved."
said "c$s" "There is nothing further outstanding on the second item."
assert_eq "2" "$(grep -c '|' "$WRITER_LOG")" "two consecutive REJECTED turns both record, not deduped"

next
silent "c$s"; silent "c$s"
assert_eq "2" "$(grep -c '|' "$WRITER_LOG")" "two consecutive never-written turns both record, not deduped"

next
said "c$s" "Your review is complete and approved without concerns."
silent "c$s"
assert_eq "2" "$(grep -c '|' "$WRITER_LOG")" "a rejected turn then a never-written turn both record"

next
silent "c$s"
said "c$s" "Your review is complete and approved without concerns."
assert_eq "2" "$(grep -c '|' "$WRITER_LOG")" "a never-written turn then a rejected turn both record"

# ---------------------------------------------------------------------------
# 5. Neither placeholder exceeds the length limit, and neither is cut mid-word.
#    A long folder name is the only thing that can push either one over.
# ---------------------------------------------------------------------------
longname=""
for i in 1 2 3 4 5 6 7 8 9; do longname="${longname}averyverylongprojectfoldername"; done
longdir="/home/b/projects/$longname"

check_len(){
  local d="$1" what="$2"
  if (( ${#d} <= 255 )); then pass "$what within the 255 cap (${#d})"; else echo "  FAIL: $what is ${#d} chars"; fi
  case "$d" in
    *" ") echo "  FAIL: $what has a trailing space, so it was cut mid-word: $d" ;;
    *) pass "$what is not cut mid-word" ;;
  esac
}

next; silent "c$s" "$longdir"
D="$(last)"
check_len "$D" "never-written placeholder"
assert_contains "$D" "$PH_NONE" "never-written flag survives a long folder name"

next; prompt "c$s" "$longdir"; printf '%s' "Your review is complete and approved." > "$TT/description-c$s.txt"; stop "c$s"
D="$(last)"
check_len "$D" "rejected placeholder"
assert_contains "$D" "$PH_REJ" "rejected flag survives a long folder name"

# ---------------------------------------------------------------------------
# 6. The distinction is about what the SESSION wrote, not about the salvage
#    attempt. A refused transcript candidate means the session wrote nothing,
#    which is the never-written cause. Counting it against the screen would
#    inflate exactly the number this ticket exists to make trustworthy.
# ---------------------------------------------------------------------------
mktranscript(){
  local out="$1"; shift; : > "$out"
  local t
  for t in "$@"; do
    printf '{"type":"assistant","timestamp":"2026-09-01T10:00:00Z","message":{"content":[{"type":"text","text":%s}]}}\n' \
      "$(printf '%s' "$t" | jq -Rs .)" >> "$out"
  done
}
mktranscript "$WORK/tr.jsonl" "Claude updated the plugin and reran the suite for you."
export APROPOS_TRANSCRIPT="$WORK/tr.jsonl"
next; silent "c$s"
assert_contains "$(last)" "$PH_NONE" "a refused transcript is still the never-written cause"
assert_not_contains "$(last)" "$PH_REJ" "a refused transcript is not counted against the screen"
unset APROPOS_TRANSCRIPT

# ---------------------------------------------------------------------------
# 7. The two causes can be counted separately over a period. This is the whole
#    point of the ticket: the cost of the screen has to be reportable on its own.
# ---------------------------------------------------------------------------
next
said "c$s" "Your first review is complete and approved."
silent "c$s"
said "c$s" "There is nothing outstanding on the second item."
silent "c$s"
said "c$s" "Still waiting on the database owner for the audit."
n_rej="$(cut -d'|' -f2 < "$WRITER_LOG" | grep -c -F "$PH_REJ")"
n_none="$(cut -d'|' -f2 < "$WRITER_LOG" | grep -c -F "$PH_NONE")"
assert_eq "3" "$n_rej"  "rejected cause counts separately over a period"
assert_eq "2" "$n_none" "never-written cause counts separately over a period"
assert_eq "0" "$(cut -d'|' -f2 < "$WRITER_LOG" | grep -F "$PH_REJ" | grep -c -F "$PH_NONE")" \
  "the two counts do not overlap, so neither double-counts the other"

finish
