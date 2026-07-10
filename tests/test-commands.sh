#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
for f in time-ericb time-joelp time-barrettg time-calebb break lunch out; do
  [[ -f "$DIR/commands/$f.md" ]] && pass "$f.md exists" || { echo "  FAIL: $f.md"; _TEST_FAILS=$((_TEST_FAILS+1)); }
done
assert_contains "$(cat "$DIR/commands/lunch.md")" "7" "lunch EventTypeID 7"
assert_contains "$(cat "$DIR/commands/break.md")" "3" "break EventTypeID 3"
assert_contains "$(cat "$DIR/commands/out.md")" "8" "out EventTypeID 8"
assert_contains "$(cat "$DIR/commands/time-joelp.md")" "344" "joel person 344"
[[ -f "$DIR/skills/time/SKILL.md" ]] && pass "reference skill" || { echo "  FAIL: skill"; _TEST_FAILS=$((_TEST_FAILS+1)); }
assert_not_contains "$(cat "$DIR/skills/time/SKILL.md")" "ClaudeAI2026" "skill has no secret"
finish
