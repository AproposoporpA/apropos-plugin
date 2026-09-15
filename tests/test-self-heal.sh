#!/usr/bin/env bash
# The self-repair pass: a flagged entry is amended once a description can be derived
# for it, instead of sitting on the invoice until a person cleans it up by hand.
#
# The ledger (lib/ledger.sh) remembers a flagged entry's start time, session and cwd.
# This pass walks it, points desc_from_transcript at each row's own session and cwd, and
# amends the row by start time when a usable, non-flag candidate comes back. It runs once
# a turn for the running session (repair_pending "$SID", from record_turn) and once a
# machine a day for everything (repair_pending "", from the SessionStart path, gated by
# sweep_due so concurrent sessions do not all run it at once). sweep_prune drops a row
# nothing is ever going to fix.
#
# The row's CURRENT description is not recorded anywhere: the ledger only ever held the
# start time, session and cwd. What record_turn would have written is reconstructible
# from the cwd alone though (the flag text, or the flag text with the folder name
# appended), so the repair pass tries that as -ExpectDescription rather than needing a
# copy of its own. The mock amender below stands in for Update-TimeDescription.ps1's
# -StartTimeUTC path and returns its real exit codes: 0 amended, 2 the expectation did
# not match (either the wrong guess, or a person already corrected the row), 1 anything
# else (no such row).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
HOOK="$DIR/hooks-handlers/time-track-per-turn.sh"
WORK="$(mktemp -d)"
export HOME="$WORK"
export APROPOS_WRITER="$WORK/mock-writer.sh"
export APROPOS_AMENDER="$WORK/mock-amender.sh"
export WRITER_LOG="$WORK/writer.log"
export AMEND_LOG="$WORK/amend.log"
export CURRENT_DESC_DIR="$WORK/current-desc"
mkdir -p "$CURRENT_DESC_DIR"
export APROPOS_OPEN_FILE="$WORK/open-entries.tsv"
export USERNAME="barrettgoldberg"
TT="$WORK/claude-timetrack"; mkdir -p "$TT"
export APROPOS_TRACK_DIR="$TT"
export APROPOS_SWEEP_STAMP="$WORK/last-sweep"

cat > "$APROPOS_WRITER" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$WRITER_LOG"
exit 0
EOF

cat > "$APROPOS_AMENDER" <<'EOF'
#!/usr/bin/env bash
# $1 start  $2 person  $3 new description  $4 expected current description
key="${1// /_}"; key="${key//:/-}"
f="$CURRENT_DESC_DIR/$key"
if [[ ! -f "$f" ]]; then
  printf 'NOROW|%s\n' "$1" >> "$AMEND_LOG"
  exit 1
fi
cur="$(cat "$f")"
if [[ -n "${4:-}" && "$4" != "$cur" ]]; then
  printf 'MISMATCH|%s|%s|%s\n' "$1" "$4" "$cur" >> "$AMEND_LOG"
  exit 2
fi
printf 'OK|%s|%s\n' "$1" "$3" >> "$AMEND_LOG"
printf '%s' "$3" > "$f"
exit 0
EOF
chmod +x "$APROPOS_WRITER" "$APROPOS_AMENDER"

# Ledger helpers, sourced directly, exactly as test-flag-ledger.sh does, so rows can be
# seeded and inspected without going through a whole turn.
source "$DIR/hooks-handlers/lib/ledger.sh"

if ! command -v jq >/dev/null 2>&1; then echo "  SKIP: jq not present"; finish; fi

