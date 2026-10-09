# Getting started

A quick start: from a clone to a built library with its tests, then to a
library of your own. For setup details, what a local build guarantees and
troubleshooting, see [DEVELOPMENT.md](../DEVELOPMENT.md); for what is in the
repository, see [architecture.md](architecture.md).

> **Supported today: Linux x86_64.** Native builds on macOS (Apple silicon)
> and Linux arm64 are being added: a Mac will build on its own with no build
> service. Until then, on a Mac you can install and run `./buck2` and read the
> code. The steps below are for Linux x86_64.

Two terms: **buck2** is the build tool, and the **toolchain** is the pinned
set of tools every build step uses (the Mojo compiler, zig and a static
busybox), which buck2 downloads for you.

## 1. Clone

```sh
git clone https://github.com/komira-ai/komira.git
cd komira
```

## 2. Get buck2

Run buck2 through `./buck2` at the repository root. The first run downloads
the pinned release, checks its size and sha256, and caches it. You need `sh`,
`curl`, `zstd`, and `sha256sum` or `shasum`:

```sh
./buck2 --version
```

## 3. First build

```sh
./buck2 run //tools/build/examples:hello
```

The first build also downloads the toolchain, so it takes longest; later
builds reuse it. Nothing else is configured: with no `.buckconfig.local`,
every step runs on your machine. It prints `hello from mojo`.

Measured on one Linux x86_64 workstation (61 GB of memory), from a clean
checkout with nothing cached: `hello` took 23 seconds, including the toolchain
download; one library and its tests took 5 seconds; `//src/...` took about 10
minutes (588 seconds, 962 local actions). Other machines will differ.
See [what a local build guarantees](../DEVELOPMENT.md#what-a-local-build-guarantees).

## 4. Build a library and run its tests

Every Mojo module is a `mojo_library` named after its directory under
`src/`. Building it runs its tests:

```sh
./buck2 build //src/komira_atomic_alias:komira_atomic_alias
```

The library's BUCK file names its tests in `test_srcs`. Each one is compiled
against the package and run as a build step, and the published package
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

## 5. Edit a library

Open `src/komira_atomic_alias/atypes.mojo`, change something, and build the
same target again: only what the change affects is rebuilt, and its tests run
again. To see a failing test, break an assertion in
`src/komira_atomic_alias/tests/test_atomic_alias_widths.mojo`; the build stops
with `GATED TEST FAILED`. Undo the edit and the build is green again.

## 6. Add a library

A new module is a directory `src/<module>/` with an `__init__.mojo`, its
sources, its tests under `tests/`, and a BUCK file:

```python
load("@komira//tools/build/mojo:defs.bzl", "mojo_library")

# What this library is for, in one or two sentences.
mojo_library(
    name = "komira_example",
    srcs = glob(["**/*.mojo"], exclude = ["tests/**/*.mojo"]),
    deps = [
        "//src/komira_arrow:komira_arrow",
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

Every attribute, the output layout, binaries, tests, protobuf and C
dependencies are in
[the Mojo rules](../tools/build/mojo/README.md); worked examples of each rule
are in [tools/build/examples/](../tools/build/examples/).

## 7. Where next

- **The module's own description** goes at the top of its `__init__.mojo`:
  what the package is and why it is a package of its own.
  [architecture.md](architecture.md#the-module-map) quotes it, one row per
  package: add the row in the same change, or `//:src_layout` fails.
- **A design doc** for a subsystem goes in `docs/design/<doc>.md`, one flat
  directory, and gets a row in [docs/index.md](index.md), which records what
  each canonical doc is the authority for.
- **Links are checked by the build.** `//:docs` fails when a relative link or
  `#anchor` in any Markdown file does not resolve, so `./buck2 build //...`
  catches a dead link. A new package needs nothing for this.
