#!/usr/bin/env bash
_TEST_FAILS=0
assert_eq()          { if [[ "$1" == "$2" ]]; then echo "  ok: $3"; else echo "  FAIL: $3 (expected '$1' got '$2')"; _TEST_FAILS=$((_TEST_FAILS+1)); fi; }
assert_contains()    { if [[ "$1" == *"$2"* ]]; then echo "  ok: $3"; else echo "  FAIL: $3 ('$2' not found)"; _TEST_FAILS=$((_TEST_FAILS+1)); fi; }
assert_not_contains(){ if [[ "$1" != *"$2"* ]]; then echo "  ok: $3"; else echo "  FAIL: $3 ('$2' unexpectedly present)"; _TEST_FAILS=$((_TEST_FAILS+1)); fi; }
pass()               { echo "  ok: $1"; }
finish()             { if (( _TEST_FAILS > 0 )); then echo "TESTS FAILED ($_TEST_FAILS)"; exit 1; else echo "ALL TESTS PASSED"; exit 0; fi; }
