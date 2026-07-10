#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
M="$DIR/.claude-plugin/plugin.json"
[[ -f "$M" ]] && pass "plugin.json exists" || { echo "  FAIL: missing"; _TEST_FAILS=$((_TEST_FAILS+1)); }
jq empty "$M" 2>/dev/null && pass "valid JSON" || { echo "  FAIL: invalid JSON"; _TEST_FAILS=$((_TEST_FAILS+1)); }
assert_eq "apropos" "$(jq -r '.name' "$M" 2>/dev/null)" "name is apropos"
if grep -rniE 'ClaudeAI2026|claudeaproposreadonly|password=|connectionstring' "$DIR" --include='*.json' --include='*.sh' --include='*.md' -l 2>/dev/null | grep -vE '/(docs|tests)/'; then
  echo "  FAIL: possible secret in shipped files"; _TEST_FAILS=$((_TEST_FAILS+1));
else pass "no secrets in shipped files"; fi
finish
