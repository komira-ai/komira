# shellcheck shell=bash
# coverage_branch_tests.sh -- tests of branch coverage runs
# (tools/build/coverage/branch/README.md). Sourced by
# tools/build/tests/coverage_run_tests.sh after test 46's (uses run_tests.sh's
# BUCK2, LOG, pass, fail, expect_green and expect_red); not run on its own.
#
#  47. Branch coverage runs: with coverage, each welded test is also emitted
#      as LLVM bitcode, instrumented with IR profile counters by Mojo's lld,
#      linked with the profile runtime, and run through the release gate's
#      runner; its merged profile is [coverage][branch][<test>], that
#      profile applied to the bitcode [coverage][branch_ir][<test>], and the
#      branch records of the library's sources [coverage][branch_info][<test>]
#      (tools/build/tests/coverage_runs.md, test 47).
#      tests//functional/coverage:branch_counts (branchlib's test takes some
#      arms of classify_score, an if/elif/or/and function: its counters,
#      sorted, are 0,0,1,1,2,2); :link_line (the branch link of that test
#      is its release link plus the profile runtime); :branchlib and its
#      [coverage][branch][test_gate_env] (the run gives the test no LC_ALL,
#      as the release gate does not); :branchc and its [coverage][branch]
#      (a closure with a C library: the link tail); :branchtd and its
#      [coverage][branch] (a test needing a test_deps package with a C
#      library: the tests' closure and C link); :reproducible_branch and
#      :reproducible_pgo_bin (one test's bitcode and instrumented binary,
#      built in two actions with different keys, are the same bytes);
#      :branch_info (the branch records cov_branch_classify writes for
#      test_score_arms are its golden file: the `if` and both `elif`s, which
#      Mojo puts on one location, three records; the `or` and `and` with
#      their right operands derived; shapes.mojo's while, range( loop,
#      ternary, or chain and plain @always_inline helper; values.mojo's
#      and/or whose result is returned, stored or passed on, each its own
#      two arms, and those whose result a branch tests, with their right
#      operands; loops.mojo's
#      loops over a List and a list literal, arm 0 the end; lookup.mojo's
#      Dict subscript, compiler-made; mask.mojo's two user masks, decisions;
#      and for test_unrun, unrun.mojo's Tag.write_to, which the link drops
#      as only a folded-away assert failure calls it: its `if`, never run);
#      tests//negative/coverage: branchfail, branchannotate,
#      branchnoprof and branchversion build green (their release gates),
#      and branchfail[coverage][branch][test_profile_env] is red (a test
#      failing only instrumented: the run's message, without gate_runner's
#      banner), branchnoprof[...] red (a cov_branch_run.sh copy whose test
#      gets no LLVM_PROFILE_FILE: no .profraw), branchversion[...] red (a
#      copy raising each raw profile's version to 12: refused as version 12,
#      not 11), branchannotate[coverage][branch_ir][test_one] red (a
#      cov_branch_annotate.sh copy changing the control flow before the
#      profile is applied: LLVM's hash mismatch warning, refused),
#      branchmissing[...][branch_ir] red (a cov_branch_run.sh copy merging
#      without the test's main: a function the binary links that the
#      profile lacks, refused), branchinternal[...][branch_ir] red (a copy
#      internalizing the bitcode before the profile is applied: a function
#      of the profile the bitcode does not hold, refused), branchwide's
#      [branch_ir] green (a copy padding the section-name pipeline with
#      1 MB: its reader takes all of it, so no writer dies of SIGPIPE),
#      branchweights[...][branch_ir] red (a copy annotating a bitcode that
#      already holds branch weights), branchentry[...][branch_ir] red (that
#      copy with the weights check off: the entry counts refused), branchnodebug[...][branch_info] red
#      (a nodebug helper's decision at its call),
#      branchenv red at analysis (a test_env setting
#      LLVM_PROFILE_FILE), branchlinkline red (a cov_branch_link.sh copy
#      without -lm: not the release link). The actions exist only with the
#      switch on: coverage_keys.sh (test 41).

