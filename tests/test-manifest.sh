#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
M="$DIR/.claude-plugin/plugin.json"
[[ -f "$M" ]] && pass "plugin.json exists" || { echo "  FAIL: missing"; _TEST_FAILS=$((_TEST_FAILS+1)); }
jq empty "$M" 2>/dev/null && pass "valid JSON" || { echo "  FAIL: invalid JSON"; _TEST_FAILS=$((_TEST_FAILS+1)); }
assert_eq "apropos" "$(jq -r '.name' "$M" 2>/dev/null)" "name is apropos"

# marketplace.json carries its own version and it is the one /plugin update reads. It was
# left at 0.2.3 while plugin.json moved on, and three releases reached nobody who was
# waiting to be offered them. Nothing enforced the two agreeing, so nothing caught it.
# Added alongside #31098 because this release has to ship through that same path.
MP="$DIR/.claude-plugin/marketplace.json"
[[ -f "$MP" ]] && pass "marketplace.json exists" || { echo "  FAIL: missing marketplace.json"; _TEST_FAILS=$((_TEST_FAILS+1)); }
jq empty "$MP" 2>/dev/null && pass "marketplace.json is valid JSON" || { echo "  FAIL: marketplace.json invalid JSON"; _TEST_FAILS=$((_TEST_FAILS+1)); }
assert_eq "$(jq -r '.version' "$M" 2>/dev/null)" "$(jq -r '.plugins[] | select(.name=="apropos") | .version' "$MP" 2>/dev/null)" \
  "marketplace.json version matches plugin.json, so /plugin update offers this release"
if grep -rniE 'ClaudeAI2026|claudeaproposreadonly|password=|connectionstring' "$DIR" --include='*.json' --include='*.sh' --include='*.md' -l 2>/dev/null | grep -vE '/(docs|tests)/'; then
  echo "  FAIL: possible secret in shipped files"; _TEST_FAILS=$((_TEST_FAILS+1));
else pass "no secrets in shipped files"; fi
finish
