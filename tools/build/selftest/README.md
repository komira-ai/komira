# Build self-test scenarios

The checks of the build system that must drive buck2 from outside: where
targets execute, analysis-time and load-time refusals, builds that must go
red, unconfigured queries.
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
| [`analysis_refusals_mojo`](analysis_refusals_mojo.zig) | the gate bypass, empty `exports`, test_data, env, test_deps, assert level, defines and memory cap refusals, a dep of the wrong kind, an optimization level `mojo build` does not accept | each `fail()` deleted, `[ungated]` returning MojoInfo |
| [`analysis_refusals_aws_client`](analysis_refusals_aws_client.zig) | mojo_aws_client's 11 analysis refusals | the duplicate-operation check deleted |
| [`analysis_refusals_gcp_client`](analysis_refusals_gcp_client.zig) | mojo_gcp_client's 10 analysis refusals | the roots-or-methods check deleted |
| [`analysis_refusals_proto`](analysis_refusals_proto.zig) | a `bundle_only` entry outside the closure | the membership check deleted |
| [`analysis_refusals_readme`](analysis_refusals_readme.zig) | no `[readme]` on a base library; the `readme` keyword's load refusals | the bool check removed |
| [`analysis_refusals_lint`](analysis_refusals_lint.zig) | the five files-xor refusals of the lints; a retired_names `unchecked` entry naming no file; in a scratch tree, a matrix row naming a missing target or an incompatible test | one xor `fail()` deleted; the `unchecked` membership `fail()` deleted; the matrix's deps made soft |
| [`analysis_refusals_python_oracle`](analysis_refusals_python_oracle.zig) | inputs built outside third_party/ | the owner check dropped |
| [`analysis_refusals_node`](analysis_refusals_node.zig) | the Node.js rules' 8 analysis refusals | the staged-twice check deleted |
| [`planted_red_builds_node`](planted_red_builds_node.zig) | the Node.js rules' 36 planted defects that fail in an action: node_test's verdict, esbuild, npm_package's and node_dist's pins, c_shared_lib's `-Werror` | expect_error matched case-insensitively; `-Werror` dropped |
| [`planted_red_builds_npm_modules`](planted_red_builds_npm_modules.zig) | the node_modules rules' 13 planted defects: a lockfile package not pinned, a pinned lock or tarball that disagrees with the integrity, a changed package.json, a missing program, a failing cdk synth, a type error, a failing and an empty jest run | the tarball sha512 check dropped; `--ci` and the no-test failure dropped |
| [`analysis_refusals_zig_rules`](analysis_refusals_zig_rules.zig) | the Zig rules' module-closure name clash, unknown `optimize` and bad `target`, and zig_test's bad or runner-owned `exec_tools` names and file-and-directory `data`, each with its message | the name-clash `fail()` deleted |
| [`planted_red_builds_zig_rules`](planted_red_builds_zig_rules.zig) | a module importing a module it does not declare, an importer reaching a dep's dep, and the red twins of `optimize`, `strip` and `target` | the root module given the whole closure; `optimize` or `strip` ignored |
| [`analysis_refusals_rust`](analysis_refusals_rust.zig) | rust_library's test_srcs refusals | the `.rs` check deleted |
| [`analysis_refusals_coverage`](analysis_refusals_coverage.zig) | the coverage rules' analysis refusals | the import-name, no-args and LLVM_PROFILE_FILE checks deleted |
| [`config_refusals`](config_refusals.zig) | `komira.coverage`, `komira.mutation`, `komira.test_timeout_s` values refused at load | any value but true read as false; the margin's `<=` made `<` |
| [`rerun`](rerun.zig) | `-c komira.rerun` naming one target re-runs only its test actions, on the farm; naming one target of each of the 20 rules that run tests re-runs an action of each; the `buck2 test` commands of a mojo_test and a rust_test carry it; its value and label refusals | `rerun_env` ignoring the label (every target salted); a rule not calling it |
| [`graph_check_refusals`](graph_check_refusals.zig) | python_closure over planted graphs (`tests//negative/python_closure`): a Python rule reached only through an exec dependency, and a stale ceiling entry, refused; the same graph with its findings in the ceiling passes | the closure narrowed to target dependencies; the ceiling read as a cap |
| [`sql_oracle`](sql_oracle.zig) | `tests//functional/sql_oracle:check` builds; `buck2 aquery` of `write` shows the fixed invocation in order (`SET threads = 1; SET TimeZone = 'UTC'`, the version and environment checks from SELECT to END, the version exactly as `buck2 uquery` reads it (digits and dots), the lib path exactly the output of `komira//third_party/duckdb:native_libs`, `.safe_mode` before the first src); each of sql_oracle's and duckdb_dist's analysis refusals with its message, bad list entries past the first (both input path loops); the planted defects of `tests//negative/sql_oracle` each fail in their `sql_oracle` action with DuckDB's or the rule's message (undeclared output, a missing first, middle or last output, SQL error, a file outside `inputs`, an absolute path, a glob pattern, a changed setting, each refused dot command), and 2 planted cases of komira_test_oracle's oracle discipline, each failing with its message, each a fresh farm execution | `.safe_mode` dropped; the output existence check dropped or narrowed to the first or last output; `SET TimeZone` dropped; the version or environment check unable to fire (a condition added in the text between pinned pieces included, or in the dist's `version` attribute); duckdb_dist's version pattern admitting a quote, `v` or `V` (widened to `a-z` or `A-Z`, or any range holding `v` or `V`; a letter range without them, such as `a-f`, admits no quote and is not pinned), a space, a semicolon, `/` or `:`, a newline (the `(?m)` flag), or empty, or narrowed to refuse 0 or 9 (`dist_version_digit_bounds` must build); the lib path wired to another directory; `TZ`, `LC_ALL` or `LD_LIBRARY_PATH` dropped from the environment; any analysis `fail()` of the rule deleted, or an arm of its condition no other arm covers; the oracle case runner no longer calling the discipline |

