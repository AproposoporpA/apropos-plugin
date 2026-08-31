#!/usr/bin/env bash
# apropos plugin — per-turn time recording hook. Handles TWO events:
#
#   UserPromptSubmit — stamps the turn's real start time, flushes the queue, and
#                      recovers a description that Stop failed to consume.
#   Stop             — the primary recorder. Runs after the response is complete,
#                      so the model's description for THIS turn already exists.
#
# Always records (or durably queues) exactly one start-marker per turn.
# Credentialed write stays in R: Record-Time.ps1; this layer is local so it
# survives R:/network outages. Exits 0 always.
#
# WHY TWO EVENTS (changed 2026-08-07). The hook previously ran on UserPromptSubmit
# only, which fires at the START of a turn and therefore read the description file
# written at the END of the previous turn. Three consequences, all measured on
# Barrett's machine (person 276) on 2026-08-07:
#   1. Turn 1 of every session had no description file yet, so it recorded the
#      placeholder "[needs description] <cwd basename>". With cwd
#      "R:\Barrett Goldberg\Claude" that literal string was "[needs description]
#      Claude", putting an AI reference on a client-invoice-facing field. 13 of
#      that day's 39 entries.
#   2. The final turn of every session was never recorded, because no further
#      prompt ever arrived to consume its file. 7 orphaned description files were
#      sitting in /tmp/claude-timetrack at worktypes 18, 48, 57 and 86 with zero
#      entries at any of those worktypes in the database.
#   3. Every description that did land was stamped with the NEXT turn's start time.
# Recording on Stop fixes all three: the description is the current turn's, the
# final turn fires, and StartTime comes from the stamp laid down at prompt time.
set +e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/queue.sh"
source "$HERE/lib/writer.sh"

TRACK_DIR="${APROPOS_TRACK_DIR:-/tmp/claude-timetrack}"
QUEUE="${HOME}/.claude/apropos-time/pending.tsv"
mkdir -p "$TRACK_DIR" "${HOME}/.claude/apropos-time" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

# Parse session id + cwd + event (prefer jq; grep fallback).
if command -v jq >/dev/null 2>&1; then
  SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
  EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)"
else
  SID="$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')"
  CWD="$(printf '%s' "$INPUT" | grep -o '"cwd":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')"
  EVENT="$(printf '%s' "$INPUT" | grep -o '"hook_event_name":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')"
fi
SID="${SID:-${CLAUDE_CODE_SESSION_ID:-nosession}}"
# Older payloads / direct invocation carry no event name. Treat as UserPromptSubmit
# so an un-migrated hooks.json keeps the previous single-event behaviour.
EVENT="${EVENT:-UserPromptSubmit}"

# Opt out of time recording entirely. Scheduled and headless runs are nobody's
# working time: a `claude -p` job fired by Task Scheduler has no human at the keyboard
# and never writes a description file, so every one of them booked a
# "[needs description] <cwd>" placeholder against Barrett. Over the 2026-08-08 weekend
# that was 7 scheduled runs, which the queue defect then multiplied into 239 rows.
#
# Two ways to opt out, because the launchers and the agent directories are maintained
# by different people:
#   APROPOS_TIME_TRACKING=off   (or APROPOS_SKIP=1) in the scheduled launcher's env
#   a .apropos-notime file in the working directory, which covers that agent however
#   it is started, including a manual run
case "$(printf '%s' "${APROPOS_TIME_TRACKING:-}" | tr '[:upper:]' '[:lower:]')" in
  off|0|false|no|disabled) exit 0 ;;
esac
case "$(printf '%s' "${APROPOS_SKIP:-}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) exit 0 ;;
esac
# Stamp the working directory before the marker check, not after. The Stop payload
# carries no cwd, so without this an opted-out session would exit at UserPromptSubmit
# having recorded nothing, and then Stop would have no cwd to test the marker against
# and would record anyway.
[[ -n "$CWD" ]] && printf '%s' "$CWD" > "$TRACK_DIR/cwd-$SID.txt" 2>/dev/null
_optout_dir="$CWD"; [[ -z "$_optout_dir" && -s "$TRACK_DIR/cwd-$SID.txt" ]] && _optout_dir="$(cat "$TRACK_DIR/cwd-$SID.txt")"
if [[ -n "$_optout_dir" ]]; then
  _d="${_optout_dir//\\//}"
  # Walk up from the working directory so a marker at an agent root covers its subdirs.
  while [[ -n "$_d" && "$_d" != "/" && "$_d" != "." ]]; do
    if [[ -e "$_d/.apropos-notime" ]]; then exit 0; fi
    _parent="$(dirname "$_d")"; [[ "$_parent" == "$_d" ]] && break; _d="$_parent"
  done
fi

# Person resolution (cannot record without it — not a transient failure).
u="$(printf '%s' "${USERNAME:-${USER:-}}" | tr '[:upper:]' '[:lower:]')"
case "$u" in
  ericbarone) PERSON=321 ;; joelperez) PERSON=344 ;;
  barrettgoldberg) PERSON=276 ;; calebbarone) PERSON=1298 ;;
  *) exit 0 ;;
esac

