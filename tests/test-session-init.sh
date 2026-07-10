#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
export CLAUDE_PLUGIN_ROOT="$DIR"
OUT="$(bash "$DIR/hooks-handlers/session-init.sh"; echo rc=$?)"
assert_contains "$OUT" "rc=0" "exits 0"
assert_contains "$OUT" "Engineering" "has worktype names"
assert_contains "$OUT" "description-" "explains description file"
assert_contains "$OUT" "worktype-" "explains worktype file"
assert_contains "$OUT" "backdate" "explains backdating"
assert_not_contains "$OUT" "ClaudeAI2026" "no secret"
finish
