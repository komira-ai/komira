# Developing komira

The build uses [Buck2](https://buck2.build). **Supported today: Linux x86_64**,
where by default every action runs on your machine, with the
[pinned toolchain](tools/build/toolchains/README.md) buck2 downloads and
verifies. So far only the toolchain, zig and C actions have been measured
running locally; Mojo compiles and tests have so far run on a remote-execution
service ([what a local build guarantees](#what-a-local-build-guarantees)).
Native builds on macOS (Apple silicon) and Linux arm64 are being added; until
then, on a Mac you can install and run `./buck2` and read the code. If you
already run a remote-execution service, see
[Advanced: remote execution](#advanced-remote-execution); it is optional and
configured only by a `.buckconfig.local` you write.

## Repository layout

| directory | holds |
|---|---|
| `src/<module>/` | one Mojo library komira ships per directory, directly under `src/`. The directory name is the import name (`from komira_crypto import ...`) and the name of its `mojo_library`; there are no nested Mojo namespaces, because a nested one has to re-export every child. A module's tests are in its own `tests/`, and a binary is declared in its module's own package. |
| `src/tests/<kind>/<module>/` | a package that exists only to test others, by kind: `e2e` (end-to-end and loopback tests), `conformance` (against an external suite), `helpers` (test harnesses no shipped library depends on). Same rules as `src/<module>/`; the `src_layout` lint keeps an `*_e2e`, `*_loopback` or `*_conformance` package out of `src/<module>/` ([architecture](docs/architecture.md#end-to-end-tests)). |
| `tools/` | the build rules, toolchains and platforms, the lints, and the end-to-end tests cell (`tools/build/tests`) |
| `docs/` | the repository's documentation |
| `third_party/` | C and C++ libraries built from pinned source archives |

A new module is `src/<module>/BUCK` with a `mojo_library(name = "<module>")`
and a row in the [module map](docs/architecture.md#the-module-map), which
`//:src_layout` requires; the Markdown link check reads its files with
nothing more ([step 2](#2-build-linux-x86_64)).
A library kci owns is named `kci_<x>`.

## 1. Get buck2

Run buck2 through [`./buck2`](buck2), at the repository root:

```sh
./buck2 --version
```

The first run downloads the release pinned in [`tools/buck2`](tools/buck2)
(**2026-09-15**), refuses it unless its size and sha256 match the pin,
decompresses it and caches it at
`~/.cache/komira/buck2/<sha256>/buck2` (under `$XDG_CACHE_HOME` when set);
later runs start the cached binary directly. It needs `sh`, `curl`, `zstd`
(`brew install zstd` on macOS) and `sha256sum` or `shasum`. `tools/buck2` is
the only place the version is written; it is also a
[dotslash](https://dotslash-cli.com) file, so `tools/buck2 ...` works the same
where dotslash is installed. The prelude is the one bundled with that binary
(`[external_cells] prelude = bundled` in [`.buckconfig`](.buckconfig)), so the
pin fixes the prelude too.

`tools/buck2` has entries for Linux x86_64 and macOS aarch64, so buck2
itself runs on a Mac. A build is a separate matter: the toolchain is unpacked
by Linux x86_64 programs (a static busybox, zig) that macOS cannot run, so
today a purely local build works on Linux x86_64 and refuses on a Mac, naming
`.buckconfig.local`. A native macOS build is being added; it is a gap in this
repository, not a limit of Mojo. Two things need a Linux x86_64 client:
`./buck2 run`, and `tools/build/tests/run_tests.sh` (section 3), which
refuses any other client.

Commands below use `./buck2`; a `buck2` on your `PATH` at the same version
works the same.

## 2. Build (Linux x86_64)

With no `.buckconfig.local`, every action runs on this machine. Measured on
one Linux x86_64 workstation: `hello` took 23 seconds cold, `//src/...` about
10 minutes
([what a local build guarantees](#what-a-local-build-guarantees)); the same
commands build on a remote-execution service if you run one
([Advanced: remote execution](#advanced-remote-execution)):

```sh
./buck2 build //tools/build/examples:hello                         # one binary
./buck2 build '//tools/build/examples:hello_pkg_user[run_check]'   # run a binary, compare its stdout
./buck2 run //tools/build/examples:hello                           # build and run it
./buck2 test //tools/build/examples:test_hellopkg                  # a standalone Mojo test
./buck2 build //...                                                  # every target in the komira cell (rules, toolchains, examples, lints)
```

The rules, their attributes and sub-targets are described in
[tools/build/mojo/README.md](tools/build/mojo/README.md), with the
[examples](tools/build/examples/) that use each one.

A build is also the lint: shellcheck, actionlint, the repository checks and
the Markdown link check (`//:docs`: every relative link and `#anchor`
resolves) are validations ([tools/build/lint/defs.bzl](tools/build/lint/defs.bzl)), and
the scripts the Mojo and Rust rules run are linted through their toolchains,
so `./buck2 build //...` fails with `Validation for <target> failed:` and the
findings. A new shell script belongs in the `srcs` of the `shell_lint` target
of the rule or package that runs it. A new package needs nothing for the
link check: the first rule its BUCK file calls declares the package's
`doc_tree` (its files, and its subpackages' `doc_tree`s, which Buck2 lists),
so `//:docs` reaches every package with no list
([tools/build/lint/doc_tree.bzl](tools/build/lint/doc_tree.bzl)). The komira
rules do this where they are defined; the prelude rules the repository's
BUCK files call (`cxx_library`, `export_file`, `filegroup`,
`platform`, `constraint_setting`, `constraint_value`) do it through
`[buildfile] includes` in `.buckconfig`
([tools/build/lint/includes.bzl](tools/build/lint/includes.bzl)). A BUCK
file that calls none of them is an analysis error of `//:docs`
(`Unknown target \`doc_tree\` from package ...`), never a package left out;
such a file calls `package_docs()` from `doc_tree.bzl`. A new rule a BUCK
file calls is exported through `declares_docs`. Test 17 of
`tools/build/tests/run_tests.sh` requires every package in `//:docs` and no
BUCK file naming its own `doc_tree`.

Mojo compiles take a lot of memory. Buck2 runs as many local actions at once
as the machine has cores; on a machine with less than a few GB of memory per
core, pass `-j <n>` to run fewer.

`./buck2 audit execution-platform-resolution <target>` shows where a target
builds; `./buck2 log what-ran` shows `local` for each action that ran here.

### What a local build guarantees

A local build runs the same commands, with the same inputs and the same
configuration, as a remote one: only the executor differs
([tools/build/platforms/README.md](tools/build/platforms/README.md#local-or-remote)).
What that gives you, and what it does not:

- **Guaranteed: the toolchain is pinned.** Every tool an action runs -- a
  static busybox for the shell and file utilities, zig, the Mojo compiler and
  the C++ runtime it needs -- is a download pinned by sha256, unpacked by
  build actions. An action sets `PATH` to a private directory of busybox
  applets and its own `HOME`, `TMPDIR` and caches; no command line names a
  host path ([test 5](tools/build/tests/README.md)).
- **Measured locally so far: toolchain, zig and C actions only.** With an
  empty host `PATH`, unpacking zig and the conda packages, building the zig
  programs, assembling the Mojo runtime, and one C compile and archive run
  locally and succeed; [test 25](tools/build/tests/README.md) repeats the
  zig unpack and two concurrent zig builds on every run. **A local
  Mojo compile has been measured once**, on one Linux x86_64 workstation
  (61 GB of memory) from a clean checkout with nothing cached: `hello` built
  and ran in 23 seconds (9 local actions, a 119 MiB toolchain download), one
  library with its welded tests built in 5 seconds, and `//src/...` built in
  588 seconds (962 local actions, none cached). That is one machine; do not
  assume another host, or an empty host `PATH`, behaves the same.
- **Guaranteed: the host floor, as remotely.** An action still takes the
  kernel, the CPU and glibc from the machine it runs on (see
  [Host floor](#host-floor)).
- **Not guaranteed: isolation.** Buck2 does not sandbox local actions. They
  run in the checkout's root directory, with the environment of the buck2
  daemon (whatever your shell had when the daemon started), and can read any
  file on the machine. The rules do not read what they do not declare, but
  nothing stops a mistake from doing so: a missing dependency or an
  undeclared input that goes unnoticed locally fails on a remote service,
  where an action sees only its declared inputs. A variable that changes how
  the loader or a compiler behaves (for example `LD_PRELOAD`) reaches every
  local action. Each action keeps its own scratch in the per-action directory
  buck2 gives it, except C and C++ compiles, which share zig's cache in
  `.zig-cache/` at the checkout root (gitignored; zig locks its own cache).
- **Not guaranteed: a shared cache.** Local results are kept in `buck-out`
  of this checkout only; nothing is uploaded or downloaded.

When a result matters (a release, a bug report about the build), build it on
a remote-execution service, or at least from a shell with a minimal
environment (`env -i HOME="$HOME" PATH=/usr/bin:/bin buck2 ...` after
`./buck2 kill`, so the daemon restarts with it).

## 3. Run the tests

```sh
tools/build/tests/run_tests.sh                 # everything
tools/build/tests/run_tests.sh --no-umbrella   # skip the umbrella cache check (two scratch checkouts)
tools/build/tests/run_tests.sh --no-run        # skip the `./buck2 run` test (a scratch clone)
tools/build/tests/run_tests.sh --no-uncached   # skip the two uncached bundle builds (test 15)
```

The checks run where your checkout builds. The first line of output says
which: `MODE  remote` with a `.buckconfig.local` (or, as on the CI runner, a
machine-wide buckconfig) naming a service, when every
test runs; `MODE  local` without one, when every action runs on this machine
and the tests that need a remote service (the umbrella cache, `buck2 run`'s
download budget, the per-action property-set test, macOS)
each print a `SKIP` line saying so. Test 3 (a missing `deps` edge fails to
compile) is also skipped locally: it relies on the remote executor staging
only declared inputs, and a local action, which is not sandboxed, may find
the undeclared package in the checkout. Test 25, that a fresh clone with no
`.buckconfig.local` resolves to local execution, runs in both.

`run_tests.sh` runs `./buck2`; `BUCK2=...` overrides it. Besides buck2 it
runs `git`, `readelf`, `objdump`, `curl` and `zstd` on the client, and no
Python: the JSON, tar and Mach-O reads are a Mojo tool
([tools/build/inspect](tools/build/inspect/inspect.mojo)) the tests build on
the farm like any other target. Logs and the scratch checkouts of the umbrella and `./buck2 run`
tests go under `$TMPDIR`; where `/tmp` is memory, point `TMPDIR` at a disk
directory. The scratch checkouts are deleted on exit,
pass or fail (`KEEP_SCRATCH=1` keeps them); logs are kept, and the last line
of output names their directory. It exits non-zero if any test failed.
Each test is described, with how to run it on its own, in
[tools/build/tests/README.md](tools/build/tests/README.md). CI runs the same
script, after `./buck2 build //...` and `./buck2 test //...`; see
[docs/ci.md](docs/ci.md). It needs a Linux x86_64 client (it runs Linux
binaries the farm built, and `readelf`/`objdump`, on your machine) and
refuses any other with exit 2.

## Advanced: remote execution

Everything above runs on your machine. This section is for people who
already operate a remote-execution service (a server that speaks the Bazel
Remote Execution API, for example Buildbarn) and want komira's actions to run
there. It is optional: nothing in [getting started](docs/getting-started.md)
needs it.


Committed configuration names no service, worker pool or property set, so a
fresh clone builds locally. To build remotely instead, put your service in
`.buckconfig.local`, which is gitignored:

```sh
cp .buckconfig.local.example .buckconfig.local
./buck2 kill                                      # the daemon reads remote settings when it starts
```

Fill in:

- **`[buck2_re_client]`**: the addresses of your remote-execution service
  (engine, action cache, CAS), its instance name, TLS, and
  `execution_concurrency_limit`.
- **`[komira_re]`**: one key per platform, each the exact property set every
  action of that platform carries, as comma-separated `key=value` pairs:
  `linux_x86_64_properties` (for example `pool=mojo-sized`) and
  `darwin_arm64_properties` (for example `pool=darwin-sized`). Your service
  picks the worker for each action; the build says nothing about worker
  classes. A Mac needs `darwin_macos_hosts` too (see
  [tools/build/toolchains/README.md](tools/build/toolchains/README.md#macos)).
  How target platforms, execution platforms and toolchains fit together is
  in [tools/build/platforms/README.md](tools/build/platforms/README.md).

Workers match a property set exactly: a key your workers do not advertise
leaves actions queued until the scheduler gives up. The property set is part
of every action digest, so checkouts share cache entries only when they send
the same set.

**Where actions run follows your own platform.** Builds default to the
platform of the machine you run them on. Once the key of *that* platform is
set (`linux_x86_64_properties` on Linux x86_64, `darwin_arm64_properties` on
a Mac), every action runs remotely: the platforms then have local execution
disabled, so nothing falls back to your machine. If `.buckconfig.local` sets
only another platform's key, builds for your own platform run on your machine
and nothing fails; that key is used when you name the platform with
`--target-platforms`. Names no key at all: everything is local.
`-c komira.execution=local` builds one command
locally anyway, and `[komira] execution = local` in `.buckconfig.local` keeps
the service settings but builds locally. The commands in step 2 are the same
either way.

A `.buckconfig.local` that names a service in `[buck2_re_client]` but has no
`[komira_re]` section (missing, or misspelled) refuses to build rather than
building on your machine; so does a `[komira_re]` still naming a key of the
earlier layouts (`linux_properties` and `darwin_properties`, the per-class
`light_properties` and `mojo_compile_properties`, ...), which names the key to
rename it to. On a machine that must never build locally, put
`[komira] execution = remote` in your user buckconfig (`~/.buckconfig.local`):
a checkout there with no `.buckconfig.local` then refuses too.

[`.buckconfig`](.buckconfig) caps each batched CAS request at 1 MiB
(`[buck2_re_client] max_total_batch_size`); larger blobs use ByteStream.
Without it buck2 packs up to 4000000 bytes into one BatchReadBlobs request
when the server does not advertise a lower limit, which a server with a
2 MiB gRPC message limit rejects ("Attempted to read a total of at least N
bytes, while a maximum of 2097152 bytes is permitted"). The setting changes no
action digest.

### macOS workers

This applies only if your service has macOS (Apple silicon) workers. It is
separate from the native macOS build that is being added, which needs no
service.

- The plain `./buck2 build` targets `linux-x86_64`, because `.buckconfig` maps
  every target there. For a macOS result pass
  `--target-platforms komira//tools/build/platforms:darwin-arm64` and set
  `darwin_properties` (the property set of your macOS workers) and
  `darwin_macos_hosts` in `.buckconfig.local`. A host identity is one line per
  macOS worker OS and hardware, from `sh tools/build/mojo/darwin/host_identity.sh`
  run on that worker; identities are pinned, and a worker whose identity does
  not match refuses the action. The compile runs on the macOS workers and the
  toolchain unpack runs on Linux x86_64 workers of the same service. Checks:
  [check.sh](tools/build/tests/functional/darwin/check.sh).
- Welded tests and the runtime library path: a test binary finds the Mojo
  runtime libraries through `DYLD_LIBRARY_PATH`, which the macOS gate runner
  sets. macOS drops every `DYLD_*` variable when it starts one of its protected
  binaries (everything in `/bin` and `/usr/bin`, so every busybox applet on a
  macOS worker), so the runner starts the test itself, with no applet such as
  `env` in between. Two checks need no macOS worker:
  `tests//functional/test_data:runner_cases` (a build action) and section 6 of
  [check.sh](tools/build/tests/functional/darwin/check.sh) run the macOS
  runner against a busybox that drops `DYLD_*` as macOS does. Section 7 of
  check.sh builds `//tools/build/examples/libgate_ok:libgate_ok`, whose welded
  test needs the variable, on the macOS workers. A C or C++ dependency cannot
  build for `darwin-arm64` yet (the C toolchain is Linux x86_64 only), so no
  welded test with native code runs on macOS.

## Host floor

An action takes a small, fixed set of things from the worker: a Linux x86_64
kernel, a CPU implementing `x86-64-v3`, and glibc 2.34 or newer (the dynamic
loader and four of its libraries). Everything else, including the C++
runtime, comes from the pinned toolchain. The exact list, and the check that
enforces it, are in
[tools/build/toolchains/README.md](tools/build/toolchains/README.md#host-floor).
None of the floor is part of an action key, so workers that differ in it must
not share a remote cache.

## Caching

- **Locally, results stay in `buck-out`.** A local build uses buck2's own
  per-checkout cache and no remote cache.
- **Remotely, every action runs on the service, and results are cached by
  it.** The remote execution platforms disable local execution outright and
  read the remote cache before executing
  ([tools/build/platforms/defs.bzl](tools/build/platforms/defs.bzl)). The
  client never uploads action results of its own; it uploads only inputs,
  such as the pinned downloads and your sources.
- **What a remote action digest covers:** its command, its inputs and the
  worker property set. Whether a checkout could build locally is not part of
  it. Two checkouts at the same revision, with the same buck2
  release and the same property sets, have the same digests and share cache
  entries -- including a repository that uses komira as a cell, as a git
  external cell or a submodule
  ([tools/build/README.md](tools/build/README.md#using-komira-from-another-repository)).
  The host floor is not in the key (see above).
- **Remote outputs stay remote until needed.** `[buck2] materializations = deferred`
  in [`.buckconfig`](.buckconfig): a build downloads nothing it does not
  have to. Pass `--materializations all` to fetch a target's outputs, as the
  output test does. `./buck2 run` downloads the binary and its runtime
  libraries only, never the compiler.
- **Forcing real execution.** A cache hit records no worker properties and
  runs nothing. To make every action execute, build with
  `--no-remote-cache`, ideally under its own `--isolation-dir` so your normal
  daemon's state is untouched (the action-platform test does this).

## Troubleshooting

- **`komira_local_execution_platforms: no platform row matches this host`** (or
  `this host is linux-arm64, which komira reserves a row for but does not
  build for yet`). Local builds run this machine's own platform, one row of
  [the platform table](tools/build/platforms/table.bzl); a machine no
  registered row matches builds through a remote service ([advanced](#advanced-remote-execution)), naming
  the platform with `--target-platforms`.
- **On a Mac, a local build stops at the first toolchain action.** The
  default platform is `darwin-arm64`, but unpacking the toolchain still runs
  Linux x86_64 binaries, so a darwin target needs a remote service until the
  unpack tier has a darwin row of its own.
- **A local build is slow or runs out of memory.** Pass `-j <n>` to run
  fewer actions at once (step 2).
- **You want to know whether a build was local or remote.** `buck2 log
  what-ran`: `local` for an action run here, `re(...)` or `cache` for one run
  or found on the service.
- **You changed `[buck2_re_client]` (endpoints, batch size) and nothing
  changed.** These settings take effect when the buck2 daemon starts. Run
  `./buck2 kill`, then build again.
- **`BatchReadBlobs` fails with "Attempted to read a total of at least N
  bytes, while a maximum of 2097152 bytes is permitted".** The batch size
  limit is missing or was raised above your server's message limit; keep
  `max_total_batch_size = 1048576`, then `./buck2 kill`.
- **``[buck2_re_client] <key>` names a remote-execution service, but
  `[komira_re]` names no worker property set``.** Your `.buckconfig.local`
  has the service addresses but no (or a misspelled) `[komira_re]`; fill it
  in ([advanced](#advanced-remote-execution)), or pass `-c komira.execution=local` to build here.
- **``[komira_re] <key>` is not set``.** You asked for remote execution
  (`komira.execution = remote`, or a `[komira_re]` key on a machine no platform
  row matches) but not the key of your own platform; see [Advanced: remote execution](#advanced-remote-execution).
- **Actions sit queued and never start.** The property set names a key or
  value no worker advertises.
- **`.buckconfig.local` seems ignored in a non-root cell.** It configures the
  root cell (`komira`, which holds the rules and toolchains) only; the
  standalone-only `toolchains` and `tests` cells do not read it. Pass a cell-scoped override instead, e.g.
  `-c tests//komira_re.linux_x86_64_properties=...`.
- **Which execution platform did a target get?**
  `./buck2 audit execution-platform-resolution <target>` shows the platform and
  why the others were skipped.
- **Errors from inside the Mojo rules**: `GATED TEST FAILED`, `REFUSING:
  toolchain member ...` (exit 2), an output containing the action's working
  directory (exit 4) -- see
  [tools/build/mojo/README.md](tools/build/mojo/README.md#errors).
