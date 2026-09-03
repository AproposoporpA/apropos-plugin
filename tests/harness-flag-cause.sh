#!/usr/bin/env bash
# Standalone harness for the two flag wordings (#31098).
#
# The suite drives the whole hook and takes minutes. A green suite proves nothing about a
# text rule: five QA rounds on #30987 ran green while real defects sat in the screen, and
# every one of them was found by pulling the functions out and firing adversarial text at
# them in milliseconds. This does that for the placeholder split. Run it before the suite,
# not after.
#
#   bash tests/harness-flag-cause.sh
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$DIR/hooks-handlers/time-track-per-turn.sh"
FAILS=0
ok(){   echo "  ok: $1"; }
bad(){  echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

# Pull the constants and the predicate straight out of the handler, so the harness tests
# the shipped code rather than a copy of it that can drift.
eval "$(sed -n '/^DESC_PH_NONE=/p;/^DESC_PH_REJECTED=/p' "$HOOK")"
eval "$(sed -n '/^_desc_is_placeholder() {$/,/^}$/p' "$HOOK")"
DESC_MAX="$(sed -n 's/^DESC_MAX=\([0-9]*\)$/\1/p' "$HOOK" | head -1)"

[[ -n "$DESC_PH_NONE" && -n "$DESC_PH_REJECTED" ]] || { bad "handler does not define both placeholders"; echo "HARNESS FAILED ($FAILS)"; exit 1; }
[[ -n "$DESC_MAX" ]] || { bad "handler does not define DESC_MAX"; echo "HARNESS FAILED ($FAILS)"; exit 1; }

echo "== constants =="
echo "  never written: $DESC_PH_NONE"
echo "  rejected:      $DESC_PH_REJECTED"

# --- The two must be separable by text alone -------------------------------------------
[[ "$DESC_PH_NONE" != "$DESC_PH_REJECTED" ]] && ok "the two flags differ" || bad "the two flags are the same string"

# Neither may be a prefix of the other. If one were, a count of the shorter would swallow
# the longer and the split would silently report zero of one cause.
case "$DESC_PH_REJECTED" in "$DESC_PH_NONE"*) bad "rejected flag starts with the never-written flag, so a count cannot separate them" ;; *) ok "rejected flag is not prefixed by the never-written flag" ;; esac
case "$DESC_PH_NONE" in "$DESC_PH_REJECTED"*) bad "never-written flag starts with the rejected flag, so a count cannot separate them" ;; *) ok "never-written flag is not prefixed by the rejected flag" ;; esac

# A substring match in either direction breaks a naive grep count, which is exactly how
# these will be counted in Apropos and in the measurement script.
case "$DESC_PH_REJECTED" in *"$DESC_PH_NONE"*) bad "rejected flag CONTAINS the never-written flag; grep counts would double-count" ;; *) ok "neither flag contains the other" ;; esac
case "$DESC_PH_NONE" in *"$DESC_PH_REJECTED"*) bad "never-written flag CONTAINS the rejected flag; grep counts would double-count" ;; *) ok "neither flag contains the other (reverse)" ;; esac

# The historical flag must not change meaning. The record is full of it and every one of
# those entries was written before the causes were split.
[[ "$DESC_PH_NONE" == "[needs description]" ]] && ok "the historical flag is unchanged, so old entries keep their meaning" || bad "the historical flag changed, which silently rewrites every entry already in the record"

# Must not collide with the legacy string that comes from outside this recorder.
for ph in "$DESC_PH_NONE" "$DESC_PH_REJECTED"; do
  case "$ph" in *"Work Description Needed"*) bad "flag collides with the legacy external string: $ph" ;; *) ok "no collision with the legacy external string: $ph" ;; esac
done

# --- Invoice-facing constraints --------------------------------------------------------
for ph in "$DESC_PH_NONE" "$DESC_PH_REJECTED"; do
  (( ${#ph} <= DESC_MAX )) && ok "fits the cap with room for a project name: $ph (${#ph})" || bad "flag alone exceeds DESC_MAX: $ph"
  printf '%s' "$ph" | grep -Eq '^\[[^]]+\]$' && ok "bracketed so it stands out on a timesheet: $ph" || bad "not bracketed: $ph"
  printf '%s' "$ph" | grep -Eqi 'claude|anthropic|\bai\b|assistant|chatbot|copilot|agent' && bad "names the tooling on an invoice-facing field: $ph" || ok "names no tooling: $ph"
  printf '%s' "$ph" | grep -Eqi 'needs|rewrite|correct|missing' && ok "reads as asking for a correction: $ph" || bad "does not ask for a correction: $ph"
  # House rules ban these outright from the field.
  case "$ph" in *[$'—–‘’“”']*) bad "carries a banned dash or curly quote: $ph" ;; *) ok "no banned punctuation: $ph" ;; esac
  case "$ph" in *\\*) bad "carries a backslash, which the screen bans as a path: $ph" ;; *) ok "no backslash: $ph" ;; esac
  # A flag containing a pipe would break every downstream split on the writer log.
  case "$ph" in *"|"*) bad "carries a pipe, which breaks the writer log format: $ph" ;; *) ok "no pipe: $ph" ;; esac
done

# --- The predicate the dedup guard depends on ------------------------------------------
# A flag is an admission that we do not know what the work was, not evidence that two
# turns were the same. Every flag must be recognised, or the second flagged turn inside
# 15 minutes is deduped away and its time is lost outright (#30987 QA round 3).
echo "== _desc_is_placeholder =="
must_match=(
  "$DESC_PH_NONE"
  "$DESC_PH_REJECTED"
  "$DESC_PH_NONE apropos-plugin"
  "$DESC_PH_REJECTED apropos-plugin"
  "$DESC_PH_NONE some-very-long-folder-name-here"
  "$DESC_PH_REJECTED some-very-long-folder-name-here"
)
for m in "${must_match[@]}"; do
  _desc_is_placeholder "$m" && ok "recognised as a flag: $m" || bad "NOT recognised as a flag, so dedup can drop its time: $m"
done

must_not_match=(
  "Deployed the inventory sync correction and verified it on the server."
  "Rebuilt the template to be responsive and verified it at five widths."
  "Corrected the nightly push so it stops being rejected."
  ""
  " "
  "Wrote the estimate email."
  # Real work that merely mentions the words. Neither may be swallowed by a loose match.
  "Rewrote the description screen so it stops refusing real entries."
  "Reviewed what the release still needs before it can ship."
  "[Work Description Needed]"
)
for m in "${must_not_match[@]}"; do
  _desc_is_placeholder "$m" && bad "a real description was treated as a flag: '$m'" || ok "not a flag: '${m:0:44}'"
done

if (( FAILS > 0 )); then echo "HARNESS FAILED ($FAILS)"; exit 1; else echo "HARNESS PASSED"; exit 0; fi