# Build a transcript whose final assistant text block is $2..., at the path
# transcript_path would resolve for session $1's cwd $2.
transcript_for() {
  local sid="$1" cwd="$2" slug
  slug="$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$HOME/.claude/projects/$slug"
  printf '%s/%s.jsonl' "$HOME/.claude/projects/$slug" "$sid"
}
mktranscript() {
  local out="$1"; shift
  : > "$out"
  for t in "$@"; do
    printf '{"type":"assistant","timestamp":"2026-09-15T10:00:00Z","message":{"content":[{"type":"text","text":%s}]}}\n' \
      "$(printf '%s' "$t" | jq -Rs .)" >> "$out"
  done
}
# What record_turn itself would have written for this folder: the flag, plus the folder
# name unless it is too long or names the tooling. Real cwds below are short and plain,
# so this is always "$ph $proj".
flag_text() { printf '%s %s' "$1" "$(basename "$2")"; }
current_file_for() { local key="${1// /_}"; key="${key//:/-}"; printf '%s/%s' "$CURRENT_DESC_DIR" "$key"; }
sweep() { printf '{"hook_event_name":"Sweep"}' | bash "$HOOK" >/dev/null 2>&1; }

# 1. A pending row whose transcript now yields a usable line is amended, and leaves the
#    ledger.
CWD1="/home/b/projects/repair-one"; SID1="heal-s1"; START1="2026-09-15 10:00:00"
fl_record "$START1" "$SID1" "$CWD1" "$(date -u +%s)"
mktranscript "$(transcript_for "$SID1" "$CWD1")" \
  "Deployed the inventory sync correction and verified it on the server."
printf '%s' "$(flag_text '[needs description]' "$CWD1")" > "$(current_file_for "$START1")"
rm -f "$APROPOS_SWEEP_STAMP"
sweep
got="$(fl_pending)"
assert_not_contains "$got" "$START1" "a repaired row leaves the ledger"
assert_contains "$(cat "$AMEND_LOG")" "OK|$START1|Deployed the inventory sync correction and verified it on the server." \
  "the derived description was written by start time"

# 2. A row a person corrected first is NOT overwritten: the mock amender refuses (its
#    text matches neither flag shape), and the row is cleared rather than retried forever.
CWD2="/home/b/projects/repair-two"; SID2="heal-s2"; START2="2026-09-15 10:05:00"
fl_record "$START2" "$SID2" "$CWD2" "$(date -u +%s)"
mktranscript "$(transcript_for "$SID2" "$CWD2")" \
  "Corrected the delivery path and verified the retry succeeded."
printf '%s' "Fixed by hand this afternoon." > "$(current_file_for "$START2")"
rm -f "$APROPOS_SWEEP_STAMP"
sweep
got="$(fl_pending)"
log="$(cat "$AMEND_LOG")"
assert_not_contains "$got" "$START2" "a corrected row is cleared rather than retried forever"
assert_contains "$log" "MISMATCH|$START2" "the amend recognizes the row no longer says either flag"
assert_not_contains "$log" "OK|$START2|" "the human correction was never overwritten"

# 3. A row whose candidate is refused or too thin stays pending, and nothing is even
#    attempted against it.
CWD3="/home/b/projects/repair-three"; SID3="heal-s3"; START3="2026-09-15 10:10:00"
fl_record "$START3" "$SID3" "$CWD3" "$(date -u +%s)"
mktranscript "$(transcript_for "$SID3" "$CWD3")" "Sent."
printf '%s' "$(flag_text '[needs description]' "$CWD3")" > "$(current_file_for "$START3")"
rm -f "$APROPOS_SWEEP_STAMP"
sweep
got="$(fl_pending)"
assert_contains "$got" "$START3" "an unusable candidate leaves the row pending"
assert_not_contains "$(cat "$AMEND_LOG")" "$START3" "no amend was even attempted"

# 4. repair_pending with a session filter (the per-turn call, via record_turn) touches
#    only that session's rows. A different session's row, even one that WOULD repair
#    cleanly, is left for its own turn or the daily sweep.
CWD4A="/home/b/projects/repair-four-a"; SID4A="heal-s4a"; START4A="2026-09-15 10:15:00"
CWD4B="/home/b/projects/repair-four-b"; SID4B="heal-s4b"; START4B="2026-09-15 10:16:00"
fl_record "$START4A" "$SID4A" "$CWD4A" "$(date -u +%s)"
fl_record "$START4B" "$SID4B" "$CWD4B" "$(date -u +%s)"
mktranscript "$(transcript_for "$SID4A" "$CWD4A")" \
  "Rebuilt the release checklist and verified every item against the manifest."
