# Getting started

This page takes you from a clone to a library built with its tests, and then
to a library of your own. Setup details, what a local build guarantees, a
remote-execution service and troubleshooting are in
[DEVELOPMENT.md](../DEVELOPMENT.md); this page links there rather than
repeating it. For what is in the repository, see
[architecture.md](architecture.md).

## 1. Clone

```sh
git clone https://github.com/komira-ai/komira.git
cd komira
```

## 2. Get buck2

Run buck2 through `./buck2` at the repository root. The first run downloads
the pinned release, checks its size and sha256, and caches it. It works the
same on a Mac (Apple silicon) and on Linux x86_64, and needs `curl` and
`zstd`; on a Mac, `brew install zstd` first (a non-interactive shell may not
have Homebrew's `bin` on its `PATH`):

```sh
./buck2 --version
```

## 3. Choose where builds run

buck2 is a client: it plans the build and hands each action to an executor.
Which executor you have decides what to run next. The pinned Mojo toolchain
is unpacked by a small set of Linux x86_64 programs (a static busybox, zig),
and a macOS machine cannot run those, so today the two cases differ.

| you have | what works today |
|---|---|
| a Mac (Apple silicon) | `./buck2` installs and runs. Builds run on a **remote-execution service** that has macOS arm64 workers for the compile and Linux x86_64 workers for the toolchain unpack. The repository ships a `darwin-arm64` target platform and a macOS Mojo toolchain for that, and a remote build of `//tools/build/examples:hello` succeeded on such workers. A purely local build on a Mac is **not supported yet**: it refuses at load, and lifting that refusal is not enough, because the unpack step still needs the Linux programs. |
| a Linux x86_64 machine | Builds run on that machine by default. This includes a Linux VM, container or cloud machine reached from a Mac. A local Mojo compile has not been measured yet ([what a local build guarantees](../DEVELOPMENT.md#what-a-local-build-guarantees)). |
| a remote-execution service (any client) | Copy `.buckconfig.local.example` to `.buckconfig.local`, fill in your service, run `./buck2 kill`, and the commands below run every action there. Steps in [DEVELOPMENT.md](../DEVELOPMENT.md#3-optional-build-on-a-remote-execution-service). |

On a Mac, then, the shortest working route is the remote-execution service
(or a Linux machine to build on). Local macOS builds are a gap in the
repository, not a limit of Mojo, and closing it is planned work: a
host-aware platform choice and a macOS-native unpack step.

## 4. Build one library and its tests

Every Mojo module is a `mojo_library` named after its directory under `src/`.
Building it runs its tests (from a Linux x86_64 machine, or through a
remote-execution service, per the table above):

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
`tools/build/tests/run_tests.sh`
([DEVELOPMENT.md](../DEVELOPMENT.md#4-run-the-tests)).

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
