# shellcheck shell=bash
# coverage_gate_tests.sh -- tests of the coverage gate and what waits for it
# (tools/build/coverage/README.md#the-build-gate). Sourced by
# tools/build/tests/coverage_run_tests.sh (uses run_tests.sh's BUCK2, LOG,
# pass, fail, expect_green and expect_red); not run on its own.
#
#  46. The coverage gate: with coverage, a library's conda package (what
#      ships) waits for its tests' coverage runs and for `covcheck gate` over
#      their reports and their branch records (--branch-lcov); the library
#      itself, and so every dependent, does not.
#      tests//negative/coverage (tools/build/coverage/README.md, "The build
#      gate"; tools/build/tests/coverage_runs.md, test 46):
#      the [coverage][gate] of covlow, covnotests, covun, covfull_unread,
#      covbranch, covtry and covandor in enforce mode is red, each naming its
#      finding:
#      BelowTarget (a test covering 3 of 6 lines, and 1 of the 4 arms of its
#      two `if`s), NotMeasured (a library with no test still has a gate),
#      UnmeasuredFile (a source no test compiles), BranchNotMeasured alone
#      (every line covered and a ratchet row, its gate reading no branch
#      record: coverage_branch_gate = False), BelowTarget on branch alone
#      (every line covered, one arm of its `if` never taken: the branch
#      records reach the gate), BelowTarget on branch alone again (every
#      line covered, a raising call in a `try:` body never raising), and
#      again (every line covered, `return a or b` never skipping its right
#      operand: an and/or whose result no branch tests is a decision);
#      covbranch_both, covtry_both and covandor_both (every arm taken) and covfull
#      (the library of covfull_unread, no decision, its records naming its
#      file with no arm) are green in enforce mode, gate included; the
#      census twins are green and their result.json says so
#      (:<name>_census_result); covlow's library in a test-only package
#      (tests//src/tests/coverage:covinfo, under COVERAGE_INFO_ONLY_DIRS) has a
#      green gate in enforce mode, its BelowTarget and MissingRow information
#      (:covinfo_result), while covlow's stays red, and so does its copy
#      in tests//src/testsuite/coverage (covnotinfo: not under src/tests); covtop_census_result: a library whose welded
#      tests are outside its package's tests/ analyzes with coverage, and
#      its gate leaves both tests out of its numbers (--test-source); covbad:
#      a census gate over a malformed ratchet is red (covcheck exit 1 fails
#      the gate in every mode); what a red gate blocks: the libraries above
#      and covlow_user (which depends on covlow and runs its test against
#      covlow's package) are green, and covlow_conda and covnotests_conda
#      (a REFUSED package: no test) are red with their gate's failure; a
#      generated client (komira_aws_tiny_query, tests at its package's top)
#      analyzes with coverage and has its gate; tracer_shipped (a test that
#      fails only traced) and its conda package are green without the
#      switch; with -c komira.coverage=true the library is still green and
#      its conda package red (it waits for the coverage run);
#      no_gate.bxl holds the ledger COVERAGE_NO_GATE equal to the Mojo
#      libraries the gate's tool depends on, and each one's conda package
#      depends on its `<name>_cov_gate`; branch_gate.bxl holds every row of
#      COVERAGE_BRANCH_GATE to a mojo_library of komira//src/... (a row
#      whose library moved is read by nothing); as actions (aquery): the package
#      joins of tracer_shipped (outside the ledger, coverage from the
#      switch) and readme_examples (in it) wait for no coverage action, and both joins of each one's conda
#      package wait for each of its coverage runs and its one gate (the
#      library's own, or `<name>_cov_gate`). That the switch moves no
#      release action of a library, its join included: coverage_keys.sh
#      (test 41). The refusals of the coverage attributes outside the tests
#      cell are test 7's (umbrella_cache.sh, in a consumer's cell).
#      README examples and mojo_test targets: tests//functional/coverage
#      covreadme_result (a library whose only test is its README's example
#      is measured by it: 2 of 2 lines), covreadme_none_result (a README
#      with no example: NotMeasured), covmt_result (covmt_cov_gate reads the
#      runs of the two mojo_test targets covmt names in coverage_tests, one
#      in another package: 2 of 2 lines, its own test set aside);
#      tests//negative/coverage:tracer_mt and test_tracer_mt green and
#      tracer_mt_conda red (what ships waits for the run of a test the
#      library names); covmt_stray_cov_gate, covmt_args_cov_gate,
#      covmt_gen_cov_gate and covmt_nocov_cov_gate red at analysis (a named
#      test must depend on the library, have no args and a source main, and
#      have a coverage build); komira_db_sqlite (outside the tests cell,
#      naming coverage_tests) analyzes with the switch on, with no gate
#      action of its own and one in komira_db_sqlite_cov_gate.
#      A shared library's gate (COVERAGE_SHARED_LIB_MODE): covso_traced is
#      green with the switch on and its driver's coverage run red (nothing
#      waits for it); enforce is refused in analysis (covso_enforce). A
#      welded test at a library source's path is refused (testpath).

