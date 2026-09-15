#!/usr/bin/env bash
# The ledger records which entries were flagged and what produced them, so a later pass
# can revisit them. Without it a flagged entry is unreachable the moment its activity
# closes.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
WORK="$(mktemp -d)"
export APROPOS_LEDGER_FILE="$WORK/flagged.tsv"
source "$DIR/hooks-handlers/lib/ledger.sh"

fl_record "2026-09-15 16:04:00" "sess-a" "/repo/one" 1789424974
fl_record "2026-09-15 16:09:00" "sess-b" "/repo/two" 1789425082

got="$(fl_pending)"
assert_contains "$got" "2026-09-15 16:04:00" "a flagged entry is remembered"
assert_contains "$got" "sess-a" "its session is remembered"
assert_contains "$got" "/repo/one" "its working directory is remembered"

fl_clear "2026-09-15 16:04:00"
got="$(fl_pending)"
assert_not_contains "$got" "2026-09-15 16:04:00" "a repaired entry leaves the ledger"
assert_contains "$got" "2026-09-15 16:09:00" "clearing one entry leaves the others"

fl_record "2026-09-15 16:09:00" "sess-b" "/repo/two" 1789425082
assert_eq "1" "$(fl_pending | grep -c '^2026-09-15 16:09:00')" "recording the same entry twice keeps one row"

# The hook itself must write to the ledger, not just the library.
HOOK="$DIR/hooks-handlers/time-track-per-turn.sh"
H="$(mktemp -d)"; export HOME="$H"
export APROPOS_LEDGER_FILE="$H/flagged.tsv"
export APROPOS_WRITER="$DIR/tests/mocks/mock-writer.sh"
export WRITER_LOG="$H/writer.log"
export APROPOS_OPEN_FILE="$H/open-entries.tsv"
export USERNAME="barrettgoldberg"
TT="$H/claude-timetrack"; mkdir -p "$TT"; export APROPOS_TRACK_DIR="$TT"
export APROPOS_DERIVE=off
printf '28682' > "$TT/task-sess-hook.txt"
printf '{"hook_event_name":"UserPromptSubmit","session_id":"sess-hook","cwd":"/repo/thing","prompt":"go"}' | bash "$HOOK" >/dev/null 2>&1
printf '{"hook_event_name":"Stop","session_id":"sess-hook"}' | bash "$HOOK" >/dev/null 2>&1
got="$(fl_pending)"
assert_contains "$got" "sess-hook" "the hook records a flagged entry against its session"
assert_contains "$got" "/repo/thing" "and against the directory that produced it"

finish
