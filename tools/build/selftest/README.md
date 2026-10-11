# Build self-test scenarios

The checks of the build system that must drive buck2 from outside: where
targets execute, analysis-time and load-time refusals, unconfigured queries.
Each scenario is one `buck2 test` target, a Zig program built with the helper
library [`lib/`](lib/lib.zig). The design, and the inventory of the checks of
`tools/build/tests/run_tests.sh` these replace, is
[docs/design/build_selftests.md](../../../docs/design/build_selftests.md).

```sh
./buck2 test //tools/build/selftest:analysis_refusals_mojo   # one scenario
./buck2 test //tools/build/selftest/...                      # all of them
./buck2 bxl //tools/build/selftest/graph/checks.bxl:check -- --check //tools/build/selftest/graph:selftest_closure
```

## How a scenario runs

`selftest_scenario` ([defs.bzl](defs.bzl)) runs the scenario's binary on the
client, from the project root, given the pinned buck2 release
(`:buck2`, the `tools/buck2` asset unpacked by [`unzst.zig`](unzst.zig)).
Every inner command runs under `--isolation-dir selftest_<scenario>` (a
daemon of its own, stopped when the scenario ends) or in a scratch tree, and
with `-c komira_selftest.inner=true`. Before anything else the guard
([lib/guard.zig](lib/guard.zig)) refuses `--nested`, a client that is not
Linux x86_64, a buck2 that is not the release `tools/buck2` pins, and an
inner daemon with an execution platform that is not remote: every inner
build runs on the farm. A scenario passes only when it asserted something and
nothing failed. Its logs, one file per inner command, and its scratch trees
are under `buck-out/selftest_tmp/<scenario>`.

The recursion guard: under `-c komira_selftest.inner=true` every scenario is
incompatible (`:inner` selects `:never` into its `target_compatible_with`),
so an inner `//...` skips the scenarios; and a scenario that lost that is
given `--nested`, which the guard refuses.

## Scenarios

| scenario | what it checks | a planted defect it catches |
|---|---|---|
| [`exec_platforms`](exec_platforms.zig) | Mojo, toolchain, third_party_srcs and C/C++ targets resolve to `linux-x86_64`; the host platform's own `[komira_re]` key decides remote execution; under the inner key `hello` keeps the pinned configuration hash | a second platform registered first; any key selecting remote |
| [`uquery_select_branches`](uquery_select_branches.zig) | `uquery deps(cshim:cadd_user)` reaches `toolchains//:cxx_no_default_deps` | the alias deleted |
| [`analysis_refusals_platform_table`](analysis_refusals_platform_table.zig) | the table's load-time cases hold; the platforms declared; `host`; the reserved row's key refused | a pending pin accepted in a registered row |
| [`analysis_refusals_mojo`](analysis_refusals_mojo.zig) | the gate bypass, empty `exports`, test_data, env, test_deps, assert level, defines and memory cap refusals, a dep of the wrong kind | each `fail()` deleted, `[ungated]` returning MojoInfo |
| [`analysis_refusals_aws_client`](analysis_refusals_aws_client.zig) | mojo_aws_client's 11 analysis refusals | the duplicate-operation check deleted |
| [`analysis_refusals_gcp_client`](analysis_refusals_gcp_client.zig) | mojo_gcp_client's 10 analysis refusals | the roots-or-methods check deleted |
| [`analysis_refusals_proto`](analysis_refusals_proto.zig) | a `bundle_only` entry outside the closure | the membership check deleted |
| [`analysis_refusals_readme`](analysis_refusals_readme.zig) | no `[readme]` on a base library; the `readme` keyword's load refusals | the bool check removed |
| [`analysis_refusals_lint`](analysis_refusals_lint.zig) | the five files-xor refusals of the lints; in a scratch tree, a matrix row naming a missing target or an incompatible test | one xor `fail()` deleted; the matrix's deps made soft |
| [`analysis_refusals_python_oracle`](analysis_refusals_python_oracle.zig) | inputs built outside third_party/ | the owner check dropped |
| [`analysis_refusals_node`](analysis_refusals_node.zig) | the Node.js rules' 8 analysis refusals | the staged-twice check deleted |
| [`analysis_refusals_rust`](analysis_refusals_rust.zig) | rust_library's test_srcs refusals | the `.rs` check deleted |
| [`analysis_refusals_coverage`](analysis_refusals_coverage.zig) | the coverage rules' analysis refusals | the buck-out, no-args and LLVM_PROFILE_FILE checks deleted |
| [`config_refusals`](config_refusals.zig) | `komira.coverage`, `komira.mutation`, `komira.test_timeout_s` values refused at load | any value but true read as false; the margin's `<=` made `<` |
| [`rerun`](rerun.zig) | `-c komira.rerun` naming one target re-runs only its test actions, on the farm; naming one target of each of the 17 rules that run tests re-runs an action of each; the `buck2 test` commands of a mojo_test and a rust_test carry it; its value and label refusals | `rerun_env` ignoring the label (every target salted); a rule not calling it |

A refusal row passes only when `buck2 audit providers <target>` (analysis,
nothing built) fails and its output holds the row's message exactly, as the
rule's `fail()` writes it; a message buck2 interrupts with a configuration
hash is given as its pieces, each required.

## Graph checks

[`graph/`](graph/BUCK): each `graph_check` names a check and the targets it
queries, as strings. [`graph/checks.bxl`](graph/checks.bxl) collects the
check's facts and runs its checker, [`graph/graph_checks.zig`](graph/graph_checks.zig),
over them as a build action; `release/ci/build_targets.sh` runs it for every
graph_check of a batch. `selftest_closure` fails when the closure of this
package holds a library under `src/` (a scenario names what it builds as a
string), so a change to a library does not reach `build_selftests`.

## In the pull-request check

The package is the declared check `build_selftests`
(`release/artifacts.textproto`): a change to `tools/build/**` widens the check
to every unit, this one included. On a 28-core client the 14 scenarios ran in
3.5 s of wall time, all 14 at once, each with its own inner daemon (3.0 GiB
of resident memory together at the peak). How many run at once on a runner is
its local test concurrency.

Those 14 query the graph; `rerun`, added since, builds: 18 targets three
times, re-running 19 test actions on the farm. Its inner daemon's own
`--isolation-dir` changes the output paths in every command line, so its
first run after a change to those targets' closure executes their actions
anew (31 of 160 in the run its pull request recorded, 4 min 05 s); a run
with nothing changed is cache hits and the 19 test actions.
