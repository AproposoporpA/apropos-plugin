#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; rc=0
for t in "$DIR"/tests/test-*.sh; do echo "== $(basename "$t") =="; bash "$t" || rc=1; done
[[ $rc -eq 0 ]] && echo "SUITE GREEN" || echo "SUITE RED"; exit $rc
