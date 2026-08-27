#!/usr/bin/env bash
# The open-entry map is read-modify-written by every session on the machine, so
# concurrent writers must not lose each other's lines.
#
# Added 2026-08-14 after the map was shipped without a lock. Seen on Barrett's real
# entries: 336753 was the same activity as 336751 and written 8 minutes later, inside
# the window, but a third insert landed 2 seconds earlier, the line went missing, and it
# inserted a duplicate instead of amending.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
source "$DIR/hooks-handlers/lib/queue.sh"
WORK="$(mktemp -d)"
export APROPOS_OPEN_FILE="$WORK/open-entries.tsv"
export APROPOS_MERGE_MAX_SECS=1800
source "$DIR/hooks-handlers/lib/writer.sh"

# 1. Concurrent writers on DIFFERENT activities must all survive.
#    Without the lock each one rewrites the whole file from its own stale read.
rm -f "$APROPOS_OPEN_FILE"
for i in $(seq 1 12); do ( oe_record "13|$((28000+i))|26" "$((900000+i))" ) & done
wait
lines="$(wc -l < "$APROPOS_OPEN_FILE" 2>/dev/null | tr -d ' ')"
assert_eq "12" "$lines" "12 concurrent writers on distinct activities all kept ($lines survived)"

# 2. A concurrent writer must not evict an unrelated line that is still open.
rm -f "$APROPOS_OPEN_FILE"
oe_record "13|28682|26" "336751"
for i in $(seq 1 8); do ( oe_record "50|23953|56" "$((800000+i))" ) & done
wait
survived="$(oe_lookup "13|28682|26" || true)"
assert_contains "$survived" "336751" "the pre-existing activity survived concurrent writes"

# 3. The key match is anchored. An unanchored match let a short key hit a longer line.
rm -f "$APROPOS_OPEN_FILE"
oe_record "13|28682|26" "336751"
short="$(oe_lookup "3|28682|26" || true)"
assert_eq "" "$short" "a short key does not match a longer activity key"
r="$(oe_lookup "13|28682|26")"
assert_contains "$r" "336751" "the exact key still matches"

# 4. An aged-out entry is still refused.
rm -f "$APROPOS_OPEN_FILE"
printf '%s\t%s\t%s\n' "13|28682|26" "111" "$(( $(date -u +%s) - 99999 ))" > "$APROPOS_OPEN_FILE"
aged="$(oe_lookup "13|28682|26" || true)"
assert_eq "" "$aged" "an aged-out entry is refused"

# 5. The lock is released, so a later call still works.
rm -f "$APROPOS_OPEN_FILE"
oe_record "13|28682|26" "222"
oe_record "13|28682|26" "333"
r="$(oe_lookup "13|28682|26")"
assert_contains "$r" "333" "a second write succeeds, so the lock is not left held"

finish
