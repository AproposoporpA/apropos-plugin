#!/usr/bin/env bash
# The description fallback chain: model file, then the transcript, then a placeholder.
#
# Added 2026-08-12. The README has advertised the transcript fallback since 0.2.0 but
# nothing implemented it, so a turn where the model forgot to write a description
# recorded "[needs description] <project>". Where the working directory is named
# "Claude" that put a literal AI reference onto a client-invoice-facing field.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
HOOK="$DIR/hooks-handlers/time-track-per-turn.sh"
WORK="$(mktemp -d)"
export HOME="$WORK"
export APROPOS_WRITER="$DIR/tests/mocks/mock-writer.sh"
export WRITER_LOG="$WORK/writer.log"
export USERNAME="ericbarone"
TT="$WORK/claude-timetrack"; mkdir -p "$TT"
export APROPOS_TRACK_DIR="$TT"
chmod +x "$DIR/tests/mocks/mock-writer.sh"

# Build the payload with jq so a Windows cwd's backslashes are escaped properly. Using
# printf here produced invalid JSON escapes, jq dropped the cwd, and the project-name
# assertion below passed for the wrong reason.
prompt(){
  jq -nc --arg sid "$1" --arg cwd "${2:-/home/eric/projects/apropos-plugin}" \
    '{hook_event_name:"UserPromptSubmit", session_id:$sid, cwd:$cwd, prompt:"go"}' | bash "$HOOK"
}
stop(){ printf '{"hook_event_name":"Stop","session_id":"%s"}' "$1" | bash "$HOOK"; }

# Build a transcript whose final assistant text block is $1.
mktranscript(){
  local out="$1"; shift
  : > "$out"
  for t in "$@"; do
    printf '{"type":"assistant","timestamp":"2026-08-12T10:00:00Z","message":{"content":[{"type":"text","text":%s}]}}\n' \
      "$(printf '%s' "$t" | jq -Rs .)" >> "$out"
  done
}

if ! command -v jq >/dev/null 2>&1; then echo "  SKIP: jq not present"; finish; fi

# 1. No description file, but a transcript exists -> describe from the last reply.
mktranscript "$WORK/t1.jsonl" "Earlier reply that must not be used." \
  "Deployed the inventory sync correction and verified it on the server. Both processes came back up."
export APROPOS_TRANSCRIPT="$WORK/t1.jsonl"
rm -f "$WRITER_LOG"; prompt s1; stop s1
L="$(cat "$WRITER_LOG" 2>/dev/null)"
assert_not_contains "$L" "needs description" "transcript fallback replaces the placeholder"
assert_contains "$L" "Deployed the inventory sync correction and verified it on the server." "uses the final reply's first sentence"
assert_not_contains "$L" "Earlier reply" "earlier blocks are not used"

# 2. A labelled summary at the end wins over the body.
mktranscript "$WORK/t2.jsonl" "Long body with lots of mechanism and detail nobody wants on an invoice. Summary: Rebuilt the template and verified it at five widths."
export APROPOS_TRANSCRIPT="$WORK/t2.jsonl"
rm -f "$WRITER_LOG"; prompt s2; stop s2
assert_contains "$(cat "$WRITER_LOG")" "Rebuilt the template and verified it at five widths." "labelled summary is preferred"

# 3. The model's own file still wins over the transcript.
mktranscript "$WORK/t3.jsonl" "Something the transcript says."
export APROPOS_TRANSCRIPT="$WORK/t3.jsonl"
rm -f "$WRITER_LOG"; prompt s3
printf '%s' 'Wrote the estimate email' > "$TT/description-s3.txt"; stop s3
L="$(cat "$WRITER_LOG")"
assert_contains "$L" "Wrote the estimate email" "model file beats the transcript"
assert_not_contains "$L" "Something the transcript says" "transcript not consulted when a description exists"

# 4. A transcript that names the tooling is rejected, not written to an invoice field.
mktranscript "$WORK/t4.jsonl" "Claude updated the plugin and reran the suite for you."
export APROPOS_TRANSCRIPT="$WORK/t4.jsonl"
rm -f "$WRITER_LOG"; prompt s4; stop s4
L="$(cat "$WRITER_LOG")"
assert_not_contains "$L" "Claude" "an AI reference from the transcript is refused"
assert_contains "$L" "needs description" "falls through to the placeholder instead"

# 5. Markdown and a leading timestamp are stripped.
mktranscript "$WORK/t5.jsonl" "2026-08-12 14:30:00 UTC **Corrected** the \`nightly\` push so it stops being rejected."
export APROPOS_TRANSCRIPT="$WORK/t5.jsonl"
rm -f "$WRITER_LOG"; prompt s5; stop s5
L="$(cat "$WRITER_LOG")"
assert_not_contains "$L" "**" "markdown emphasis stripped"
assert_not_contains "$L" "2026-08-12 14:30" "leading timestamp stripped"
assert_contains "$L" "Corrected the nightly push" "text survives the strip"