descf="$TRACK_DIR/description-$SID.txt"
wtf="$TRACK_DIR/worktype-$SID.txt"
taskf="$TRACK_DIR/task-$SID.txt"
projf="$TRACK_DIR/project-$SID.txt"
# The worktype the model wrote is a one-shot file, deleted at the end of the turn.
# These two are what make it survive: the session carries its last worktype, and the
# machine remembers the worktype last used on each task so a NEW session on known
# work does not fall back to Engineering. See #30986.
stickywtf="$TRACK_DIR/worktype-sticky-$SID.txt"
taskwtf="$TRACK_DIR/task-worktype.tsv"
lastf="$TRACK_DIR/last-entry-$SID.txt"
startf="$TRACK_DIR/turnstart-$SID.txt"
cwdf="$TRACK_DIR/cwd-$SID.txt"

NOW="$(date -u +%s)"

# Description cap. The DB column is nvarchar(500) but the downstream Intervals
# import truncates at 255, which was cutting real entries mid-sentence with no
# signal. Cap here so the boundary is visible and consistent.
DESC_MAX=255

_hash() {
  # Short fingerprint of the description, so dedup can tell "same activity
  # re-marked" from "new work at the same worktype/task".
  if command -v md5sum >/dev/null 2>&1; then printf '%s' "$1" | md5sum | cut -c1-10
  elif command -v cksum >/dev/null 2>&1; then printf '%s' "$1" | cksum | tr -d ' '
  else printf '%s' "${#1}"; fi
}

# Cap how far back a turn-start stamp may drag an entry. The stamp is written at
# UserPromptSubmit and consumed when the response ends, so a session left idle keeps a
# stale stamp: observed 2026-08-11, work done at 07:13 PT was stamped 21:06 PT the
# previous evening, a 607-minute backdate that moved it onto the wrong day. Beyond this
# window the stamp is not a credible start time, so fall back to now-60s.
APROPOS_MAX_BACKDATE_SECS="${APROPOS_MAX_BACKDATE_SECS:-7200}"

# start_from_stamp <stampfile> -> echoes a UTC "YYYY-MM-DD HH:MM:SS"
start_from_stamp() {
  local f="$1" ts age
  if [[ -s "$f" ]]; then
    ts="$(tr -d '[:space:]' < "$f")"
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
      age=$(( NOW - ts ))
      if (( age >= 0 && age <= APROPOS_MAX_BACKDATE_SECS )); then
        date -u -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
        return 0
      fi
    fi
  fi
  date -u -d '1 minute ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -v-1M '+%Y-%m-%d %H:%M:%S' 2>/dev/null
}

# Locate this session's transcript. Claude Code stores it at
#   ~/.claude/projects/<slug>/<session-id>.jsonl
# where <slug> is the working directory with every non-alphanumeric character
# replaced by a hyphen ("R:\Barrett Goldberg\Claude" -> "R--Barrett-Goldberg-Claude").
# Derived rather than read from the hook payload, because the Stop payload's fields
# are not guaranteed and the working directory is already stamped at prompt time.
# $APROPOS_TRANSCRIPT overrides, which is how the tests drive this.
transcript_path() {
  local sid="$1" dir="$2" slug p
  if [[ -n "${APROPOS_TRANSCRIPT:-}" ]]; then
    [[ -s "$APROPOS_TRANSCRIPT" ]] && { printf '%s' "$APROPOS_TRANSCRIPT"; return 0; }
    return 1
  fi
  [[ -n "$dir" && -n "$sid" ]] || return 1
  slug="$(printf '%s' "$dir" | sed 's/[^A-Za-z0-9]/-/g')"
  p="${HOME}/.claude/projects/${slug}/${sid}.jsonl"
  [[ -s "$p" ]] && { printf '%s' "$p"; return 0; }
  return 1
}

# Words that must never reach an invoice-facing field, whatever the source.
APROPOS_BANNED='claude|anthropic|\bAI\b|assistant|chatbot|copilot'

# Last resort before the placeholder: describe the turn from what the response
# actually said. The final assistant text block IS this turn's answer, because Stop
# only fires once the response is complete.
#
# Added 2026-08-12. The plugin README has claimed this behaviour since 0.2.0 but no
# code implemented it, so every turn where the model forgot to write a description
# booked "[needs description] <project>" instead. On Barrett's machine the working
# directory is named "Claude", so that placeholder put a literal AI reference on a
# client-invoice-facing field, repeatedly.
# Shortest derived description worth putting on a timesheet. Measured against 12 real
# sessions: below this the candidates are things like "Sent", "Draft below" and
# "Incident is closed", which say less than an honest placeholder does.
#
# Length alone is not enough. A floor of 60 was tried and rejected because it threw
# out real descriptions ("Rebuilt the template and verified it at five widths.", 52).
# The bad short candidates are conversational acknowledgements, not short work, so
# they are matched by shape below instead.
APROPOS_DERIVE_MIN="${APROPOS_DERIVE_MIN:-40}"

# Punctuation the house style rules ban outright. Normalised rather than refused, and
# done with bash parameter expansion rather than sed: this runs on every turn, and a
# subprocess costs about half a second on the Windows shell this ships to. (#30987)
_desc_normalise() {
  local s="$1"
  s="${s//—/-}"; s="${s//–/-}"
  s="${s//‘/\'}"; s="${s//’/\'}"
  s="${s//“/\"}"; s="${s//”/\"}"
  s="${s//…/...}"
  printf '%s' "$s"
}

