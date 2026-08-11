#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
source "$DIR/hooks-handlers/lib/queue.sh"
WORK="$(mktemp -d)"; QF="$WORK/pending.tsv"; LOG="$WORK/log"

# base64 roundtrip incl. special chars
q_enqueue "$QF" 321 $'Fix tab\there and "quotes"' 13 0 0 "2026-07-10 12:00:00"
q_enqueue "$QF" 344 "Second entry" 23 29100 0 "2026-07-10 12:01:00"

ok_cb(){ printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$LOG"; return 0; }
q_flush "$QF" ok_cb
[[ ! -f "$QF" ]] && pass "queue drained/removed on success" || { echo "  FAIL: queue remains"; _TEST_FAILS=$((_TEST_FAILS+1)); }
L="$(cat "$LOG")"
assert_contains "$L" '321|Fix tab	here and "quotes"|13|0|0|2026-07-10 12:00:00' "entry 1 decoded correctly (order preserved)"
assert_contains "$L" '344|Second entry|23|29100|0|' "entry 2 delivered"

# all-fail retains everything
rm -f "$LOG"
q_enqueue "$QF" 321 "A" 13 0 0 "t1"
q_enqueue "$QF" 321 "B" 13 0 0 "t2"
fail_cb(){ return 1; }
q_flush "$QF" fail_cb
assert_eq "2" "$(wc -l < "$QF" | tr -d ' ')" "all entries retained on total failure"

# partial: first succeeds, rest fail and are retained in order
rm -f "$QF" "$LOG"
q_enqueue "$QF" 321 "first" 13 0 0 "t1"
q_enqueue "$QF" 321 "second" 13 0 0 "t2"
q_enqueue "$QF" 321 "third" 13 0 0 "t3"
CNT="$WORK/cnt"; echo 0 > "$CNT"
partial_cb(){ n=$(cat "$CNT"); n=$((n+1)); echo $n > "$CNT"; if [[ $n -eq 1 ]]; then printf '%s\n' "$2" >> "$LOG"; return 0; else return 1; fi; }
q_flush "$QF" partial_cb
assert_eq "2" "$(wc -l < "$QF" | tr -d ' ')" "2 undelivered retained after partial"
assert_contains "$(cat "$LOG")" "first" "first delivered"
FIRSTLINE="$(head -1 "$QF")"
assert_contains "$FIRSTLINE" "$(printf 'second' | base64 | tr -d '\n')" "retained queue keeps order (second first)"

# ---------------------------------------------------------------------------
# REGRESSION (2026-08-10): concurrent flushes must deliver each entry ONCE.
# Two flushes racing used to deliver every queued entry once each. Measured live:
# 239 Apropos rows from 7 real moments over 2026-08-08 to 08-10.
# ---------------------------------------------------------------------------
rm -rf "$QF" "$QF.lock" "$LOG"
for i in 1 2 3; do q_enqueue "$QF" 276 "race-$i" 13 0 0 "2026-08-08 11:59:0$i"; done
slow_cb(){ sleep 0.3; printf '%s\n' "$2" >> "$LOG"; return 0; }
( q_flush "$QF" slow_cb ) &
( q_flush "$QF" slow_cb ) &
( q_flush "$QF" slow_cb ) &
wait
assert_eq "3" "$(wc -l < "$LOG" | tr -d ' ')" "three concurrent flushes deliver 3 entries, not 9"
assert_eq "1" "$(grep -c 'race-1' "$LOG")" "race-1 delivered exactly once"
assert_eq "1" "$(grep -c 'race-3' "$LOG")" "race-3 delivered exactly once"
[[ ! -d "$QF.lock" ]] && pass "lock released after flush" || { echo "  FAIL: lock left behind"; _TEST_FAILS=$((_TEST_FAILS+1)); }

# An enqueue arriving during a flush must survive it (no lost update).
rm -rf "$QF" "$QF.lock" "$LOG"
for i in 1 2; do q_enqueue "$QF" 276 "pre-$i" 13 0 0 "t$i"; done
( q_flush "$QF" slow_cb ) &
sleep 0.1
q_enqueue "$QF" 276 "arrived-during-flush" 13 0 0 "t9"
wait
ALL="$(cat "$LOG" 2>/dev/null)"
if [[ "$ALL" == *"arrived-during-flush"* ]] || grep -q 'arrived-during-flush' "$QF" 2>/dev/null; then
  pass "entry enqueued during a flush is not lost"
else
  echo "  FAIL: entry enqueued mid-flush disappeared"; _TEST_FAILS=$((_TEST_FAILS+1))
fi

# ---------------------------------------------------------------------------
# REGRESSION (2026-08-10): one bad entry must not block the ones behind it.
# Head-of-line blocking is what produced the 383-entry (07-28) and 212-entry
# (08-05) archived backlogs on this machine.
# ---------------------------------------------------------------------------
rm -rf "$QF" "$QF.lock" "$QF.dead" "$LOG"
q_enqueue "$QF" 276 "poison" 13 0 0 "t1"
q_enqueue "$QF" 276 "good-A" 13 0 0 "t2"
q_enqueue "$QF" 276 "good-B" 13 0 0 "t3"
selective_cb(){ if [[ "$2" == "poison" ]]; then return 1; fi; printf '%s\n' "$2" >> "$LOG"; return 0; }
q_flush "$QF" selective_cb
assert_contains "$(cat "$LOG")" "good-A" "entry behind a failing one is still delivered"
assert_contains "$(cat "$LOG")" "good-B" "second entry behind a failing one is still delivered"
assert_eq "1" "$(wc -l < "$QF" | tr -d ' ')" "only the failing entry is retained"

# ...and it is parked after Q_MAX_ATTEMPTS instead of retrying forever.
for i in 2 3 4 5; do q_flush "$QF" selective_cb; done
[[ ! -f "$QF" ]] && pass "poison entry no longer in the live queue" || { echo "  FAIL: still queued after max attempts"; _TEST_FAILS=$((_TEST_FAILS+1)); }
[[ -s "$QF.dead" ]] && pass "poison entry parked in .dead for inspection" || { echo "  FAIL: not parked"; _TEST_FAILS=$((_TEST_FAILS+1)); }

# ---------------------------------------------------------------------------
# Backward compatibility: 6-field lines written by the previous version still read.
# ---------------------------------------------------------------------------
rm -rf "$QF" "$QF.lock" "$LOG"
printf '276\t%s\t13\t0\t0\t2026-08-07 12:00:00\n' "$(printf 'legacy line' | base64 | tr -d '\n')" > "$QF"
q_flush "$QF" ok_cb
assert_contains "$(cat "$LOG")" "legacy line" "6-field legacy queue line still delivers"

# A stale lock must not wedge recording forever.
rm -rf "$QF" "$QF.lock" "$LOG"
q_enqueue "$QF" 276 "after-stale-lock" 13 0 0 "t1"
mkdir -p "$QF.lock"; echo $(( $(date -u +%s) - 9999 )) > "$QF.lock/ts"
q_flush "$QF" ok_cb
assert_contains "$(cat "$LOG")" "after-stale-lock" "stale lock is broken so the queue still drains"

rm -rf "$WORK"
finish
