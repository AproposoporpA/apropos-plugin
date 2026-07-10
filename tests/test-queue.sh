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

rm -rf "$WORK"
finish