N=tests//negative/coverage
P=tools/build/tests/negative/coverage
expect_green coverage_gate_census "$N:covlow_census_result" "$N:covnotests_census_result" \
    "$N:covun_census_result" "$N:covfull_census_result" "$N:covfull_unread_census_result" \
    "$N:covtop_census_result" "$N:covbranch_census_result" "$N:covtry_census_result" \
    "$N:covandor_census_result" "$N:covbranch_both[coverage][gate]" "$N:covtry_both[coverage][gate]" \
    "$N:covandor_both[coverage][gate]" "$N:covfull[coverage][gate]"
# A test-only package below the target: its gate is green in enforce mode,
# what it found information (covlow, the same library elsewhere, is red
# below).
expect_green coverage_gate_test_only "tests//src/tests/coverage:covinfo[coverage][gate]" tests//src/tests/coverage:covinfo_result
# ... at a segment boundary: src/testsuite is not under src/tests.
expect_red coverage_gate_not_test_only "COVERAGE GATE FAILED (enforce): tools/build/tests/src/testsuite/coverage (tests//src/testsuite/coverage:covnotinfo [coverage gate]): covcheck gate exited 3" "tests//src/testsuite/coverage:covnotinfo[coverage][gate]"
expect_red coverage_gate_census_malformed "COVERAGE GATE ERROR: $P ($N:covbad [coverage gate]): covcheck exited 1" "$N:covbad[coverage][gate]"
expect_red coverage_gate_enforce "COVERAGE GATE FAILED (enforce): $P ($N:covlow [coverage gate]): covcheck gate exited 3" "$N:covlow[coverage][gate]"
expect_red coverage_gate_notests "- **NotMeasured** \`$P\`: no line of this package was measured" "$N:covnotests[coverage][gate]"
expect_red coverage_gate_unmeasured "- **UnmeasuredFile** \`$P\` \`$P/covun/unused.mojo\`: no test binary compiled this file" "$N:covun[coverage][gate]"
expect_red coverage_gate_branch "- **BranchNotMeasured** \`$P\`: no branch of this package was measured" "$N:covfull_unread[coverage][gate]"
expect_red coverage_gate_branch_arm "COVERAGE GATE FAILED (enforce): $P ($N:covbranch [coverage gate]): covcheck gate exited 3" "$N:covbranch[coverage][gate]"
expect_red coverage_gate_branch_try "COVERAGE GATE FAILED (enforce): $P ($N:covtry [coverage gate]): covcheck gate exited 3" "$N:covtry[coverage][gate]"
expect_red coverage_gate_branch_andor "COVERAGE GATE FAILED (enforce): $P ($N:covandor [coverage gate]): covcheck gate exited 3" "$N:covandor[coverage][gate]"
# Each red is its own finding: covlow's is BelowTarget, covfull_unread's
# only finding is BranchNotMeasured (line 100%, a ratchet row), and covbranch's
# only finding is BelowTarget on branch (line 100%, a ratchet row, its
# branch records read), and so is covtry's (a `try` decision's raise arm)
# and covandor's (an `or`'s arm skipping its right operand).
# The enforce banner names what a red gate blocks:
# the conda package only.
for want in "coverage_gate_enforce|- **BelowTarget** \`$P\`: line 50.00% is below the target 100.00%" \
    "coverage_gate_enforce|The conda package (covlow_conda) is not produced until its coverage meets the policy;" \
    "coverage_gate_branch|### Findings (1)" \
    "coverage_gate_branch_arm|- **BelowTarget** \`$P\`: branch 50.00% is below the target 100.00%" \
    "coverage_gate_branch_arm|### Findings (1)" \
    "coverage_gate_branch_try|- **BelowTarget** \`$P\`: branch 83.33% is below the target 100.00%" \
    "coverage_gate_branch_try|### Findings (1)" \
    "coverage_gate_branch_andor|- **BelowTarget** \`$P\`: branch 50.00% is below the target 100.00%" \
    "coverage_gate_branch_andor|### Findings (1)"; do
    if grep -qF -- "${want#*|}" "$LOG/${want%%|*}.log"; then
        pass "${want%%|*}_finding"
    else
        fail "${want%%|*}_finding: the log does not hold '${want#*|}' (see $LOG/${want%%|*}.log)"
    fi
