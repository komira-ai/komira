# Re-running one target's tests: `-c komira.rerun`

A build welds each package's tests into its targets, and a cached result is
a pass on identical inputs. To run one target's tests again, fresh, without
`--no-remote-cache` (which re-runs every action of the build), name it:

```sh
./buck2 build komira//src/foo:foo -c komira.rerun='komira//src/foo:foo#1'
```

Every test action of `komira//src/foo:foo` gets one more environment
variable, `KOMIRA_RERUN=1`. The environment is part of an action's key, so
those actions miss the cache and execute; every other action of the build,
of that target and of every other, keeps its key and stays a cache hit. A
new number runs them again; a number used before is a cache hit of that run.
The bisect tool sets the flag; a person may by hand. Nothing else does.

## The value

A comma-separated list of `<cell>//<package>:<name>#<n>`:

- the target's label with its cell (`komira//`, `tests//`, or the consuming
  repository's own cell), with no configuration and no sub-target. It names
  the target in every configuration;
- `<n>`, a whole number from 1.

The rules parse it in analysis, in every target that reads it, so a value of
another form fails the build, naming the entry and the reason: no `#<n>`, a
number that is not one (`#x`), a label without a cell, a sub-target or a
configuration, a label named twice.

One target's analysis cannot tell that a label names nothing, and a build of
other targets then re-runs nothing. [`check.bxl`](check.bxl) checks the
labels themselves: it fails unless each names an existing target whose rule
takes the variable.

```sh
./buck2 bxl //tools/build/rerun/check.bxl:check -c komira.rerun='komira//src/foo:foo#1'
```

## The rules that take it

[`rerun.bzl`](rerun.bzl) holds the helper: a rule declares `RERUN_ATTRS`
(a hidden attribute holding the value), passes `env = rerun_env(ctx)` to each
action that runs a test, and returns `rerun_info(ctx)` (the provider
`check.bxl` looks for).

| rule | its test actions (category) |
|---|---|
| `mojo_library` | each `test_srcs` test and the README's examples (`mojo_gated_test`) |
| `mojo_test` | the `buck2 test` command (`ExternalRunnerTestInfo.env`) |
| `mojo_shared_lib` | each gate driver, the exports check included (`mojo_shared_lib_gate`) |
| `mojo_binary` | the run check (`mojo_run_check`) |
| `rust_test` | its harness (`rust_gated_test`) and its `buck2 test` command |
| `rust_library` | each `test_srcs` crate (`rust_gated_test`) |
| `rust_binary` | the run check (`rust_run_check`) |
| `zig_test` | `zig test` (`zig_test`) |
| `script_test` | the command (`script_test`) |
| `node_test` | the script (`node_test`) |
| `py_test` | the script (`py_test`) |
| `launcher_level_test` | the level test (`launcher_level_test`) |
| `release_order_test` | the order check over its fixtures (`release_order_test`) |
| `release_readme_test` | the README check over its fixtures (`release_readme_test`) |
| `kcov_guard_cases` | the guard's cases (`kcov_guard_cases`) |
| `coverage_ci_cases` | the coverage workflow scripts' cases (`coverage_ci_cases`) |
| `proto_fixture_case` | the fixture check over its case (`proto_fixture_case`) |
| `proto_check_case` | the closure check over its case (`proto_check_case`) |
| `install_gate_cases` (tests cell) | install_gate.sh's cases (`install_gate_cases`) |
| `mojo_test_command_case` (tests cell) | a mojo_test's `buck2 test` command, run (`mojo_test_command_case`) |
| `mojo_watchdog_cases` (tests cell) | the compile watchdog's cases (`mojo_watchdog_cases`) |
| `git_check` | git_check.sh over the built git and git-lfs (`git_check`) |

Not wired:

- Lints (`src_layout`, `public_boundary`, `pointer_lint`, `retired_names`,
  `docs`, `no_endpoint` and the rest) and checks over
  built artifacts (`proto_check`, `proto_fixture_check`, `oci_image_check`,
  the conda checks, `prefixed_archive_check`). Each checks outputs the build
  already made, deterministically: the same inputs give the same verdict, so
  running it again measures nothing.
- `gcp_client_tests_check` (tests cell): it reads a library's pass markers.
  The tests that wrote them are the library's `test_srcs`; naming the library
  re-runs them.
- The coverage and mutation builds' runs of a library's tests
  (`mojo_cov_run`, `mojo_cov_branch_run`, `mutation_run_test`): measurements
  under `-c komira.coverage` and `-c komira.mutation`, not the tests the
  build welds.

## The guard

The self-test scenario [`rerun`](../selftest/rerun.zig) builds one target of
each rule above, then the same build with the flag naming the first, then
with it naming all of them, and reads `buck2 log what-ran`: only the named
targets' test actions may run, each on the farm, and each named target must
run one. It also holds the `buck2 test` commands of a `mojo_test` and a
`rust_test`, and each refusal above with its message.
