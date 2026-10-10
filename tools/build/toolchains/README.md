# Toolchain

The package `komira//tools/build/toolchains` ([`BUCK`](BUCK)) builds the hermetic Mojo toolchain
from sha256-pinned downloads, using the rules in
[`mojo/toolchain.bzl`](../mojo/toolchain.bzl) and
[`mojo/download.bzl`](../mojo/download.bzl).

## What is pinned

| target | what | source |
|---|---|---|
| `:busybox` | static busybox 1.35.0 (x86_64, musl): `sh` and the file utilities every action uses | busybox.net |
| `:zig_linux_x86_64.tar.xz` | zig 0.12.0: the C link driver for `mojo build`, and the compiler for `conda_unpack` | ziglang.org |
| `:mojo_compiler_1.0.0_linux-64.conda` | the Mojo compiler package, 1.0.0, linux-64 | conda.modular.com |
| `:libstdcxx_15.3.0_linux-64.conda`, `:libgcc_15.3.0_linux-64.conda` | the C++ runtime (`libstdc++.so.6`, `libgcc_s.so.1`) the compiler and built binaries link against; one matched pair from conda-forge | conda.anaconda.org |
| `:pixi` | pixi 0.67.2, the raw static executable of the target platform's row (`pixi-0.67.2-x86_64-unknown-linux-musl` or `pixi-0.67.2-aarch64-apple-darwin`), never unpacked; `:pixi_version` runs the linux one and fails unless it prints `pixi 0.67.2` ([`pixi.bzl`](pixi.bzl)) | github.com/prefix-dev/pixi |

kcov, the line coverage tool, is built from its pinned source in its own
package, [`kcov/`](kcov/README.md). The LLVM pieces of branch coverage (Mojo's
own lld, and the LLVM 23 profile runtime and llvm-profdata) are unpacked and
checked in [`llvm_branch/`](llvm_branch/README.md).

