#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
WORK="$(mktemp -d)"; export HOME="$WORK"; mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/CLAUDE.md" <<'EOF'
# User
## Time tracking - per-turn Apropos convention
old hand-pasted block
## Keep me
EOF
OUT="$(bash "$DIR/setup/setup.sh" --remove-legacy; echo rc=$?)"
assert_contains "$OUT" "rc=0" "exits 0"
assert_contains "$OUT" "SETUP OK" "reports OK"
MD="$(cat "$HOME/.claude/CLAUDE.md")"
assert_not_contains "$MD" "old hand-pasted block" "legacy block removed"
assert_contains "$MD" "Keep me" "unrelated content kept"
ls "$HOME/.claude/"CLAUDE.md.bak-* >/dev/null 2>&1 && pass "backup made" || { echo "  FAIL: no backup"; _TEST_FAILS=$((_TEST_FAILS+1)); }
OUT2="$(bash "$DIR/setup/setup.sh" --remove-legacy)"
assert_contains "$OUT2" "SETUP OK" "idempotent second run"
rm -rf "$WORK"; finish
