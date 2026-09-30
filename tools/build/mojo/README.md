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
| `mojo_library(srcs, deps, test_srcs, import_name, test_optimization_level)` | `<name>.mojoc` via `mojo precompile`. Each file in `test_srcs` is built against the package and run; the package is published only if every one passes. `[ungated]` is the package file before its tests; it carries no `MojoInfo`, so it cannot be named in `deps`. | [`hellopkg`](../examples/BUCK), [`libgate_ok`](../examples/libgate_ok/BUCK) |
| `mojo_binary(srcs, deps, main, optimization_level, expected_stdout)` | an executable via `mojo build`, and `RunInfo` for `buck2 run`. `[runnable]` is the binary together with its runtime libraries. `[run_check]` runs it remotely and, with `expected_stdout`, fails unless its stdout matches exactly. `[shared]` is the same program as `lib<name>.so`, for a bundle (see [Packaging](../package/README.md)). | [`hello`, `hello_pkg_user`](../examples/BUCK) |
| `mojo_test(srcs, deps, main, optimization_level, labels)` | a test executable for `buck2 test`; `buck2 run` and `[runnable]` as for `mojo_binary`. | [`test_hellopkg`](../examples/BUCK) |

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
- **Holding a known-failing test: `tests_known_failing`.** A red test that
  must not block the library's closure is held by a row
  `{"<test_srcs path>": {"issue": "<n>, #<n> or its GitHub issue URL", "reason": "..."}}`.
  The hold inverts rather than mutes: the held test still builds and runs in
  the gate, and its marker (`HELD <label>`) is produced only if it FAILS. A
  held test that passes is red, `LEDGER STALE`, naming the row to delete; an
  unheld failing test is still `GATED TEST FAILED`. A held test killed by
  SIGKILL (exit 137, what a memory limit delivers) has NO VERDICT: its action
  fails without a marker, so an executor can retry it with more memory
  instead of caching a too-small machine's kill as the held failure. Refused
  at analysis: a key that is not a `test_srcs` entry, any field besides
  `issue` and `reason`, a missing or malformed issue (a GitHub issue number or
  URL, nothing else), an empty reason, two rows with byte-identical reasons, and holding every test
  ([`tests/functional/known_failing`](../tests/functional/known_failing/BUCK)).
- **`test_srcs`, not `tests`**: Buck2 reserves `tests`. `buck2 test` on a
  `mojo_library` therefore runs nothing; its tests run when the library (or
  anything depending on it) is built.

Output layout of a library `L` with import name `I`:

```
L/ungated/I.mojoc   the compiler's output (sub-target [ungated])
L/pkg/I.mojoc       the public package, gated on every test's PASS marker
L/src/I/...         the staged package sources
L/tests/<t>/...     one binary and one PASS marker per test
```

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
  own shell, so a name the runner uses internally (`HELD`, `BIN`, `rc`)
  reaches the test and cannot change the verdict
  ([`tests//functional/test_data:runner_cases`](../tests/functional/test_data/runner_cases.sh)).
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

`mojo_proto_library(name, srcs, deps, proto_deps, import_prefix, bundle_proto_deps)`
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
`.proto` files). A generated package has no tests of its own (no
`test_srcs`): it is gated only through the tests of the libraries and
binaries that depend on it. Generation is deterministic, checked by
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
names `.proto` files that others import but no Mojo is generated from.

The toolchain, `toolchains//:mojo_proto` (declared by
`komira_proto_toolchains()`, see [toolchains](../toolchains/README.md)), is protoc
29.1 (the sha256-pinned static release build, with its well-known-type
`.proto` files) and `komira//tools/build/proto-codegen:protoc-gen-mojo` and
`:protoc-gen-mojo-db`, built from source with the [Rust rules](../rust/README.md) against the
crates in `third_party/rust`. The plugin crate, `komira_proto_codegen`, is
in [`../proto-codegen/`](../proto-codegen/);
[`tests//functional/proto`](../tests/functional/proto/BUCK) holds the example protos and tests.

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
`cxx_library` names it; it has no interpreter. A repository with its own
C/C++ toolchain keeps it and passes `omit = ["cxx"]` to `komira_toolchains`.

A Mojo target lists C/C++ libraries in `deps` next to Mojo packages. A dep
providing `MergedLinkInfo` (any `cxx_library`) is linked, statically, into
every executable with that target in its closure: a `mojo_library` passes its
C deps on to its consumers and to its own gated tests. A dep providing neither
`MojoInfo` nor `MergedLinkInfo` is refused. The link arguments go at the end of
the link line, after the compiler's own objects. C++ code links zig's libc++
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

## Errors

| message | from | meaning |
|---|---|---|
| `GATED TEST FAILED: <label> (exit N)` | [`gate_runner.sh`](gate_runner.sh) | a `test_srcs` test (or `buck2 test` of a `mojo_test`) failed, and it is not held by `tests_known_failing` |
| `LEDGER STALE: <label> PASSED, but it is held as known-failing.` | [`gate_runner.sh`](gate_runner.sh) | a test held by `tests_known_failing` passed; delete its row |
| `<target>: test_data[<entry>]: not a test_srcs entry` | [`defs.bzl`](defs.bzl) | a `test_data` key names no test; fix the path or delete the key |
| `<target>: ... data destination <d> ...` | [`defs.bzl`](defs.bzl) | a data destination is absolute, has an empty, `.` or `..` segment, or is also the directory of another destination |
| `<target>: ... env sets <NAME>, which the test runner sets itself` | [`defs.bzl`](defs.bzl) | `test_env`/`env` names a variable the runner owns |
| `mojo-watchdog: killed deadlocked compiler after <n>s of zero process-tree CPU` (exit 124) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | the compile's process tree used no CPU for `watchdog_idle_secs`; retry the action |
| `mojo_wrapper: REFUSING: toolchain member '<m>' is missing or empty` (exit 2) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | the unpacked toolchain lacks a file its `CLOSURE_MANIFEST` lists; nothing falls back to the worker ([test 4](../tests/README.md#4-closure-refusal)) |
| `mojo_wrapper: <output> contains this action's working directory` (exit 4) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | a compile output embeds a machine-specific path |
| `mojo_wrapper: compiler exited 0 but <output> is missing or empty` (exit 3) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | the compiler reported success without writing its output |
| `run_check: stdout of <binary> differs from <expected>` | [`run_check.sh`](run_check.sh) | `[run_check]` output did not match `expected_stdout` |
| `<target>: dep <dep> provides neither MojoInfo (a Mojo package) nor MergedLinkInfo (a C/C++ library)` | [`defs.bzl`](defs.bzl) | a `deps` entry is neither a `mojo_library` nor a C/C++ library |
| `cxx toolchain: <tool> is not provided` | [`cxx.bzl`](cxx.bzl) | a `cxx_library` reached a prelude feature that needs a host tool the toolchain does not provide |
| `unable to locate module '<pkg>'` | the compiler | the importing target does not list that package in `deps` |

## Not yet supported

Test helper modules or test-only deps (each gated
test is built from its one file against the library); extra compile flags, defines, or include roots; shared C libraries (C
deps link statically); choosing the package root (the shallowest `__init__.mojo`
in `srcs` is the root).