# Is one token a past tense verb? Irregulars were matched as whole tokens, so every
# prefixed form was invisible: "rebuilt" is not "built", "rewrote" is not "wrote",
# "resent" is not "sent", "reset" is not "set". All four open real entries in the
# record, and a record of work carrying a copula in the same clause was then refused as
# a state report. Prefixes are stripped from a known short list rather than matching any
# suffix, because "present" ends in "sent" and "asset" ends in "set". (#30987 QA round 6)
_desc_past_token() {
  local t="$1"
  case "$t" in
    *ed) return 0 ;;
    wrote|ran|sent|built|made|took|set|met|put|held|got|gave|left|told|brought|caught|found|kept|spent|dealt|began|drew|read|split|cut|shut|hit|let|won|lost|paid|said|saw|went|came|did|had|was|were) return 0 ;;
  esac
  case "$t" in
    re?*|un?*|over?*|under?*|mis?*|out?*)
      local b="${t#re}"
      [[ "$b" == "$t" ]] && b="${t#un}"
      [[ "$b" == "$t" ]] && b="${t#over}"
      [[ "$b" == "$t" ]] && b="${t#under}"
      [[ "$b" == "$t" ]] && b="${t#mis}"
      [[ "$b" == "$t" ]] && b="${t#out}"
      case "$b" in
        wrote|ran|sent|built|made|took|set|met|put|held|got|gave|left|told|brought|caught|found|kept|spent|dealt|began|drew|read|split|cut|shut|hit|let|won|lost|paid|said|saw|went|came|did|had|was|were) return 0 ;;
      esac
    ;;
  esac
  return 1
}

# Does the OPENING clause of a padded, lowercased description carry completed work?
# Returns 0 when it does. Only the first five tokens count: "Retracting Finding 3 as I
# wrote it" has a past tense verb, but it sits in a subordinate clause and the sentence
# is still narration, while "Onboarding tasks were reassigned" carries its past tense up
# front. Shared by the gerund rule and the quantifier openers. (#30987)
_desc_opens_past() {
  local tok p1="" p2="" p3="" seen=0
  for tok in $1; do
    seen=$((seen+1)); (( seen > 5 )) && break
    case "$tok" in
      *ed)
        # A PRESENT copula in front of the participle makes it a state, not work:
        # "Both programmes ARE connected" describes how things stand, while "Both
        # files WERE regenerated" is work that happened.
        #
        # The copula is not always the word immediately before. An adverb sits between
        # them constantly, and QA round 4 found that a single one defeated the check:
        # "Both changes are NOW merged", "Both PRs are ALREADY approved", "Testing is
        # ESSENTIALLY finished" all reached the invoice field. So look back three
        # tokens, not one. "have been regenerated" is deliberately NOT blocked: present
        # perfect passive reports work that was completed. (#30987 QA round 4)
        case " is are am be being " in
          *" $p1 "*|*" $p2 "*|*" $p3 "*) p3="$p2"; p2="$p1"; p1="$tok"; continue ;;
        esac
        return 0 ;;
      *)
        _desc_past_token "$tok" && return 0 ;;
    esac
    p3="$p2"; p2="$p1"; p1="$tok"
  done
  return 1
}

