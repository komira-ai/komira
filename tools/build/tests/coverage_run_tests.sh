# shellcheck shell=bash
# coverage_run_tests.sh -- tests of coverage runs (tools/build/coverage/kcov/README.md#cov_run).
# Sourced by tools/build/tests/run_tests.sh (uses its BUCK2, LOG, pass, fail,
# expect_green and expect_red); not run on its own. Sources test 46's
# coverage_gate_tests.sh after its own, then test 47's
# coverage_branch_tests.sh.
#
#  43. Coverage runs: each test's coverage binary runs under kcov through the
#      release gate's runner, and its report is in repository paths.
#      tests//functional/coverage:numbers (each per-test report of
#      covlib_forced equals its golden file: a covered function, an arm no
#      test takes, a `# cov: unreachable` line, all under
#      tools/build/tests/functional/coverage/; and covgen's, whose generated
#      source is not measured, and covgenmany's, whose twelve long-named
#      generated sources are not either: cov_run.sh once named them all in
#      one kcov argument of 2048 bytes or more, which kcov fails on);
#      :covgentest_report and :covgentest_result (a generated test has its
#      coverage run, and its gate counts what it runs and sets it aside);
#      :census (covcheck's gate in
#      census mode reads them: 7 of 9 lines, 1 exempt, the tests set aside);
#      :aggregates_tests and :aggregates_all ([coverage][tests] and
#      [coverage]); covenv[coverage] (test_env, data, PATH, HOME, TMPDIR, no
#      LD_PRELOAD and the CPUs the test may run on are the gate's under kcov;
#      a data file where the binary names a standard library source stays
#      out of the report); branchlib[coverage][tests][test_gate_env] (no
#      LC_ALL under kcov: cov_run.sh's own is not exported to the test);
#      tests//negative/coverage:tracer green, its kcov run red (kcov traced
#      the test and passed its exit status on); orphan[coverage] green and
#      exits[coverage] red, exit 1 and exit 137 (the status is the test's,
#      not a child's it left behind, and 128+N for signal N), the first
#      without gate_runner's banner (the release gate's test did not fail);
#      tests//negative/coverage:linger and linger[coverage][tests][test_brief]
#      green, ...[test_lingers] red (a child left sleeping 100 s holds kcov,
#      and the run's 20 s test-only limit kills the run), and its log without
#      "survived the kill" (the kill reached the run's whole process group);
#      lingerproc[coverage][tests][test_lingers] red (a cov_run.sh copy
#      taking 1 for its own pid, so /proc/<pid> is another process, as in a
#      /proc of another PID namespace: a /proc that does not show the run's
#      shell under its own pid is refused before the survivor scan, which
#      would see none of the group there);
#      tests//negative/coverage:lost[coverage] red (sources staged where the
#      line tables do not name them are refused as unmapped, not dropped);
#      lostdir[coverage] red (a binary naming the sources by another
#      directory than the run stages is refused before kcov runs); clash and
#      clash_buckout red at analysis (data where a run stages sources);
#      refused[coverage] red (kcov refused by the executor is said so);
#      covreadme[coverage][tests][readme] and covreadme_none's (a README's
#      examples, and a README with none, run under kcov like a test) and
#      covmt_cov_gate[tests] (the mojo_test targets covmt names in
#      coverage_tests, one in another package, run against its sources);
#      longarg[coverage] red (a cov_run.sh copy whose limit on a kcov
#      argument is 64 bytes refuses the run before kcov starts, naming it);
#      shared libraries: covso's driver report and census gate, covso_skip
#      red with kcov skipping the loaded library, the examples' [coverage]
#      with the switch, coverage_shared_lib.sh (no release action moves),
#      and covso_gen's run red (every source generated: nothing to check).
#      The release actions with the switch on: coverage_keys.sh (test 41).

expect_green coverage_runs tests//functional/coverage:numbers tests//functional/coverage:census \
    tests//functional/coverage:covgentest_report tests//functional/coverage:covgentest_result \
    tests//functional/coverage:aggregates_tests tests//functional/coverage:aggregates_all \
    tests//functional/coverage:covenv 'tests//functional/coverage:covenv[coverage]' \
    tests//functional/coverage:covgen tests//functional/coverage:covgenmany \
    'tests//functional/coverage:branchlib[coverage][tests][test_gate_env]' \
    tests//negative/coverage:tracer tests//negative/coverage:lost \
    tests//negative/coverage:orphan 'tests//negative/coverage:orphan[coverage]' \
    tests//negative/coverage:linger 'tests//negative/coverage:linger[coverage][tests][test_brief]' \
    'tests//functional/coverage/covreadme:covreadme[coverage][tests][readme]' \
    'tests//functional/coverage/covreadme_none:covreadme_none[coverage][tests][readme]' \
    'tests//functional/coverage:covmt_cov_gate[tests]'