# 6. No transcript at all -> placeholder, as before.
unset APROPOS_TRANSCRIPT
rm -f "$WRITER_LOG"; prompt s6; stop s6
assert_contains "$(cat "$WRITER_LOG")" "needs description" "placeholder still used when nothing is available"

# 7. REGRESSION: a project directory named "Claude" must not be tagged onto the
#    placeholder. This is what put "[needs description] Claude" on Barrett's timesheet.
rm -f "$WRITER_LOG"; prompt s7 'R:\Barrett Goldberg\Claude'; stop s7
L="$(cat "$WRITER_LOG")"
assert_not_contains "$L" "Claude" "AI-named project is not tagged onto the placeholder"
assert_contains "$L" "[needs description]" "placeholder itself is still flagged"

# 8. An ordinary project name is still tagged.
rm -f "$WRITER_LOG"; prompt s8 '/home/eric/projects/apropos-plugin'; stop s8
assert_contains "$(cat "$WRITER_LOG")" "[needs description] apropos-plugin" "ordinary project name still tagged"

# 9. The derived description respects the 255 cap and does not cut mid-word.
long="$(printf 'Investigated the queue and rewrote the delivery path %.0s' $(seq 1 12))"
mktranscript "$WORK/t9.jsonl" "$long"
export APROPOS_TRANSCRIPT="$WORK/t9.jsonl"
rm -f "$WRITER_LOG"; prompt s9; stop s9
D="$(cut -d'|' -f2 < "$WRITER_LOG")"
if (( ${#D} <= 255 )); then pass "derived description within the 255 cap (${#D})"; else echo "  FAIL: ${#D} chars"; fi
case "$D" in *" ") echo "  FAIL: trailing space" ;; *) pass "no trailing partial word" ;; esac

# 10. Candidates below the quality floor are refused rather than written.
#     Measured on real sessions: "Sent", "Draft below", "Noted, that reads well".
mktranscript "$WORK/t10.jsonl" "Sent."
export APROPOS_TRANSCRIPT="$WORK/t10.jsonl"
rm -f "$WRITER_LOG"; prompt s10; stop s10
assert_contains "$(cat "$WRITER_LOG")" "needs description" "too-thin candidate is refused"

# 11. A candidate carrying a file path is refused; paths are banned from the field.
mktranscript "$WORK/t11.jsonl" "Spec doc updated so it no longer says the mobile layer is missing: R:\Barrett Goldberg\specs.md and that is done."
export APROPOS_TRANSCRIPT="$WORK/t11.jsonl"
rm -f "$WRITER_LOG"; prompt s11; stop s11
L="$(cat "$WRITER_LOG")"
assert_not_contains "$L" "specs.md" "file path never reaches the description"
assert_contains "$L" "needs description" "path-bearing candidate falls through"

# 12. APROPOS_DERIVE=off restores the old placeholder-only behaviour.
mktranscript "$WORK/t12.jsonl" "Deployed the inventory sync correction and verified it on the server."
export APROPOS_TRANSCRIPT="$WORK/t12.jsonl"
export APROPOS_DERIVE=off
rm -f "$WRITER_LOG"; prompt s12; stop s12
assert_contains "$(cat "$WRITER_LOG")" "needs description" "derive can be switched off"
unset APROPOS_DERIVE

# 13. Conversational acknowledgements are refused. These pass a length floor but say
#     nothing about the work, so shape is what rejects them, not length.
for ack in "Noted, that reads well and the ask is clear and I agree." "Perfect, that covers everything you asked about here." "Yes, that is exactly what the report is showing today."; do
  mktranscript "$WORK/t13.jsonl" "$ack"
  export APROPOS_TRANSCRIPT="$WORK/t13.jsonl"
  rm -f "$WRITER_LOG"; rm -f "$TT/last-entry-s13.txt"; prompt s13; stop s13
  assert_contains "$(cat "$WRITER_LOG")" "needs description" "acknowledgement refused: ${ack:0:22}"
done

# 14. A short but real description is KEPT. A 60-character floor was tried and threw
#     these out, which is why the filter is by shape rather than length.
mktranscript "$WORK/t14.jsonl" "Rebuilt the template and verified it at five widths."
export APROPOS_TRANSCRIPT="$WORK/t14.jsonl"
rm -f "$WRITER_LOG"; prompt s14; stop s14
assert_contains "$(cat "$WRITER_LOG")" "Rebuilt the template and verified it at five widths." "short real description survives"

finish
