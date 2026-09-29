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

## Errors

| message | from | meaning |
|---|---|---|
| `GATED TEST FAILED: <label> (exit N)` | [`gate_runner.sh`](gate_runner.sh) | a `test_srcs` test (or `buck2 test` of a `mojo_test`) failed |
| `mojo_wrapper: REFUSING: toolchain member '<m>' is missing or empty` (exit 2) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | the unpacked toolchain lacks a file its `CLOSURE_MANIFEST` lists; nothing falls back to the worker ([check 4](../checks/README.md#4-closure-refusal)) |
| `mojo_wrapper: <output> contains this action's working directory` (exit 4) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | a compile output embeds a machine-specific path |
| `mojo_wrapper: compiler exited 0 but <output> is missing or empty` (exit 3) | [`mojo_wrapper.sh`](mojo_wrapper.sh) | the compiler reported success without writing its output |
| `run_check: stdout of <binary> differs from <expected>` | [`run_check.sh`](run_check.sh) | `[run_check]` output did not match `expected_stdout` |
| `numa_guard: REFUSING to run: ...` (exit 3) | [`numa_guard.sh`](numa_guard.sh) | a multi-NUMA run landed on a worker it can use fewer than `numa_nodes` NUMA nodes of |
| `unable to locate module '<pkg>'` | the compiler | the importing target does not list that package in `deps` |

## Not yet supported

A `data` attribute for test fixtures (a gated test runs with the action root
as its working directory); test helper modules or test-only deps (each gated
test is built from its one file against the library); holding a known-failing
test; extra compile flags, defines, include roots, or C libraries to link; a
compile watchdog; choosing the package root (the shallowest `__init__.mojo`
in `srcs` is the root); a gated library test that needs more than one NUMA
node (see [Multi-NUMA tests](#multi-numa-tests)).
