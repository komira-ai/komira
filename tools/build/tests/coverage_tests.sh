# shellcheck shell=bash
# coverage_tests.sh -- tests of coverage builds
# (tools/build/mojo/README.md#coverage-builds). Sourced by
# tools/build/tests/run_tests.sh (uses its BUCK2, ROOT, LOG, pass, fail,
# expect_green and expect_red); not run on its own.
#
#  41. Coverage builds: with -c komira.coverage=true, every release action
#      of tests//functional/coverage:covlib, :covuser and //src/komira_retry
#      keeps its command line and inputs, but the join, whose inputs gain
#      exactly one coverage run per test and the gate (test 46), and covuser
#      (a dependent of covlib) does not compile again; :covbare (no test, no
#      README) has a join only with the switch on, waiting for its gate
#      alone; and the only new actions are coverage ones,
#      one -O0 build per test, unset is false, darwin-arm64 gets no coverage
#      attribute, and a README's build and run do not run again when the
#      switch turns on (tools/build/tests/functional/coverage_keys.sh: aquery,
#      cquery, and two cached builds of //src/komira_retry); [coverage] and
#      [coverage][bin] are exactly the per-test binaries
#      (tests//functional/coverage:aggregates); the coverage binaries keep .debug_line, hold the
#      placeholder of the C runtime's compilation directory, name the Mojo
#      sources by relative directories, hold no absolute path, and have no
#      compressed section (:hermetic; planted strings with an absolute path
#      or without a relative directory fail it,
#      tests//negative/coverage:abs_relocated, :abs_other, :no_reldir); two
#      actions building one test give the same bytes (:reproducible); a
#      no-op relocator fails the build
#      with the wrapper's exit 4 (tests//negative/coverage:noop[coverage]);
#      and a value other than true or false fails at load. Off
#      linux-x86_64 coverage is a no-op (never measured there): on
#      darwin-arm64 with the switch, libraries and shared libraries, from
#      the switch or forced by a tests-cell fixture, have no coverage
#      attribute and the actions they have with it off
#      (tools/build/tests/functional/coverage_platforms.sh).

if BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/coverage_platforms.sh" "$LOG" > "$LOG/coverage_platforms.log" 2>&1; then
    pass "$(grep -o 'PASS  coverage platforms: .*' "$LOG/coverage_platforms.log" | cut -c 7-)"
else
    fail "$(grep -o 'FAIL  coverage platforms: .*' "$LOG/coverage_platforms.log" | cut -c 7- | cut -c 1-400) (see $LOG/coverage_platforms.log)"
fi
if BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/coverage_keys.sh" "$LOG" > "$LOG/coverage_keys.log" 2>&1; then
    pass "$(grep -o 'PASS  coverage keys: .*' "$LOG/coverage_keys.log" | cut -c 7-)"
else
    fail "$(grep -o 'FAIL  coverage keys: .*' "$LOG/coverage_keys.log" | cut -c 7- | cut -c 1-400) (see $LOG/coverage_keys.log)"
fi
expect_green coverage_binaries tests//functional/coverage/...
expect_red coverage_abs_relocated "holds an absolute path under the working directory" tests//negative/coverage:abs_relocated
expect_red coverage_abs_other "holds an absolute path (/var/build/" tests//negative/coverage:abs_other
expect_red coverage_no_reldir "no relative directory matching 'tests'" tests//negative/coverage:no_reldir
expect_red coverage_noop_relocate "contains this action's working directory" 'tests//negative/coverage:noop[coverage]'
if "$BUCK2" build tests//functional/coverage:covlib -c komira.coverage=yes > "$LOG/coverage_switch_yes.log" 2>&1; then
    fail "coverage_switch_yes: -c komira.coverage=yes built, but it must fail at load"
elif grep -qF '[komira] coverage = "yes": it must be `true` or `false`' "$LOG/coverage_switch_yes.log"; then
    pass "coverage_switch_yes"
else
    fail "coverage_switch_yes: failed without naming the value (see $LOG/coverage_switch_yes.log)"
fi
