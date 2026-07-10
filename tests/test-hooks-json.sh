#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"; H="$DIR/hooks/hooks.json"
[[ -f "$H" ]] && pass "exists" || { echo "  FAIL: missing"; _TEST_FAILS=$((_TEST_FAILS+1)); }
jq empty "$H" 2>/dev/null && pass "valid JSON" || { echo "  FAIL: invalid"; _TEST_FAILS=$((_TEST_FAILS+1)); }
assert_contains "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$H")" "time-track-per-turn.sh" "UPS wired"
assert_contains "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$H")" "session-init.sh" "SessionStart wired"
finish