expect_green coverage_branch tests//functional/coverage:branch_counts tests//functional/coverage:link_line \
    tests//functional/coverage:branchlib 'tests//functional/coverage:branchlib[coverage][branch][test_gate_env]' \
    tests//functional/coverage:branchc 'tests//functional/coverage:branchc[coverage][branch]' \
    tests//functional/coverage:branchtd 'tests//functional/coverage:branchtd[coverage][branch]' \
    tests//functional/coverage:reproducible_branch tests//functional/coverage:reproducible_pgo_bin \
    tests//functional/coverage:branch_info \
    tests//negative/coverage:branchfail tests//negative/coverage:branchannotate \
    tests//negative/coverage:branchnoprof tests//negative/coverage:branchversion \
    tests//negative/coverage:branchmissing tests//negative/coverage:branchweights \
    tests//negative/coverage:branchinternal tests//negative/coverage:branchwide \
    tests//negative/coverage:branchentry \
    'tests//negative/coverage:branchwide[coverage][branch_ir][test_one]' \
    tests//negative/coverage:branchnodebug
expect_red coverage_branch_test_fails "The test failed instrumented for branch coverage (exit 1)" \
    'tests//negative/coverage:branchfail[coverage][branch][test_profile_env]'
# The failing run's message is a branch coverage run's: not gate_runner's
# banner, which would say the release gate's test failed (it passed).
# A missing log is a failure, not a pass (grep's exit 2 is not "absent").
if [ ! -f "$LOG/coverage_branch_test_fails.log" ]; then
    fail "coverage_branch_banner: $LOG/coverage_branch_test_fails.log does not exist, so the banner cannot be checked"
elif grep -E "GATED TEST FAILED|package is not produced" "$LOG/coverage_branch_test_fails.log" > "$LOG/coverage_branch_banner.txt"; then
    fail "coverage_branch_banner: a failing branch coverage run prints the release gate's banner: $(head -n 1 "$LOG/coverage_branch_banner.txt") (see $LOG/coverage_branch_test_fails.log)"
else
    pass coverage_branch_banner
fi
expect_red coverage_branch_no_profile "The test passed but wrote no .profraw" \
    'tests//negative/coverage:branchnoprof[coverage][branch][test_one]'
expect_red coverage_branch_raw_version "has raw profile version 12, not 11" \
    'tests//negative/coverage:branchversion[coverage][branch][test_one]'
expect_red coverage_branch_annotate_mismatch "diagnostic(s) applying the profile: lld: warning: ld-temp.o: function control flow change detected (hash mismatch)" \
    'tests//negative/coverage:branchannotate[coverage][branch_ir][test_one]'
expect_red coverage_branch_missing_function "a run writes the record of every function its binary links, ran or not" \
    'tests//negative/coverage:branchmissing[coverage][branch_ir][test_one]'
expect_red coverage_branch_other_bitcode "the binary that wrote it was not made from this bitcode" \
    'tests//negative/coverage:branchinternal[coverage][branch_ir][test_one]'
expect_red coverage_branch_static_weights "already holds branch weights" \
    'tests//negative/coverage:branchweights[coverage][branch_ir][test_one]'
expect_red coverage_branch_static_entry_counts "already holds function entry counts" \
    'tests//negative/coverage:branchentry[coverage][branch_ir][test_one]'
expect_red coverage_branch_nodebug "may be a decision of count_down" \
    'tests//negative/coverage:branchnodebug[coverage][branch_info][test_nodebug]'
expect_red coverage_branch_test_env "test_env sets LLVM_PROFILE_FILE, which a branch coverage run sets itself" \
    tests//negative/coverage:branchenv
expect_red coverage_branch_link_line "the branch coverage link is not the release link plus the profile runtime" \
    tests//negative/coverage:branchlinkline
