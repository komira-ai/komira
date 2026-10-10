# Mojo rules

```python
load("@komira//tools/build/mojo:defs.bzl", "mojo_library", "mojo_binary", "mojo_test")
```

The rules are in [`defs.bzl`](defs.bzl); their providers in
[`providers.bzl`](providers.bzl). Every action runs the hermetic toolchain
([`toolchains//:mojo`](../toolchains/README.md)) through
[`mojo_wrapper.sh`](mojo_wrapper.sh), which is where to read the environment
the compiler sees. Worked uses of each rule are in
[`../examples/BUCK`](../examples/BUCK), and fixtures that must fail are in
[`../tests/`](../tests/README.md).

| rule | produces | example |
|---|---|---|
| `mojo_library(srcs, deps, test_srcs, import_name, test_optimization_level, readme)` | `<name>.mojoc` via `mojo precompile`. Each file in `test_srcs` is built against the package and run, and so are the ```` ```mojo ```` examples of the package's `README.md` (see [README examples](#readme-examples)); the package is published only if every one passes. `[ungated]` is the package file before its tests; it carries no `MojoInfo`, so it cannot be named in `deps`. | [`hellopkg`](../examples/BUCK), [`libgate_ok`](../examples/libgate_ok/BUCK) |
| `mojo_binary(srcs, deps, main, optimization_level, expected_stdout)` | an executable via `mojo build`, and `RunInfo` for `buck2 run`. `[runnable]` is the binary together with its runtime libraries. `[run_check]` runs it remotely and, with `expected_stdout`, fails unless its stdout matches exactly. `[shared]` is the same program as `lib<name>.so`, for a bundle (see [Packaging](../package/README.md)). | [`hello`, `hello_pkg_user`](../examples/BUCK) |
| `mojo_test(srcs, deps, main, optimization_level, data, env, args, labels)` | a test executable for `buck2 test`; `buck2 run` and `[runnable]` as for `mojo_binary`. | [`test_hellopkg`](../examples/BUCK) |
| `mojo_shared_lib(srcs, main, deps, out_name, exports, exports_exact, gate_srcs, force_load, optimization_level)` | `<out_name>.so` (Linux) or `<out_name>.dylib` (macOS arm64): a C-ABI shared library via `mojo build --emit shared-lib` from one file of `@export` functions, published only if its gate passes (see [C-ABI shared libraries](#c-abi-shared-libraries)). | [`spike`](../examples/shared_lib/BUCK), [`mid`](../examples/shared_lib_mid/BUCK) |
| `mojo_doc_json(lib, golden, symbols)` ([`doc.bzl`](doc.bzl)) | `<name>.json`: the `mojo doc` JSON of the `mojo_library` `lib`, optionally checked against a golden file and for named declarations (see [API JSON](doc.md)). | [`hellopkg_doc`](../examples/BUCK) |

## Libraries and the `test_srcs` gate

```python
mojo_library(
    name = "libgate_ok",
    srcs = ["__init__.mojo", "payload.mojo"],
    test_srcs = ["tests/test_payload_passes.mojo"],
)
```

- **Package root.** The shallowest `__init__.mojo` in `srcs` is the package
  root; every other source must lie under it. A library without an
  `__init__.mojo` fails.
- **Import name.** The label name, or `import_name`; it must be a Mojo
  identifier. Consumers `import` that name.
- **`gen`** (optional) names the target that generated `srcs`; its
  DefaultInfo, sub-targets included, is re-exported as the `[gen]`
  sub-target, so a reader or an IDE finds the generated code (see [mojo_gcp_client](#generated-google-cloud-clients-mojo_gcp_client)).
- **`deps`** carries the full transitive closure of packages to the compiler,
  one `-I` directory per package, each holding exactly one `.mojoc`, so a
  staged source directory can never shadow a package. A package reaches the
  compiler only through `deps`
  ([`tests/negative/missing_dep`](../tests/negative/missing_dep/BUCK) fails to compile).
- **The gate.** Each file in `test_srcs` is built from that one file against
  the ungated package (at `test_optimization_level`, default `-O1`; see [Optimization levels](#optimization-levels)) and run;
  a failing test prints `GATED TEST FAILED: <label> (exit N)`. The public
  package `L/pkg/<I>.mojoc` is a copy of the ungated one that takes every
  test's PASS marker as an input, so it cannot exist unless every test passed,
  and neither can anything depending on it
  ([`tests/negative/libgate_bad`](../tests/negative/libgate_bad/BUCK): the library and its
  consumer go red, `[ungated]` builds, and a binary naming `[ungated]` in
  `deps` fails analysis).
- **Every welded test must pass.** There is no way to hold a red test: a
  `mojo_library` naming `tests_known_failing` is refused when its BUCK file
  loads.
- **`test_srcs`, not `tests`**: Buck2 reserves `tests`. `buck2 test` on a
  `mojo_library` therefore runs nothing; its tests run when the library (or
  anything depending on it) is built.
- **`test_deps`** (optional) lists Mojo packages the welded tests are
  compiled against besides the library and its `deps`: a test-support
  package, such as a fake service several tests share
  ([`test_deps.bzl`](test_deps.bzl)). They reach the tests only, never the
  library's compile, its package, its `MojoInfo`, its README examples or
  its conda package, so a test-only package (`conda = False`) can be one.
  An entry that is not a `mojo_library`, or that is also in `deps`, is
  refused; one that depends on the library is a cycle buck2 refuses
  ([`tests//functional/test_deps`](../tests/functional/test_deps/BUCK),
  [`tests//negative/test_deps`](../tests/negative/test_deps/BUCK)).

Output layout of a library `L` with import name `I`:

```
L/ungated/I.mojoc   the compiler's output (sub-target [ungated])
L/pkg/I.mojoc       the public package, gated on every test's PASS marker
L/src/I/...         the staged package sources
L/tests/<t>/...     one binary and one PASS marker per test
L/tests/readme/...  the README's generated program, binary and marker
```

### README examples

