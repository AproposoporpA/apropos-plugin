#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
source "$DIR/hooks-handlers/lib/queue.sh"
export CLAUDE_PLUGIN_ROOT="$DIR"

WORK="$(mktemp -d)"; export HOME="$WORK"
export APROPOS_WRITER="$DIR/tests/mocks/mock-writer.sh"
export WRITER_LOG="$WORK/writer.log"; export WRITER_FAIL="$WORK/nofail"
chmod +x "$DIR/tests/mocks/mock-writer.sh"
# Pre-seed a stranded queued entry from a "prior offline session".
q_enqueue "$HOME/.claude/apropos-time/pending.tsv" 321 "stranded from prior session" 13 0 0 "2026-07-10 09:00:00"

OUT="$(bash "$DIR/hooks-handlers/session-init.sh"; echo rc=$?)"
assert_contains "$OUT" "rc=0" "exits 0"
assert_contains "$OUT" "Engineering" "has worktype names"
assert_contains "$OUT" "description-" "explains description file"
assert_contains "$OUT" "worktype-" "explains worktype file"
assert_contains "$OUT" "backdate" "explains backdating"
assert_not_contains "$OUT" "ClaudeAI2026" "no secret"
# Flush delivered the stranded entry and did not leak into the injected context.
assert_contains "$(cat "$WRITER_LOG" 2>/dev/null)" "stranded from prior session" "SessionStart flushed queued entry"
assert_not_contains "$OUT" "stranded from prior session" "flush output not injected into context"
[[ ! -f "$HOME/.claude/apropos-time/pending.tsv" ]] && pass "queue drained at session start" || { echo "  FAIL: queue not drained"; _TEST_FAILS=$((_TEST_FAILS+1)); }

rm -rf "$WORK"
finish
