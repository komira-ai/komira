# shellcheck shell=bash
# coverage_gate_tests.sh -- tests of the coverage gate and the join
# (tools/build/coverage/README.md#the-build-gate). Sourced by
# tools/build/tests/coverage_run_tests.sh (uses run_tests.sh's BUCK2, LOG,
# pass, fail, expect_green and expect_red); not run on its own.
#
#  45. The coverage gate: with coverage, a library's package waits for its
#      tests' coverage runs and for `covcheck gate` over their reports.
#      tests//negative/coverage (tools/build/coverage/README.md, "The build
#      gate"; tools/build/tests/coverage_runs.md, test 45):
#      covlow, covnotests, covun and covfull in enforce mode are red, each
#      naming its finding: BelowTarget (a test covering 3 of 6 lines),
#      NotMeasured (a library with no test still has a join and a gate),
#      UnmeasuredFile (a source no test compiles), BranchNotMeasured alone
#      (every line covered and a ratchet row, but kcov measures no branch);
#      their census twins are green and their result.json says so
#      (:<name>_census_result); covtop_census_result: a library whose welded
#      tests are outside its package's tests/ analyzes with coverage, and
#      its gate leaves both tests out of its numbers (--test-source); covbad:
#      a census gate over a malformed ratchet is red (covcheck exit 1 fails
#      the gate in every mode); a generated client (komira_aws_tiny_query,
#      tests at its package's top) analyzes with coverage and has its gate;
#      tracer_joined (a test that fails only
#      traced) is green without the switch and red with
#      -c komira.coverage=true (the package waits for the coverage run);
#      no_gate.bxl holds the ledger COVERAGE_NO_GATE equal to the Mojo
#      libraries the gate's tool depends on, and each one's conda package
#      depends on its `<name>_cov_gate`; as actions (aquery), readme_examples's
#      join waits for each of its coverage runs and no gate, and both joins
#      of its conda package wait for its gate. The join's inputs are the one
#      release difference the switch makes: coverage_keys.sh (test 41). The
#      refusals of the coverage attributes outside the tests cell are test 7's
#      (umbrella_cache.sh, in a consumer's cell).

N=tests//negative/coverage
P=tools/build/tests/negative/coverage
expect_green coverage_gate_census "$N:covlow_census_result" "$N:covnotests_census_result" \
    "$N:covun_census_result" "$N:covfull_census_result" "$N:covtop_census_result"
expect_red coverage_gate_census_malformed "COVERAGE GATE ERROR: $P ($N:covbad [coverage gate]): covcheck exited 1" "$N:covbad"
expect_red coverage_gate_enforce "COVERAGE GATE FAILED (enforce): $P ($N:covlow [coverage gate]): covcheck gate exited 3" "$N:covlow"
expect_red coverage_gate_notests "- **NotMeasured** \`$P\`: no line of this package was measured" "$N:covnotests"
expect_red coverage_gate_unmeasured "- **UnmeasuredFile** \`$P\` \`$P/covun/unused.mojo\`: no test binary compiled this file" "$N:covun"
expect_red coverage_gate_branch "- **BranchNotMeasured** \`$P\`: no branch of this package was measured" "$N:covfull"
# Each red is its own finding: covlow's is BelowTarget, and covfull's only
# finding is BranchNotMeasured (line 100%, a ratchet row).
for want in "coverage_gate_enforce|- **BelowTarget** \`$P\`: line 50.00% is below the target 100.00%" \
    "coverage_gate_branch|### Findings (1)"; do
    if grep -qF -- "${want#*|}" "$LOG/${want%%|*}.log"; then
        pass "${want%%|*}_finding"
    else
        fail "${want%%|*}_finding: the log does not hold '${want#*|}' (see $LOG/${want%%|*}.log)"
    fi
