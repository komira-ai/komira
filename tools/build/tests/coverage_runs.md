# Tests 41, 43 and 44: coverage builds, runs and the gate

The checks of [test 41](README.md#41-coverage-builds),
[test 43](README.md#43-coverage-runs) and
[test 44](README.md#44-coverage-gate) of the [tests README](README.md).

## Test 41: coverage builds

[Coverage builds](../mojo/README.md#coverage-builds) (`-c komira.coverage=true`)
add one -O0 binary with line tables per `test_srcs` entry and must leave
every release action as it is, but the package's join, which also waits for
the coverage runs and the gate (test 44). [`coverage_tests.sh`](coverage_tests.sh)
runs these checks:

| check | what it proves | the defect planted to see it go red |
|---|---|---|
| [`coverage_keys.sh`](functional/coverage_keys.sh) | over [`covlib`, `covuser`](functional/coverage/BUCK) (which depends on covlib) and `//src/komira_retry`, read from `buck2 aquery` and `cquery` (analysis only) with the switch off and on: each target keeps its execution platform, and every release action keeps its command line, the actions that make its inputs and its execution attributes (executor preference and configuration, cache upload, weight, dep files), except the join (`mojo_gate_join`), whose inputs with it on are those with it off plus coverage actions, at least one, and no other (a README's join: its command line only, since aquery cannot traverse the README's dynamic actions); with it off there is no coverage action; with it on every new action is one (`mojo_build_cov_test`, `mojo_cov_run`, `mojo_cov_gate`, or an output under `cov/`), one build and one run per test and one gate per library; with it unset (`-c komira.coverage=`, which clears a global value) every fact is the one of `=false`; on `darwin-arm64` with it on no target has the `coverage_debug`, `coverage_run` or `coverage_gate` attribute (cquery). A README's build and run, which aquery cannot see, are compared by building `//src/komira_retry` and `covuser` with the switch off, then on, in one daemon: every action of them the second build runs (`buck2 log what-ran`) must have run in the first under the same digest (cache hits only), but the coverage actions and the joins, and each one's join must run again. covuser's compile and test not running again shows that covlib's package has the same bytes with the switch on. Not seen: an action's environment (aquery prints none; a planted `env` passes), a hidden source-file input, and, in a daemon that already built a target with the switch on, an action it does not recompute (what-ran lists what a build runs) | the release test build given the debug link directory when coverage is on (command lines differ); the coverage binaries added to the gate join's inputs (inputs differ); `prefer_local` on the release test build when coverage is on (execution attributes differ; the test before them passed it); the switch's default `true` (unset differs from `=false`); the platform `select` giving every platform the link directory (the darwin cquery fails); the README's build at -O0 when coverage is on (its build and run run again under new digests); the join not waiting for the coverage actions (`the join of tests//functional/coverage:covuser did not run again`) |
| [`:aggregates`, `:aggregates_tests`, `:aggregates_all`](functional/coverage/BUCK) | `covlib_forced[coverage][bin]` has exactly the binaries `[coverage][bin][<test>]` of its two tests as default outputs, `[coverage][tests]` exactly their reports (test 43) and `[coverage]` both (checked at analysis) | the list missing its first binary |
| [`:hermetic`](functional/coverage/BUCK) | each binary of `covlib_forced[coverage][bin]` has a `.debug_line` section and the string `value.mojo`, the library source both tests call, which only the compile's line tables put there (zig's C runtime has line tables of its own, and without `--debug-level` an -O0 binary still names the test's own file, its compile unit, but no library file), names its sources by relative directories, as the pinned Mojo writes them (whole strings `tests` and `buck-out/.../__covlib_forced__/<hash>/src/covlib`; Mojo records no compilation directory), holds a placeholder `/___...` (the compilation directory of zig's C runtime units, the only ones that record one, relocated), holds no placeholder followed by `/` and no whole string that is an absolute path other than the placeholder and the ELF interpreter (whatever the executor's directory layout), and has no compressed section (debug_relocate, which refuses one, runs over a copy) | the coverage compile without `--debug-level line-tables` (the binary still has `.debug_line` and its own file name, but not `value.mojo`); planted strings, `tests//negative/coverage:abs_relocated` (a relocated absolute Mojo path), `:abs_other` (an absolute path of another build directory) and `:no_reldir` (no `tests` directory), each fail with its message |
| [`tests//negative/coverage:noop[coverage]`](negative/coverage/BUCK) | must fail with `contains this action's working directory`: a relocator that rewrites nothing and claims it did (`noop_relocate.zig`) gets past `cov_zig`, and mojo_wrapper.sh's exit 4 stops it, so the wrapper's check stays on for coverage builds | it is the planted defect |
| [`:reproducible`](functional/coverage/BUCK) | `repro_a` and `repro_b` build one test (it imports only their common dependency) in two actions with different keys, so two sandboxes: the binaries have one sha256. No `--no-remote-cache` | `-Wl,--build-id=uuid` in cov_zig (the binaries differ) |
| `-c komira.coverage=yes` | fails at load, naming the value | |

The library fixtures in the tests cell may name their link directory (`coverage_debug`, and the run directory
`coverage_run`), which gives them coverage binaries and runs whatever the switch says; that is how
`:hermetic`, `:reproducible`, test 43 and the negative builds build without `-c`.

```sh
tools/build/tests/functional/coverage_keys.sh
./buck2 build tests//functional/coverage/...
./buck2 build 'tests//negative/coverage:noop[coverage]'   # must fail: contains this action's working directory
./buck2 build tests//negative/coverage:abs_relocated   # must fail: holds an absolute path under the working directory
./buck2 build tests//negative/coverage:abs_other       # must fail: holds an absolute path (/var/build/...
./buck2 build tests//negative/coverage:no_reldir       # must fail: no relative directory matching 'tests'
./buck2 build tests//functional/coverage:covlib -c komira.coverage=yes   # must fail at load
```

## Test 43: coverage runs

With coverage on, each test's coverage binary also runs under kcov through the release gate's runner ([cov_run](../coverage/kcov/README.md#cov_run)), giving `[coverage][tests][<test>]`, its Cobertura report in repository paths. [`coverage_run_tests.sh`](coverage_run_tests.sh) runs these checks (the release actions with the switch on are test 41's `coverage_keys.sh`, which counts one `mojo_cov_run` per test):

| check | what it proves | the defect planted to see it go red |
|---|---|---|
| [`:numbers`](functional/coverage/BUCK) | each report of `covlib_forced` is its golden file in `functional/coverage/golden/` byte for byte: a library in the tests cell with its sources in `covlib/` mapped to `tools/build/tests/functional/coverage/covlib/value.mojo`, a covered function, an arm no test takes (lines 12 and 13 at 0), a `# cov: unreachable` line at 0; and `covgen`'s report (`golden/test_gen.xml`): its test calls a function of `covgen/plain.mojo` and one of `covgen/gen.mojo`, generated from `gen.mojo.in`, and the report has the first and not the second | the map of `[src]` without the package root `covlib/` (the paths differ); kcov without `cobertura-full-paths=1` (bare names, refused as unmapped); no `--gen` for a generated source (gen.mojo in covgen's report) |
| [`:census`](functional/coverage/BUCK) | `covcheck gate --mode census` reads those reports over the package's sources and its result holds value.mojo's numbers: 7 of 9 lines hit, line 14 exempt, the two tests set aside, conclusion neutral | the same map without `covlib/` (covcheck exits 1: unmapped) |
| [`covenv`, `covenv[coverage]`](functional/coverage/BUCK) | a test checking the gate's contract from inside (its `test_env` variable, its data file reached from the working directory, PATH, HOME and TMPDIR as `bin/`, `home/` and `tmp/` of one run directory, LD_LIBRARY_PATH, no LD_PRELOAD, and a CPU affinity no narrower than its parent's and grandparent's) passes in the release gate and under kcov; a second data file sits at `oss/modular/mojo/stdlib/std/testing/testing.mojo`, the name the binary's line tables give a standard library source, which kcov could open from the working directory, so the run is green only while `--include-path` keeps it out of the report | the run without the test's `--env` (COVENV missing); kcov run outside `gate_runner.sh` (HOME is not the runner's); kcov v42 as released, which pins the test to one CPU (red: `the test may run on CPUs 22, its ancestor ... on 22-43,66-87`); kcov given `TMPDIR=/tmp` (`TMPDIR beside PATH's bin/`); no `--skip-solibs` (kcov preloads its `libkcov_sowrapper.so`: `LD_PRELOAD is unset`); no `--include-path`, or one of all of `share/` (the decoy is refused as unmapped) |
| [`tests//negative/coverage:tracer`](negative/coverage/BUCK) | builds (the release gate runs `test_tracer` untraced); its `[coverage][tests][test_tracer]` must fail with `test_tracer: traced, TracerPid`: kcov traced the test and passed its exit status on | cov_run.sh ignoring the runner's status (the run goes green) |
| [`tests//negative/coverage:orphan`, `orphan[coverage]`](negative/coverage/BUCK) | `test_orphan_late` passes, leaving a child that exits 3 half a second later: the release gate and the coverage run are green, the run's status is the test's | kcov v42 as released (it returns the status of the last traced process to exit: red, exit 3) |
| [`tests//negative/coverage:exits[coverage][tests][test_parent_fails]`](negative/coverage/BUCK), [`...[test_killed]`](negative/coverage/BUCK) | must fail with `The test failed under kcov (exit 1)` (the test fails, its child exits 0 later) and `(exit 137)` (SIGKILL, as a shell reports it); the release gate of `:exits` is red by design and nothing builds it. The first one's output (`coverage_run_banner`) holds neither `GATED TEST FAILED` nor `package is not produced`: gate_runner's banner is left out, since it would say the release gate's test failed | kcov v42 as released (`test_parent_fails` builds green; `test_killed` says exit 9); cov_run.sh printing gate_runner's output whole (the banner check is red) |
| [`tests//negative/coverage:linger[coverage][tests][test_lingers]`](negative/coverage/BUCK) | must fail with `The test left processes running or did not finish within 20 s under kcov`, about 20 s after the run starts: the test passes leaving a child that sleeps 100 s, kcov waits for it, and the run's limit (`linger_run`, a `cov_run_dir` with the tests cell's `limit_s = 20`; komira's is 450 s) kills the run's whole process group. `:linger` (its release gate, which waits for the test alone) and `linger[coverage][tests][test_brief]` (a test leaving nothing, under the same limit) build green, so the red is the child, not a limit too short for a run; its log must not hold `processes of the coverage run survived the kill`, which cov_run.sh prints when a process of the group (not a zombie) is still running 10 s after the limit's kill | cov_run.sh without the limit (the run builds green, after the child's 100 s); the kill sent to gate_runner alone, `kill -s KILL "$gate"` without the group's `-` (red with `processes of the coverage run survived the kill of its process group`, kcov and the sleeping child listed, not the limit's message) |
| [`tests//negative/coverage:lingerproc[coverage][tests][test_lingers]`](negative/coverage/BUCK) | must fail with `/proc is not readable as this run's own`, about 20 s after the run starts: a cov_run.sh copy (`cov_plant`) takes 1 for its own pid, so `/proc/1/stat` exists and starts with that pid, as `/proc/<pid>` of another PID namespace names another process with it; after the limit's kill cov_run.sh refuses that /proc before listing the group's processes from it, where it would list none and pass. The harness's `coverage_run_lingers_group` and `coverage_run_banner` checks fail when their log does not exist, rather than reading grep's exit 2 as no match | only `/proc/$$/stat` compared with the pid, without the `/proc/self/stat` the shell reads itself (the plant passes it, and the run fails with the limit's message instead) |
| [`tests//negative/coverage:refused[coverage][tests][test_one]`](negative/coverage/BUCK) | must fail with `kcov could not trace the test`: a stand-in kcov (`kcov_refused.zig`) prints kcov's `Can't set personality: Operation not permitted` and exits 255, as kcov does under a seccomp profile | cov_run.sh matching only the ptrace lines (it says the test failed) |
| [`tests//negative/coverage:lost[coverage][tests][test_lost]`](negative/coverage/BUCK) | must fail with cov_normalize's `lostlib/value.mojo': no --map or --exclude prefix covers it`: a cov_run.sh copy (`cov_plant`) stages the library's sources at the working directory's root, kcov cannot open them where the line tables name them, and their names fall through to the run's `lost/` copy instead of leaving the report silently | it is the planted defect; with `--replace-src-path='^/_+:<share>'` in place of the `lost/` fallback it builds green with no library file in the report |
| [`tests//negative/coverage:lostdir[coverage][tests][test_lost]`](negative/coverage/BUCK) | must fail with `this run stages them at buck-out/v2/art/tests/negative/coverage/__lostdir__/`: a cov_run.sh copy stages, includes and maps the sources at `[src]`'s path plus `x`, as if the rule passed another `[src]` than the binary was compiled from; cov_run.sh's check of the directories the binary names refuses it before kcov runs | it is the planted defect; without that check it builds green with no library file in the report (`lost/` sits at the same wrong directory) |
| [`tests//negative/coverage:clash`](negative/coverage/BUCK) | must fail at analysis with `collides with its source`: a test's data staged at the test's own path, where a coverage run stages its source | it is the planted defect |
| [`tests//negative/coverage:clash_buckout`](negative/coverage/BUCK) | must fail at analysis with `is under buck-out/, where a coverage run stages`: a test's data staged under `buck-out/`, where a coverage run stages the library's sources | it is the planted defect |

```sh
./buck2 build tests//functional/coverage:numbers tests//functional/coverage:census 'tests//functional/coverage:covenv[coverage]' tests//negative/coverage:tracer
./buck2 build 'tests//negative/coverage:tracer[coverage][tests][test_tracer]'   # must fail: test_tracer: traced, TracerPid
./buck2 build 'tests//negative/coverage:lost[coverage][tests][test_lost]'       # must fail: no --map or --exclude prefix covers it
./buck2 build 'tests//negative/coverage:lostdir[coverage][tests][test_lost]'    # must fail: this run stages them at ...
./buck2 build tests//negative/coverage:orphan 'tests//negative/coverage:orphan[coverage]'
./buck2 build 'tests//negative/coverage:exits[coverage][tests][test_parent_fails]'   # must fail: exit 1
./buck2 build 'tests//negative/coverage:exits[coverage][tests][test_killed]'         # must fail: exit 137
./buck2 build 'tests//negative/coverage:refused[coverage][tests][test_one]'     # must fail: kcov could not trace the test
./buck2 build tests//negative/coverage:linger 'tests//negative/coverage:linger[coverage][tests][test_brief]'
./buck2 build 'tests//negative/coverage:linger[coverage][tests][test_lingers]'  # must fail: did not finish within 20 s
```

## Test 44: the coverage gate

With coverage on, each library also has a gate, `covcheck gate` over its
tests' reports and its sources ([The build gate](../coverage/README.md#the-build-gate)),
and its package waits for the gate and every coverage run.
[`coverage_gate_tests.sh`](coverage_gate_tests.sh) runs these checks over the
fixtures of [`negative/coverage`](negative/coverage/BUCK), each a library
with coverage and a gate whatever the switch says (a tests-cell fixture may
name its gate and mode), in enforce mode and as a census twin:

| check | what it proves | the defect planted to see it go red |
|---|---|---|
| `tests//negative/coverage:covlow` | must fail with `COVERAGE GATE FAILED (enforce): tools/build/tests/negative/coverage (...:covlow [coverage gate]): covcheck gate exited 3` and the summary's `BelowTarget ... line 50.00%`: its test calls `word(0)` only, 3 of 6 lines run, and the package (its default output) is not built | cov_gate.sh mapping covcheck's exit 3 to 0 (covlow builds green) |
| `:covnotests` | must fail with `NotMeasured`: a library with no test (no join without coverage) gets a join and a gate, which has no report | the gate left out for a library with no coverage run (covnotests builds green) |
| `:covun` | must fail with `UnmeasuredFile ... covun/unused.mojo`: a source of the package that no test binary compiles counts its lines, uncovered | the repository's files given to covcheck from the files the reports name (red, but with no UnmeasuredFile: the check fails) |
| `:covfull` | must fail with `BranchNotMeasured` as its only finding (`### Findings (1)`): every line covered (1 of 1) and a ratchet row at 100% (`covfull_gate`, a `cov_gate_dir` with `covfull_ratchet.tsv`), but kcov gives no branch data, so branch coverage is not shown to meet the target | covcheck before `BranchNotMeasured` (covfull builds green, conclusion `success`); covcheck's `BranchNotMeasured` turned off (its welded `test_analyze` fails) |
| `:covlow_census_result`, `:covnotests_census_result`, `:covun_census_result`, `:covfull_census_result` | the census twins build green and their `[coverage][gate][result]` holds conclusion `neutral`, mode `census`, the package's numbers (`tools/build/tests/negative/coverage`: covlow 3/6, covnotests 0/2, covun 1/3 with one unmeasured file, covfull 1/1) and the finding | each expected string |
| `:covtop_census_result` | a library whose welded tests are outside its package's `tests/` (`elsewhere/tests/test_top.mojo`, as `komira_db_postgres`'s `wire/tests/`; `test_covtop.mojo` at the package's top, as a cloud SDK client's) analyzes with coverage on, and its gate names both to covcheck (`--test-source`): its numbers are covtop's own (1 file, 1/1 lines) and `excluded_test_files` is 2 | the rule before `--test-source` (analysis fails: "is not under the package's tests/"); the rule passing no `--test-source` (3 files, 7 lines: the tests measured as covtop's source) |
| `:covbad` | must fail with `COVERAGE GATE ERROR: ... (...:covbad [coverage gate]): covcheck exited 1`: a census gate whose ratchet (`covbad_gate`, `covbad_ratchet.tsv`) holds a floor that is not a number; census never fails on a finding, but does on an input covcheck refuses | cov_gate.sh writing the marker for exits other than 0 and 3 outside enforce mode (covbad builds green) |
| a coverage-on analysis of `//tools/build/proto-codegen/aws_query:komira_aws_tiny_query` (aquery) | a generated client, whose tests are at its package's top, analyzes with the switch on and has its gate action | the rule before `--test-source` (analysis fails) |
| `:tracer_joined` | green without the switch; with `-c komira.coverage=true` it must fail with `COVERAGE RUN FAILED: ...:tracer_joined:tests/test_tracer.mojo [coverage]`: a library with no coverage attribute of its own, whose test fails only traced, has a package that waits for its coverage run | the join without any coverage marker, the runs' and the gate's (it builds green with the switch); the join without the runs' markers alone stays red here, since the gate reads the reports a failing run never writes: `coverage_keys.sh` (test 41) and `coverage_ledger_waits` see that one |
| [`no_gate.bxl`](../coverage/no_gate.bxl) (`-c komira.coverage=true`) | the ledger `COVERAGE_NO_GATE` of [`policy.bzl`](../coverage/policy.bzl) is within the frozen list `_CEILING` (it only shrinks) and names exactly the Mojo libraries `komira//tools/build/coverage:cov_gate` depends on (`komira_json`, `covcheck`, `readme_examples`), none of them has a gate of its own, and each one's conda package depends on its `<name>_cov_gate` | a row deleted (`Configured target cycle detected`); a row for a library outside that closure (`rows naming no library of that closure`); a ledger row missing from `_CEILING`, as when a row is added (`only shrinks`) |
| `coverage_ledger_waits` (aquery, `-c komira.coverage=true`) | the ledger's waits as actions, which `no_gate.bxl` (target dependencies only) does not see: the join of `//tools/build/readme_examples:readme_examples` (the ledger's library with no README, so aquery can read its join's inputs) waits for each of its coverage runs (one per `mojo_build_cov_test`, 3) and for no gate, and both joins of `readme_examples_conda` (`conda_join`, `conda_release_join`) wait for its `readme_examples_cov_gate` | the join of a library with no gate waiting for no coverage run (`0 0 1 1`); `conda_join` without the gate's marker (`3 0 0 1`) |

The join's inputs are the one release difference the switch makes: test 41's
`coverage_keys.sh`, which also requires the join's new inputs to be exactly
one coverage run per test and the gate (a join without the runs' markers, or
without the gate's, fails it), and `tests//functional/coverage:covbare`, a
library with no test and no README, to have no join with the switch off and,
with it on, a join waiting for its gate alone (a join for every library with
no test, whatever the switch, fails it).

Outside the tests cell no fixture may set a coverage attribute, so the
refusals are test 7's: `tests/functional/umbrella_cache.sh` plants, in a
consumer repository's own cell, a `mojo_library` passing them (refused at
load, even with the policy's mode and komira's directories) and four calls
of `mojo_library_rule` itself (refused in analysis: another mode, another
gate directory, runs with no gate, the ledger's join for a library not in
it). Planted: each refusal removed in turn (the consumer's target is
accepted).

```sh
./buck2 build tests//negative/coverage:covlow_census_result tests//negative/coverage:covnotests_census_result \
    tests//negative/coverage:covun_census_result tests//negative/coverage:covfull_census_result tests//negative/coverage:tracer_joined
./buck2 build tests//negative/coverage:covlow        # must fail: COVERAGE GATE FAILED (enforce), BelowTarget
./buck2 build tests//negative/coverage:covnotests    # must fail: NotMeasured
./buck2 build tests//negative/coverage:covun         # must fail: UnmeasuredFile ... covun/unused.mojo
./buck2 build tests//negative/coverage:covfull       # must fail: BranchNotMeasured, its only finding
./buck2 build tests//negative/coverage:covtop_census_result
./buck2 build tests//negative/coverage:covbad        # must fail: COVERAGE GATE ERROR, covcheck exited 1
./buck2 build tests//negative/coverage:tracer_joined -c komira.coverage=true   # must fail: COVERAGE RUN FAILED
./buck2 bxl //tools/build/coverage/no_gate.bxl:check -c komira.coverage=true
```