# Does this text read as a reply, a report or a finding rather than a record of the work?
# Returns 0 when it must NOT reach the invoice field.
#
# Rewritten 2026-08-28 after QA failed #30987. The first version only inspected the FIRST
# word, so the defect kept landing in other shapes: proper-noun and numeral subjects,
# "there is" mid sentence, gerund narration, a lowercase verdict, and commit hashes. Of
# 12 real entries recorded in the hour after it shipped, it refused none and 6 were still
# defective. Every rule below is matched against real examples from that record.
#
# No subprocesses. Everything is bash string work.
_desc_refuse() {
  local s="$1" l w p
  l="${s,,}"
  # Punctuation to spaces, padded, so a plain substring test gives word boundaries.
  p=" ${l//[^a-z0-9]/ } "
  p="${p//  / }"; p="${p//  / }"; p="${p//  / }"

  # Second person. The field is read by a customer, not by the person being replied to.
  case "$p" in *" you "*|*" your "*|*" yours "*|*" youre "*) return 0 ;; esac
  # Contracted forms survive the punctuation strip as two tokens, so match them on the
  # normalised text instead. (#30987 QA round 4)
  case "$l" in *"y'all"*|*"ya'll"*|*" yall "*|"yall "*) return 0 ;; esac

  # First-person analysis and retraction, which narrates thinking rather than work.
  case "$p" in
    " i "*|*" i had "*|*" i have not "*|*" i cannot "*|*" i could not "*|*" i was wrong "*|*" i am not "*|*" i do not "*) return 0 ;;
  esac

  w="${l%% *}"; w="${w//[^a-z0-9]/}"
  # A condition or a state, not an action.
  case " the it that this there these those nothing here " in
    *" $w "*) return 0 ;;
  esac
  # "all" and "both" are quantifiers, and in front of completed work they open an
  # ordinary record: "Both files were regenerated and checked". They only signal a
  # state when nothing in the opening clause is past tense, which is the same
  # discriminator the gerund rule below already uses. QA round 3 found the blanket
  # form throwing real entries away. (#30987)
  case " all both " in
    *" $w "*) _desc_opens_past "$p" || return 0 ;;
  esac
  # A verdict opening the sentence. The rule further down catches a verdict sitting
  # after a comma or a colon, but one that OPENS the sentence has neither in front of
  # it, so "approved, no blocking concerns" reached the invoice while "Security review
  # complete, approved, ..." was refused. The upper case form was refused too, so the
  # test case passed while the class it stands for did not. (#30987 QA round 3)
  #
  # A verdict word is also an ordinary transitive verb. "Passed the release gate
  # through stakeholder QA and handed it off" is a real entry from the record and must
  # survive. The discriminator is whether the word takes an object: a comma straight
  # after it, or a preposition where a noun phrase would go, means it does not.
  case " approved blocked passed failed rejected denied " in
    *" $w "*)
      case "$l" in "$w,"*|"$w."*|"$w;"*|"$w:"*) return 0 ;; esac
      local second="${p#" $w "}"; second="${second%% *}"
      # A preposition where a noun phrase would go means the verdict takes no object.
      # QA round 4 found the original short list let "approved by the client",
      # "approved over email" and "blocked in review" through. (#30987)
      case " with without on at for pending against by over during in into after before since under about " in
        *" $second "*) return 0 ;;
      esac
    ;;
  esac
  # State and finding openers. Each one announces a condition or an opinion rather
  # than work that was done. Measured against 1151 real descriptions covering 25 days,
  # not one opens with any of them, so this costs nothing. Before this, the screen
  # refused "Everything downstream waits on a db owner" while accepting "Still waiting
  # on the db owner", which made the rule arbitrary rather than principled: QA round 3
  # ruled that the refusals were right and the equivalents had to follow. (#30987)
  case " still currently not no looks seems appears waiting pending awaiting unable ready my " in
    *" $w "*) return 0 ;;
  esac
  # A present tense copula in the opening clause, with nothing completed in front of
  # it, is a state report whatever the subject is: "Status is now resolved", "Coverage
  # is largely adequate", "Being now fully resolved, ...". This is general rather than
  # another opener on a denylist, and QA round 5 is why. The round 4 copula guard was
  # only ever REACHED from two gates, a "both"/"all" opener or an "-ing" opener, so any
  # other subject skipped it, and "being" satisfies the -ing gate itself so a fourth
  # adverb walked past the three token lookback. It also closes the noun-subject gap
  # that had been disclosed and accepted since round 1.
  #
  # Scanned forward: a past tense verb reached first means the sentence is a record of
  # work and the copula is only reporting what was found, so "Determined that the key
  # audit is blocked" survives. "to be responsive" survives because "be" is not in the
  # set and "Rebuilt" comes first anyway. Measured across 1151 real descriptions this
  # refuses 8 more, and every one of them is either a finding or real work written in
  # the present passive rather than the past tense the house rules ask for. (#30987)
  local ctok cseen=0
  for ctok in $p; do
    cseen=$((cseen+1)); (( cseen > 5 )) && break
    case " is are am being " in
      *" $ctok "*) return 0 ;;
    esac
    _desc_past_token "$ctok" && break
  done
  # A numeral subject: "31018 is closed as not reproducible".
  case "$w" in ''|*[!0-9]*) ;; *) return 0 ;; esac
  # A count opening the sentence, but only before a lowercase word, so a proper noun
  # such as "One Horse product import verified" is not refused.
  case " one two three four five six seven eight nine ten " in
    *" $w "*)
      local rest="${s#* }"
      # "One of my entries was ..." is a partitive, not a count opening a report. But
      # the skip was written as "anything after of", which also swallowed the genuine
      # count report "Two of three closed out cleanly" that this ticket claimed to
      # catch. A partitive names things; a count report names another number.
      # (#30987 QA round 3)
      case "$rest" in
        "of "*|"Of "*)
          local after="${rest#* }"; after="${after%% *}"; after="${after//[^a-zA-Z0-9]/}"
          after="${after,,}"
          case " one two three four five six seven eight nine ten " in
            *" $after "*) return 0 ;;
          esac
          case "$after" in ''|*[!0-9]*) ;; *) return 0 ;; esac
          ;;
        [a-z]*) return 0 ;;
      esac
    ;;
  esac
  # Gerund narration: "Retracting Finding 3...", "Correcting the report...". A completed
  # record says "Retracted" or "Corrected".
  #
  # But plenty of ordinary work opens with an -ing NOUN: "Onboarding tasks were
  # reassigned", "Billing report exported and reconciled". The discriminator is whether
  # the sentence reports completed work at all, so only refuse when nothing in it is
  # past tense. Every example here came out of the real record. (#30987 QA rework 2)
  case "$w" in
    *ing)
      # Only the opening clause counts. "Retracting Finding 3 as I wrote it" has a past
      # tense verb, but it sits in a subordinate clause and the sentence is still
      # narration. "Onboarding tasks were reassigned" carries its past tense up front.
      _desc_opens_past "$p" || return 0
    ;;
  esac

  # A condition stated as the point of the sentence, which means at its start or straight
  # after a colon. NOT as the object of completed work: "confirmed there is no guard for
  # orders that already shipped" is a proper record and must survive. (#30987 QA rework 2)
  case "$l" in
    "there is"*|"there are"*|"there was"*|"there were"*) return 0 ;;
    *": there is"*|*": there are"*|*": there was"*|*": there were"*) return 0 ;;
  esac

  # A verdict lifted out of a review. Matched in its report shape rather than as a bare
  # word, so "deployed it after the full suite passed" is still allowed.
  case "$l" in
    *": approved"*|*", approved,"*|*", approved."*|*": blocked"*|*", blocked,"*|*", blocked."*) return 0 ;;
  esac
  # Shouted verdicts, as whole tokens. A substring test would also fire on BYPASS and
  # COMPASS, and on PASSED inside ordinary prose.
  local u=" ${s//[^A-Za-z0-9]/ } "
  u="${u//  / }"; u="${u//  / }"; u="${u//  / }"
  case "$u" in *" APPROVED "*|*" BLOCKED "*|*" PASS "*|*" FAIL "*|*" PASSED "*|*" FAILED "*) return 0 ;; esac

  # Internal identifiers: draft ids, and commit hashes such as "committed as 55793a7".
  local t
  for t in $p; do
    case "$t" in
      r[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) return 0 ;;
    esac
    if [[ ${#t} -ge 7 && ${#t} -le 40 && "$t" != *[!0-9a-f]* && "$t" == *[a-f]* && "$t" == *[0-9]* ]]; then
      return 0
    fi
  done

  # Parity with the derived path: a file path or a reference to the tooling must never
  # reach the field from either route. QA found these applied only to the derived text.
  case "$l" in
    *".ps1"*|*".sh"*|*".js"*|*".md"*|*".sql"*|*".json"*|*".html"*|*".jsonl"*|*".yaml"*|*".yml"*|*".py"*|*".csv"*|*".txt"*|*".bat"*|*".cmd"*|*".php"*|*".xlsx"*) return 0 ;;
    # Any backslash at all. Measured across 550 real descriptions from ten days: not one
    # contains a backslash, so this costs nothing and catches every Windows and UNC path
    # shape without trying to enumerate them. (#30987 QA rework 2)
    *\\*) return 0 ;;
    */[a-z0-9_.-]*/[a-z0-9_.-]*) return 0 ;;
  esac
  case "$p" in *" claude "*|*" anthropic "*|*" ai "*|*" assistant "*|*" chatbot "*|*" copilot "*|*" agent "*|*" subagent "*) return 0 ;; esac

  return 1
}

