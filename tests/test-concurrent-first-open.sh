#!/usr/bin/env bash
# Two sessions opening the SAME brand-new activity at once must produce one entry (#30903).
#
# QA blocked #30903 on this. oe_lookup is read-only and releases its lock immediately; the
# entry is not marked open until write_entry runs later in the same invocation. Between one
# session's miss and its own oe_record there is a real window, and this hook was measured
# taking 12 to 20 seconds per invocation on the machine it ships to. A second session
# hitting Stop on the identical activity inside that window also misses and also inserts,
# producing two rows for one activity: one per session, which is what requirement 4 of
# #30903 says must not happen.
#
# Every existing concurrency test races either distinct keys or a key that is already open,
# so none of them reach this.
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

# The insert is deliberately slow, standing in for the PowerShell and Azure round trip
# that makes this window wide in the first place. It records the open entry the way
# write_entry does, including the description field.
cat > "$APROPOS_WRITER" <<'EOF'
#!/usr/bin/env bash
sleep "${MOCK_WRITE_DELAY:-2}"
printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$WRITER_LOG"
n=$(( $(wc -l < "$WRITER_LOG") + 5000 ))
# write_entry short-circuits to this mock, so oe_record never runs. Record the entry as
# open here, exactly as write_entry would, the same way tests/test-merge-open-entry.sh
# does. Note the claim line for this key must be replaced, not appended beside.
if [[ -n "$4" && "$4" != "0" ]]; then
  k="$3|$4|$5"
  tmp="$APROPOS_OPEN_FILE.mocktmp.$$"
  : > "$tmp"
  if [[ -s "$APROPOS_OPEN_FILE" ]]; then
    while IFS=$'\t' read -r a b c d; do
      [[ "$a" == "$k" ]] && continue
      printf '%s\t%s\t%s\t%s\n' "$a" "$b" "$c" "$d" >> "$tmp"
    done < "$APROPOS_OPEN_FILE"
  fi
  printf '%s\t%s\t%s\t%s\n' "$k" "$n" "$(date -u +%s)" "$(printf '%s' "$2" | base64 | tr -d '\n')" >> "$tmp"
  mv "$tmp" "$APROPOS_OPEN_FILE"
fi
echo "APROPOS_ENTRY_ID=$n"
exit 0
EOF
cat > "$APROPOS_AMENDER" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$3" >> "$AMEND_LOG"
exit 0
EOF
chmod +x "$APROPOS_WRITER" "$APROPOS_AMENDER"

turn(){
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"/home/b/p","prompt":"go"}' "$1" | bash "$HOOK" >/dev/null 2>&1
  printf '%s' "$2" > "$TT/description-$1.txt"
  printf '13'    > "$TT/worktype-$1.txt"
  printf '28682' > "$TT/task-$1.txt"
  printf '{"hook_event_name":"Stop","session_id":"%s"}' "$1" | bash "$HOOK" >/dev/null 2>&1
}
writes(){ wc -l < "$WRITER_LOG" 2>/dev/null | tr -d ' '; }
amends(){ wc -l < "$AMEND_LOG" 2>/dev/null | tr -d ' '; }

# 1. Two sessions, same brand-new activity, overlapping. One entry, not two.
: > "$WRITER_LOG"; : > "$AMEND_LOG"; rm -f "$APROPOS_OPEN_FILE"
( turn c1 "Opened the release checks on the package manifest." ) &
sleep 0.3
( turn c2 "Continued the release checks and recorded the outcome." ) &
wait
w="$(writes)"
assert_eq "1" "$w" "two sessions opening one new activity record a single entry ($w recorded)"

# 2. The second session's work is not lost: it amended rather than vanishing.
a="$(amends)"
assert_eq "1" "$a" "the second session amended the first session's entry ($a amends)"

# 3. Distinct activities still open separately and are never merged together.
: > "$WRITER_LOG"; : > "$AMEND_LOG"; rm -f "$APROPOS_OPEN_FILE"
( turn d1 "Worked the support queue for the morning." ) &
sleep 0.3
( printf '{"hook_event_name":"UserPromptSubmit","session_id":"d2","cwd":"/home/b/p","prompt":"go"}' | bash "$HOOK" >/dev/null 2>&1
  printf 'Reviewed the release notes for the upcoming version.' > "$TT/description-d2.txt"
  printf '23'    > "$TT/worktype-d2.txt"
  printf '30717' > "$TT/task-d2.txt"
  printf '{"hook_event_name":"Stop","session_id":"d2"}' | bash "$HOOK" >/dev/null 2>&1 ) &
wait
w2="$(writes)"
assert_eq "2" "$w2" "two different activities still record two entries ($w2 recorded)"

# 4. A claim left behind by a session that died must not block the activity forever.
: > "$WRITER_LOG"; : > "$AMEND_LOG"
printf '13|28682|0\tpending:999999\t%s\t\n' "$(( $(date -u +%s) - 3600 ))" > "$APROPOS_OPEN_FILE"
turn e1 "Picked the work back up after the earlier session died."
w3="$(writes)"
assert_eq "1" "$w3" "an abandoned claim does not block recording ($w3 recorded)"

# 5. REGRESSION (QA re-review #30903, 2026-08-28): the wait must outlast the REAL writer.
#    The first version waited a nominal 10 seconds while the documented round trip on the
#    machine this ships to is 12 to 20 seconds, so the second session timed out and
#    inserted the duplicate anyway, just later. Proven then by reproducing it with a wait
#    budget deliberately shorter than the writer delay.
: > "$WRITER_LOG"; : > "$AMEND_LOG"; rm -f "$APROPOS_OPEN_FILE"
export MOCK_WRITE_DELAY=14
( turn f1 "Opened the release checks under a realistic writer delay." ) &
sleep 0.3
( turn f2 "Continued the release checks under a realistic writer delay." ) &
wait
unset MOCK_WRITE_DELAY
w4="$(writes)"
assert_eq "1" "$w4" "one entry even when the writer takes 14 seconds ($w4 recorded)"

# 6. A wait budget shorter than the writer is the failure this closed. With the budget
#    forced below the delay the duplicate returns, which proves the budget is what matters.
: > "$WRITER_LOG"; : > "$AMEND_LOG"; rm -f "$APROPOS_OPEN_FILE"
export MOCK_WRITE_DELAY=6 APROPOS_CLAIM_WAIT_SECS=1
( turn g1 "Opened the work with a deliberately short wait budget." ) &
sleep 0.3
( turn g2 "Continued the work with a deliberately short wait budget." ) &
wait
unset MOCK_WRITE_DELAY APROPOS_CLAIM_WAIT_SECS
w5="$(writes)"
assert_eq "2" "$w5" "a budget shorter than the writer still duplicates, as expected ($w5)"

finish
