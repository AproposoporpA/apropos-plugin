#!/usr/bin/env bash
# Logs args; fails (exit 1) while $WRITER_FAIL file exists.
printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$WRITER_LOG"
[[ -f "$WRITER_FAIL" ]] && exit 1
exit 0
