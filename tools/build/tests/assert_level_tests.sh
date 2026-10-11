# shellcheck shell=bash
# assert_level_tests.sh -- tests of the per-target assert level, defines and
# memory cap (tools/build/mojo/README.md#assert-level-defines-and-memory-cap).
# Sourced by tools/build/tests/run_tests.sh (uses its BUCK2, ROOT, LOG, pass,
# fail, expect_green and expect_red); not run on its own.
#
#  49. Assert level, defines and memory cap: the commands carry `-D
#      ASSERT=<level>` and each define where a target sets them, the gated
#      test runs under mem_cap.sh at 4096 MiB by default at ASSERT=none and at
#      the cap a target names, and a target that sets none of them has neither
#      (tools/build/tests/functional/assert_level.sh: aquery, with and
#      without komira.coverage=true, and a mojo_test's buck2-test command);
#      mem_cap.sh on a stand-in leaves nothing alive when /proc stops being
#      readable, it is signalled, or a child left the stand-in's process tree
#      (tests//functional/mem_cap:cases);
#      tests//functional/assert_level and tests//functional/mem_cap build (a
#      library's debug_asserts are off in its test at ASSERT=none, an
#      assert_mode=none one is off at the default level, a define reaches the
#      test and the library's package, a test holding 256 MiB for 2 s passes
#      under a 1024 MiB cap), :bin_none's [run_check] and `buck2 test` of :test_none
#      pass at ASSERT=none, and with komira.coverage=true the branch coverage
#      runs of :lib_none, :lib_defines and :lib_level_and_defines pass (their
#      bitcode got the level and every define); each twin in tests//negative/assert_level fails
#      (the same tests at ASSERT=all and at the default level, the same
#      programs at the default level) and each inadmissible declaration is
#      refused at analysis; a test that allocates without bound and the
#      256 MiB test under a 192 MiB cap are killed by the cap
#      (tests//negative/mem_cap), as a library's gated test and under
#      `buck2 test`. The time limit of a mojo_test under `buck2 test`:
#      test_deadline.sh on a stand-in passes the runner's status through at
#      once, kills the test at its limit and leaves the runner to report it,
#      and leaves nothing alive (tests//functional/test_deadline:cases); a
#      mojo_test sleeping past it, with the test runner's timeout at 90 s, is
#      killed at 30 s and says so (tests//negative/test_deadline); a
#      komira.test_timeout_s that is not a whole number, or is not over the
#      60 s margin, is refused.

if BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/assert_level.sh" "$LOG" > "$LOG/assert_level.log" 2>&1; then
    pass "$(grep -o 'PASS  assert level: .*' "$LOG/assert_level.log" | cut -c 7-)"
else
    fail "$(grep -o 'FAIL  assert level: .*' "$LOG/assert_level.log" | cut -c 7- | cut -c 1-400) (see $LOG/assert_level.log)"
fi
expect_green assert_level_functional tests//functional/assert_level: tests//functional/mem_cap:
# Each test's branch coverage run (its bitcode compiled, linked and run, as
# the gate would read it) passes only when the bitcode got the test's level
# and defines: at the default level safe_probe's assert fires (exit 132), and
# a missing define fails the test's assert_equal.
expect_green assert_level_branch_runs -c komira.coverage=true \
    'tests//functional/assert_level:lib_none[coverage][branch][test_quiet_at_none]' \
    'tests//functional/assert_level:lib_defines[coverage][branch][test_define_seen]' \
    'tests//functional/assert_level:lib_level_and_defines[coverage][branch][test_level_and_defines]'
if ! "$BUCK2" build tests//functional/mem_cap:cases --show-full-simple-output > "$LOG/mem_cap_cases.txt" 2> "$LOG/mem_cap_cases.log"; then
    fail "mem_cap cases: $(grep '^BAD ' "$LOG/mem_cap_cases.log" | sort -u | tr '\n' ' ')(see $LOG/mem_cap_cases.log)"
else
    report=$(tail -n 1 "$LOG/mem_cap_cases.txt")
    ok=$(grep -c '^ok ' "$report" || true)
    if grep -q '^BAD ' "$report" || [ "$ok" -lt 4 ]; then
        fail "mem_cap cases: $(grep -v '^ok ' "$report" | tr '\n' ' ') ($ok ok; see $report)"
    else
        pass "mem_cap cases: $ok stand-in runs; an unreadable /proc, a signalled cap and a child reparented out of the tree leave nothing of the run alive"
    fi
fi
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

# The time limit of a mojo_test under `buck2 test` (test_deadline.sh,
# test_limit.bzl).
if ! "$BUCK2" build tests//functional/test_deadline:cases --show-full-simple-output > "$LOG/test_deadline_cases.txt" 2> "$LOG/test_deadline_cases.log"; then
    fail "test_deadline cases: $(grep '^BAD ' "$LOG/test_deadline_cases.log" | sort -u | tr '\n' ' ')(see $LOG/test_deadline_cases.log)"
else
    report=$(tail -n 1 "$LOG/test_deadline_cases.txt")
    ok=$(grep -c '^ok ' "$report" || true)
    if grep -q '^BAD ' "$report" || [ "$ok" -lt 6 ]; then
        fail "test_deadline cases: $(grep -v '^ok ' "$report" | tr '\n' ' ') ($ok ok; see $report)"
    else
        pass "test_deadline cases: $ok stand-in runs; the status passes through at once, the test is killed at its limit and the runner reports it, and nothing is left alive"
    fi
fi
TD=tests//negative/test_deadline:test_slow
if timeout 900 "$BUCK2" test -c komira.test_timeout_s=90 "$TD" -- --timeout 90 > "$LOG/test_deadline_slow.log" 2>&1; then
    fail "test_deadline_slow: buck2 test $TD passed, but its time limit must kill it"
elif ! grep -qF "TEST TIME LIMIT: killed $TD after 30 s, under the test runner's timeout of 90 s (komira.test_timeout_s)" "$LOG/test_deadline_slow.log" ||
    ! grep -qF "GATED TEST FAILED: $TD (exit 137)" "$LOG/test_deadline_slow.log" ||
    ! grep -qF "TEST_DEADLINE_FIXTURE start" "$LOG/test_deadline_slow.log"; then
    fail "test_deadline_slow: failed without the limit's line, the runner's report or the test's output (see $LOG/test_deadline_slow.log)"
else
    pass "test_deadline_slow: a mojo_test past its limit is killed 60 s before the test runner's timeout, and says so"
fi
for v in abc 60; do
    if "$BUCK2" build -c komira.test_timeout_s=$v "$TD" > "$LOG/test_deadline_bad_$v.log" 2>&1; then
        fail "test_deadline_bad_$v: [komira] test_timeout_s = $v was accepted"
    elif ! grep -qF -e "[komira] test_timeout_s = \"$v\" is not a whole number of seconds" -e "[komira] test_timeout_s = $v must be over 60 s" "$LOG/test_deadline_bad_$v.log"; then
        fail "test_deadline_bad_$v: refused without its message (see $LOG/test_deadline_bad_$v.log)"
    else
        pass "test_deadline_bad_$v: [komira] test_timeout_s = $v is refused"
    fi
done