mktranscript "$(transcript_for "$SID4B" "$CWD4B")" \
  "Reviewed the second queue and cleared the backlog of stale claims."
printf '%s' "$(flag_text '[needs description]' "$CWD4A")" > "$(current_file_for "$START4A")"
printf '%s' "$(flag_text '[needs description]' "$CWD4B")" > "$(current_file_for "$START4B")"
# A live turn for session 4a only, with an ordinary description of its own, so the turn
# does not add anything new to the ledger. record_turn's own repair_pending "$SID" call
# is what should reach row 4a.
printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"%s","prompt":"go"}' "$SID4A" "$CWD4A" | bash "$HOOK" >/dev/null 2>&1
printf 'Reviewed the request and staged the fix for release.' > "$TT/description-$SID4A.txt"
printf '{"hook_event_name":"Stop","session_id":"%s"}' "$SID4A" | bash "$HOOK" >/dev/null 2>&1
got="$(fl_pending)"
assert_not_contains "$got" "$START4A" "the current session's own pending row is repaired on its turn"
assert_contains "$got" "$START4B" "a different session's pending row is left untouched"

# 5. sweep_due gates the whole-machine pass to once per machine per day.
rm -f "$APROPOS_SWEEP_STAMP"
CWD5="/home/b/projects/repair-five"
START5A="2026-09-15 10:20:00"
fl_record "$START5A" "heal-s5a" "$CWD5" "$(date -u +%s)"
mktranscript "$(transcript_for "heal-s5a" "$CWD5")" \
  "Closed out the review and merged the change into the release branch."
printf '%s' "$(flag_text '[needs description]' "$CWD5")" > "$(current_file_for "$START5A")"
sweep
assert_not_contains "$(fl_pending)" "$START5A" "a fresh stamp file: the sweep runs and repairs the row"
assert_eq "$(date -u +%Y-%m-%d)" "$(cat "$APROPOS_SWEEP_STAMP")" "sweep_mark stamps today's date"

START5B="2026-09-15 10:21:00"
fl_record "$START5B" "heal-s5b" "$CWD5" "$(date -u +%s)"
mktranscript "$(transcript_for "heal-s5b" "$CWD5")" \
  "Closed out a second review and merged that change too."
printf '%s' "$(flag_text '[needs description]' "$CWD5")" > "$(current_file_for "$START5B")"
sweep
assert_contains "$(fl_pending)" "$START5B" "a same-day stamp: a second sweep does not run again"

printf '2026-09-01' > "$APROPOS_SWEEP_STAMP"
sweep
assert_not_contains "$(fl_pending)" "$START5B" "an older stamp date: the sweep is due again and runs"

# 6. sweep_prune drops a row older than the window and keeps a recent one. Neither row
#    has a transcript, so repair alone could not remove either: pruning is the only thing
#    that can drop the old one here.
rm -f "$APROPOS_SWEEP_STAMP"
CWD6="/home/b/projects/repair-six"
OLD_START="2026-09-01 09:00:00"; OLD_EPOCH=$(( $(date -u +%s) - 10*86400 ))
RECENT_START="2026-09-15 09:00:00"; RECENT_EPOCH="$(date -u +%s)"
fl_record "$OLD_START" "heal-old" "$CWD6" "$OLD_EPOCH"
fl_record "$RECENT_START" "heal-recent" "$CWD6" "$RECENT_EPOCH"
sweep
got="$(fl_pending)"
assert_not_contains "$got" "$OLD_START" "a row past the sweep window is pruned"
assert_contains "$got" "$RECENT_START" "a row inside the window is kept"

finish
