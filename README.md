# komira

## Building

The build uses [Buck2](https://buck2.build) with remote execution. Every
action -- unpacking the toolchain, compiling, and running tests -- runs on a
remote-execution service that speaks the Bazel Remote Execution API (for
example Buildbarn). Nothing is compiled on your machine.

### 1. Get buck2

The pinned release is **2026-09-15**. `tools/buck2` is a
[dotslash](https://dotslash-cli.com) file that fetches and verifies it:

```sh
tools/buck2 --version
```

Without dotslash, download the release asset for your platform from
<https://github.com/facebook/buck2/releases/tag/2026-09-15>, check it against
the sha256 in `tools/buck2`, and decompress it with `zstd -d`. The prelude is
the one bundled with that binary.

### 2. Point it at your remote-execution service

```sh
cp .buckconfig.local.example .buckconfig.local   # gitignored
```

Fill in the `[buck2_re_client]` addresses and, under `[komira_re]`, the
exact platform property set of each kind of Linux x86_64 worker (see
[Execution platforms](#execution-platforms)): `light_properties` and
`mojo_compile_properties` (for example `pool=light` and `pool=mojo`; both may
name the same set), and optionally `mojo_compile_multi_numa_properties`.

`.buckconfig` caps each batched CAS request at 1 MiB
(`[buck2_re_client] max_total_batch_size`); larger blobs use ByteStream.
Without it buck2 packs up to 4000000 bytes into one BatchReadBlobs request
when the server does not advertise a lower limit, which a server with a
2 MiB gRPC message limit rejects ("Attempted to read a total of at least N
bytes, while a maximum of 2097152 bytes is permitted"). The setting takes
effect when the buck2 daemon starts; run `buck2 kill` after changing it.

### 3. Build

`buck2` below is either a `buck2` on your `PATH` or `tools/buck2`;
`checks/run_checks.sh` falls back to `tools/buck2` when none is on `PATH`
(`BUCK2=...` overrides both).

```sh
buck2 build //...                                  # examples: packages, binaries, gated library
buck2 build '//examples:hello_pkg_user[run_check]' # run a binary remotely, compare its stdout
buck2 run //examples:hello                         # build remotely, run here (Linux x86_64)
buck2 test //examples:test_hellopkg                # a standalone Mojo test, run remotely
checks/run_checks.sh                               # end-to-end checks, including the negative ones
```

The `checks` cell holds fixtures that must fail (a library whose test fails, a
binary missing a dependency, an incomplete toolchain). They are outside
`//...` and are exercised by `checks/run_checks.sh`.

## Mojo rules

`load("@mojo//:defs.bzl", "mojo_library", "mojo_binary", "mojo_test", "mojo_multi_numa_test")`

| rule | produces |
|---|---|
| `mojo_library(srcs, deps, test_srcs)` | `<name>.mojoc` via `mojo precompile`. Each file in `test_srcs` is built against the package and run; the package is published only if every one passes. `[ungated]` is the package file before its tests; it carries no `MojoInfo`, so it cannot be named in `deps`. |
| `mojo_binary(srcs, deps, main, expected_stdout)` | an executable via `mojo build`, and `RunInfo` for `buck2 run`. `[runnable]` is the binary together with its runtime libraries. `[run_check]` runs it remotely and, with `expected_stdout`, fails unless its stdout matches exactly. `[shared]` is the same program as `lib<name>.so`, for a bundle (see Packaging). |
| `mojo_test(srcs, deps)` | a test executable for `buck2 test`; `buck2 run` and `[runnable]` as for `mojo_binary`. |
| `mojo_multi_numa_test(binary, expected_stdout)` | runs `binary` (a `mojo_binary` or `mojo_test`, compiled by its own target) on a worker spanning more than one NUMA node. Building it runs the binary like `[run_check]`; `buck2 test` runs it like a `mojo_test`. Fails to configure when no execution platform provides `numa_multi`. |

`deps` carries the full transitive closure of packages to the compiler, one
`-I` directory per package. The import name (the label name, or
`import_name`) must be a Mojo identifier.

Gated tests are declared with `test_srcs`, not `tests`: Buck2 reserves
`tests`. `buck2 test` on a `mojo_library` therefore runs nothing; its tests
run when the library (or anything depending on it) is built.

**Outputs.** Every compile targets the toolchain's `target_cpu`
(`x86-64-v3`), not the CPU of the worker that ran it. Linked binaries carry
one run path, DT_RUNPATH `$ORIGIN/lib`, and no debug sections, and every
compile action fails (exit 4) if its output contains the action's working
directory. The compiler records source file names in a linked program (for
error locations); they are recorded relative to the package (`hello.mojo`),
not as paths inside the action.

**Running.** A built binary loads a few shared libraries from the toolchain
(`toolchains//:mojo_runtime`: the Mojo runtime and the pinned C++ runtime,
about 24 MB). The runnable directory of a binary holds the binary and a copy
of those libraries in `lib/`, where its run path finds them, so it starts
from anywhere with no environment. `RunInfo` points at it, so `buck2 run`
downloads the binary and those libraries, never the compiler. `[run_check]`
runs the same command remotely with no library path set. The list of
libraries is checked against what the loader actually maps during a run.

**Not yet supported.** a `data` attribute for test fixtures (a
gated test runs with the action root as its working directory); test helper
modules or test-only deps (each gated test is built from its one file against
the library); holding a known-failing test; extra compile flags, defines,
include roots, or C libraries to link; a compile watchdog; choosing the
package root (the shallowest `__init__.mojo` in `srcs` is the root); a
gated library test that needs more than one NUMA node (see below). Gated tests build at `-O3` by
default (`test_optimization_level`).

Rules are loaded from one cell: a `.bzl` file's providers are distinct per
loading cell, so a Mojo target in one cell cannot depend on a Mojo library in
another. The `checks` cell therefore has its own fixtures rather than reusing
`examples`.

## Packaging

`load("@komira//package:defs.bzl", "mojo_bundle")`

```python
mojo_bundle(
    name = "hello_bundle",
    binary = ":hello",              # a mojo_binary
    version = "0.1.0",
    data = {"share/greeting.txt": "greeting.txt"},
)
```

A bundle is a directory holding a program and everything it needs besides
glibc (2.34 or later) and the kernel. Package formats are built from it.

```
bin/hello                                 launcher
lib/glibc-hwcaps/x86-64-v3/libhello.so    the program
lib/                                      Mojo runtime, C++ runtime
share/                                    data
VERSION                                   name, version, platform, CPU level
SHA256SUMS                                every other file
```

`bin/hello` is a small C launcher built for the baseline x86-64 ISA, so it
starts on any x86-64 CPU. It reads the CPU's x86-64 level the way glibc's
loader does (cpuid, and whether the OS saves the AVX and AVX-512 registers).
Below the level the program was compiled for (the toolchain's `target_cpu`)
it prints one line and exits 1, before loading anything:

```
hello requires an x86-64-v3 CPU (Haswell or newer)
```

Otherwise it loads `libhello.so` by name. The loader looks in the launcher's
run path, `$ORIGIN/../lib`, and in the `glibc-hwcaps/x86-64-v<N>/`
directories under it that the CPU supports, so builds for other levels can
sit next to this one. The launcher then calls the program's C entry point
`komira_main`, which runs `main` through the same standard-library function a
Mojo executable uses: arguments, environment, output and exit status are
those of the executable (checks//bundle_parity compares the two).
`lib<name>.so` has run path `$ORIGIN/../..`, the bundle's `lib/`. Every run
path is relative to its file, so the bundle runs from wherever it is copied
and through a symlink. A program finds its data through `/proc/self/exe`:
`<its directory>/../share`.

The bundle is built by copying files with fixed modes (0755 for `bin/`,
0644 otherwise); `VERSION` holds no time or revision, so the same sources
give the same bytes (checked across two uncached builds).

`[test_launcher]` is the launcher built with a test hook: it judges the
made-up CPU named by `$KOMIRA_TEST_CPU` (see `package/launcher/cpu_models.h`)
instead of the real one. It exists for checks and is never part of a
bundle; the shipped launcher has no override.

A program built as `[shared]` is compiled from a generated file next to its
main module, which imports `main` from it; the main module's file name must
therefore be a Mojo identifier. Only linux x86_64 bundles are built today.

### Package formats

Each format is a rule over a bundle that produces files; nothing is pushed
or published by the build.

```python
load("@komira//package:defs.bzl", "bundle_tarball", "oci_image")

bundle_tarball(name = "hello_tarball", bundle = ":hello_bundle")
oci_image(name = "hello_image", bundle = ":hello_bundle", repository = "komira/hello")
```

- `bundle_tarball` writes `hello-0.1.0-linux-x86_64.tar.gz`, the bundle under
  `hello-0.1.0/`.
- `oci_image` writes an OCI image layout directory (`hello_image.oci/`): the
  layers of a base image, then one layer holding the bundle at `/opt/hello/`,
  with entrypoint `/opt/hello/bin/hello` and platform linux/amd64.
  `[docker_archive]` is the same image as one tar for `docker load`, and
  `[digest]` a file holding the image manifest digest.

The base image is `toolchains//:distroless_base` (distroless base-debian12,
which has glibc, CA certificates and no shell), declared with `oci_base`: the
digest of its linux/amd64 manifest, that manifest's bytes checked in, and one
pinned download per blob. The packing action has no network access to need:
it reads only those files and refuses unless the manifest hashes to its
digest and names exactly the downloaded blobs.

Both formats are written by `komira_pack` (`package/pack/komira_pack.zig`), a
static executable built by the pinned zig and run with no shell. The bytes
depend only on the bundle and the base: tar entries are sorted, with
directories listed, mtime and uid/gid 0 and modes 0755/0644; gzip headers
carry no time; JSON keys are sorted and every timestamp is
1970-01-01T00:00:00Z. Two uncached builds give the same tarball and the same
image digest (checks/bundle.sh), and `docker run` of the loaded image prints
the greeting (checks/formats.sh).

## Execution platforms

`//platforms` declares two abstract execution constraints, and three
execution configurations built from them:

| configuration | constraints | runs |
|---|---|---|
| `exec-mojo` | `mojo_compile`, `numa_single` | Mojo compiles, gated library tests, run checks, `buck2 test` of a `mojo_test`; also any target that states no constraint |
| `exec-light` | `light` | unpacking and copying toolchain files (`toolchains//:zig`, `:conda_unpack`, `:mojo_compiler`, `:mojo_runtime`) |
| `exec-mojo-multi-numa` | `mojo_compile`, `numa_multi` | `mojo_multi_numa_test` only |

The Mojo rules get their constraints from their toolchain:
`toolchains//:mojo` states `mojo_compile` + `numa_single`, and
`toolchains//:mojo_multi_numa` (the private toolchain of
`mojo_multi_numa_test`) states `mojo_compile` + `numa_multi`. A toolchain's
`exec_compatible_with` binds every target that uses it.

`komira_execution_platforms` (`//platforms:defs.bzl`) registers one remote
execution platform per configuration, given the worker property set of each.
A standalone checkout reads those sets from `[komira_re]` in
`.buckconfig.local` (`//platforms/remote`); a repository mounting komira calls
the same macro with its own sets. Nothing committed here names a worker pool.
`buck2 audit execution-platform-resolution <target>` shows which
configuration a target got and why the others were skipped.

**Multi-NUMA runs.** `exec-mojo-multi-numa` is registered only when
`mojo_compile_multi_numa_properties` is set. Without it, a target requiring
`numa_multi` fails to configure (`Can't find toolchain_dep execution
platform`, with `exec-mojo` skipped because `numa_multi` is not satisfied),
before any action runs. A repository that sets it must point it at workers
that can each place a process across more than one NUMA node: every CPU and
all memory of at least two nodes visible to the action (no cpuset or memory
binding narrowing it to one node), with the same OS image and runtime floor
as the `mojo_compile` workers, since the binary it runs was built there.

The constraint is only a claim about those workers, so the hardware is
checked too. `komira_execution_platforms` fails if the multi-NUMA property
set equals the `mojo_compile` one. And every multi-NUMA run (the build's run
check and the `buck2 test` command) starts through `mojo/numa_guard.sh`,
which exits 3 with `numa_guard: REFUSING to run` unless the action can use
at least `numa_nodes` (default 2) NUMA nodes: online and with memory
(`/sys/devices/system/node`), in its own `Mems_allowed_list`, and holding a
CPU in its own `Cpus_allowed_list` (`/proc/<pid>/status`). A property set
that routes to a single-NUMA worker, or a worker narrowed to one node by a
cpuset, affinity mask or memory binding, goes red instead of green.

**One platform per target.** Buck2 chooses the execution platform per
target, not per action: a target's compiles, gated tests and run checks all
run on the same kind of worker. A run that needs a multi-NUMA worker is
therefore its own target. `mojo_multi_numa_test(binary = ":b")` runs the
binary `:b` built on `exec-mojo`, so only the run occupies a multi-NUMA
worker, and the compiler is not one of its inputs. A gated library test
(`test_srcs`) runs inside the library's target and so always on
`exec-mojo`. A library test that needs several NUMA nodes is declared as a
`mojo_test` plus a `mojo_multi_numa_test` over it; it is not welded into the
library's package, since that would need a platform per action. A gate that
publishes a package only after such a run would take the run's output as an
input of a separate publishing target.

**Two runtime surfaces.** `buck2 run`, `[run_check]` and
`mojo_multi_numa_test` start a binary from its runnable directory, whose
`lib/` holds only the libraries a run loads (`toolchains//:mojo_runtime`).
Gated library tests and `buck2 test` of a `mojo_test` still run the binary
with `LD_LIBRARY_PATH` set to the compiler's `lib/`, a superset. A test that
passes there can therefore load a library the runnable directory lacks; the
runtime-library check (`checks/run_checks.sh`) keeps the subset equal to what
a real run loads. Moving the gated tests onto the runnable directory would
change the command of every gated test action, and so their cache keys.

## Toolchain

`toolchains//:mojo` is built from three sha256-pinned downloads: the Mojo
compiler `.conda` package (1.0.0, linux-64), a static busybox, and zig 0.12.0.
Remote actions unpack them: busybox extracts zig, zig compiles
`mojo/tools/conda_unpack.zig`, and that static tool extracts the compiler
closure from the `.conda`. Every tool an action runs is one of its inputs;
actions never search the worker's `PATH`. The client's only work is
downloading the pinned files and uploading them to the remote cache.

**Host floor.** What an action still takes from the worker: a Linux x86_64
kernel (including `/proc` and `/dev/null`); a CPU implementing `x86-64-v3`
(AVX2, BMI2, FMA), since gated tests and run checks execute the code they
compile; and glibc 2.34 or newer (link steps target `x86_64-linux-gnu.2.34`):
the dynamic loader `/lib64/ld-linux-x86-64.so.2` with `libc.so.6`,
`libm.so.6`, `libdl.so.2` and `libpthread.so.0`. Nothing else. The C++
runtime the compiler and built binaries link against (`libstdc++.so.6`,
`libgcc_s.so.1`) is pinned by sha256 from conda-forge and unpacked into the
toolchain's `lib/`; the compiler finds it through its own `$ORIGIN/../lib`
run path, built binaries through their `$ORIGIN/lib` run path (or
`LD_LIBRARY_PATH`, which gated tests set). None of the floor is part of an
action key, so workers that differ in it must not share a remote cache.
`checks/run_checks.sh` enforces the floor: it reads the loader's own record
(`LD_DEBUG`) of a real compile and a run, and fails if either maps the C++
runtime from the worker, or any object from the worker that is not glibc's.

That check, together with `toolchains//:mojo_runtime` (which refuses a
library name missing from the toolchain), is what guards the C++ runtime pin.
The wrapper's exit-2 refusal does not: it checks the members listed in
`CLOSURE_MANIFEST`, and `conda_unpack` writes that list from what it
unpacked, so a toolchain built without the pin carries a manifest without
those names, and a worker's own `libstdc++.so.6` would satisfy the compiler.
The floor is measured on the compile and run of a hello-world program only;
a library the compiler loads lazily on another path (for example its Python
interop) is not traced. The runtime libraries keep their vendor `DT_RPATH`
entries; `checks/run_checks.sh` requires every run path in a runnable
directory's `lib/` to be `$ORIGIN`-relative, so an absolute one arriving with
an upstream update fails the checks.
`buck2 build checks//re_probe:probe` records what a worker provides.

The client only downloads the pinned files and uploads them; on macOS
(`tools/buck2` has a macos-aarch64 entry) buck2 works as a client, and every
action still runs on the Linux workers.

## Mounting komira in another repository

A larger repository can include komira as a git submodule and build it as a
set of cells, sharing remote cache entries with standalone checkouts: the same
targets, built at the same revision with the same buck2 release and worker
property set, have the same action digests in both.

```sh
git submodule add <komira-url> komira
komira/tools/umbrella_buckconfig.sh komira > .buckconfig
```

`tools/umbrella_buckconfig.sh` prints the cells komira declares, moved under
the mount point with their names unchanged, and copies `[cell_aliases]`,
`[external_cells]`, `[buildfile]`, `[parser]` and `[buck2_re_client]`. Buck2
registers cells only from the project root's `.buckconfig` (and does not
follow `<file:...>` includes there), so the outer repository has to restate
them; regenerate the output whenever the submodule moves. The mount path may
be nested (`checks/umbrella_cache.sh` builds at `komira` and at
`third_party/komira`). Then add the outer repository's own root cell and
execution platform. Buck2 merges repeated sections, so these can follow the
generated block in the same file as a second `[cells]` (the recipe above
overwrites `.buckconfig`; keep the outer repository's own part in a file you
append, or paste the generated block into a hand-maintained `.buckconfig`):

```
[cells]
  umbrella = .

[build]
  execution_platforms = umbrella//platforms:remote
```

```python
# platforms/BUCK in the outer repository
load("@komira//platforms:defs.bzl", "komira_execution_platforms")

komira_execution_platforms(
    name = "remote",
    light = {...},         # property set of the workers for `exec-light`
    mojo_compile = {...},  # ... for `exec-mojo`
    # mojo_compile_multi_numa = {...},  # only for workers spanning >1 NUMA node
    visibility = ["PUBLIC"],
)
```

The property sets may be written inline or read with
`re_properties("<key>")` from a `[komira_re]` section, as //platforms/remote
does. The generated `[buck2_re_client]` already carries
`max_total_batch_size = 1048576`; the outer repository adds only its
endpoints (in `.buckconfig` or `.buckconfig.local`) and must not raise that
value, since a server whose message limit is below buck2's default batch size
then fails `BatchReadBlobs`. Build komira targets as
`buck2 build komira//examples/...`.

**The outer repository's own targets need a target platform too.**
`target_platform_detector_spec` is a single key: an outer `[parser]` section
that sets it replaces komira's value, dropping komira's mappings, which
changes the configurations and so the action digests. Append the outer
repository's cells to the one generated line instead, leaving komira's
entries unchanged, e.g. `... target:umbrella//...->komira//platforms:linux-x86_64`.

What keeps the digests equal:

- **Cell names.** Output paths contain the cell name (`buck-out/v2/.../komira/...`),
  so every komira cell keeps its name in the outer repository. The mount path
  itself never reaches a command: sources enter actions through copies under
  `buck-out`.
- **Execution platform name.** `komira_execution_platforms` names each
  platform after the abstract configuration it realizes
  (`komira//platforms:exec-mojo`, ...), not after the target that declares it.
  That name keys the configuration of the toolchain, and so the toolchain's
  output paths. An execution platform declared some other way must do the
  same.
- **Target platform.** Every komira cell maps to
  `komira//platforms:linux-x86_64` in `[parser]`, copied unchanged.
  `//platforms` holds only abstract constraints; the standalone remote
  platform lives in `//platforms/remote`, which the outer repository never
  loads.
- **Worker properties.** They are part of every action digest, so the outer
  repository must give each configuration the same property set as the
  checkouts it wants to share a cache with.

`checks/umbrella_cache.sh` builds the examples in a fresh standalone clone and
then in a scratch umbrella repository mounting the working tree as a
submodule, each with a fresh daemon, and fails unless every umbrella command
is a cache hit and both builds report the same action digests.