done
# What a red gate blocks: what ships (the conda package), not the library,
# so not a dependent either (covlow_user compiles against covlow's package
# and runs its test). A library with no test has a REFUSED conda package,
# which waits for its gate all the same.
expect_green coverage_gate_library "$N:covlow" "$N:covnotests" "$N:covun" "$N:covfull" "$N:covfull_unread" \
    "$N:covbranch" "$N:covtry" "$N:covandor" "$N:covbad" "$N:covlow_user"
expect_red coverage_gate_conda "COVERAGE GATE FAILED (enforce): $P ($N:covlow [coverage gate]): covcheck gate exited 3" "$N:covlow_conda"
expect_red coverage_gate_conda_notests "- **NotMeasured** \`$P\`: no line of this package was measured" "$N:covnotests_conda"
# README examples and the mojo_test targets a library names in
# coverage_tests are its tests for coverage: their runs reach its gate, and
# what ships waits for them.
expect_green coverage_gate_readme_mojo_test tests//functional/coverage:covreadme_result \
    tests//functional/coverage:covreadme_none_result tests//functional/coverage:covmt_result \
    "$N:tracer_mt" "$N:test_tracer_mt"
expect_red coverage_gate_mojo_test_conda "COVERAGE RUN FAILED: $N:test_tracer_mt [coverage of $N:tracer_mt]" "$N:tracer_mt_conda"
expect_red coverage_gate_mojo_test_stray "$N:test_tracer_mt does not name $N:covmt_stray in its deps" "$N:covmt_stray_cov_gate"
expect_red coverage_gate_mojo_test_args "$N:test_args cannot run under kcov: it has" "$N:covmt_args_cov_gate"
expect_red coverage_gate_mojo_test_gen "$N:test_gen_main cannot run under kcov: its main source" "$N:covmt_gen_cov_gate"
expect_red coverage_gate_mojo_test_nocov "$N:test_nocov is not a mojo_test with a coverage build" "$N:covmt_nocov_cov_gate"
# A generated client whose welded tests are at its package's top analyzes
# with the switch on, and has its gate (analysis only: aquery).
CG=//tools/build/proto-codegen/aws_query:komira_aws_tiny_query
if "$BUCK2" aquery "attrfilter(category, mojo_cov_gate, all_actions($CG))" -c komira.coverage=true > "$LOG/coverage_gate_codegen.log" 2> "$LOG/coverage_gate_codegen.err" &&
    [ "$(grep -c "^(target: \`komira${CG} (" "$LOG/coverage_gate_codegen.log")" = 1 ]; then
    pass coverage_gate_codegen
else
    fail "coverage_gate_codegen: $CG has no coverage gate with -c komira.coverage=true, or does not analyze (see $LOG/coverage_gate_codegen.log and .err)"
fi
# A library outside the tests cell naming coverage_tests analyzes with the
# switch on (the rule accepts no gate of its own for it), and its gate is the
# one action of komira_db_sqlite_cov_gate (analysis only: aquery).
DB=//src/komira_db_sqlite:komira_db_sqlite
if "$BUCK2" aquery "attrfilter(category, mojo_cov_gate, all_actions(set($DB ${DB}_cov_gate)))" -c komira.coverage=true > "$LOG/coverage_gate_db_sqlite.log" 2> "$LOG/coverage_gate_db_sqlite.err" &&
    [ "$(grep -c "^(target: \`komira${DB} (" "$LOG/coverage_gate_db_sqlite.log")" = 0 ] &&
    [ "$(grep -c "^(target: \`komira${DB}_cov_gate (" "$LOG/coverage_gate_db_sqlite.log")" = 1 ]; then
    pass coverage_gate_coverage_tests_analysis
else
    fail "coverage_gate_coverage_tests_analysis: $DB does not analyze with -c komira.coverage=true, or its gate is not the one action of ${DB}_cov_gate (see $LOG/coverage_gate_db_sqlite.log and .err)"
fi
# The switch: a library with no coverage attribute of its own, whose test
# fails only under kcov, builds with it on; its conda package does not.
expect_green coverage_switch_off "$N:tracer_shipped" "$N:tracer_shipped_conda"
expect_green coverage_switch_library "$N:tracer_shipped" -c komira.coverage=true
if "$BUCK2" build "$N:tracer_shipped_conda" -c komira.coverage=true > "$LOG/coverage_switch_conda.log" 2>&1; then
    fail "coverage_switch_conda: $N:tracer_shipped_conda built with -c komira.coverage=true, but what ships must wait for the library's coverage run, which fails"
elif grep -qF "COVERAGE RUN FAILED: $N:tracer_shipped:tests/test_tracer.mojo [coverage]" "$LOG/coverage_switch_conda.log"; then
    pass coverage_switch_conda
else
    fail "coverage_switch_conda: failed without the coverage run's message (see $LOG/coverage_switch_conda.log)"
fi
if "$BUCK2" bxl //tools/build/coverage/no_gate.bxl:check -c komira.coverage=true > "$LOG/coverage_no_gate.log" 2>&1; then
    pass "coverage_no_gate: $(grep -o 'the [0-9]* libraries of the ledger.*' "$LOG/coverage_no_gate.log" | cut -c 1-160)"
else
    fail "coverage_no_gate: $(grep -E 'no_gate: |cycle' "$LOG/coverage_no_gate.log" | head -n 1 | cut -c 1-400) (see $LOG/coverage_no_gate.log)"
fi
if "$BUCK2" bxl //tools/build/coverage/branch_gate.bxl:check > "$LOG/coverage_branch_gate_rows.log" 2>&1; then
    pass "coverage_branch_gate_rows: $(grep -o 'the [0-9]* rows of COVERAGE_BRANCH_GATE.*' "$LOG/coverage_branch_gate_rows.log" | cut -c 1-160)"
else
    fail "coverage_branch_gate_rows: $(grep -E 'branch_gate: ' "$LOG/coverage_branch_gate_rows.log" | head -n 1 | cut -c 1-400) (see $LOG/coverage_branch_gate_rows.log)"
fi
# What waits, as actions (no_gate.bxl reads only the targets' deps), for a
# library outside the ledger whose coverage comes from the switch
# (tracer_shipped, its gate an action of its own) and one in it
# (readme_examples, its gate `<name>_cov_gate`), neither with a README
# (aquery cannot read a join's input through a README's dynamic action): the package's
# join waits for no coverage run and no gate; the conda package's
# conda_join and conda_release_join each wait for every coverage run and
# the one gate. Analysis only.
cov_cats() { # aquery expression, log name -> the category of each action it prints
    "$BUCK2" aquery "$1" -c komira.coverage=true -a '^category$' --json > "$LOG/$2.json" 2> "$LOG/$2.err" &&
        inspect_tool json "$LOG/$2.json" > "$LOG/$2.tsv" &&
        awk -F '\t' '$2 == "category" { print $3 }' "$LOG/$2.tsv"
}
for lib in "$N:tracer_shipped" //tools/build/readme_examples:readme_examples; do
    n=coverage_waits_${lib##*:}
    if all=$(cov_cats "all_actions($lib)" "${n}_all") &&
        join=$(cov_cats "deps(attrfilter(category, mojo_gate_join, all_actions($lib)), 1)" "${n}_join") &&
        cj=$(cov_cats "deps(attrfilter(category, conda_join, all_actions(${lib}_conda)), 1)" "${n}_conda") &&
        cr=$(cov_cats "deps(attrfilter(category, conda_release_join, all_actions(${lib}_conda)), 1)" "${n}_release"); then
        nb=$(grep -cx mojo_build_cov_test <<< "$all")
        got="$(grep -cx mojo_gate_join <<< "$all") $(grep -cx -E 'mojo_cov_run|mojo_cov_gate' <<< "$join")"
        got="$got $(grep -cx mojo_cov_run <<< "$cj") $(grep -cx mojo_cov_gate <<< "$cj") $(grep -cx mojo_cov_run <<< "$cr") $(grep -cx mojo_cov_gate <<< "$cr")"
        if [ "$nb" -gt 0 ] && [ "$got" = "1 0 $nb 1 $nb 1" ]; then
            pass "$n: $lib's join waits for none of its $nb coverage runs and no gate; both joins of ${lib}_conda wait for its $nb runs and its gate"
        else
            fail "$n: $lib has $nb coverage binaries; got (joins, coverage inputs of the join, conda_join runs and gates, conda_release_join runs and gates) $got, want 1 0 $nb 1 $nb 1 (see $LOG/${n}_*.tsv)"
        fi
    else
        fail "$n: an aquery of $lib with -c komira.coverage=true failed (see $LOG/${n}_*.err)"
    fi
done

# A shared library's gate is reported, never enforced, and nothing of it
# waits for its coverage: covso_traced (the published file) builds with the
# switch on while its driver's coverage run is red; enforce is refused in
# analysis (covso_enforce: the rule called without the macro, so a BUCK
# file cannot bypass it; the macro passes the mode through to the same check).
expect_green coverage_shared_lib_published "$N:covso_traced" -c komira.coverage=true
if "$BUCK2" build "$N:covso_traced[coverage][tests][covso_traced_driver]" -c komira.coverage=true > "$LOG/coverage_shared_lib_run.log" 2>&1; then
    fail "coverage_shared_lib_run: $N:covso_traced[coverage][tests][covso_traced_driver] built, but its driver fails under kcov"
elif grep -qF "COVERAGE RUN FAILED: $N:covso_traced:tests/covso_traced_driver.mojo [coverage]" "$LOG/coverage_shared_lib_run.log"; then
    pass coverage_shared_lib_run
else
    fail "coverage_shared_lib_run: failed without the coverage run's message (see $LOG/coverage_shared_lib_run.log)"
fi
expect_red coverage_gate_test_path "$N:testpath: coverage gate: the test lostlib/value.mojo has the path of a source of the library" "$N:testpath"
expect_red coverage_shared_lib_enforce "$N:covso_enforce: a mojo_shared_lib's coverage gate is reported, never enforced" "$N:covso_enforce"
