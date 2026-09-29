# Mojo rules

```python
load("@komira//tools/build/mojo:defs.bzl", "mojo_library", "mojo_binary", "mojo_test", "mojo_multi_numa_test")
```

The rules are in [`defs.bzl`](defs.bzl); their providers in
[`providers.bzl`](providers.bzl). Every action runs the hermetic toolchain
([`toolchains//:mojo`](../toolchains/README.md)) through
[`mojo_wrapper.sh`](mojo_wrapper.sh), which is where to read the environment
the compiler sees. Worked uses of each rule are in
[`../examples/BUCK`](../examples/BUCK), and fixtures that must fail are in
[`../checks/`](../checks/README.md).

| rule | produces | example |
|---|---|---|
| `mojo_library(srcs, deps, test_srcs, import_name, test_optimization_level)` | `<name>.mojoc` via `mojo precompile`. Each file in `test_srcs` is built against the package and run; the package is published only if every one passes. `[ungated]` is the package file before its tests; it carries no `MojoInfo`, so it cannot be named in `deps`. | [`hellopkg`](../examples/BUCK), [`libgate_ok`](../examples/libgate_ok/BUCK) |
| `mojo_binary(srcs, deps, main, optimization_level, expected_stdout)` | an executable via `mojo build`, and `RunInfo` for `buck2 run`. `[runnable]` is the binary together with its runtime libraries. `[run_check]` runs it remotely and, with `expected_stdout`, fails unless its stdout matches exactly. `[shared]` is the same program as `lib<name>.so`, for a bundle (see [Packaging](../package/README.md)). | [`hello`, `hello_pkg_user`](../examples/BUCK) |
| `mojo_test(srcs, deps, main, optimization_level, labels)` | a test executable for `buck2 test`; `buck2 run` and `[runnable]` as for `mojo_binary`. | [`test_hellopkg`](../examples/BUCK) |
| `mojo_multi_numa_test(binary, expected_stdout, numa_nodes, labels)` | runs `binary` (a `mojo_binary` or `mojo_test`, compiled by its own target) on a worker spanning more than one NUMA node. Building it runs the binary like `[run_check]`; `buck2 test` runs it like a `mojo_test`. Fails to configure when no execution platform provides `numa_multi`. | [`checks//numa:hello_multi_numa`](../checks/numa/BUCK) |

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
  ([`checks/missing_dep`](../checks/missing_dep/BUCK) fails to compile).
- **The gate.** Each file in `test_srcs` is built from that one file against
  the ungated package (at `test_optimization_level`, default `-O3`) and run;
  a failing test prints `GATED TEST FAILED: <label> (exit N)`. The public
  package `L/pkg/<I>.mojoc` is a copy of the ungated one that takes every
  test's PASS marker as an input, so it cannot exist unless every test passed,
  and neither can anything depending on it
  ([`checks/libgate_bad`](../checks/libgate_bad/BUCK): the library and its
  consumer go red, `[ungated]` builds, and a binary naming `[ungated]` in
  `deps` fails analysis).
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

## Binaries and tests

- **`main`**: the file holding `main()`. It defaults to the only file in
  `srcs`; with several, name it.
- **`optimization_level`**: default `3`.
- **`[run_check]`** (`mojo_binary`): runs the binary remotely from its
  runnable directory, with no library path set, and with `expected_stdout`
  compares its stdout byte for byte
  ([`examples/BUCK`](../examples/BUCK) `hello`, `hello_pkg_user`).
