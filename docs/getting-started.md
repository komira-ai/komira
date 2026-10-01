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
the pinned release, checks its size and sha256, and caches it; it needs
`curl` and `zstd`:

```sh
./buck2 --version
```

Local builds need Linux x86_64. On macOS, buck2 works as a client of a
remote-execution service. Both are in
[DEVELOPMENT.md](../DEVELOPMENT.md#1-get-buck2); what to put in
`.buckconfig.local` is in
[DEVELOPMENT.md](../DEVELOPMENT.md#3-optional-build-on-a-remote-execution-service).

## 3. Build one library and its tests

Every Mojo module is a `mojo_library` named after its directory under `src/`.
Building it runs its tests:

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

## 4. Add a library

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

## 5. Where the docs go

- **The module's own description** goes at the top of its `__init__.mojo`:
  what the package is and why it is a package of its own.
  [architecture.md](architecture.md#the-module-map) quotes it.
- **A design doc** for a subsystem goes in `docs/design/<doc>.md`, one flat
  directory, and gets a row in [docs/index.md](index.md), which records what
  each canonical doc is the authority for.
- **Links are checked by the build.** `//:docs` fails when a relative link or
  `#anchor` in any Markdown file does not resolve, so `./buck2 build //...`
  catches a dead link. A new package needs nothing for this.
