#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
WORK="$(mktemp -d)"; export HOME="$WORK"; mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/CLAUDE.md" <<'EOF'
# User
## Time tracking — per-turn Apropos convention (established 2026-05-13, refined 2026-05-14)
em-dash block with trailing text
more lines
## Time tracking - per-turn Apropos convention
hyphen block
## Keep me
kept content
EOF
cat > "$HOME/.claude/settings.json" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "bash \"R:/Intranet/ClaudeAI/skills/work-management/time/time-track-per-turn.sh\"", "timeout": 10 } ] }
    ],
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "echo keepme-hook" } ] }
    ]
  },
  "statusLine": { "type": "command", "command": "keepme-status" }
}
EOF
OUT="$(bash "$DIR/setup/setup.sh" --remove-legacy; echo rc=$?)"
assert_contains "$OUT" "rc=0" "exits 0"
assert_contains "$OUT" "SETUP OK" "reports OK"
MD="$(cat "$HOME/.claude/CLAUDE.md")"
assert_not_contains "$MD" "em-dash block with trailing text" "em-dash block removed"
assert_not_contains "$MD" "hyphen block" "hyphen block removed"
assert_contains "$MD" "Keep me" "unrelated heading kept"
assert_contains "$MD" "kept content" "unrelated content kept"
ls "$HOME/.claude/"CLAUDE.md.bak-* >/dev/null 2>&1 && pass "backup made" || { echo "  FAIL: no backup"; _TEST_FAILS=$((_TEST_FAILS+1)); }
SJ="$(cat "$HOME/.claude/settings.json")"
assert_not_contains "$SJ" "time-track-per-turn.sh" "legacy settings hook removed"
assert_contains "$SJ" "keepme-hook" "unrelated SessionStart hook kept"
assert_contains "$SJ" "keepme-status" "statusLine kept"
jq empty "$HOME/.claude/settings.json" 2>/dev/null && pass "settings.json still valid JSON" || { echo "  FAIL: settings invalid"; _TEST_FAILS=$((_TEST_FAILS+1)); }
ls "$HOME/.claude/"settings.json.bak-* >/dev/null 2>&1 && pass "settings backup made" || { echo "  FAIL: no settings backup"; _TEST_FAILS=$((_TEST_FAILS+1)); }
OUT2="$(bash "$DIR/setup/setup.sh" --remove-legacy)"
assert_contains "$OUT2" "SETUP OK" "idempotent second run"
rm -rf "$WORK"; finish
