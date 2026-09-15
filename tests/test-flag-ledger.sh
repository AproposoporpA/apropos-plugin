#!/usr/bin/env bash
# The ledger records which entries were flagged and what produced them, so a later pass
# can revisit them. Without it a flagged entry is unreachable the moment its activity
# closes.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
WORK="$(mktemp -d)"
export APROPOS_LEDGER_FILE="$WORK/flagged.tsv"
source "$DIR/hooks-handlers/lib/ledger.sh"

fl_record 340938 "sess-a" "/repo/one" 1789424974
fl_record 340939 "sess-b" "/repo/two" 1789425082

got="$(fl_pending)"
assert_contains "$got" "340938" "a flagged entry is remembered"
assert_contains "$got" "sess-a" "its session is remembered"
assert_contains "$got" "/repo/one" "its working directory is remembered"

fl_clear 340938
got="$(fl_pending)"
assert_not_contains "$got" "340938" "a repaired entry leaves the ledger"
assert_contains "$got" "340939" "clearing one entry leaves the others"

fl_record 340939 "sess-b" "/repo/two" 1789425082
assert_eq "1" "$(fl_pending | grep -c '^340939')" "recording the same entry twice keeps one row"

finish
