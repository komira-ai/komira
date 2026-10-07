# shellcheck shell=bash
# assert_level_tests.sh -- tests of the per-target assert level, defines and
# memory cap (tools/build/mojo/README.md#assert-level-defines-and-memory-cap).
# Sourced by tools/build/tests/run_tests.sh (uses its BUCK2, ROOT, LOG, pass,
# fail, expect_green and expect_red); not run on its own.
#
#  45. Assert level, defines and memory cap: the commands carry `-D
#      ASSERT=<level>` and each define where a target sets them, the gated
#      test runs under mem_cap.sh at 4096 MiB by default at ASSERT=none and at
#      the cap a target names, and a target that sets none of them has neither
#      (tools/build/tests/functional/assert_level.sh: aquery);
#      tests//functional/assert_level and tests//functional/mem_cap build (a
#      library's debug_asserts are off in its test at ASSERT=none, an
#      assert_mode=none one is off at the default level, a define reaches the
#      test and the library's package, a test holding 256 MiB passes under a
#      1024 MiB cap), :bin_none's [run_check] and `buck2 test` of :test_none
#      pass at ASSERT=none; each twin in tests//negative/assert_level fails
#      (the same tests at ASSERT=all and at the default level, the same
#      programs at the default level) and each inadmissible declaration is
#      refused at analysis; a test that allocates without bound and the
#      256 MiB test under a 192 MiB cap are killed by the cap
#      (tests//negative/mem_cap), as a library's gated test and under
#      `buck2 test`.

if BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/assert_level.sh" "$LOG" > "$LOG/assert_level.log" 2>&1; then
    pass "$(grep -o 'PASS  assert level: .*' "$LOG/assert_level.log" | cut -c 7-)"
else
    fail "$(grep -o 'FAIL  assert level: .*' "$LOG/assert_level.log" | cut -c 7- | cut -c 1-400) (see $LOG/assert_level.log)"
fi
expect_green assert_level_functional tests//functional/assert_level: tests//functional/mem_cap:
expect_green assert_level_run_check 'tests//functional/assert_level:bin_none[run_check]'
if timeout 900 "$BUCK2" test tests//functional/assert_level:test_none > "$LOG/assert_level_test_none.log" 2>&1; then
    pass "assert_level_test_none: buck2 test of a mojo_test at ASSERT=none"
else
    fail "assert_level_test_none (see $LOG/assert_level_test_none.log)"
fi

A=tests//negative/assert_level
expect_red assert_level_all "GATED TEST FAILED: $A:lib_all:tests/test_quiet_by_default.mojo" "$A:lib_all"
expect_red assert_level_all_probe "Assert Error: ASSERT_PROBE all_only_probe: an assert_mode=none debug_assert fired" "$A:lib_all"
expect_red assert_level_safe_default "Assert Error: ASSERT_PROBE safe_probe: an assert_mode=safe debug_assert fired" "$A:lib_safe_default"
expect_red assert_level_bin_default "/bin_default exited 132" "$A:bin_default[run_check]"
expect_red assert_level_bad_level "$A:bad_level: test_assert_level \`fast\` is not one of none, warn, safe, all" "$A:bad_level"
expect_red assert_level_bad_binary_level "$A:bad_binary_level: assert_level \`off\` is not one of none, warn, safe, all" "$A:bad_binary_level"
expect_red assert_level_define_assert "$A:define_assert: test_defines sets ASSERT; set \`test_assert_level\` instead" "$A:define_assert"
expect_red assert_level_define_not_identifier "$A:define_not_identifier: defines entry \"1ST=x\" is not NAME or NAME=VALUE with NAME an identifier" "$A:define_not_identifier"
expect_red assert_level_define_twice "$A:define_twice: defines sets KOMIRA_X twice" "$A:define_twice"
expect_red assert_level_bad_cap "$A:bad_cap: test_memory_cap_mib is -1; it must be a number of MiB, or 0 for no cap" "$A:bad_cap"
if timeout 900 "$BUCK2" test "$A:test_default" > "$LOG/assert_level_test_default.log" 2>&1; then
    fail "assert_level_test_default: buck2 test $A:test_default passed, but its safe assert must fire at the default level"
elif ! grep -qF "GATED TEST FAILED: $A:test_default (exit 132)" "$LOG/assert_level_test_default.log"; then
    fail "assert_level_test_default: failed without its assert's exit 132 (see $LOG/assert_level_test_default.log)"
else
    pass "assert_level_test_default: a mojo_test at the default level fails on its safe assert"
fi

M=tests//negative/mem_cap
expect_red mem_cap_unbounded "MEMORY CAP: killed $M:lib_unbounded:tests/test_unbounded.mojo at " "$M:lib_unbounded"
expect_red mem_cap_unbounded_cap "MiB resident, over its cap of 512 MiB" "$M:lib_unbounded"
expect_red mem_cap_unbounded_gate "GATED TEST FAILED: $M:lib_unbounded:tests/test_unbounded.mojo (exit 137)" "$M:lib_unbounded"
expect_red mem_cap_over_cap "MiB resident, over its cap of 192 MiB" "$M:lib_over_cap"
expect_red mem_cap_over_cap_started "MEMCAP_FIXTURE holds 64 MiB" "$M:lib_over_cap"
if timeout 900 "$BUCK2" test "$M:test_unbounded" > "$LOG/mem_cap_test_unbounded.log" 2>&1; then
    fail "mem_cap_test_unbounded: buck2 test $M:test_unbounded passed, but its cap must kill it"
elif ! grep -qF "MEMORY CAP: killed $M:test_unbounded at " "$LOG/mem_cap_test_unbounded.log"; then
    fail "mem_cap_test_unbounded: failed without the cap's line (see $LOG/mem_cap_test_unbounded.log)"
else
    pass "mem_cap_test_unbounded: buck2 test of a mojo_test that allocates without bound is killed by its cap"
fi