expect_red coverage_run_tracer "test_tracer: traced, TracerPid" 'tests//negative/coverage:tracer[coverage][tests][test_tracer]'
expect_red coverage_run_lost "lostlib/value.mojo': no --map or --exclude prefix covers it" 'tests//negative/coverage:lost[coverage][tests][test_lost]'
expect_red coverage_run_data_clash 'collides with its source, which a coverage run stages at "tests/test_lost.mojo"' tests//negative/coverage:clash
expect_red coverage_run_data_buckout 'the data destination "buck-out/data.txt" is under buck-out/, where a coverage run stages' tests//negative/coverage:clash_buckout
expect_red coverage_run_parent_fails "The test failed under kcov (exit 1)" 'tests//negative/coverage:exits[coverage][tests][test_parent_fails]'
expect_red coverage_run_killed "The test failed under kcov (exit 137)" 'tests//negative/coverage:exits[coverage][tests][test_killed]'
# The failing run's message is a coverage run's: not gate_runner's banner,
# which would say the release gate's test failed (it passed).
# A missing log is a failure, not a pass (grep's exit 2 is not "absent").
if [ ! -f "$LOG/coverage_run_parent_fails.log" ]; then
    fail "coverage_run_banner: $LOG/coverage_run_parent_fails.log does not exist, so the banner cannot be checked"
elif grep -E "GATED TEST FAILED|package is not produced" "$LOG/coverage_run_parent_fails.log" > "$LOG/coverage_run_banner.txt"; then
    fail "coverage_run_banner: a failing coverage run prints the release gate's banner: $(head -n 1 "$LOG/coverage_run_banner.txt") (see $LOG/coverage_run_parent_fails.log)"
else
    pass coverage_run_banner
fi
expect_red coverage_run_lostdir "this run stages them at buck-out/v2/art/tests/negative/coverage/__lostdir__/" 'tests//negative/coverage:lostdir[coverage][tests][test_lost]'
expect_red coverage_run_refused "kcov could not trace the test" 'tests//negative/coverage:refused[coverage][tests][test_one]'
expect_red coverage_run_longarg "is longer than kcov takes (64)" 'tests//negative/coverage:longarg[coverage][tests][test_lost]'
expect_red coverage_run_lingers "The test left processes running or did not finish within 20 s under kcov" 'tests//negative/coverage:linger[coverage][tests][test_lingers]'
# The limit's kill reached the whole group: cov_run.sh says when a process
# of it survived (a kill of gate_runner alone, its pid without the '-').
# A missing log is a failure, not a pass (grep's exit 2 is not "absent").
if [ ! -f "$LOG/coverage_run_lingers.log" ]; then
    fail "coverage_run_lingers_group: $LOG/coverage_run_lingers.log does not exist, so whether the kill reached the whole group cannot be checked"
elif grep -F "processes of the coverage run survived the kill" "$LOG/coverage_run_lingers.log" > "$LOG/coverage_run_lingers_survivors.txt"; then
    fail "coverage_run_lingers_group: the time limit's kill left processes of the run: $(head -n 1 "$LOG/coverage_run_lingers_survivors.txt") (see $LOG/coverage_run_lingers.log)"
else
    pass coverage_run_lingers_group
fi
expect_red coverage_run_proc "/proc is not readable as this run's own" 'tests//negative/coverage:lingerproc[coverage][tests][test_lingers]'

# Shared libraries (mojo_shared_lib): each driver of gate_srcs runs under
# kcov with the library's coverage build, which kcov measures as the driver
# loads it. covso's report and census gate (tests//functional/coverage);
# covso_skip's published file is green and its run red with kcov told to skip
# the libraries a driver loads (the report must hold the library's source);
# the example shared libraries, coverage from the switch (drivers at the
# package's top, a force-loaded C library, a version script); and
# coverage_shared_lib.sh: the switch moves no release action of a shared
# library, and its published file waits for no coverage action.
expect_green coverage_run_shared_lib tests//functional/coverage:covso_report tests//functional/coverage:covso_result \
    tests//negative/coverage:covso_skip
expect_red coverage_run_shared_lib_skip "no class for tools/build/tests/negative/coverage/covso/covso_one.mojo (--must-contain)" \
    'tests//negative/coverage:covso_skip[coverage][tests][covso_one_driver]'
expect_red coverage_run_shared_lib_generated "cov_run: --solib with no --solib-src: every source of the shared library covso_one.so is generated" \
    'tests//negative/coverage:covso_gen[coverage][tests][covso_one_driver]'
expect_green coverage_run_shared_lib_switch 'komira//tools/build/examples/shared_lib:spike[coverage]' \
    'komira//tools/build/examples/shared_lib:plain[coverage]' 'komira//tools/build/examples/shared_lib:spike_exact[coverage]' \
    -c komira.coverage=true
if BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/coverage_shared_lib.sh" "$LOG" > "$LOG/coverage_shared_lib.log" 2>&1; then
    pass "$(grep -o 'PASS  coverage shared lib: .*' "$LOG/coverage_shared_lib.log" | cut -c 7-)"
else
    fail "$(grep -o 'FAIL  coverage shared lib: .*' "$LOG/coverage_shared_lib.log" | cut -c 7- | cut -c 1-400) (see $LOG/coverage_shared_lib.log)"
fi

# 46
# shellcheck source=tools/build/tests/coverage_gate_tests.sh
. "$ROOT/tools/build/tests/coverage_gate_tests.sh"

# 47
# shellcheck source=tools/build/tests/coverage_branch_tests.sh
. "$ROOT/tools/build/tests/coverage_branch_tests.sh"
