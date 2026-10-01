# Getting started

This page takes you from a clone to a library built with its tests, and then
to a library of your own. Setup details, what a local build guarantees, a
remote-execution service and troubleshooting are in
[DEVELOPMENT.md](../DEVELOPMENT.md); this page links there rather than
repeating it. For what is in the repository, see
[architecture.md](architecture.md).

**On a Mac, read step 3 before step 4.** Today a Mac can install and run
`./buck2`, but it cannot build anything without a remote-execution service
that you run yourself; no public service exists. Linux x86_64 is the platform
that builds on its own.

A few terms used below:

- **buck2** is the build tool. It plans a build and hands each step (an
  *action*) to an executor.
- An **executor** is whatever runs an action: your machine (local) or a
  remote-execution service.
- A **remote-execution service** is a server you operate that speaks the
  Bazel Remote Execution API (Buildbarn is one) and runs actions on its
  workers.
- A **target platform** is the operating system and CPU a build produces
  code for, for example `linux-x86_64` or `darwin-arm64`.
- The **toolchain** is the pinned set of tools every action uses: the Mojo
  compiler, zig and a static busybox. **Unpacking** is the first action that
  extracts the compiler from its downloaded archive.

## 1. Clone

```sh
git clone https://github.com/komira-ai/komira.git
cd komira
```

## 2. Get buck2

Run buck2 through `./buck2` at the repository root. The first run downloads
the pinned release, checks its size and sha256, and caches it. This works on
a Mac (Apple silicon) and on Linux x86_64 with no service and no
configuration:

```sh
./buck2 --version
```

Prerequisites:

