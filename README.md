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

### 3. Build

```sh
buck2 build //...                                  # examples: packages, binaries, gated library
buck2 build '//examples:hello_pkg_user[run_check]' # run a binary remotely, compare its stdout
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
| `mojo_library(srcs, deps, test_srcs)` | `<name>.mojoc` via `mojo precompile`. Each file in `test_srcs` is built against the package and run; the package is published only if every one passes. `[ungated]` is the package before its tests. |
| `mojo_binary(srcs, deps, main, expected_stdout)` | an executable via `mojo build`. `[run_check]` runs it remotely and, with `expected_stdout`, fails unless its stdout matches exactly. |
| `mojo_test(srcs, deps)` | a test executable for `buck2 test`. |

`deps` carries the full transitive closure of packages to the compiler, one
`-I` directory per package.

## Toolchain

`toolchains//:mojo` is built from three sha256-pinned downloads: the Mojo
compiler `.conda` package (1.0.0, linux-64), a static busybox, and zig 0.12.0.
Remote actions unpack them: busybox extracts zig, zig compiles
`mojo/tools/conda_unpack.zig`, and that static tool extracts the compiler
closure from the `.conda`. Every tool an action runs is one of its inputs;
actions never search the worker's `PATH`. The client's only work is
downloading the pinned files and uploading them to the remote cache.

**Host floor.** What an action still takes from the worker: the Linux kernel
(including `/proc` and `/dev/null`), the glibc dynamic loader
`/lib64/ld-linux-x86-64.so.2` with `libc.so.6` and `libm.so.6`, and
`libstdc++.so.6` and `libgcc_s.so.1`, which the `mojo` compiler binary links
against. Built Mojo binaries need only glibc and the toolchain's own runtime
libraries. `buck2 build checks//re_probe:probe` records what a worker
provides.
