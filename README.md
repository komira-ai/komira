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

Fill in the `[buck2_re_client]` addresses and `[komira_re]
linux_x86_64_properties`, the exact platform property set your Linux x86_64
workers advertise (for example `pool=mojo`).

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

`load("@mojo//:defs.bzl", "mojo_library", "mojo_binary", "mojo_test")`

| rule | produces |
|---|---|
| `mojo_library(srcs, deps, test_srcs)` | `<name>.mojoc` via `mojo precompile`. Each file in `test_srcs` is built against the package and run; the package is published only if every one passes. `[ungated]` is the package file before its tests; it carries no `MojoInfo`, so it cannot be named in `deps`. |
| `mojo_binary(srcs, deps, main, expected_stdout)` | an executable via `mojo build`, and `RunInfo` for `buck2 run`. `[runnable]` is the binary together with its runtime libraries. `[run_check]` runs it remotely and, with `expected_stdout`, fails unless its stdout matches exactly. |
| `mojo_test(srcs, deps)` | a test executable for `buck2 test`; `buck2 run` and `[runnable]` as for `mojo_binary`. |

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
directory.

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
separate worker pool for non-compile actions. Gated tests build at `-O3` by
default (`test_optimization_level`).

Rules are loaded from one cell: a `.bzl` file's providers are distinct per
loading cell, so a Mojo target in one cell cannot depend on a Mojo library in
another. The `checks` cell therefore has its own fixtures rather than reusing
`examples`.

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
`[external_cells]`, `[buildfile]` and `[parser]`. Buck2 registers cells only
from the project root's `.buckconfig` (and does not follow `<file:...>`
includes there), so the outer repository has to restate them; regenerate the
output whenever the submodule moves. Then add the outer repository's own root
cell and execution platform:

```
[cells]
  umbrella = .

[build]
  execution_platforms = umbrella//platforms:remote
```

```python
# platforms/BUCK in the outer repository
load("@komira//platforms:defs.bzl", "re_properties", "remote_execution_platforms")

remote_execution_platforms(
    name = "remote",
    names = ["linux-x86_64"],
    constraints = ["komira//platforms:linux-x86_64"],
    properties = [re_properties("linux_x86_64_properties")],
    visibility = ["PUBLIC"],
)
```

plus `[buck2_re_client]` and `[komira_re] linux_x86_64_properties` in its own
`.buckconfig` or `.buckconfig.local`. Build komira targets as
`buck2 build komira//examples/...`.

What keeps the digests equal:

- **Cell names.** Output paths contain the cell name (`buck-out/v2/.../komira/...`),
  so every komira cell keeps its name in the outer repository. The mount path
  itself never reaches a command: sources enter actions through copies under
  `buck-out`.
- **Execution platform name.** `remote_execution_platforms` names each
  platform after the abstract platform it realizes
  (`komira//platforms:linux-x86_64`), not after the target that declares it.
  That name keys the configuration of the toolchain, and so the toolchain's
  output paths. An execution platform declared some other way must do the
  same.
- **Target platform.** Every komira cell maps to
  `komira//platforms:linux-x86_64` in `[parser]`, copied unchanged.
  `//platforms` holds only abstract constraints; the standalone remote
  platform lives in `//platforms/remote`, which the outer repository never
  loads.
- **Worker properties.** They are part of every action digest, so the outer
  repository must send the same `linux_x86_64_properties` as the checkouts it
  wants to share a cache with.

`checks/umbrella_cache.sh` builds the examples in a fresh standalone clone and
then in a scratch umbrella repository mounting the working tree as a
submodule, each with a fresh daemon, and fails unless every umbrella command
is a cache hit and both builds report the same action digests.
