#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
for f in time break lunch out setup; do
  [[ -f "$DIR/commands/$f.md" ]] && pass "$f.md exists" || { echo "  FAIL: $f.md"; _TEST_FAILS=$((_TEST_FAILS+1)); }
done
for f in time-ericb time-joelp time-barrettg time-calebb; do
  [[ ! -f "$DIR/commands/$f.md" ]] && pass "$f.md removed" || { echo "  FAIL: $f.md still present"; _TEST_FAILS=$((_TEST_FAILS+1)); }
done
assert_contains "$(cat "$DIR/commands/lunch.md")" "7" "lunch EventTypeID 7"
assert_contains "$(cat "$DIR/commands/break.md")" "3" "break EventTypeID 3"
assert_contains "$(cat "$DIR/commands/out.md")" "8" "out EventTypeID 8"
TIMEMD="$(cat "$DIR/commands/time.md")"
assert_contains "$TIMEMD" "logged-in user" "/time records for the logged-in user"
assert_contains "$TIMEMD" "321" "/time resolves person from username (has ID map)"
assert_contains "$TIMEMD" "1298" "/time map includes all team IDs"
[[ -f "$DIR/skills/time/SKILL.md" ]] && pass "reference skill" || { echo "  FAIL: skill"; _TEST_FAILS=$((_TEST_FAILS+1)); }
assert_not_contains "$(cat "$DIR/skills/time/SKILL.md")" "ClaudeAI2026" "skill has no secret"
finish