A library whose package holds a `README.md` runs the README's examples as one
more welded test, `[tests][readme]`, so the documentation cannot rot. Nothing
declares it: the README is declared by existing. The program generator is
the Zig tool [`//tools/build/readme_examples:tool`](../readme_examples/BUCK)
(`generate`, and `map` for a report's lines; its unit tests are welded). It
reads Markdown through the shared Zig module
[`//tools/build/markdown`](../markdown/BUCK) (CommonMark fences, code spans,
links). Two Mojo programs read Markdown in process through the Mojo library
of the same package, `readme_examples`, until they move to the Zig tool and
module: `buildtools.doc_links` (the link check) and `kci_validate`, which
makes an installed README into the programs `generate` makes for it.

- **An example** is a fenced block whose info string is `mojo` or
  `mojo module` (```` ``` ```` or `~~~`; a closing fence is the same
  character, at least as long, so a ```` ```` ```` fence may quote
  ```` ``` ````). Every example runs: there is no skip word. A sketch that
  cannot run is fenced ```` ```text ````. Any other word after `mojo`
  (`mojo skip`) and any near miss (`Mojo`, `mojo,`, `.mojo`) is refused,
  naming `README.md:<line>`.
- **One program per example**, `readme_<I>_<line>.mojo` (`<line>`: its
  opening fence's README line), compiled and run on its own as a gated test
  labelled `<target>:README.md:<line>`. Examples share nothing: two may
  import the same names and declare the same ones, and a failure names one
  example. The fence tag is the mode; nothing is inferred from the code:
  - ```` ```mojo ````: statements. The lines are pasted as they are, each
    indented four spaces, into `def main() raises:`. Every line is indented,
    the continuation lines of a triple-quoted string too, so such a string's
    content gains those four spaces. Mojo allows an import inside a
    function, so nothing is hoisted or parsed. Assertions are visible
    `std.testing` calls.
  - ```` ```mojo module ````: a whole program, copied as it is, with its own
    `def main()`. Fence an example that declares a `struct` or `trait` (or
    anything else that must be module-level) this way.
- **Hidden lines**: an HTML comment `<!-- mojo-hidden ... -->` ending on the
  line just before an example's fence is prepended to it, and one starting on
  the line just after is appended (one line, or `<!-- mojo-hidden`, the code,
  then `-->`). GitHub's page does not render it; every raw view, and the
  installed copy, shows it. A `mojo-hidden` comment next to no example, or a
  misspelled marker, is refused.
- **Lines**: line n of an example's program is README line n (the lines
  around the copied ones are blank, but for a header comment and the
  `def main() raises:` of a ```` ```mojo ```` example), so a compile error
  or an assertion at `readme_<I>_<line>.mojo:<n>` names README line n. The
  generator also writes `readme_<I>.mojo` (never `<I>.mojo`: a file named
  like the package beside the programs would shadow it), a runner that
  imports every example's program and runs each inside `try`, printing
  `<package>/README.md:<line>: FAILED: <error>` for each that raises, then
  `readme_<I> validation: P of E checks passed`: what a coverage build and
  an installed README's validation run, in one process.
- **No example**: whether a README holds one is in its bytes, which analysis
  cannot read, so a dynamic action reads the examples' lines. With none, nothing is
  compiled or run and the marker reads `NO EXAMPLE <label>`, never `PASS`. A
  README's examples do not count as the tests a conda package needs.
- **Which library**: a BUCK file of one library says nothing. Every library
  of a BUCK file takes the directory's `README.md` unless it says otherwise,
  so a BUCK file of several libraries names the one the README is about with
  `readme` ([`readme.bzl`](readme.bzl)): `readme = False` takes no README
  (no `[tests][readme]`, none in its conda package); `readme = True` takes
  `README.md` and is refused if there is none. Left on a library that does
  not reach what the README imports, the README fails that library's
  `[tests][readme]` compile; left on several, it ships in each of their
  packages. `mojo_gcp_client`, `mojo_aws_client` and the welded
  `mojo_proto_library` pass `readme` through.