The buck2 binary, and with it the bundled prelude, is pinned separately by
[`tools/buck2`](../../buck2) ([DEVELOPMENT.md](../../../DEVELOPMENT.md#1-get-buck2)).

## How it is built

Remote actions unpack the pinned files: busybox extracts zig
(`komira//tools/build/toolchains:zig`), zig compiles [`mojo/tools/conda_unpack.zig`](../mojo/tools/conda_unpack.zig)
(`:conda_unpack`), and that static tool extracts the compiler closure from the
`.conda`, placing the pinned C++ runtime in its `lib/` (`:mojo_compiler`).
`:mojo_runtime` copies the libraries a built binary loads out of that closure,
and refuses (`mojo_runtime: REFUSING: lib/<name> is missing or empty`) a name
the closure lacks. All of these are linux x86_64 actions, on the linux
execution platform ([platforms/README.md](../platforms/README.md#toolchains)).

`komira_mojo_toolchains` ([`defs.bzl`](defs.bzl)) bundles them into
`toolchains//:mojo` for `mojo_library`, `mojo_binary` and `mojo_test` (its
actions run on the linux execution platform). It links for `x86_64-linux-gnu.2.34` and compile for `target_cpu = "x86-64-v3"`.
`komira_toolchains` calls it from the `toolchains` cell of the repository at
the project root (`tools/build/cells/toolchains/BUCK` in a standalone
checkout), so a repository using komira can pass its own compiler
([tools/build/README.md](../README.md#using-komira-from-another-repository)).

Every tool an action runs is one of its inputs; actions never search the
worker's `PATH`. The client's only work is downloading the pinned files
(`pinned_file`, the only client-side operation) and uploading them to the
remote cache. The Mojo wrapper ([`mojo/mojo_wrapper.sh`](../mojo/mojo_wrapper.sh))
refuses (exit 2) to run a toolchain missing a member listed in its
`CLOSURE_MANIFEST` instead of falling back to anything on the worker
([test 4](../tests/README.md#4-closure-refusal)).

## Host floor

What an action still takes from the worker:

- a Linux x86_64 kernel (including `/proc` and `/dev/null`);
- a CPU implementing `x86-64-v3` (AVX2, BMI2, FMA), since gated tests and run
  checks execute the code they compile;
- glibc 2.34 or newer (link steps target `x86_64-linux-gnu.2.34`): the dynamic
  loader `/lib64/ld-linux-x86-64.so.2` with `libc.so.6`, `libm.so.6`,
  `libdl.so.2` and `libpthread.so.0`.

Nothing else. The C++ runtime the compiler and built binaries link against
(`libstdc++.so.6`, `libgcc_s.so.1`) is pinned by sha256 from conda-forge and
unpacked into the toolchain's `lib/`; the compiler finds it through its own
`$ORIGIN/../lib` run path, built binaries through their `$ORIGIN/lib` run
path (or `LD_LIBRARY_PATH`, which gated tests set). None of the floor is part
of an action key, so workers that differ in it must not share a remote cache.

[Test 8](../tests/README.md#8-host-floor-and-runtime-libraries) enforces
the floor: it reads the loader's own record (`LD_DEBUG`) of a real compile and
a run ([`tests//functional/runtime_libs:loader_trace`](../tests/functional/runtime_libs/BUCK)),
and fails if either maps the C++ runtime from the worker, or any object from
the worker that is not glibc's. `buck2 build tests//re_probe:probe`
([`tests/re_probe`](../tests/re_probe/BUCK)) records what a worker provides.

That check, together with `komira//tools/build/toolchains:mojo_runtime` (which refuses a
library name missing from the toolchain), is what guards the C++ runtime pin.
The wrapper's exit-2 refusal does not: it checks the members listed in
`CLOSURE_MANIFEST`, and `conda_unpack` writes that list from what it
unpacked, so a toolchain built without the pin carries a manifest without
those names, and a worker's own `libstdc++.so.6` would satisfy the compiler.
The floor is measured on the compile and run of a hello-world program only;
a library the compiler loads lazily on another path (for example its Python
interop) is not traced. The runtime libraries keep their vendor `DT_RPATH`
entries; test 8 requires every run path in a runnable directory's `lib/` to
be `$ORIGIN`-relative, so an absolute one arriving with an upstream update
fails the checks.

## Updating a pin

A `pinned_file` has a `url`, a `sha256` and a `size_bytes`; the download
fails unless the bytes match. The size lets buck2 skip any request to the URL
while the remote cache holds the file. To move to a new release:

1. Download the new file and compute its sha256 (`sha256sum`) and size
   (`stat -c %s`).
2. Change `url`, `sha256` and `size` of its `pin(...)` together in the
   platform table, [`table.bzl`](../platforms/table.bzl). The names of the
   `.conda` and zig targets carry their version; if you rename one, update
   the targets that name it (`conda_closure(package = ..., libs = ...)`,
   `zig_dist(archive = ..., strip_prefix = ...)`).
3. For the C++ runtime, keep `libstdcxx` and `libgcc` a matched pair: that
   `libstdcxx` build depends on exactly that `libgcc` build. A new compiler may
   need newer symbol versions (today `GLIBCXX_3.4.30`, `CXXABI_1.3.13`,
   `GCC_3.3`, i.e. GCC 12 or newer).
4. If a new compiler loads a different set of runtime libraries, update the
   `libs` list of `:mojo_runtime`; test 8 fails until it matches what a run
   loads.
5. Run the full [checks](../tests/README.md). A toolchain change changes the
   digest of every action downstream of it, so expect a cold remote cache.

To update buck2, change each platform's `size`, `digest` and release URL in
[`tools/buck2`](../../buck2). Tests 18 and 25 pin the configuration hash of
`linux-x86_64`, which a buck2 release may move; update the pins with it.

## macOS

`--target-platforms komira//tools/build/platforms:darwin-arm64` builds Mojo
targets for macOS on Apple silicon. `toolchains//:mojo` selects the toolchain
by the target platform's os: `komira//tools/build/toolchains/darwin:mojo` for
macos, built from the sha256-pinned osx-arm64 compiler package of the same
release. The C/C++, Rust and protobuf toolchains are linux x86_64 only, so a
darwin-arm64 target that needs one is incompatible rather than built for
linux.

Its compiles, gated tests and run checks run on macOS arm64 workers, the
execution platform `komira//tools/build/platforms:darwin-arm64`.
It is registered only when `.buckconfig.local` names their property set and
their hosts:

```ini
[komira_re]
  darwin_arm64_properties = pool=macos
  darwin_macos_hosts = 26.5-0123456789abcdef 26.5-fedcba9876543210
```

`darwin_arm64_properties` is the exact property set the workers advertise, and
must differ from the linux one (`linux_x86_64_properties`).
`darwin_macos_hosts` lists what `sh tools/build/mojo/darwin/host_identity.sh`
prints on each worker host: the SDK version, then a digest of the developer
dir, the SDK version and build, `cc --version`, `ld -v` and the OS build.
Unset, no macOS platform exists, a darwin-arm64 Mojo target fails to
configure, a wildcard over `tools/build/toolchains/darwin` skips its targets,
and the linux build is unchanged (its actions are the same with and without
the keys). The macOS platform is registered last, so an action that states
no os never lands on it. Unpacking the osx-arm64 toolchain moves bytes only
and runs on the linux execution platform.

What a macOS action takes from the worker, and what keys it:

* `/bin/sh` and the file utilities in `/bin` and `/usr/bin`, through
  `tools/build/mojo/darwin/busybox.sh` (a fixed applet list; anything else is
  refused). They belong to the sealed operating-system volume, whose build
  is part of the host identity.
* The Command Line Tools or Xcode: `/usr/bin/xcrun`, the SDK, and
  `/usr/bin/cc` through `tools/build/mojo/darwin/cc`, which links with the
  host's `ld`. Every compile links this way, measured on the workers: the
  compiler does not use the `lld_path` its `modular.cfg` names, and the
  closure has no `bin/lld`.
* The system libraries a built binary loads (`/usr/lib`, `/System`),
  covered by the OS build in the host identity.

The host list is written into every compile's inputs, so it is part of every
action key, and a compile refuses (exit 2) a host whose identity is not
listed, printing that host's fields. The key names the list, not the host:
a worker pool advertises one property set for all its hosts, so which listed
host ran an action is not part of its key. That is the residual: results
are shared between the listed hosts, which must be interchangeable. To key
on one host, give each its own worker property (e.g. `macos_host=<its
identity>`) and each its own property set. A host outside the list, or one
whose SDK, Xcode, Command Line Tools or OS is updated, is refused until the
list is updated, which re-keys every macOS action.
`tests//functional/darwin:host_census` reports the identities the workers print.

A built binary names its runtime libraries `@rpath/...` and carries one run
path, `@loader_path/lib`, the `lib/` of its runnable directory; it targets
`apple-m1` (every Apple silicon Mac) and macOS 11.0, the compiler's own
minimum. Gated tests set `DYLD_LIBRARY_PATH` to the compiler's `lib/`, and
run checks start the binary with no `DYLD_*` variable. Bundles
(`mojo_bundle`, the `[shared]` sub-target) are linux only: the macOS wrapper
refuses `--emit shared-lib` unless the library names itself with
`-Xlinker -install_name` (`mojo_shared_lib`, a `.dylib`). `tools/build/tests/functional/darwin/check.sh` checks all
of this, most of it without a macOS worker; with the keys above set, it also
builds and runs `//tools/build/examples:hello` on the workers.
