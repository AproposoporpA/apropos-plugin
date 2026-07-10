#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
HOOK="$DIR/hooks-handlers/time-track-per-turn.sh"
WORK="$(mktemp -d)"
export HOME="$WORK"                 # queue lands in $HOME/.claude/apropos-time
export APROPOS_WRITER="$DIR/tests/mocks/mock-writer.sh"
export WRITER_LOG="$WORK/writer.log"
export WRITER_FAIL="$WORK/FAIL"
export USERNAME="ericbarone"
TT="$WORK/claude-timetrack"; mkdir -p "$TT"
export APROPOS_TRACK_DIR="$TT"
chmod +x "$DIR/tests/mocks/mock-writer.sh"
run(){ echo "$1" | bash "$HOOK"; }

# 1. No model files -> flagged, project-tagged placeholder + worktype 13 (NOT the prompt)
run '{"session_id":"s1","cwd":"/home/eric/projects/apropos-plugin","prompt":"go"}'
L="$(cat "$WRITER_LOG" 2>/dev/null)"
assert_contains "$L" "321|[needs description] apropos-plugin|13|" "fallback uses flagged placeholder + project"
assert_not_contains "$L" "|go|" "raw prompt is NOT used as description"

# 2. Model files override the fallback
rm -f "$WRITER_LOG"
printf 'Refactored auth module' > "$TT/description-s2.txt"
printf '50' > "$TT/worktype-s2.txt"
run '{"session_id":"s2","prompt":"ignored because model wrote files"}'
assert_contains "$(cat "$WRITER_LOG")" "321|Refactored auth module|50|" "model files used over prompt"

# 3. Dedup: same segment within 15 min -> second not recorded
rm -f "$WRITER_LOG"
printf 'seg work' > "$TT/description-s3.txt"; printf '13' > "$TT/worktype-s3.txt"
run '{"session_id":"s3","prompt":"a"}'
printf 'seg work again' > "$TT/description-s3.txt"; printf '13' > "$TT/worktype-s3.txt"
run '{"session_id":"s3","prompt":"b"}'
assert_eq "1" "$(grep -c '321|' "$WRITER_LOG")" "duplicate segment recorded once"

# 4. Write failure -> queued; next turn (writer restored, new worktype) -> both delivered
rm -f "$WRITER_LOG"; touch "$WRITER_FAIL"
printf 'will fail then queue' > "$TT/description-s4.txt"; printf '92' > "$TT/worktype-s4.txt"
run '{"session_id":"s4","prompt":"x"}'
[[ -f "$HOME/.claude/apropos-time/pending.tsv" ]] && pass "failed write queued locally" || { echo "  FAIL: not queued"; _TEST_FAILS=$((_TEST_FAILS+1)); }
rm -f "$WRITER_FAIL"; rm -f "$WRITER_LOG"
printf 'next turn' > "$TT/description-s4.txt"; printf '23' > "$TT/worktype-s4.txt"
run '{"session_id":"s4","prompt":"y"}'
assert_contains "$(cat "$WRITER_LOG")" "will fail then queue" "queued entry flushed on recovery"
[[ ! -f "$HOME/.claude/apropos-time/pending.tsv" ]] && pass "queue drained after recovery" || { echo "  FAIL: queue not drained"; _TEST_FAILS=$((_TEST_FAILS+1)); }

# 5. Unknown user -> nothing recorded, exit 0
rm -f "$WRITER_LOG"; export USERNAME="stranger"
run '{"session_id":"s5","prompt":"hello"}'; RC=$?
assert_eq "0" "$RC" "hook exits 0 for unknown user"
[[ ! -f "$WRITER_LOG" ]] && pass "unknown user records nothing" || { echo "  FAIL: recorded for unknown"; _TEST_FAILS=$((_TEST_FAILS+1)); }

rm -rf "$WORK"
finish