done
# A generated client whose welded tests are at its package's top analyzes
# with the switch on, and has its gate (analysis only: aquery).
CG=//tools/build/proto-codegen/aws_query:komira_aws_tiny_query
if "$BUCK2" aquery "attrfilter(category, mojo_cov_gate, all_actions($CG))" -c komira.coverage=true > "$LOG/coverage_gate_codegen.log" 2> "$LOG/coverage_gate_codegen.err" &&
    [ "$(grep -c "^(target: \`komira${CG} (" "$LOG/coverage_gate_codegen.log")" = 1 ]; then
    pass coverage_gate_codegen
else
    fail "coverage_gate_codegen: $CG has no coverage gate with -c komira.coverage=true, or does not analyze (see $LOG/coverage_gate_codegen.log and .err)"
fi
expect_green coverage_join_off "$N:tracer_joined"
if "$BUCK2" build "$N:tracer_joined" -c komira.coverage=true > "$LOG/coverage_join_on.log" 2>&1; then
    fail "coverage_join_on: $N:tracer_joined built with -c komira.coverage=true, but its package must wait for its coverage run, which fails"
elif grep -qF "COVERAGE RUN FAILED: $N:tracer_joined:tests/test_tracer.mojo [coverage]" "$LOG/coverage_join_on.log"; then
    pass coverage_join_on
else
    fail "coverage_join_on: failed without the coverage run's message (see $LOG/coverage_join_on.log)"
fi
if "$BUCK2" bxl //tools/build/coverage/no_gate.bxl:check -c komira.coverage=true > "$LOG/coverage_no_gate.log" 2>&1; then
    pass "coverage_no_gate: $(grep -o 'the [0-9]* libraries of the ledger.*' "$LOG/coverage_no_gate.log" | cut -c 1-160)"
else
    fail "coverage_no_gate: $(grep -E 'no_gate: |cycle' "$LOG/coverage_no_gate.log" | head -n 1 | cut -c 1-400) (see $LOG/coverage_no_gate.log)"
fi
# The ledger's waits, as actions (no_gate.bxl reads only the targets' deps):
# readme_examples (the ledger's library with no README, whose join's inputs
# aquery can read) has a package that waits for each of its coverage runs
# and for no gate, and a conda package whose two joins each wait for its
# `<name>_cov_gate`. Analysis only.
LE=//tools/build/readme_examples:readme_examples
cov_cats() { # aquery expression, log name -> the category of each action it prints
    "$BUCK2" aquery "$1" -c komira.coverage=true -a '^category$' --json > "$LOG/$2.json" 2> "$LOG/$2.err" &&
        inspect_tool json "$LOG/$2.json" > "$LOG/$2.tsv" &&
        awk -F '\t' '$2 == "category" { print $3 }' "$LOG/$2.tsv"
}
if all=$(cov_cats "all_actions($LE)" coverage_ledger_all) &&
    join=$(cov_cats "deps(attrfilter(category, mojo_gate_join, all_actions($LE)), 1)" coverage_ledger_join) &&
    cj=$(cov_cats "deps(attrfilter(category, conda_join, all_actions(${LE}_conda)), 1)" coverage_ledger_conda) &&
    cr=$(cov_cats "deps(attrfilter(category, conda_release_join, all_actions(${LE}_conda)), 1)" coverage_ledger_release); then
    nb=$(grep -cx mojo_build_cov_test <<< "$all")
    got="$(grep -cx mojo_cov_run <<< "$join") $(grep -cx mojo_cov_gate <<< "$join") $(grep -cx mojo_cov_gate <<< "$cj") $(grep -cx mojo_cov_gate <<< "$cr")"
    if [ "$nb" -gt 0 ] && [ "$got" = "$nb 0 1 1" ]; then
        pass "coverage_ledger_waits: $LE's join waits for its $nb coverage runs and no gate; both joins of ${LE}_conda wait for its gate"
    else
        fail "coverage_ledger_waits: $LE has $nb coverage binaries; its join waits for (runs, gates), then its conda_join and conda_release_join for gates: $got, want $nb 0 1 1 (see $LOG/coverage_ledger_*.tsv)"
    fi
else
    fail "coverage_ledger_waits: an aquery of $LE with -c komira.coverage=true failed (see $LOG/coverage_ledger_*.err)"
fi