- **`buck2 run <target>`**: builds remotely and runs the binary on your
  machine (Linux x86_64) from its runnable directory, downloading the binary
  and its runtime libraries, never the compiler
  ([check 9](../checks/README.md#9-buck2-run)).
- **`buck2 test <mojo_test>`**: runs the test binary remotely through
  [`gate_runner.sh`](gate_runner.sh). `buck2 run` of a `mojo_test` runs its
  binary directly, from the runnable directory.

### Outputs and the runnable directory

Every compile targets the toolchain's `target_cpu` (`x86-64-v3`), not the CPU
of the worker that ran it. Linked binaries carry one run path, DT_RUNPATH
`$ORIGIN/lib`, and no debug sections, and every compile action fails (exit 4)
if its output contains the action's working directory
([check 6](../checks/README.md#6-outputs)).
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
([check 8](../checks/README.md#8-host-floor-and-runtime-libraries)).

**Two runtime surfaces.** `buck2 run`, `[run_check]` and
`mojo_multi_numa_test` start a binary from its runnable directory, whose
`lib/` holds only the libraries a run loads (`komira//tools/build/toolchains:mojo_runtime`).
Gated library tests and `buck2 test` of a `mojo_test` still run the binary
with `LD_LIBRARY_PATH` set to the compiler's `lib/`, a superset. A test that
passes there can therefore load a library the runnable directory lacks; the
runtime-library check keeps the subset equal to what a real run loads. Moving
the gated tests onto the runnable directory would change the command of every
gated test action, and so their cache keys.

## Multi-NUMA tests

```python
mojo_binary(name = "hello", srcs = ["hello.mojo"])

mojo_multi_numa_test(
    name = "hello_multi_numa",
    binary = ":hello",
    expected_stdout = "...",
)
```

Buck2 picks one execution platform per target, not per action: a target's
compiles, gated tests and run checks all run on the same kind of worker. A run
that needs a multi-NUMA worker is therefore its own target.
`mojo_multi_numa_test(binary = ":b")` runs the binary `:b` built on
`exec-mojo`, so only the run occupies a multi-NUMA worker, and the compiler is
not one of its inputs. Its toolchain (`toolchains//:mojo_multi_numa`) is
private and states `numa_multi`, so the requirement cannot be dropped from a
BUCK file.

Every run (the build's run check and the `buck2 test` command) starts through
[`numa_guard.sh`](numa_guard.sh), which exits 3 with
`numa_guard: REFUSING to run` unless the action can use at least `numa_nodes`
(default 2, minimum 2) NUMA nodes. What that means, and how the workers are
configured, is in
[platforms/README.md](../platforms/README.md#multi-numa-runs); the fixtures
are in [`checks/numa`](../checks/numa/BUCK)
([checks 10 and 11](../checks/README.md#10-execution-platforms)).

A gated library test (`test_srcs`) runs inside the library's target and so
always on `exec-mojo`. A library test that needs several NUMA nodes is
declared as a `mojo_test` plus a `mojo_multi_numa_test` over it; it is not
welded into the library's package, since that would need a platform per
action. A gate that publishes a package only after such a run would take the
run's output as an input of a separate publishing target.

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
`proto_deps` closure is generated into this package too. Sub-targets:
`[gen]` (the generated directory), `[<stem>.mojo]`, `[proto]` (the staged
`.proto` files). A generated package has no tests of its own (no
`test_srcs`): it is gated only through the tests of the libraries and
binaries that depend on it. Generation is deterministic, checked by
comparing two uncached builds
([check 23](../checks/README.md#23-protobuf)).

The toolchain, `toolchains//:mojo_proto` (declared by
`komira_proto_toolchains()`, see [toolchains](../toolchains/README.md)), is protoc
29.1 (the sha256-pinned static release build, with its well-known-type
`.proto` files) and `komira//tools/build/proto-codegen:protoc-gen-mojo`,
built from source with the [Rust rules](../rust/README.md) against the
crates in `third_party/rust`. The plugin crate, `komira_proto_codegen`, is
in [`../proto-codegen/`](../proto-codegen/);
[`checks//proto`](../checks/proto/BUCK) holds the example protos and tests.

## C and C++

C and C++ code is built with the prelude's own `cxx_library` rule, using
`toolchains//:cxx` (declared by `komira_cxx_toolchains` in
[`../toolchains/defs.bzl`](../toolchains/defs.bzl)): zig's clang (from the
pinned zig) for `x86_64-linux-gnu.2.34`, `x86-64-v3`, every object
position-independent and compiled with `-g0`. Compiles and archives run on
`exec-light`. The toolchain names no host tool: `zig_cc_launcher`
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
digest in every consumer (check 7). A repository's own C code, mounted at one
place, does not need it.
[`../examples/cshim`](../examples/cshim) calls C from Mojo.

zig's libc++ and libc++abi are linked statically. The Mojo runtime itself
loads `libstdc++.so.6`, so a binary may hold both runtimes; it exports no
dynamic symbol, so neither can interpose on the other (check 20, on the snappy
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
archive's CMake lists by
[`third_party/gen_srcs.py`](../../../third_party/gen_srcs.py); s2n-tls's
feature defines are `features.bzl`, the probes that pass. Check 25 holds
both to the archives and to a compile of every probe, and runs known-answer
tests ([`../examples/aws_lc`](../examples/aws_lc)) and a TLS 1.3 handshake
([`../examples/s2n_tls`](../examples/s2n_tls)) from Mojo. The aarch64
assembly lists are generated but not built yet.

## Errors

| message | from | meaning |
|---|---|---|
| `GATED TEST FAILED: <label> (exit N)` | [`gate_runner.sh`](gate_runner.sh) | a `test_srcs` test (or `buck2 test` of a `mojo_test`) failed |
| `mojo_wrapper: REFUSING: toolchain member '<m>' is missing or empty` (exit 2) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | the unpacked toolchain lacks a file its `CLOSURE_MANIFEST` lists; nothing falls back to the worker ([check 4](../checks/README.md#4-closure-refusal)) |
| `mojo_wrapper: <output> contains this action's working directory` (exit 4) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | a compile output embeds a machine-specific path |
| `mojo_wrapper: compiler exited 0 but <output> is missing or empty` (exit 3) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | the compiler reported success without writing its output |
| `run_check: stdout of <binary> differs from <expected>` | [`run_check.sh`](run_check.sh) | `[run_check]` output did not match `expected_stdout` |
| `numa_guard: REFUSING to run: ...` (exit 3) | [`numa_guard.sh`](numa_guard.sh) | a multi-NUMA run landed on a worker it can use fewer than `numa_nodes` NUMA nodes of |
| `<target>: dep <dep> provides neither MojoInfo (a Mojo package) nor MergedLinkInfo (a C/C++ library)` | [`defs.bzl`](defs.bzl) | a `deps` entry is neither a `mojo_library` nor a C/C++ library |
| `cxx toolchain: <tool> is not provided` | [`cxx.bzl`](cxx.bzl) | a `cxx_library` reached a prelude feature that needs a host tool the toolchain does not provide |
| `unable to locate module '<pkg>'` | the compiler | the importing target does not list that package in `deps` |

## Not yet supported

A `data` attribute for test fixtures (a gated test runs with the action root
as its working directory); test helper modules or test-only deps (each gated
test is built from its one file against the library); holding a known-failing
test; extra compile flags, defines, or include roots; shared C libraries (C
deps link statically); a compile watchdog; choosing the package root (the shallowest `__init__.mojo`
in `srcs` is the root); a gated library test that needs more than one NUMA
node (see [Multi-NUMA tests](#multi-numa-tests)).