A refusal row passes only when `buck2 audit providers <target>` (analysis,
nothing built) fails and its output holds the row's message exactly, as the
rule's `fail()` writes it; a message buck2 interrupts with a configuration
hash is given as its pieces, each required. A planted-red row
([lib/reds.zig](lib/reds.zig)) passes only when `buck2 build <target>` fails,
its output holds the row's text, and `buck2 log what-ran` lists the actions
the build ran, all on the farm: a red that comes from analysis, not from an
action, belongs in a refusal table.

## Graph checks

[`graph/`](graph/BUCK): each `graph_check` names a check and the targets it
queries, as strings. [`graph/checks.bxl`](graph/checks.bxl) collects the
check's facts and runs its checker, [`graph/graph_checks.zig`](graph/graph_checks.zig),
over them as a build action; `release/ci/build_targets.sh` runs it for every
graph_check of a batch. `selftest_closure` fails when the closure of this
package holds a library under `src/` (a scenario names what it builds as a
string), so a change to a library does not reach `build_selftests`.
`python_closure` (declared in the root package, `//:python_closure`) fails on
Python outside the Python surface: a target whose closure, every kind of
dependency, holds a Python rule, a target under `third_party/python/` or
`tools/build/python/` or a `.py` source; a `.py` file; a kci textproto or a
workflow that runs Python. Its allowlist, `tests/python_closure_allowlist.bzl`,
only shrinks ([`graph/python_closure.zig`](graph/python_closure.zig)).

## In the pull-request check

The package is the declared check `build_selftests`
(`release/artifacts.textproto`): a change to `tools/build/**` widens the check
to every unit, this one included. On a 28-core client the 14 scenarios of that
measurement ran in 3.5 s of wall time, all 14 at once, each with its own inner daemon (3.0 GiB
of resident memory together at the peak). How many run at once on a runner is
its local test concurrency. `planted_red_builds_node` took
2 min 53 s on its first run and 1 min 46 s on a later one: a failed action is
never cached, so every run executes each row's failing action on the farm
again.

Those 14 query the graph; `rerun`, added since, builds: 21 targets three
times, re-running 24 test actions on the farm. Its inner daemon's own
`--isolation-dir` changes the output paths in every command line, so its
first run after a change to those targets' closure executes their actions
anew; a run with nothing changed is cache hits and the 26 test actions
(5 min 36 s in the run that added the tests cell's case rules).