# Clean one candidate sentence, or fail. Shared by both sources below.
_clean_candidate() {
  local s
  s="$(printf '%s' "$1" \
       | sed -e 's/[*`#|_>]/ /g' \
             -e 's/\[\([^]]*\)\]([^)]*)/\1/g' \
             -e 's/^[[:space:]]*[Tt]imestamp:[[:space:]]*//' \
             -e 's/^[[:space:]]*[0-9-]\{10\}[[:space:]][0-9:]\{5,8\}[[:space:]]*UTC[[:space:]-]*//' \
             -e 's/^[[:space:]]*[-—–][[:space:]]*//' \
             -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//')"
  s="${s%%. *}"; s="${s%.}"
  (( ${#s} < APROPOS_DERIVE_MIN )) && return 1
  # Acknowledgements, not work. "Noted, that reads well and the ask is clear" passes a
  # length floor but describes nothing that happened.
  printf '%s' "$s" | grep -Eqi '^(noted|sent|done|yes|no|correct|agreed|thanks|thank you|ok|okay|right|sure|understood|good|fair|exactly|indeed|got it|perfect)([^[:alnum:]]|$)' && return 1
  # The rules ban file paths and script names from an invoice-facing field.
  printf '%s' "$s" | grep -Eq '[A-Za-z]:\\|\\\\|/[A-Za-z0-9_.-]+/|\.(ps1|sh|js|md|php|sql|json|html|txt|csv|xlsx|jsonl|cmd|bat|py)\b' && return 1
  printf '%s' "$s" | grep -Eqi "$APROPOS_BANNED" && return 1
  # The same voice screen the model-written description gets, so neither route bypasses
  # it. The derived text is the worse offender: it is lifted from a reply. (#30987)
  s="$(_desc_normalise "$s")"
  _desc_refuse "$s" && return 1
  (( ${#s} > DESC_MAX )) && { s="${s:0:$DESC_MAX}"; s="${s% *}"; }
  # Sentence case, since a lifted fragment often starts mid-thought.
  printf '%s.' "$(printf '%s' "${s:0:1}" | tr '[:lower:]' '[:upper:]')${s:1}"
}

# Last resort before the placeholder: describe the turn from what the response
# actually said. The final assistant text block IS this turn's answer, because Stop
# only fires once the response is complete.
#
# Two sources, best first: the labelled summary that ends a long reply, then the
# reply's opening sentence. Measured across 12 real sessions, the summary is present
# about 60% of the time and is usually a statement of what was done; the opening
# sentence is the better of the rest. Anything failing the floor or the content rules
# falls through to the placeholder, which is the honest outcome.
#
# Added 2026-08-12. The plugin README has claimed this behaviour since 0.2.0 but no
# code implemented it, so every turn where the model forgot to write a description
# booked "[needs description] <project>". On Barrett's machine the working directory
# is named "Claude", so that put a literal AI reference on an invoice-facing field.
desc_from_transcript() {
  local f raw out
  command -v jq >/dev/null 2>&1 || return 1
  f="$(transcript_path "$SID" "$1")" || return 1

  # One line per text block, newest last. gsub collapses the block so tail -1 gets a
  # whole block rather than its last physical line.
  raw="$(tail -n 800 "$f" 2>/dev/null \
        | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text | gsub("\\s+"; " ")' 2>/dev/null \
        | awk 'NF' | tail -n 1)"
  [[ -n "$raw" ]] || return 1

  case "$raw" in
    *"Summary:"*) out="$(_clean_candidate "${raw##*Summary:}")" && { printf '%s' "$out"; return 0; } ;;
  esac
  out="$(_clean_candidate "$raw")" && { printf '%s' "$out"; return 0; }
  return 1
}

# task_wt_lookup <task> -> prints the worktype last recorded against that task.
task_wt_lookup() {
  local t="$1" k v
  [[ "$t" =~ ^[0-9]+$ ]] && [[ "$t" != "0" ]] || return 1
  [[ -s "$taskwtf" ]] || return 1
  while IFS=$'	' read -r k v; do
    if [[ "$k" == "$t" ]]; then printf '%s' "$v"; return 0; fi
  done < "$taskwtf"
  return 1
}

# task_wt_record <task> <worktype> — remember the worktype for this task. Shared across
# every session on the machine, so it is a read-modify-write and takes the lock. Failing
# to get it means the next session may fall back to the default, which is untidy, where
# clobbering the file would lose every task's worktype at once.
task_wt_record() {
  local t="$1" w="$2" tmp k v
  [[ "$t" =~ ^[0-9]+$ ]] && [[ "$t" != "0" ]] || return 0
  [[ "$w" =~ ^[0-9]+$ ]] || return 0
  mkdir -p "$(dirname "$taskwtf")" 2>/dev/null || true
  # Retry rather than give up on the first miss. QA measured the single-attempt version
  # keeping only 2 or 3 of 20 concurrent writes, which silently defeats the whole point
  # of the map: the next session finds nothing and falls back to Engineering. _oe_lock is
  # the same bounded retry the open-entry map already uses, added after this identical
  # failure mode lost real data. Reusing it rather than repeating the mistake. (#30986)
  _tw_lock "$taskwtf" || return 0
  tmp="$taskwtf.tmp.$$"
  {
    if [[ -s "$taskwtf" ]]; then
      while IFS=$'	' read -r k v; do
        [[ "$k" == "$t" ]] && continue
        [[ "$k" =~ ^[0-9]+$ ]] && [[ "$v" =~ ^[0-9]+$ ]] || continue
        printf '%s	%s
' "$k" "$v"
      done < "$taskwtf"
    fi
    printf '%s	%s
' "$t" "$w"
  } > "$tmp" 2>/dev/null && mv "$tmp" "$taskwtf" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  q_unlock "$taskwtf"
}

# Bounded retry around the shared task map, mirroring _oe_lock in lib/writer.sh. Kept
# local to this file because writer.sh's copy is bound to APROPOS_OPEN_FILE. (#30986)
_tw_lock() {
  local f="$1" i=0
  command -v q_lock >/dev/null 2>&1 || return 1
  while (( i < 50 )); do
    q_lock "$f" && return 0
    sleep 0.1
    i=$((i+1))
  done
  return 1
}

record_turn() {
  # $1 = start time as UTC "YYYY-MM-DD HH:MM:SS"
  local START="$1"

  # Description, best source first:
  #   1. the model-written file, which is the intended path
  #   2. the last assistant message from the transcript
  #   3. a flagged placeholder
  # Never the raw prompt, which describes the request rather than the work done.
  local DESC=""
  if [[ -s "$descf" ]]; then
    DESC="$(_desc_normalise "$(cat "$descf")")"
    # A supplied description is held to the same standard as a derived one. Refusing it
    # falls through to the transcript and then to the flagged placeholder, which is
    # visible and gets corrected, rather than shipping a reply onto an invoice. (#30987)
    if _desc_refuse "$DESC"; then
      printf 'apropos: the description written this turn reads as a reply rather than a record of the work, so it was not used. Rewrite it in the past tense, from your own perspective, saying what was accomplished.\n' >&2
      DESC=""
    fi
  fi
  local basecwd="$CWD"
  [[ -z "$basecwd" && -s "$cwdf" ]] && basecwd="$(cat "$cwdf")"
  # APROPOS_DERIVE=off keeps the old behaviour, for anyone who would rather see an
  # explicit placeholder to correct than an approximate description that reads as
  # finished. The derived text is a safety net; the model writing one is the fix.
  case "$(printf '%s' "${APROPOS_DERIVE:-on}" | tr '[:upper:]' '[:lower:]')" in
    off|0|false|no) ;;
    *) [[ -z "${DESC//[[:space:]]/}" ]] && DESC="$(desc_from_transcript "$basecwd" 2>/dev/null)" ;;
  esac
  if [[ -z "${DESC//[[:space:]]/}" ]]; then
    local proj; proj="$(basename "$basecwd" 2>/dev/null)"
    # Do not tag the placeholder with a project name that is itself an AI reference.
    # "R:\Barrett Goldberg\Claude" would otherwise write "[needs description] Claude"
    # onto a field that reaches client invoices.
    if printf '%s' "$proj" | grep -Eqi "$APROPOS_BANNED"; then proj=""; fi
    if [[ -n "$proj" && "$proj" != "." && "$proj" != "/" ]]; then
      DESC="[needs description] $proj"
    else
      DESC="[needs description]"
    fi
  fi
  DESC="${DESC:0:$DESC_MAX}"

  # Optional sticky task/project. Resolved BEFORE the worktype, because the worktype can
  # be inherited from the task.
  local TASK="0"; [[ -s "$taskf" ]] && TASK="$(tr -d '[:space:]#' < "$taskf")"; [[ "$TASK" =~ ^[0-9]+$ ]] || TASK="0"
  local PROJ="0"; [[ -s "$projf" ]] && PROJ="$(tr -d '[:space:]' < "$projf")"; [[ "$PROJ" =~ ^[0-9]+$ ]] || PROJ="0"

  # Worktype, best source first:
  #   1. the file the model wrote this turn
  #   2. the worktype last used on this task, by any session on this machine
  #   3. the worktype this session carried from an earlier turn
  #   4. the documented default, reported so it can be corrected the same day
  #
  # Until #30986 this was step 1 or the default, and the file in step 1 is deleted at the
  # end of every turn, so only the first turn of a stretch was categorised as intended.
  # Everything after it booked as Engineering.
  local WT="" WTSRC="" v=""
  if [[ -s "$wtf" ]]; then
    v="$(tr -d '[:space:]' < "$wtf")"
    if [[ "$v" =~ ^[0-9]+$ ]]; then WT="$v"; WTSRC="written this turn"; fi
  fi
  if [[ -z "$WT" ]]; then
    v="$(task_wt_lookup "$TASK" 2>/dev/null)"
    if [[ "$v" =~ ^[0-9]+$ ]]; then WT="$v"; WTSRC="last used on this task"; fi
  fi
  if [[ -z "$WT" ]] && [[ -s "$stickywtf" ]]; then
    v="$(tr -d '[:space:]' < "$stickywtf")"
    if [[ "$v" =~ ^[0-9]+$ ]]; then WT="$v"; WTSRC="carried from this session"; fi
  fi
  if [[ -z "$WT" ]]; then
    WT="13"; WTSRC="default"
    printf 'apropos: no worktype was written this turn and none is on record for task %s, so this entry took the default worktype 13 (Engineering). Correct it if that is wrong.
' "$TASK" >&2
  fi
  printf '%s' "$WT" > "$stickywtf" 2>/dev/null || true
  # Only a chosen worktype is worth remembering for the task. Recording the bare default
  # would pin a guess into the shared map as though somebody had established it, and
  # every later session would then inherit the guess with no warning. (#30986)
  # NOT recorded here. task_wt_record can now genuinely retry for the lock, and this runs
  # before the entry is queued, so at high contention a slow lock would gate the write
  # that actually reaches the invoice. QA measured a 38s worst case at 20 concurrent
  # sessions against a 30s hook timeout, which would drop the whole turn rather than
  # merely lose a worktype hint. The map is a convenience; the time is not. Recorded at
  # the end of record_turn instead, once the entry is safely queued. (#30986 QA)

  # Dedup key now includes the description fingerprint. Previously the key was
  # worktype|task|project only, so two consecutive turns of different work on the
  # same task deduped — and because the file deletion below used to run
  # unconditionally, the second turn's real description was DELETED rather than
  # merely left unmarked. The plugin spec (§5.1) says dedup is "de-duplicate only,
  # never a reason to record nothing"; keying on the description honours that.
  # ONE OPEN ENTRY PER ACTIVITY, shared across every session on this machine.
  #
  # Until 2026-08-13 this recorded a row per turn. Measured on Barrett: 321 rows Monday
  # to Thursday, 80 a day, of which 185 of 320 were under five minutes and 20 were zero
  # length. That cannot be reconciled with the 15-minute increment convention, and it
  # overran the timecard's own page load so his day stopped displaying partway down.
  #
  # The old duplicate check could not prevent it. Its key included a hash of the
  # description, and the description differs every turn, so the key never repeated and
  # the check never fired. The hash went in on 2026-08-07 to stop a second turn's
  # description being deleted; it fixed that and caused this.
  #
  # So the key is the ACTIVITY, task and worktype and project, with no description in
  # it. A turn continuing an activity that is already open amends that entry rather than
  # inserting beside it. Barrett runs six to eight sessions at once, so the open entries
  # are held in one shared file rather than per session state: otherwise two sessions on
  # two tasks alternate and nothing ever merges. Modelled on his real days this takes
  # ~84 entries a day to ~27, the number of distinct activities he actually worked.
  #
  # APROPOS_MERGE=off restores a row per turn.
  local ACT="$WT|$TASK|$PROJ"
  local MERGED=0
  case "$(printf '%s' "${APROPOS_MERGE:-on}" | tr '[:upper:]' '[:lower:]')" in
    off|0|false|no) ;;
    *)
      # Markers and unattributed turns are never merged: a break is not a continuation of
      # work, and an entry with no task cannot be amended without dropping attribution.
      if [[ "$TASK" != "0" ]]; then
        local open id
        # No entry open yet for this activity? Claim it before inserting, so a second
        # session starting the same brand-new activity in the same window waits for this
        # one's id instead of inserting a second row for the same work. If the claim is
        # refused, somebody else got there first, so wait for their id and amend that.
        # (#30903)
        if ! oe_lookup "$ACT" >/dev/null 2>&1; then
          if ! oe_claim "$ACT"; then
            open="$(oe_await "$ACT" 2>/dev/null)" || open=""
          fi
        fi
        if [[ -n "$open" ]] || open="$(oe_lookup "$ACT")"; then
          id="${open%% *}"
          # Third field is what this recorder last wrote for that entry. Pass it back so
          # the writer can refuse the amend if the row has been corrected since. A refusal
          # leaves MERGED at 0, so the turn is recorded as its own entry rather than
          # overwriting somebody's correction or being lost. (#30988)
          local expect_b64 expect=""
          expect_b64="$(printf '%s' "$open" | awk '{print $3}')"
          local amend_ok=1
          if [[ -n "$expect_b64" ]]; then
            # A corrupt field decodes to an empty string, and an empty expectation used to
            # mean "nothing to compare", so the amend went ahead unconditionally and could
            # discard a real correction: the very bug this guard exists to prevent, back
            # again for that one row. Exit status alone is not a reliable gate, since a
            # valid but unpadded value also returns 1, so require a clean round trip.
            # Anything else refuses the amend, which falls back to inserting. (#30988 QA)
            expect="$(printf '%s' "$expect_b64" | base64 -d 2>/dev/null)"
            if [[ "$(printf '%s' "$expect" | base64 | tr -d '\n')" != "$expect_b64" ]]; then
              amend_ok=0
              printf 'apropos: the open-entry record for this activity is unreadable, so the entry was recorded separately rather than risk overwriting a correction.\n' >&2
            fi
          fi
          if (( amend_ok )) && amend_entry "$id" "$PERSON" "$DESC" "$expect"; then MERGED=1; fi
        fi
      fi
      ;;
  esac

  # The old same-everything guard still applies to the insert path, so a genuinely
  # identical turn inside 15 minutes does not open a second entry.
  local SEG="$WT|$TASK|$PROJ|$(_hash "$DESC")"
  local DEDUP=0
  # ...but never on the flagged placeholder. The placeholder is identical every time it
  # is written, so two different turns that both failed to produce a usable description
  # looked like one repeated turn and the second turn's time was dropped outright. A
  # placeholder is an admission that we do not know what the work was; it is not
  # evidence that the work was the same. The stricter description screen made this
  # reachable in ordinary use rather than rarely. (#30987 QA round 3)
  if [[ -f "$lastf" && "$DESC" != "[needs description]"* ]]; then
    local line lt lk
    line="$(head -1 "$lastf")"; lt="${line%%|*}"; lk="${line#*|}"
    if [[ "$lt" =~ ^[0-9]+$ && "$lk" == "$SEG" && $((NOW - lt)) -lt 900 ]]; then DEDUP=1; fi
  fi

  if [[ $MERGED -eq 0 && $DEDUP -eq 0 ]]; then
    q_enqueue "$QUEUE" "$PERSON" "$DESC" "$WT" "$TASK" "$PROJ" "$START"
    printf '%s|%s\n' "$NOW" "$SEG" > "$lastf"
  fi

  # Consume the one-shot model files. Safe here because this line is reached only
  # after the entry was enqueued, or after it was confirmed a true duplicate
  # (identical description AND segment within 15 min). Nothing unrecorded is lost.
  # Safe to do now: the entry is queued, so a slow lock here can cost the worktype hint
  # for the next session but can never cost the time itself. (#30986 QA)
  [[ "$WTSRC" != "default" ]] && task_wt_record "$TASK" "$WT"

  rm -f "$descf" "$wtf" 2>/dev/null || true
}

case "$EVENT" in
  Stop)
    # Primary recorder. Use the start time stamped when the prompt came in, so the
    # marker sits at the real beginning of the work rather than at its end.
    START="$(start_from_stamp "$startf")"
    record_turn "$START"
    rm -f "$startf" 2>/dev/null || true
    ;;
  *)
    # UserPromptSubmit. Recovery first: a leftover description file means Stop did
    # not run for the previous turn (crash, kill, Stop not registered). Record it
    # with that turn's stamped start so the work is not lost.
    if [[ -s "$descf" ]]; then
      record_turn "$(start_from_stamp "$startf")"
    fi
    # Stamp this turn's start for the Stop hook to use.
    printf '%s' "$NOW" > "$startf"
    [[ -n "$CWD" ]] && printf '%s' "$CWD" > "$cwdf"
    ;;
esac

# Always attempt to flush (delivers this entry and any prior queued ones).
q_flush "$QUEUE" write_entry
exit 0
