#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"; H="$DIR/hooks/hooks.json"
[[ -f "$H" ]] && pass "exists" || { echo "  FAIL: missing"; _TEST_FAILS=$((_TEST_FAILS+1)); }
jq empty "$H" 2>/dev/null && pass "valid JSON" || { echo "  FAIL: invalid"; _TEST_FAILS=$((_TEST_FAILS+1)); }
assert_contains "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$H")" "time-track-per-turn.sh" "UPS wired"
# Stop is the primary recorder as of 2026-08-07. Without it the hook falls back to
# recording one turn late, which is what produced the placeholder entries.
assert_contains "$(jq -r '.hooks.Stop[0].hooks[0].command' "$H")" "time-track-per-turn.sh" "Stop wired"
assert_contains "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$H")" "session-init.sh" "SessionStart wired"
finish
