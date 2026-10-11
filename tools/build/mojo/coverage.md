# Coverage builds of the Mojo rules

The coverage build of `mojo_library` (and of `mojo_test`, for the libraries
that name it), moved out of [README.md](README.md#coverage-builds); the gate
it feeds is [The build gate](../coverage/README.md#the-build-gate).

`-c komira.coverage=true` (default `false`) gives every `mojo_library`, per
`test_srcs` entry:

- one more binary: the test compiled at `-O0` with
  `--debug-level line-tables`, against the same ungated package its gated
  test uses, for kcov to map what ran to source lines:
  `[coverage][bin][<test>]` (`cov/tests/<test>/<test>`, action category
  `mojo_build_cov_test`);
- one run of that binary under kcov, with the gated test's environment and
  data (it goes through the same `gate_runner.sh`), whose Cobertura report
  in repository paths is `[coverage][tests][<test>]` (`cov/tests/<test>.xml`
  and the marker `cov/tests/<test>.passed`, action category `mojo_cov_run`;
  [cov_run](../coverage/kcov/README.md#cov_run)). What differs: the test is
  traced without address randomization, its working directory also holds
  its source and the library's, and the run waits for every process the
  test started, so it is bounded: after 450 s every process of the run is
  killed and the action fails, saying the test left processes running or
  did not finish. komira's kcov exits with the test's status (128+N for
  signal N), so a test that fails at `-O0` or traced fails this action,
  whatever its gated run did;
- its branch coverage, which the gate reads when the library's
  `coverage_branch_gate` is set (a library of `COVERAGE_BRANCH_GATE` in
  [`policy.bzl`](../coverage/policy.bzl), or a fixture of the tests cell
  that does not pass `coverage_branch_gate = False`), and nothing waits
  for otherwise: the test emitted as
  LLVM bitcode at `-O0` with line tables (`[coverage][bc][<test>]`,
  `mojo_emit_cov_bc`, through the same `mojo_wrapper.sh`), instrumented
  with IR profile counters by the Mojo package's lld and linked with the
  LLVM profile runtime (`[coverage][pgo_bin][<test>]`, `mojo_cov_pgo_link`),
  and run through the same `gate_runner.sh` with `LLVM_PROFILE_FILE` set,
  whose merged profile is `[coverage][branch][<test>]` (`cov/branch/<test>.profdata`,
  `mojo_cov_branch_run`), that profile applied to the bitcode by the same
  lld as IR text (`[coverage][branch_ir][<test>]`, `mojo_cov_branch_annotate`),
  and its branches in the library's sources, each a source decision or a
  known compiler-made branch, as lcov `BRDA` records
  (`[coverage][branch_info][<test>]`, `cov/branch/<test>.info`,
  `mojo_cov_branch_classify`; [branch coverage runs](../coverage/branch/README.md)).
  A `test_env` setting `LLVM_PROFILE_FILE` is refused.

and, per library, with tests or without:

- the gate: `covcheck gate` over those reports (and, as above, the branch
  records: `--branch-lcov`) and the library's sources (each non-generated
  `srcs` file, recorded or not; every welded test set aside, under the
  package's `tests/` or not: `--test-source`), in
  the mode and against the target of
  [`policy.bzl`](../coverage/policy.bzl) (census, 100%), whose `result.json`
  and `summary.md` are `[coverage][gate]` (`cov/gate/`, action category
  `mojo_cov_gate`; [The build gate](../coverage/README.md#the-build-gate)).

and, as its tests for coverage (line coverage only: no branch coverage action):

- its README's examples (`[tests][readme]`), built and run as a test:
  `[coverage][bin][readme]`, `[coverage][tests][readme]`. A README with no
  example gives a program that runs nothing (`mojo_cov_readme_source`
  chooses). The report names the program under `buck-out/readme/`, which
  covcheck counts outside the repository;
- the `mojo_test` targets it names in `coverage_tests` (none by default; one
  test may be named by several libraries), each depending on it, with a
  source main and no `args`. It cannot depend on them, so its gate is the
  target `<name>_cov_gate`: each test's -O0 binary (the mojo_test's
  `[coverage][bin]`) run under kcov against the library's sources
  (`<name>_cov_gate[tests][<test>]`), and the gate over those reports and
  the library's (`<name>_cov_gate[gate]`), which its conda package waits for.

What ships, the library's conda package (`<name>_conda`: both its joins,
[`conda.bzl`](../package/conda.bzl)), then also waits for every coverage run
and the gate: with the switch on, a test that fails at `-O0` or traced, or a
gate that fails in enforce mode, leaves the conda package unbuilt. The
library's own package (`mojo_gate_join`) does not wait for them, so the
library builds and every dependent compiles and tests against it: a red
coverage run or gate blocks the package it measures from shipping, and
nothing else. A library with no test still has a gate (`NotMeasured`: it
fails in enforce mode), which its conda package waits for, as does a
library whose sources are all generated (a cloud SDK client). The libraries
the gate's own tool depends on are the ledger `COVERAGE_NO_GATE` of
`policy.bzl` (`covcheck`, `komira_json`, `readme_examples`): they have no
gate of their own (the library would depend on the gate's tool, which
depends on it), and their gate is `<name>_cov_gate`, which their conda
package waits for too. `[coverage]` is the binaries, the reports and the
gate's outputs; the branch coverage files are only its sub-targets `[bc]`,
`[pgo_bin]`, `[branch]`, `[branch_ir]` and `[branch_info]`.

```sh
./buck2 build 'komira//src/komira_retry:komira_retry[coverage]' -c komira.coverage=true
./buck2 build 'komira//src/komira_retry:komira_retry[coverage][gate][summary]' -c komira.coverage=true --show-full-output
```

The switch is read in the `mojo_library` macro ([`coverage.bzl`](coverage.bzl))
and does one thing: it sets the attributes `coverage_debug` to
`komira//tools/build/coverage/kcov:cov_link`, `coverage_run` to
`komira//tools/build/coverage/kcov:cov_run` (cov_run.sh, kcov and
cov_normalize), `coverage_branch` to
`komira//tools/build/coverage/branch:cov_branch` (the branch coverage
scripts and the LLVM pieces), `coverage_gate` to `komira//tools/build/coverage:cov_gate`
(cov_gate.sh, covcheck and the ratchet) and `coverage_mode` to the policy's
(for a library of the ledger or naming `coverage_tests`: no gate; its
`<name>_cov_gate` is declared), and a `mojo_test`'s `coverage_debug`; with it
off, `coverage_tests` is dropped. A buckconfig
value is not part of the configuration, so no output path moves; with the
switch off the attributes are absent and analysis is what it was without
coverage builds. With it on, every release action of the library
(`mojo_precompile`, `mojo_build_test`, `mojo_gated_test`, the README's,
`mojo_gate_join`) keeps its command line and inputs, so it keeps its cache
hits and so do its dependents; the conda package's joins keep their command
lines and gain the coverage markers as inputs; the coverage builds, runs
and gate are new actions ([test 41](../tests/README.md#41-coverage-builds)'s
`coverage_keys.sh`). A value other than `true` or `false` fails at load,
naming it.

The macro reads the switch from the buckconfig of the cell whose BUCK file
it runs in. `-c komira.coverage=true` on the command line, or a global
buckconfig (`~/.buckconfig.d`), applies to every cell. `[komira] coverage =
true` in a cell's own `.buckconfig` or `.buckconfig.local` applies to that
cell only: in a repository that mounts komira as the cell `komira`, setting it
in the root cell's file leaves komira's libraries without `[coverage]`
("unknown subtarget").

A coverage build runs the same `mojo_wrapper.sh` as every compile, byte for
byte, with one argument changed: its link directory (`<zig_dir>`) is
`cov_link` instead of the toolchain's zig. That directory holds the
toolchain's zig as `real/` and, as `zig`, `cov_zig`
([kcov README](../coverage/kcov/README.md#cov_zig)), which for a link drops
`-Wl,--strip-debug`, asks for no build id and no compressed debug section,
and after the link overwrites the action's directory with a placeholder of
the same length, with `debug_relocate`. The pinned Mojo records no
compilation directory and names its sources by relative paths (`tests/...`,
the staged library sources under `buck-out/`, the standard library under
`oss/modular/`); the directory overwritten is the one zig's C runtime units
record ([names in a coverage binary](../coverage/kcov/README.md#names-in-a-coverage-binary)).
The wrapper's own check, that no output holds the action's working directory
(exit 4), runs on the result as on any compile; a relocation that did not
happen fails there ([test 41](../tests/README.md#41-coverage-builds)).

Scope, for now:

- linux-x86_64, and never another platform (decided:
  `coverage-linux-x86-64` in [`limits.tsv`](../platforms/limits.tsv); kcov
  and branch coverage's LLVM pieces are pinned for linux-x86_64 only). On
  another target platform the switch is a no-op: the attributes are None (a
  `select`) and a library or shared library builds as with the switch off,
  the same actions (test 41's `coverage_platforms.sh`): it has no
  `[coverage]` sub-target, so asking for one is an "unknown subtarget" error,
  not an empty result. Whatever collects coverage asks only on linux-x86_64,
  as the pull request's `coverage` workflow does
  ([The coverage workflow](../coverage/README.md#the-coverage-workflow)).
- A library's `test_srcs`, written or generated: a generated test (an
  entry that is a build output) has its coverage binary and run as a written
  one has, and is named by its output path in the package (its report, the
  gate's `--test-source`). A `mojo_test` no library names is not run under
  kcov, nor one whose main is generated, and the library's generated
  sources are not measured.
- A `mojo_shared_lib`'s drivers (below).
- A test's data may not be staged at its own source's path or under
  `buck-out/`: a coverage run stages the sources there (analysis fails,
  naming the destination).
- Branch coverage only where the gate reads the branch records
  (`coverage_branch_gate`, above): kcov gives no branch data, so for any
  other library the gate's branch is `not measured` and never passes in
  enforce mode (`BranchNotMeasured`).

**Shared libraries.** With the switch, a `mojo_shared_lib` also has
`[coverage]`: the library built again at `-O0` with line tables through
`cov_link` (`[coverage][bin][<out_name>.so]`, `mojo_build_cov_shared_lib`);
each driver of `gate_srcs`, written or generated, at `-O0` with line tables
(`[coverage][bin][<driver>]`, `mojo_build_cov_driver`), run under kcov with
that build staged where the gate stages the library and kcov measuring the
libraries the driver loads (`[coverage][tests][<driver>]`, `mojo_cov_run`;
[cov_run](../coverage/kcov/README.md#cov_run), `--solib`); and its gate,
over those reports and the library's own non-generated sources (`srcs` and
`main`), the drivers set aside (`[coverage][gate]`). A driver counts toward
the shared library's own sources only: the code of its Mojo dependencies
compiled into it is measured by their own tests, in their own gates (a
library's numbers do not depend on what links it). The generated exports
driver is not run: it only loads the library and looks its symbols up. A
shared library none of whose sources is a source file (all generated) has
nothing measured, and its drivers' coverage runs are refused, saying so. The
gate's mode is `COVERAGE_SHARED_LIB_MODE` of
[`policy.bzl`](../coverage/policy.bzl), census: a shared library's line
coverage is reported, never enforced (one loaded by end-to-end tests exists
for them), and `enforce` is refused for every `mojo_shared_lib`, a fixture
of the tests cell included (in analysis). Nothing waits for any of it: the published file
(`mojo_shared_lib_join`) waits for the release gate only, and a shared
library ships no conda package. No workflow reports it yet: the coverage
workflow (`.github/ci/coverage_measure.sh`) selects `mojo_library` targets
only, so a shared library's `[coverage]` is built by name. For a shared
library over an engine, the report covers its own C-ABI sources only, not
the engine code compiled in from its dependencies. A source under the package's `tests/` (a
probe library such as `komira_arrow_ipc`'s `arrow_c_abi_probe`) is set aside
by covcheck like a test, so such a library's gate is `NotMeasured`.

A library in the `tests` cell may pass `coverage_debug` itself (a
`cov_link_dir`), and with it `coverage_run` (a `cov_run_dir`; the default one
when not given) and `coverage_gate` (a `cov_gate_dir`) with `coverage_mode`
(the policy's when not given): it then has coverage binaries and runs, and
with `coverage_gate` the gate, whatever the switch says, which
is how tests 41, 43, 46 and 47 build them, plant a defective relocator or run
script, and gate in enforce mode, without `-c`. Its conda package, if it has
one, waits for its runs and that gate. It may also pass
`coverage_branch_gate = False`, so its gate does not read its branch
records (test 46's `covfull_unread`). Anywhere else passing any of them is
refused. A `mojo_shared_lib` in the `tests` cell may pass the same four
(`enforce` is refused).

## API JSON: mojo_doc_json

`mojo_doc_json(lib, golden, symbols)` ([`doc.bzl`](doc.bzl)) writes the
`mojo doc` JSON of a `mojo_library`, optionally checked against a golden file
and for named declarations. [`doc.md`](doc.md) has its use, what the JSON
holds (no source locations), its two checks and test 52.
