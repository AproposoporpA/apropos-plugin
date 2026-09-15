#!/usr/bin/env bash
# Flagged-entry ledger.
#
# The recorder knows an entry is flagged at the moment it writes it, and then forgets.
# Once the activity closes, nothing can find that entry again, so it stays flagged until
# a person cleans the day by hand. This records the pairing that makes a later repair
# possible: the entry id, and the session and working directory whose transcript holds
# what the turn actually did.
#
# Local to the machine, like the rest of the plugin's state, because the transcript it
# points at is local too.

APROPOS_LEDGER_FILE="${APROPOS_LEDGER_FILE:-$HOME/.claude/apropos-time/flagged.tsv}"

_fl_init() { mkdir -p "$(dirname "$APROPOS_LEDGER_FILE")" 2>/dev/null || true; [[ -f "$APROPOS_LEDGER_FILE" ]] || : > "$APROPOS_LEDGER_FILE"; }

# fl_record <entry_id> <session_id> <cwd> <epoch>
# Recording the same entry twice keeps one row: a turn can flag the same open entry
# repeatedly, and a ledger that grew a row each time would make the sweep do the same
# work over and over.
fl_record() {
  _fl_init
  local id="$1"
  [[ "$id" =~ ^[0-9]+$ ]] || return 1
  fl_clear "$id"
  printf '%s\t%s\t%s\t%s\n' "$id" "$2" "$3" "$4" >> "$APROPOS_LEDGER_FILE"
}

# fl_pending, every entry still awaiting repair, one per line, tab separated.
fl_pending() { _fl_init; cat "$APROPOS_LEDGER_FILE"; }

# fl_clear <entry_id>, drop an entry once it has been repaired or given up on.
fl_clear() {
  _fl_init
  local id="$1" tmp
  tmp="$(mktemp)" || return 1
  awk -F'\t' -v id="$id" '$1 != id' "$APROPOS_LEDGER_FILE" > "$tmp" 2>/dev/null
  mv "$tmp" "$APROPOS_LEDGER_FILE"
}
