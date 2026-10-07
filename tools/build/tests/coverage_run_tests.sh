# shellcheck shell=bash
# coverage_run_tests.sh -- tests of coverage runs (tools/build/coverage/kcov/README.md#cov_run).
# Sourced by tools/build/tests/run_tests.sh (uses its BUCK2, LOG, pass, fail,
# expect_green and expect_red); not run on its own.
#
#  43. Coverage runs: each test's coverage binary runs under kcov through the
#      release gate's runner, and its report is in repository paths.
#      tests//functional/coverage:numbers (each per-test report of
#      covlib_forced equals its golden file: a covered function, an arm no
#      test takes, a `# cov: unreachable` line, all under
#      tools/build/tests/functional/coverage/; and covgen's, whose generated
#      source is not measured); :census (covcheck's gate in
#      census mode reads them: 7 of 9 lines, 1 exempt, the tests set aside);
#      :aggregates_tests and :aggregates_all ([coverage][tests] and
#      [coverage]); covenv[coverage] (test_env, data, PATH, HOME, TMPDIR, no
#      LD_PRELOAD and the CPUs the test may run on are the gate's under kcov;
#      a data file where the binary names a standard library source stays
#      out of the report);
#      tests//negative/coverage:tracer green, its kcov run red (kcov traced
#      the test and passed its exit status on); orphan[coverage] green and
#      exits[coverage] red, exit 1 and exit 137 (the status is the test's,
#      not a child's it left behind, and 128+N for signal N);
#      tests//negative/coverage:lost[coverage] red (sources staged where the
#      line tables do not name them are refused as unmapped, not dropped);
#      lostdir[coverage] red (a binary naming the sources by another
#      directory than the run stages is refused before kcov runs); clash and
#      clash_buckout red at analysis (data where a run stages sources);
#      refused[coverage] red (kcov refused by the executor is said so).
#      The release actions with the switch on: coverage_keys.sh (test 41).

expect_green coverage_runs tests//functional/coverage:numbers tests//functional/coverage:census \
    tests//functional/coverage:aggregates_tests tests//functional/coverage:aggregates_all \
    tests//functional/coverage:covenv 'tests//functional/coverage:covenv[coverage]' \
    tests//functional/coverage:covgen \
    tests//negative/coverage:tracer tests//negative/coverage:lost \
    tests//negative/coverage:orphan 'tests//negative/coverage:orphan[coverage]'
expect_red coverage_run_tracer "test_tracer: traced, TracerPid" 'tests//negative/coverage:tracer[coverage][tests][test_tracer]'
expect_red coverage_run_lost "lostlib/value.mojo': no --map or --exclude prefix covers it" 'tests//negative/coverage:lost[coverage][tests][test_lost]'
expect_red coverage_run_data_clash 'collides with its source, which a coverage run stages at "tests/test_lost.mojo"' tests//negative/coverage:clash
expect_red coverage_run_data_buckout 'the data destination "buck-out/data.txt" is under buck-out/, where a coverage run stages' tests//negative/coverage:clash_buckout
expect_red coverage_run_parent_fails "The test failed under kcov (exit 1)" 'tests//negative/coverage:exits[coverage][tests][test_parent_fails]'
expect_red coverage_run_killed "The test failed under kcov (exit 137)" 'tests//negative/coverage:exits[coverage][tests][test_killed]'
expect_red coverage_run_lostdir "this run stages them at buck-out/v2/art/tests/negative/coverage/__lostdir__/" 'tests//negative/coverage:lostdir[coverage][tests][test_lost]'
expect_red coverage_run_refused "kcov could not trace the test" 'tests//negative/coverage:refused[coverage][tests][test_one]'