- **A README that ships** (the library has a conda package the build can
  make, which installs it at `share/doc/<conda name>/README.md`; see
  [Conda packages](../../../packaging/conda/README.md#the-readme-in-the-package))
  refuses a relative link outside code, naming `README.md:<line>`: the
  installed copy has no neighbours. Link an absolute URL or an `#anchor`.

Test 38 ([`tests/README.md`](../tests/README.md#38-readme-examples)) builds
a README that uses every form and two whose examples declare the same names,
and requires a raising example (and no other), a compile error, a struct in
a plain ```` ```mojo ```` example and a `mojo skip` fence each to fail
naming its README line; it also
builds a two-library package whose README is one library's, and requires
the same package without `readme = False` to fail.

### The compile watchdog

The compiler can deadlock (every thread parked, the process tree using no
CPU) and then never exits, which would hold a remote worker until the
executor's action timeout. [`mojo_wrapper.sh`](mojo_wrapper.sh) runs it in a
session of its own and samples the CPU time of that session and the
compiler's whole process tree from `/proc` (a helper reparented away from the
compiler is still in the session, and counts; what is sampled is what is
killed) every `watchdog_sample_secs` (default 30); after `watchdog_idle_secs`
(default 300) of samples each gaining less than 1% of one CPU, it kills the
session and the tree and fails the action with exit 124:
`mojo-watchdog: killed deadlocked compiler after <n>s of zero process-tree
CPU`. Such an action is safe to retry. There is no wall-clock limit; a slow
compile uses CPU throughout and is never killed. Both knobs are
`mojo_toolchain` attributes (`komira_mojo_toolchains(watchdog_idle_secs = ...)`
in a toolchains cell); `watchdog_idle_secs = 0` turns the watchdog off.

The compiler dies with the wrapper. A HUP, INT or TERM to the wrapper kills
the tree before the wrapper exits (129, 130, 143). A KILL cannot be caught,
so a tether in the compiler's session blocks reading a FIFO whose only
writer is the wrapper; when the wrapper dies the read returns and the tether
kills the session. The macOS wrapper
([`darwin/mojo_wrapper.sh`](darwin/mojo_wrapper.sh)) has the same watchdog
and knobs (`mojo_darwin_toolchain`), sampling `ps` instead of `/proc` and,
with no `setsid` on macOS, the compiler's tree by parent pid instead of a
session ([`tests/functional/watchdog`](../tests/functional/watchdog/cases.sh),
[`tests/functional/darwin`](../tests/functional/darwin/check.sh)).

## Binaries and tests

- **`main`**: the file holding `main()`. It defaults to the only file in
  `srcs`; with several, name it.
- **`optimization_level`**: `mojo_binary` default `3`, `mojo_test` default `1`;
  see [Optimization levels](#optimization-levels).
- **`[run_check]`** (`mojo_binary`): runs the binary remotely from its
  runnable directory, with no library path set, and with `expected_stdout`
  compares its stdout byte for byte
  ([`examples/BUCK`](../examples/BUCK) `hello`, `hello_pkg_user`).
- **`buck2 run <target>`**: builds remotely and runs the binary on your
  machine (Linux x86_64) from its runnable directory, downloading the binary
  and its runtime libraries, never the compiler
  ([test 9](../tests/README.md#9-buck2-run)).
- **`buck2 test <mojo_test>`**: runs the test binary remotely through
  [`gate_runner.sh`](gate_runner.sh). `buck2 run` of a `mojo_test` runs its
  binary directly, from the runnable directory.
- **Exit status.** A test passes only by exiting 0. Every other status fails,
  77 included: 77 means SKIP to automake and some test harnesses, but here
  it is a failure (`GATED TEST FAILED: <label> (exit 77)`), so a test cannot
  skip itself green, whether gated or run by `buck2 test`
  ([`tests//negative/test_data:skip_77`](../tests/negative/test_data/BUCK)).

### Time limits

- **`buck2 test`** runs a test through buck2's test runner, which gives it
  a timeout: the runner's `--timeout`, 600 s unless
  `buck2 test <targets> -- --timeout <s>` sets another. (`[test]
  timeout_default_s` does not reach these tests; it is the timeout of the
  other kind of test provider.) A remote executor stops the action there, and
  buck2 reports a plain `Fail` with `Timeout 0`: no word of the timeout, and
  a `mojo_test`'s output, which its runner holds until the test exits, is
  lost. So a `mojo_test` runs under [`test_deadline.sh`](test_deadline.sh),
  which kills the test 60 s earlier ([`test_limit.bzl`](test_limit.bzl)),
  lets the runner report it (`GATED TEST FAILED: <label> (exit 137)` with its
  output), and prints `TEST TIME LIMIT: killed <label> after <n> s, under the
  test runner's timeout of <m> s (komira.test_timeout_s)`. No rule can read
  the runner's command line, so the root `.buckconfig` states its timeout as
  `[komira] test_timeout_s` (komira's [`.buckconfig`](../../../.buckconfig)
  and [`consumer.buckconfig`](../consumer.buckconfig) set 600, the
  default): with `-- --timeout <s>`, pass `-c komira.test_timeout_s=<s>`
  too. The `mojo_test` macro reads the key when the BUCK file loads; a value
  that is not a whole number, or not over 60, is refused.
- **A library's `test_srcs`** run as build actions, and buck2 gives a build
  action no timeout: neither the runner's timeout nor the limit above
  applies, only the executor's own default for an action that names none. A
  gated test that hangs holds its worker until then, and fails as the
  executor reports it.

### Outputs and the runnable directory

Every compile targets the toolchain's `target_cpu` (`x86-64-v3`), not the CPU
of the worker that ran it. Linked binaries carry one run path, DT_RUNPATH
`$ORIGIN/lib`, and no debug sections, and every compile action fails (exit 4)
if its output contains the action's working directory
([test 6](../tests/README.md#6-outputs)).
The compiler records source file names in a linked program (for error
locations); they are recorded relative to the package (`hello.mojo`), not as
paths inside the action.

A built binary loads a few shared libraries from the toolchain
(`komira//tools/build/toolchains:mojo_runtime`: the Mojo runtime and the pinned C++ runtime,
about 24 MB). The runnable directory of a binary (`[runnable]`) holds the
binary and a copy of those libraries in `lib/`, where its run path finds them,
so it starts from anywhere with no environment. `RunInfo` points at it.
([`launch.sh`](launch.sh) starts a binary from outside its runnable
directory, pointing the loader at the toolchain's `lib/`.) The list of
libraries is checked against what the loader actually maps during a run
([test 8](../tests/README.md#8-host-floor-and-runtime-libraries)).

**Two runtime surfaces.** `buck2 run` and `[run_check]` start a binary from its runnable directory, whose
`lib/` holds only the libraries a run loads (`komira//tools/build/toolchains:mojo_runtime`).
Gated library tests and `buck2 test` of a `mojo_test` still run the binary
with `LD_LIBRARY_PATH` set to the compiler's `lib/`, a superset. A test that
passes there can therefore load a library the runnable directory lacks; the
runtime-library check keeps the subset equal to what a real run loads. Moving
the gated tests onto the runnable directory would change the command of every
gated test action, and so their cache keys.


## Optimization levels

Tests compile at `-O1`; what ships compiles at `-O3`. A test is built, run
once and thrown away, so its compile is most of what it costs, while a binary
or shared library runs in production.

| what | level | override |
|---|---|---|
| `mojo_test` | `-O1` | `optimization_level` |
| each `test_srcs` file of a `mojo_library` (the gate) | `-O1` | `test_optimization_level` |
| `mojo_binary`, and its `[shared]` library | `-O3` | `optimization_level` |
| the shared libraries a bundle packs (a binary's `[shared]`) | `-O3` | the binary's `optimization_level` |

The level belongs to the target that compiles: nothing a consumer declares
changes it. A test linking a shared library or a C/C++ library links it as
that library's own target built it (a `.so` at `-O3`, a C library at its own
`compiler_flags`); a `.mojoc` holds no machine code, so a package has no
level of its own and is compiled into each binary at that binary's level. A
`[run_check]` runs the binary its target built. A test program declared as a
`mojo_binary` (for `expected_stdout`) states `optimization_level = "1"`
itself, as [`examples/aws_lc`](../examples/aws_lc/BUCK) and
[`examples/s2n_tls`](../examples/s2n_tls/BUCK) do. Levels are `0` to `3`;
anything else is refused at analysis. Test 30
([`tests/functional/opt_level.sh`](../tests/functional/opt_level.sh)) reads the levels from the
compile commands.

## Assert level, defines and memory cap

```python
mojo_library(
    ...
    test_srcs = ["tests/test_hostile_input.mojo"],
    test_assert_level = "none",       # -D ASSERT=none for each test_srcs build
    test_defines = ["KOMIRA_X=1"],     # -D KOMIRA_X=1 for each test_srcs build
    test_memory_cap_mib = 2048,       # default at ASSERT=none: 4096; 0: no cap
)

mojo_test(..., assert_level = "all", defines = ["KOMIRA_X"], memory_cap_mib = 1024)
mojo_binary(..., assert_level = "none", defines = ["KOMIRA_X=1"])
```

The attributes are in [`defines.bzl`](defines.bzl). An unset one writes
nothing, so a target that sets none of them has the commands, and the action
keys, it had before they existed.

- **Assert level** (`test_assert_level` on `mojo_library`, `assert_level`
  on `mojo_test` and `mojo_binary`) is `-D ASSERT=<level>` on `mojo build`,
  the define Mojo's `debug_assert` reads: `none` turns every `debug_assert`
  off, `safe` (the compiler's default) keeps the ones declared
  `assert_mode="safe"`, `all` turns every one on, and `warn` turns every one on
  and prints a failure instead of aborting. Any other value is refused at
  analysis. It reaches the code of every package compiled into the program,
  not only the program's own file: a `.mojoc` holds no machine code, so its
  `debug_assert`s are settled in the `mojo build` that generates the code
  ([`tests//functional/assert_level`](../tests/functional/assert_level/BUCK):
  a library's asserts are off in its test at `none`; the twins in
  [`tests//negative/assert_level`](../tests/negative/assert_level/BUCK) fail
  at `all` and at the default level).
- **Defines** (`test_defines`, `defines`) are `-D <entry>` each, in order,
  after the assert level: `NAME` or `NAME=VALUE`, `NAME` an identifier, none
  twice, and never `ASSERT` (set the assert level instead). A define read in a
  function body (`std.sys.defines.get_defined_string`) sees the value in the
  program's file and in a package's code alike.
- **Memory cap** (`test_memory_cap_mib`, `memory_cap_mib` on `mojo_test`): the
  test runs under [`mem_cap.sh`](mem_cap.sh), which sums the resident memory
  of the test's process tree from `/proc` every 0.1 s and, past the cap,
  kills the test; the gate runner then reports it (`GATED TEST FAILED: <label>
  (exit 137)`) and `mem_cap.sh` adds `MEMORY CAP: killed <label> at <n> MiB
  resident, over its cap of <cap> MiB`. A test that allocates without bound
  therefore fails instead of exhausting the worker. Unset, a test at
  `ASSERT=none` (a hostile-input test, whose bounds checks are off) is capped
  at 4096 MiB and any other test is not; `0` turns the cap off. The cap is
  sampled: a test can pass it by what it touches in one interval. It caps
  resident memory, not address space: the Mojo runtime's allocator reserves
  address space in 1 GiB regions when it starts, and a test under an
  address-space limit of a few GiB (`ulimit -v`) aborts before its first line.
  The gate runner leads a session and process group of its own, which the
  test and its children join unless they leave it. `mem_cap.sh` kills that
  process group (only the group, by number) once the gate runner has exited,
  if `/proc` cannot be read, and if `mem_cap.sh` is signalled (SIGHUP,
  SIGINT, SIGTERM) or killed (SIGKILL, through a tether process in the
  group). That reaches a child reparented out of the test's process tree,
  which the cap's kill (by parent pid) misses, as long as it is still in the
  group. It does not reach a reparented process that has left the group (a
  new session, or `setpgid` into another group), and the cap's kill also
  kills the tether, so if `mem_cap.sh` is SIGKILLed after the cap's kill and
  before its own group kill, a reparented child is left running uncapped.
  Linux only: on macOS a capped test is refused.

The `mojo_library` attributes apply to each `test_srcs` build and run, and
the assert level and defines to its coverage builds (the coverage binary and
the branch coverage bitcode); not to the package's
`mojo precompile`, the README's examples, or a coverage run under kcov, which
is not capped. `mojo_binary`'s apply to its `[shared]` library too.
Test 49 ([`tests/README.md`](../tests/README.md#49-assert-level-defines-and-memory-cap))
reads the commands and runs the fixtures.

## Test data, environment and scratch

Every test, a `test_srcs` test of a `mojo_library` or a `mojo_test` run by
`buck2 test`, runs from a tree staged for that test alone:

```
root/bin/<test>       the test binary
root/share/<dest>     each declared data file
```

```python
mojo_library(
    ...
    test_srcs = ["tests/test_reader.mojo"],
    test_data = {
        # A list: each source is staged at its path from the cell root.
        "tests/test_reader.mojo": ["fixtures/a.parquet"],
    },
    test_env = {"READER_MODE": "strict"},
)

mojo_test(
    ...
    data = {"golden/out.txt": "fixtures/expected.txt"},  # a dict: {dest: source}
    env = {"READER_MODE": "strict"},
    args = ["--reader-binary=$(exe_target //tools:reader)", "--golden=$(location :golden)", "--strict"],
)
```

- **Current directory.** [`gate_runner.sh`](gate_runner.sh) starts the test
  in `root/share` (an empty directory when nothing is declared). A test in
  package `pkg` that declares `fixtures/a.parquet` opens it as
  `pkg/fixtures/a.parquet`, the path it has in the repository. A file the
  test did not declare is absent, whether or not it exists in the repository,
  and so are the action's other inputs.
- **`test_data`** is keyed by `test_srcs` entry, so a fixture edit re-runs
  only the tests that declared it. A value is a list of sources, or a dict
  `{dest: source}` (a build output must use the dict form). A destination
  must be a relative file path with no empty, `.` or `..` segment, and may
  not also be the directory of another destination. `mojo_test` takes the
  same value as `data`.
- **`test_env`** (`env` on `mojo_test`) adds variables. The runner owns
  `PATH`, `LD_LIBRARY_PATH`, `LD_PRELOAD`, `DYLD_LIBRARY_PATH`,
  `DYLD_FALLBACK_LIBRARY_PATH`, `DYLD_INSERT_LIBRARIES`, `TMPDIR`,
  `TEST_TMPDIR`, `HOME` and `PWD`; setting one is refused at analysis.
  The variables are given to the test process only, never to the runner's
  own shell, so a name the runner uses internally (`BIN`, `rc`, `MARKER`)
  reaches the test and cannot change the verdict
  ([`tests//functional/test_data:runner_cases`](../tests/functional/test_data/runner_cases.sh)).
- **`args`** (`mojo_test` only) are the test's command-line arguments under
  `buck2 test`, in order. Configuration reaches a test as flags, so a test
  that needs a tool or file is given its path this way rather than through
  `env`. `$(location <target>)` is the path of the target's default output:
  use it for a file. `$(exe_target <target>)` is the target's run command
  (`RunInfo`), built for the test's platform: use it for a program. For a
  `mojo_binary` that is the binary inside its runnable directory, with lib/
  beside it; `$(location)` of a `mojo_binary` is the bare executable, which
  cannot load its runtime libraries. A run command of more than one word is
  not split: it reaches the test as one argument. (`$(exe <target>)` is the
  same command built for the execution platform; the two are the same
  binary only while the test's platform is its execution platform.) What a
  macro names becomes an input of the test, so it is present on the worker;
  because the test runs from `root/share`, every such path is absolute (the
  rule writes it under `@KOMIRA_ACTION_DIR@/` and the runner replaces that
  with the action's directory, so an argument may not hold that text
  literally). An argument is never exported, whatever its text.
  `buck2 run` and `[runnable]` do not pass `args`. A library's `test_srcs`
  take none: a gated test is a unit test of its package and gets everything
  it reads through `test_data`
  ([`tests//functional/test_data:mojo_test_args`](../tests/functional/test_data/BUCK)).
- **Scratch.** `TEST_TMPDIR` (equal to `TMPDIR`) and `HOME` are two empty
  directories the runner makes for this run inside the action's working
  directory, so no two runs share them, and they are removed afterwards.
- **Finding data from the executable.**
  [`komira//tools/build/mojo/runtime_paths:komira_runtime_paths`](runtime_paths/__init__.mojo)
  gives `executable_path()`, `install_root()` (the parent of the binary's
  directory), `share_dir()`, `data_path(rel)`, `read_data(rel)` and
  `test_tmpdir()` (which raises rather than fall back to `/tmp`). A bundle
  has the same layout (`bin/<name>`, `share/`), so the same call finds a
  bundle's `data` and a test's declared data; nothing reads a runfiles tree
  or an environment variable.
- **Reading a resource.** Library code uses
  [`komira_resources`](../../../src/komira_resources/resources.mojo):
  `read_resource(name)` and `resource_path(name)`, where `name` is the file's
  path under `share/` (its repository path, for a list entry). A test declares
  the file in `test_data` / `data`; a shipped program's `mojo_bundle` lists it
  in `data` as `share/<name>`, so both use the same name. An undeclared name
  raises an error naming the file and where to declare it.
  A program finds `share/` as `<exe>/../../share`, so a built program that is
  a test's data is staged the way a bundle lays it out: its `[runnable]`
  directory at `<tool>/bin` and its resources at `<tool>/share/<name>`.
  `mojo_bundle` ships `data` files mode 0644, so a shipped script is run
  through its interpreter (`bash <path>`), not executed directly.

## Protobuf: mojo_proto_library

```python
load("@komira//tools/build/mojo:proto.bzl", "mojo_proto_library")
```

`mojo_proto_library(name, srcs, deps, proto_deps, import_prefix, bundle_proto_deps, test_srcs)`
runs protoc with the `protoc-gen-mojo` plugin over `srcs` (`.proto` files)
and precompiles the generated directory, one `<stem>.mojo` per `.proto` plus
an `__init__.mojo`, into `<name>.mojoc`. Other Mojo targets name it in `deps`
like a `mojo_library`. `deps` are the Mojo libraries the generated code
imports (its runtime). A `.proto` is imported by other `.proto` files at
`import_prefix` joined with its path in the package; `proto_deps` names the
`mojo_proto_library` targets whose files these import. The generated package
is flat, and a reference to a message of another file is generated as a
module of the same package: with `bundle_proto_deps = True` the whole
`proto_deps` closure is generated into this package too, or, with
`bundle_only = [<import path>, ...]`, only those files of it (a closure often
holds files that only declare options, which need no Mojo). Sub-targets:
`[gen]` (the generated directory), `[<stem>.mojo]`, `[proto]` (the staged
`.proto` files). With `test_srcs` (and optionally `test_data`, `test_env`),
the package is welded to its tests exactly like a `mojo_library`: the call
becomes `<name>_gen` (generation only; it carries the `.proto` files, so
another proto library that imports them names `:<name>_gen` in `proto_deps`)
and `<name>`, a `mojo_library` over the generated files whose `.mojoc` is not
produced until every test passes. The welded form generates only the target's
own `srcs` (`bundle_proto_deps` and `bundle_only` are refused with it). Without
`test_srcs` a generated package is gated only through the tests of the
libraries and binaries that depend on it. Generation is deterministic, checked by
comparing two uncached builds
([test 23](../tests/README.md#23-protobuf)).

```python
load("@komira//tools/build/mojo:proto.bzl", "mojo_db_proto_library", "proto_srcs")
```

`mojo_db_proto_library(name, srcs, outs, deps, proto_deps, import_prefix)`
runs protoc with `protoc-gen-mojo-db` instead, and precompiles its output the
same way. For each message of `srcs` annotated `(komira.db.table)` the plugin
writes a struct implementing `komira_db.DbStorable` (column names and
logical types, `to_row`/`from_row`, `insert_sql`, CREATE TABLE statements)
into `<stem>_db.mojo`; a `.proto` with no table gets no file, so `outs` states
the files, and a stated file the plugin does not write fails the generation.
The options are defined in `proto-codegen/db/options.proto`, imported as
`komira/db/options.proto` through the `proto_srcs` target
`komira//tools/build/proto-codegen:db_options` in `proto_deps`. protoc hands
a plugin the descriptors of the whole import closure with their custom
options, which the plugin decodes from the raw request bytes; no
descriptor-set flag is passed. `deps` holds the `komira_db` runtime the
generated code imports. `proto_srcs(name, srcs, import_prefix, proto_deps)`
names `.proto` files that others import but no Mojo is generated from. `mojo_routes_proto_library` (HTTP routes from `google.api.http`): [its README](../proto-codegen/routes/README.md).

The toolchain, `toolchains//:mojo_proto` (declared by
`komira_proto_toolchains()`, see [toolchains](../toolchains/README.md)), is protoc
29.1 (the sha256-pinned static release build, with its well-known-type
`.proto` files) and `komira//tools/build/proto-codegen:protoc-gen-mojo`,
`:protoc-gen-mojo-db` and `:protoc-gen-mojo-routes`, built from source with the [Rust rules](../rust/README.md) against the
crates in `third_party/rust`. The plugins and their shared crate, `komira_proto_codegen`, are
in [`../proto-codegen/`](../proto-codegen/);
[`tests//functional/proto`](../tests/functional/proto/BUCK) holds the example protos and tests.

### Wire fixtures: proto_fixture_check

```python
load("@komira//tools/build/mojo:proto_fixture.bzl", "proto_encode", "proto_fixture_check")
```

protoc, the reference implementation, reads committed wire fixtures in a build
action, so a producer and a reader under test are held to an implementation
that never saw their code, as far as the legs below reach. A fixture `<stem>`
is three files:

| file | holds |
|---|---|
| `<stem>.hex` | the bytes a producer under test wrote |
| `<stem>.txtpb` | the line `# proto-message: <root>`, then exactly what `protoc --decode=<root>` prints for those bytes |
| `<stem>.canonical.hex` | what `protoc --encode=<root>` writes for the `.txtpb`, the bytes for a reader under test |

The hex format: hex digits, either case, two per byte; spaces, tabs and line
breaks anywhere are ignored; any other character, an odd number of digits and
an empty file are refused. `proto_encode` writes lowercase, 64 digits a line.

`proto_fixture_check(name, fixtures, dir, files, hex, canonical_producer, srcs,
import_prefix, proto_deps)` checks each entry `<stem>: <root>` of `fixtures`
(the root a fully qualified message name, `package.Message`), reading
`<dir>/<stem>.hex`, `.txtpb` and `.canonical.hex` from the package, or from
the `staged_files` target `files` names (`<files>[<dir>/<stem>.hex]`) when
they are another package's. `hex = {<stem>: <label>}` replaces a `.hex` with a
build output. Legs 0 and 5 read the schema as protoc's own descriptor set
(`--descriptor_set_out`, decoded with protoc's `descriptor.proto`), never a
list; the check fails (`SCHEMA`) if that table does not hold one complete row
for every field it declares.

0. The bytes show a producer: the `.hex` is not byte for byte the
   `.canonical.hex` (then both ends of legs 1 and 3 are protoc, and no
   producer is checked), unless the stem is in `canonical_producer`, which
   declares a producer that writes protoc's bytes; and no singular field of
   `<root>` is written twice at the top level (protoc's decode shows only the
   last). This is a necessary condition, not provenance: bytes that differ
   from protoc's can still be hand-made.
1. `protoc --decode=<root>` of the `.hex` is the `.txtpb` after its first
   line, compared byte for byte.
2. That decode holds no field the schema does not declare, at any depth:
   protoc prints one as a bare number (`99: 1`, or `99 {` for a group or a
   length-delimited value that parses as a message) and does not fail, so leg
   1 alone passes it once the `.txtpb` holds the number too.
3. `protoc --encode=<root>` of the `.txtpb` is the bytes of the
   `.canonical.hex`.
4. The `.txtpb`'s first line is `# proto-message: <root>`, so a fixture of
   another message is refused even when both messages give the same bytes and
   text.
5. Every enum value in the decode has a name: protoc prints a value an open
   (proto3) enum does not declare as a number on the field (`kind: 99`),
   exits 0, and parses the number back, so legs 1 to 4 all pass it. The decode
   is walked from `<root>` with the schema table, which places each line in
   its message; a line it cannot place is a failure, not skipped.

Each leg reads protoc's output and the committed files itself, never another
leg's verdict: every leg runs whatever the others found, except that legs 2
and 5 need a decode (when protoc refuses the bytes, leg 1 says so), and a
`.hex` or `.canonical.hex` that is not hex, or a root the schema does not
declare, fails the fixture before any leg (`FIXTURE`). Each failure is
reported on its own line, `proto_fixture: <stem>: LEG <n>: ...`, naming the
file read (for a `hex` override, the build output). The output is a report
with one `PASS` line per fixture, written only when every leg of every fixture
passed: building the target is the check.

What the check cannot see. Under proto3's text format a scalar at its default
is absent from the decode whether or not the producer wrote it, so a producer
that drops a field and one that writes it as zero give the same `.txtpb`; a
singular field written twice inside a nested message decodes as the last
value (leg 0 counts top-level fields only); a forger who appends a repeated
field's tag passes leg 0. So the `.txtpb` says what the bytes mean to protoc,
not everything the producer wrote. Leg 5 proves an enum value has a name, not
that it is the right one. Leg 4 compares two strings an author wrote (the
`fixtures` root and the header line), nothing in the bytes.

The check is held to its own legs: `proto_fixture_case` targets
([`proto_fixture_testdata/BUCK`](proto_fixture_testdata/BUCK)) run it over a
control fixture it must accept and one planted defect per refusal (each leg,
leg 2 at the top level, nested and as a group, and an odd-length `.hex`), and
assert the refusal and its message. Every `proto_fixture_check` and
`proto_encode` action takes their verdicts as an input, so a check that stops
refusing a defect fails every build that checks a fixture, the pull-request
check's included. [Test 23](../tests/README.md#23-protobuf) builds the same
defects end to end as planted-defect twins; those run only in
`build_system_selftests.yml` (nightly and on demand), not in the pull-request
check.

`proto_encode(name, root, txtpb, srcs, import_prefix, proto_deps)` writes
`protoc --encode=<root>` of `txtpb` (which must begin with the same
`# proto-message: <root>` line) as `<name>.hex`, and refuses a text that
encodes to no bytes. It is how a `.canonical.hex` is made:
`./buck2 build <proto_encode target> --out <dir>/<stem>.canonical.hex`. It
runs as a build action, so on the remote executors when the build is
configured for remote execution (as this repository's farm configuration is),
and nobody hand-makes the bytes. Its output is protoc's, so as a `.hex` it
checks no producer (leg 0).

`srcs` are staged at `import_prefix` joined with their path in the package,
and the `proto_deps` closure (`mojo_proto_library`, its welded `<name>_gen`,
`proto_srcs`) and protoc's well-known types are on the proto path, as for
`mojo_proto_library`; protoc reads every `.proto` file of `srcs` and of that
closure. protoc comes from `toolchains//:mojo_proto`; the macros default
`exec_compatible_with` to linux x86_64, the one execution platform that
toolchain pins protoc for.

### Generated Google Cloud clients: mojo_gcp_client

```python
load("@komira//tools/build/cloud:gcp.bzl", "mojo_gcp_client")
```

`mojo_gcp_client(name, protos, deps, bundle_proto_deps, bundle_only, roots,
methods, messages_only, proto_deps, import_prefix, protocol, test_srcs,
**kwargs)`
(`kwargs`: `test_data`, `test_env`, passed to the
`mojo_library`) generates a Google Cloud client at build
time; no generated code is checked in. It is the generation half of the rules
above (`<name>_gen`: protoc-gen-mojo writes the package and its layout probe,
nothing is compiled) plus an ordinary `mojo_library` over the generated
files, so the client is welded like any library: the generated
`_layout_probe.mojo` (one `size_of` per emitted struct) is its first
`test_srcs` entry, followed by the caller's. Output is restricted to the
closure of `roots` (messages) and `methods` (`Service.Method`), at least one
of them required; `messages_only` emits no service. `protocol` is "rest"
(the default) or "grpc", and `messages_only` output is the same under both.
Either service client is `<Service>Client[C: Connector, T: GcpTokenSource]`:
the token source (komira_gcp_core) supplies each request's bearer token. A
"grpc" client calls komira_grpc's `GrpcClient` with classic gRPC, sets
`authorization: Bearer <token>` on each call's `CallOptions` (the token
hook), and raises a non-OK gRPC status through komira_gcp_core's
`gcp_grpc_status_error`.
`protos` takes source paths of `.proto` files only, never a label. The
referenced googleapis files (monitored_resource, logging/type, rpc/status,
...) are generated as sibling modules through `bundle_only`, which
`bundle_proto_deps = True` requires. `deps` is required and non-empty:
nothing is added to the runtime the caller names, and they may be anything
`mojo_library.deps` takes. Every refusal is at analysis. `<name>[gen]` is
the generated directory, with `[gen][<file>]` one generated file and
`[gen][proto]` the staged `.proto` inputs (`mojo_library`'s optional `gen`
attribute re-exports a generating target whole, sub-targets included, as
that sub-target; nothing checks that `srcs` come from it). The module
docstring of
[`../cloud/gcp.bzl`](../cloud/gcp.bzl) has the details;
[`tests//functional/mojo_gcp_client`](../tests/functional/mojo_gcp_client/BUCK) and
[`tests//negative/mojo_gcp_client`](../tests/negative/mojo_gcp_client/BUCK) exercise it.

### Generated AWS clients: mojo_aws_client

```python
load("@komira//third_party/botocore:models.bzl", "botocore_model")
load("@komira//tools/build/cloud:aws.bzl", "mojo_aws_client")
```

`mojo_aws_client(name, model, model_sha256, operations, deps, mode, service,
endpoint_rules, partitions, overrides, hand_srcs, test_srcs, **kwargs)` (`kwargs`: `test_data`,
`test_env`, passed to the `mojo_library`) generates an AWS client from one
botocore service model at build time; no generated code is checked in.
`<name>_gen` runs `komira//tools/build/proto-codegen:aws-client-gen`, which
writes the package `<name>`: `__init__.mojo`, the module `<name>.mojo`
(imported as `<name>.<name>`) and `_layout_probe.mojo`; `<name>` is an
ordinary `mojo_library` over them, welded like mojo_gcp_client's: the probe is
its first `test_srcs` entry, then `_no_env_reads.mojo`, an environment scan
written for the client at analysis (every file of the package is its data;
it fails if any names one of the environment reads or FFI routes it lists,
or has an import statement, read at the start of a line, after a `;` or
after a `:`, outside comments and string literals, of a module outside an
allow-list of the runtime the generator imports and std.sys, and it refuses
a file with a t-string, whose braces it does not lex, or with an ASCII
control byte other than a tab or a line feed (Mojo reads a carriage return,
a vertical tab and a form feed as a line end); and it checks
that it read the whole generated module), then the caller's. `model` and
`model_sha256` are normally `botocore_model("<service>").model` and
`.sha256` from [`third_party/botocore`](../../../third_party/botocore/BUCK);
the service id is read from the model's botocore path unless `service`
names it. `operations` is required and non-empty: only the closure of the
operations named is emitted, and one the model lacks is refused by the
generator. `mode = "pure"` (the default) emits shapes and
`build_<op>_request` / `parse_<op>_response` with no transport; `"client"`
adds the signed-send surface. `endpoint_rules` and `partitions` (the
service's botocore endpoint ruleset and the partition table,
`botocore_model("<service>").endpoint_rules` and `.partitions`) are set
together or not at all; with them the module embeds both and resolves each
operation's endpoint through `komira_aws_core.EndpointRuleSet`
(`<Prefix>EndpointConfig` and `resolve_<op>_endpoint`), and in client mode
each verb sends to the endpoint it resolves; without them the
module's header lists the endpoint bindings of the model it does not apply.
`overrides` (the
generator's hand-override manifest) and `hand_srcs` (the hand-written
modules owning the operations it names, copied into the package) each
require the other. `deps` is required and non-empty, and nothing is added
to it. Every refusal of the rule is at analysis; the scan's failure is in
the build, as a welded test's. The module docstring of
[`../cloud/aws.bzl`](../cloud/aws.bzl) has the details;
[`tests//functional/mojo_aws_client`](../tests/functional/mojo_aws_client/BUCK),
[`tests//functional/aws_client_mode`](../tests/functional/aws_client_mode/BUCK)
(client mode),
[`tests//negative/mojo_aws_client`](../tests/negative/mojo_aws_client/BUCK) and, for
endpoint rulesets,
[`../proto-codegen/aws_endpoint_rules`](../proto-codegen/aws_endpoint_rules/BUCK)
exercise it.

## C-ABI shared libraries

`mojo_shared_lib` builds `<out_name>.so` (`.dylib` on macOS) straight from a file of `@export ... abi("C")`
functions (`main`, or the one entry of `srcs`) over the closure of `deps`. It has no
generated entry file and no `komira_main`; that is `mojo_binary[shared]`.

- **`out_name`** is the file name without a forced `lib` prefix (`komira.so`); DT_SONAME is the same name.
- **`deps`** takes Mojo packages and C/C++ libraries, as everywhere. **`force_load`** names C/C++
  libraries linked whole (`--whole-archive`): every object of their archives is in the library, referenced or not.
- **The gate.** The library is built as `ungated/<out_name>.so`. The gate stages it as the one data
  file of each driver and runs them: a generated driver that `dlopen`s it (`RTLD_NOW`, so an unresolved
  symbol fails there) and fails unless every symbol in **`exports`** resolves, plus each **`gate_srcs`**
  Mojo main, which `dlopen`s `./<out_name>.so` and calls into it. The published `<name>/<out_name>.so`
  is a copy that takes every driver's PASS marker as an input, so it exists only if they all passed.
  `exports` may not be empty. `[ungated]` is files only, for diagnosis.
- **`exports_exact`** (default off). Off, the dynamic symbol table also carries the symbols of static C
  dependencies (a C function a Mojo export calls is visible to every consumer). On, a version script makes
  `exports` the whole table. A twin pair shows both: `examples/shared_lib:spike_exact` passes its driver and
  `tests//negative/shared_lib:leaks_by_default` goes red on the same driver.
- **Not self-contained.** The `.so` has `DT_NEEDED libKGENCompilerRTShared.so`, the Mojo runtime (async runtime,
  allocator, globals), which the compiler's link adds to every Mojo binary and shared library; it is not linked
  statically by this rule. The `.so` loads only where that library, and what it needs
  (`libMSupportGlobals.so`, `libAsyncRTRuntimeGlobals.so`, libstdc++, libgcc_s), resolves: the run path is
  `$ORIGIN/lib`, so a packaged copy must ship them in `lib/` beside it (the runnable directory of a binary
  carries the same set). Whoever publishes the `.so` must ship or relocate those libraries.
- **macOS arm64.** The same rule builds `<out_name>.dylib`: install name `@rpath/<out_name>.dylib`, run path
  `@loader_path/lib`, linker-signed ad hoc by ld (nothing else signs it), runtime library
  `@rpath/libKGENCompilerRTShared.dylib`. `exports_exact` uses `-exported_symbols_list` (names with the C
  underscore) and `force_load` uses one `-force_load` per archive of the C libraries' link line. A driver
  opens `./<out_name>.dylib` there: pick the name with `CompilationTarget.is_macos()`. The gate runs
  on the macOS worker with `DYLD_LIBRARY_PATH` set to the compiler's `lib/` (as for tests). The wrapper
  lets `--emit shared-lib` through only when the link names itself with `-install_name`; the
  bundle's `-soname` library stays refused (bundles are Linux only).
- **Run path.** `$ORIGIN/lib`, where a packaged copy puts the runtime libraries.
- **Not yet:** consuming a `.so` from a `deps` edge (a consumer linking it, or generating its `@extern` declarations).

## C and C++

C and C++ code is built with the prelude's own `cxx_library` rule, using
`toolchains//:cxx` (declared by `komira_cxx_toolchains` in
[`../toolchains/defs.bzl`](../toolchains/defs.bzl)): zig's clang (from the
pinned zig) for `x86_64-linux-gnu.2.34`, `x86-64-v3`, every object
position-independent and compiled with `-g0`. Compiles and archives run on
the linux execution platform. The toolchain names no host tool: `zig_cc_launcher`
([`tools/zig_cc_launcher.zig`](tools/zig_cc_launcher.zig), built by a remote
action like `conda_unpack`) runs zig after expanding the nested argument files
the prelude writes, which zig itself refuses. The prelude's Python helper
tools, `nm`, `objcopy` and `strip` are not provided; the features using them
(dependency files, header maps, thin LTO, stripping) are off, and reaching one
fails with `cxx toolchain: <tool> is not provided`.
`toolchains//:python_bootstrap` exists only because configuring a
`cxx_library` names it; it has no interpreter.
`toolchains//:cxx_no_default_deps` is an alias of `:cxx`: the prelude's C/C++
rules take their toolchain from a select whose other branch names it, which no
configured build takes but an unconfigured query (`buck2 uquery deps(...)`)
follows; `:cxx` adds no default deps, so the variant without them is `:cxx`.
A repository with its own C/C++ toolchain keeps it, declares its own
`:cxx_no_default_deps`, and passes `omit = ["cxx"]` to `komira_toolchains`.

A Mojo target lists C/C++ libraries in `deps` next to Mojo packages. A dep
providing `MergedLinkInfo` (any `cxx_library`) is linked, statically, into
every executable with that target in its closure: a `mojo_library` passes its
C deps on to its consumers and to its own gated tests. A dep providing neither
`MojoInfo` nor `MergedLinkInfo` is refused. The link arguments go at the end of
the link line, after the compiler's own objects. Each C library is an archive, and the
linker pulls a member of one in only for a symbol still undefined, so a
second definition of a symbol is reported only if its object is pulled in
for some other symbol; otherwise the first definition wins silently, and two
libraries that no executable links together are never compared. The
one-definition gate,
[`komira//tools/build/one_definition:one_definition`](../one_definition/BUCK),
links every library under `src/` whole and fails on such a symbol. C++ code links zig's libc++
statically: its `cxx_library` lists
`komira//tools/build/toolchains:libcxx` in `exported_deps`.
A C or C++ source read from the project tree is an input of the remote
compile at its project path, which depends on where a repository mounts the
komira cell, and the compiler records that path in the object. komira's own
`cxx_library` targets therefore name their sources, and headers not produced
by an action, through `staged_files` ([`cxx.bzl`](cxx.bzl)), which copies
them into buck-out, so the C actions and the Mojo links using them keep one
digest in every consumer (test 7). A repository's own C code, mounted at one
place, does not need it.
[`../examples/cshim`](../examples/cshim) calls C from Mojo.

zig's libc++ and libc++abi are linked statically. The Mojo runtime itself
loads `libstdc++.so.6`, so a binary may hold both runtimes; it exports no
dynamic symbol, so neither can interpose on the other (test 20, on the snappy
example). Memory or exceptions must not cross between C++ code and the Mojo
runtime's C++ internals.

`archive_files` ([`archive.bzl`](archive.bzl)) takes named files out of a
pinned source archive, with CMake-style template substitution, for
third-party code built from source: see
[`third_party/snappy`](../../../third_party/snappy) (snappy 1.2.2, called from
Mojo in [`../examples/snappy`](../examples/snappy)). With `one_tree = True`
its output is one directory holding every file at its archive path, for code
that includes its own headers by relative path; `tree_dirs` names directories
of it for `-I$(location ...)`.

[`third_party/aws-lc`](../../../third_party/aws-lc) (libcrypto 1.39.0, not
FIPS, linux x86_64) and [`third_party/s2n-tls`](../../../third_party/s2n-tls)
(1.5.6, over that libcrypto) are built from their archives without their CMake
builds. Their source and header lists (`srcs.bzl`) are generated from the
archive's CMake lists by the Mojo tool
[`third_party_srcs`](../third_party_srcs/) (`//third_party/<lib>:srcs_gen`; the
test `:srcs_drift` fails when they differ); s2n-tls's
feature defines are `features.bzl`, the probes that pass. Test 26 holds
both to the archives and to a compile of every probe, and runs known-answer
tests ([`../examples/aws_lc`](../examples/aws_lc)) and a TLS 1.3 handshake
([`../examples/s2n_tls`](../examples/s2n_tls)) from Mojo. The aarch64
assembly lists are generated but not built yet.

aws-lc, s2n-tls and snappy are built with their global symbols renamed:
`komira_awslc_*`, `komira_s2n_*` and `komira_snappy_*` (snappy's C API), so
Mojo code calls `external_call["komira_awslc_SHA256", ...]`. The renaming is a
generated header each library force-includes, and a symbol check gates
every build that links the library; see [`../native`](../native/README.md).

## Coverage builds

`-c komira.coverage=true` (default `false`) gives every `mojo_library` on
linux-x86_64 a coverage build: each test (its `test_srcs`, its README's
examples and the `mojo_test` targets it names in `coverage_tests`) built at
-O0 with line tables and run under kcov, its branch coverage, and the gate
that its conda package waits for; and every `mojo_shared_lib` its drivers'
runs and a reported (never enforced) gate. Every release action stays as it is. The
rules, sub-targets, scope and fixtures are in [coverage.md](coverage.md).

## Errors

| message | from | meaning |
|---|---|---|
| `GATED TEST FAILED: <label> (exit N)` | [`gate_runner.sh`](gate_runner.sh) | a `test_srcs` test (or `buck2 test` of a `mojo_test`) failed |
| `COVERAGE GATE FAILED (<mode>): <package> (<label> [coverage gate]): covcheck gate exited 3` | [`cov_gate.sh`](../coverage/cov_gate.sh) | with coverage on, the library's coverage gate in enforce mode found something (its summary follows: below the target, not measured, a file no test compiled, branch not measured, ...), or in any mode the package is under its floor (`Regression`, [The ratchet](../coverage/README.md#the-ratchet)); the conda package (`<name>_conda`) is not produced, while the library and its dependents still build ([The build gate](../coverage/README.md#the-build-gate)) |
| `COVERAGE GATE ERROR: <package> (<label> [coverage gate]): covcheck exited N` | [`cov_gate.sh`](../coverage/cov_gate.sh) | covcheck refused the gate's inputs (an unmapped report path, a source it cannot read: exit 1) or its command line (exit 2), in any mode; its message is above |
| `COVERAGE RUN FAILED: <label> [coverage]` | [`cov_run.sh`](../coverage/kcov/cov_run.sh) | a coverage run failed: the test failed under kcov (with its exit status, after its output), it left processes running or did not finish within the run's limit (450 s), kcov could not trace it or failed itself, the binary names the library's sources by another directory than the run stages, or its report was missing or refused by `cov_normalize` ([cov_run](../coverage/kcov/README.md#cov_run)) |
| `<name>_cov_gate: coverage_tests of <lib>: <test> does not name <lib> in its deps` (or `cannot run under kcov: ...`, `is not a mojo_test with a coverage build`) | [`coverage.bzl`](coverage.bzl) | with coverage on, a library's `coverage_tests` names a test that does not depend on it, has `args` or a generated main, or is not a `mojo_test` ([Coverage builds](#coverage-builds)) |
| `<target>: tests_known_failing was removed: every welded test must pass` | [`defs.bzl`](defs.bzl) | a `mojo_library` call names `tests_known_failing`; delete it and make the test pass |
| `<target>: test_data[<entry>]: not a test_srcs entry` | [`defs.bzl`](defs.bzl) | a `test_data` key names no test; fix the path or delete the key |
| `<target>: ... data destination <d> ...` | [`test_runtime.bzl`](test_runtime.bzl) | a data destination is absolute, has an empty, `.` or `..` segment, or is also the directory of another destination |
| `<target>: ... env sets <NAME>, which the test runner sets itself` | [`test_runtime.bzl`](test_runtime.bzl) | `test_env`/`env` names a variable the runner owns |
| `mojo-watchdog: killed deadlocked compiler after <n>s of zero process-tree CPU` (exit 124) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | the compile's process tree used no CPU for `watchdog_idle_secs`; retry the action |
| `mojo_wrapper: REFUSING: toolchain member '<m>' is missing or empty` (exit 2) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | the unpacked toolchain lacks a file its `CLOSURE_MANIFEST` lists; nothing falls back to the worker ([test 4](../tests/README.md#4-closure-refusal)) |
| `mojo_wrapper: <output> contains this action's working directory` (exit 4) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | a compile output embeds a machine-specific path |
| `mojo_wrapper: compiler exited 0 but <output> is missing or empty` (exit 3) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | the compiler reported success without writing its output |
| ``[komira] coverage = "<v>": it must be `true` or `false` (default false)`` | [`coverage.bzl`](coverage.bzl) | the coverage switch has another value; it fails at load rather than reading a typo as off |
| `cov_zig: ... has debug sections but holds the working directory (...) nowhere` | [`cov_zig.zig`](../coverage/kcov/cov_zig.zig) | a coverage link's debug info holds neither spelling of the working directory: zig's C runtime units (the only ones that record a directory) record one the relocation was not given, so the binary would differ by machine, or have no debug info |
| `cov_zig: a link with the optimization level <level> is refused` | [`cov_zig.zig`](../coverage/kcov/cov_zig.zig) | a coverage link at a release level, where lld would merge string tails the relocation cannot see |
| `cov_zig: debug_relocate refused <output>` | [`cov_zig.zig`](../coverage/kcov/cov_zig.zig) | the relocation refused a coverage link's output (a longer name starting with the directory, a compressed section); its own message follows |
| `run_check: stdout of <binary> differs from <expected>` | [`run_check.sh`](run_check.sh) | `[run_check]` output did not match `expected_stdout` |
| ``<target>: test_assert_level `<v>` is not one of none, warn, safe, all`` (or `assert_level`) | [`defines.bzl`](defines.bzl) | an assert level Mojo's `debug_assert` does not read |
| ``<target>: test_defines sets ASSERT; set `test_assert_level` instead`` (or `defines`, `assert_level`) | [`defines.bzl`](defines.bzl) | the assert level is its own attribute |
| `<target>: defines entry "<e>" is not NAME or NAME=VALUE with NAME an identifier`, `... sets <NAME> twice` | [`defines.bzl`](defines.bzl) | a define the compiler would misread, or two values for one name |
| `<target>: test_memory_cap_mib is <n>; it must be a number of MiB, or 0 for no cap` | [`defines.bzl`](defines.bzl) | a negative cap |
| `MEMORY CAP: killed <label> at <n> MiB resident, over its cap of <cap> MiB` | [`mem_cap.sh`](mem_cap.sh) | the test's resident memory passed its memory cap and it was killed (after `GATED TEST FAILED: <label> (exit 137)`) |
| `TEST TIME LIMIT: killed <label> after <n> s, under the test runner's timeout of <m> s (komira.test_timeout_s)` | [`test_deadline.sh`](test_deadline.sh) | `buck2 test` of a `mojo_test` ran to 60 s short of the test runner's timeout and was killed (after `GATED TEST FAILED: <label> (exit 137)`); see [Time limits](#time-limits) |
| `[komira] test_timeout_s = <v> is not a whole number of seconds` / `must be over 60 s` | [`test_limit.bzl`](test_limit.bzl) | the root `.buckconfig` (or `-c`) states a test timeout a `mojo_test` cannot be limited under |
| `<target>: dep <dep> provides neither MojoInfo (a Mojo package) nor MergedLinkInfo (a C/C++ library)` | [`defs.bzl`](defs.bzl) | a `deps` entry is neither a `mojo_library` nor a C/C++ library |
| `cxx toolchain: <tool> is not provided` | [`cxx.bzl`](cxx.bzl) | a `cxx_library` reached a prelude feature that needs a host tool the toolchain does not provide |
| `mojo_doc_json: <target>: the JSON differs from its golden <file>` | [`doc.bzl`](doc.bzl) | the library's `mojo doc` JSON changed; if on purpose, replace the golden with `[raw]` |
| ``mojo_doc_json: <target>: the JSON declares no `<path>` `` | [`doc.bzl`](doc.bzl) | a `symbols` entry names no declaration of the JSON (or a private one, which `mojo doc` leaves out) |
| `unable to locate module '<pkg>'` | the compiler | the importing target does not list that package in `deps` |

## Not yet supported

Test helper modules inside the package (each gated
test is built from its one file against the library and its `test_deps`); extra compile flags or include roots; defines and an
assert level on `mojo_shared_lib`, on a package's `mojo precompile` or on a README's examples; shared C libraries (C
deps link statically); choosing the package root (the shallowest `__init__.mojo`
in `srcs` is the root).