- **Linux x86_64:** `sh`, `curl`, `zstd`, and `sha256sum` or `shasum`.
- **Mac (Apple silicon):** [Homebrew](https://brew.sh), then
  `brew install zstd`; `curl`, `sh` and `shasum` ship with macOS. A
  non-interactive shell (an ssh command, a script) may not have Homebrew's
  `bin` on its `PATH`; add it, or `./buck2` stops saying it needs zstd.

## 3. Choose where builds run

| you have | what works today |
|---|---|
| a Linux x86_64 machine | Builds run on that machine by default. This includes a Linux VM, container or cloud machine reached from a Mac. A local Mojo compile has not been measured yet ([what a local build guarantees](../DEVELOPMENT.md#what-a-local-build-guarantees)). |
| a Mac (Apple silicon), no service | `./buck2 --version` and other buck2 commands run. **A purely local build is not supported yet.** It refuses at load, by design. Lifting that refusal is not enough: the toolchain's unpack tools (a busybox, zig) are Linux x86_64 binaries, and macOS cannot run them. |
| a remote-execution service you run | Copy `.buckconfig.local.example` to `.buckconfig.local`, fill in your service, run `./buck2 kill`; every action then runs there. Steps in [DEVELOPMENT.md](../DEVELOPMENT.md#3-optional-build-on-a-remote-execution-service). This is the only route that works on a Mac today. |

There is no public remote-execution service. For a Mac your options are a
Linux x86_64 machine or VM to build on, or a remote-execution service of
your own.

**A Mac with your own service.** The plain `./buck2 build` targets
`linux-x86_64`, because `.buckconfig` maps every target there, so it builds a
Linux result even from a Mac. To build for macOS pass
`--target-platforms komira//tools/build/platforms:darwin-arm64`, and in
`.buckconfig.local` set `darwin_properties` (the property set of
your macOS workers) and `darwin_macos_hosts` (one identity per macOS worker
OS and hardware, from `sh tools/build/mojo/darwin/host_identity.sh` run on
that worker). The identities are pinned: a worker whose identity does not
match refuses the action. The compile runs on the macOS workers and the
unpack runs on Linux x86_64 workers of the same service. The checks of this
setup are in
[tools/build/tests/functional/darwin/check.sh](../tools/build/tests/functional/darwin/check.sh);
the compile and unpack split is as reported, and that script's section 7 is the
way to reproduce it.

**Known gap, not fixed on main yet and being fixed:** the macOS test gate
loses the runtime library path (macOS strips `DYLD_*` variables passed through
`/usr/bin/env`), so a welded test of a `darwin-arm64` library fails because a
runtime library is not found, and step 4 does not yet work for a library on
macOS. A target with no gated test, `//tools/build/examples:hello`, is reported
to build there; section 7 of
[check.sh](../tools/build/tests/functional/darwin/check.sh) is the reproducible
check, and it needs macOS workers.
Libraries that depend on C, C++ or Rust code are Linux x86_64 only.

## 4. Build one library and its tests

Run these on Linux x86_64, or through a remote-execution service for
`linux-x86_64` (the default target platform). On a Mac, see the known gap in
step 3. Every Mojo module is a `mojo_library` named after its directory under
`src/`. Building it runs its tests:

```sh
./buck2 build //src/komira_atomic_alias:komira_atomic_alias
```

The library's BUCK file names its tests in `test_srcs`. Each one is compiled
against the package and run as a build action, and the published package
takes every test's PASS marker as an input. So a green build means every test
in `test_srcs` passed, and so did the tests of every library in its `deps`. A
failing test stops the build with `GATED TEST FAILED: <label> (exit N)`.

Two things that are easy to get wrong:

- `./buck2 test` on a `mojo_library` runs nothing. Its tests run when the
  library, or anything depending on it, is built.
- `//src/komira_atomic_alias:komira_atomic_alias[ungated]` is the package before its tests.
  It builds even when a test fails, which helps when you are reading a
  compile error, but it cannot be named in `deps`.

Wider builds:

```sh
./buck2 build //src/...    # every library, every welded test
./buck2 build //...        # every target, including the lints and the Markdown link check
```

The end-to-end tests of the build tooling run with
`tools/build/tests/run_tests.sh`, from a Linux x86_64 client only
([DEVELOPMENT.md](../DEVELOPMENT.md#4-run-the-tests)). `./buck2 run` is also
Linux x86_64 only.

## 5. Add a library

A new module is a directory `src/<module>/` with an `__init__.mojo`, its
sources, its tests under `tests/`, and a BUCK file:

```python
load("@komira//tools/build/mojo:defs.bzl", "mojo_library")

# What this library is for, in one or two sentences.
mojo_library(
    name = "komira_example",
    srcs = glob(["**/*.mojo"], exclude = ["tests/**/*.mojo"]),
    deps = [
        "//src/komira_core:komira_core",
    ],
    test_srcs = ["tests/test_example.mojo"],
    visibility = ["PUBLIC"],
)
```

- `name` is the import name: consumers write `from komira_example import ...`.
  The shallowest `__init__.mojo` in `srcs` is the package root.
- `deps` lists every first-party package and C library the sources import.
  A package reaches the compiler only through `deps`; a missing edge is a
  compile error.
- `test_srcs` lists every test file. Each holds a `main()` that raises (or
  exits non-zero) on failure. A test file that no `test_srcs` names never runs.
- A library `kci` owns is named `kci_<x>`.

Every attribute, the output layout, holding a known-failing test, binaries,
tests, protobuf and C dependencies are in
[the Mojo rules](../tools/build/mojo/README.md); worked examples of each rule
are in [tools/build/examples/](../tools/build/examples/).

## 6. Where the docs go

- **The module's own description** goes at the top of its `__init__.mojo`:
  what the package is and why it is a package of its own.
  [architecture.md](architecture.md#the-module-map) quotes it.
- **A design doc** for a subsystem goes in `docs/design/<doc>.md`, one flat
  directory, and gets a row in [docs/index.md](index.md), which records what
  each canonical doc is the authority for.
- **Links are checked by the build.** `//:docs` fails when a relative link or
  `#anchor` in any Markdown file does not resolve, so `./buck2 build //...`
  catches a dead link. A new package needs nothing for this.
