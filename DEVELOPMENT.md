# Developing komira

The build uses [Buck2](https://buck2.build). By default every action runs
on your machine, with the [pinned toolchain](tools/build/toolchains/README.md)
buck2 downloads and verifies. So far only the toolchain, zig and C actions
have been measured running locally; Mojo compiles and tests have run only on
a remote-execution service
([what a local build guarantees](#what-a-local-build-guarantees)). If you have
a remote-execution service that speaks the Bazel Remote Execution API (for
example Buildbarn), you can build there instead (step 3). Remote execution is
opt-in: it is configured only by a `.buckconfig.local` you write.

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

`tools/buck2` has entries for Linux x86_64 and macOS aarch64. Local builds
need a Linux x86_64 machine: every toolchain action is a Linux x86_64 binary.
On macOS buck2 works as a client of a remote-execution service (step 3); a
local build there refuses, naming `.buckconfig.local`. `buck2 run` (which
starts the binary on your machine) needs Linux x86_64 either way.

Commands below use `./buck2`; a `buck2` on your `PATH` at the same version
works the same.

## 2. Build (locally, by default)

With no `.buckconfig.local`, every action runs on this machine. A local
Mojo compile has not yet been measured
([what a local build guarantees](#what-a-local-build-guarantees)); the same
commands build on a remote-execution service once `.buckconfig.local` names
one (step 3):

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

A build is also the lint: shellcheck, actionlint and the repository checks
are validations ([tools/build/lint/defs.bzl](tools/build/lint/defs.bzl)), and
the scripts the Mojo and Rust rules run are linted through their toolchains,
so `./buck2 build //...` fails with `Validation for <target> failed:` and the
findings. A new shell script belongs in the `srcs` of the `shell_lint` target
of the rule or package that runs it.

Mojo compiles take a lot of memory. Buck2 runs as many local actions at once
as the machine has cores; on a machine with less than a few GB of memory per
core, pass `-j <n>` to run fewer. A `mojo_multi_numa_test` does not configure
locally (nothing knows how many NUMA nodes this machine has); it needs a
remote service with multi-NUMA workers
([tools/build/platforms/README.md](tools/build/platforms/README.md#multi-numa-runs)).

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
  host path ([check 5](tools/build/checks/README.md)).
- **Measured locally so far: toolchain, zig and C actions only.** With an
  empty host `PATH`, unpacking zig and the conda packages, building the zig
  programs, assembling the Mojo runtime, and one C compile and archive run
  locally and succeed; [check 25](tools/build/checks/README.md) repeats the
  zig unpack and two concurrent zig builds on every run. **A local
  Mojo compile has not yet been measured**: `mojo_build`, `mojo_precompile`,
  gated tests, run checks and bundles have so far run only on a
  remote-execution service. Until they have, do not assume a local build of
  a Mojo target succeeds with an empty host `PATH`, or at all.
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

## 3. Optional: build on a remote-execution service

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
- **`[komira_re]`**: the exact platform property set of each kind of Linux
  x86_64 worker, as comma-separated `key=value` pairs:
  `light_properties` and `mojo_compile_properties` (for example `pool=light`
  and `pool=mojo`; both may name the same set if you have one kind of
  worker), and optionally `mojo_compile_multi_numa_properties` for workers
  spanning more than one NUMA node. What each class runs, and what a
  multi-NUMA worker must provide, is in
  [tools/build/platforms/README.md](tools/build/platforms/README.md).

Workers match a property set exactly: a key your workers do not advertise
leaves actions queued until the scheduler gives up. The property sets are
part of every action digest, so checkouts share cache entries only when they
send the same sets.

Once `light_properties` and `mojo_compile_properties` are set, every action
runs remotely: the platforms then have local execution disabled, so nothing
falls back to your machine. `-c komira.execution=local` builds one command
locally anyway, and `[komira] execution = local` in `.buckconfig.local` keeps
the service settings but builds locally. The commands in step 2 are the same
either way.

A `.buckconfig.local` that names a service in `[buck2_re_client]` but has no
`[komira_re]` section (missing, or misspelled) refuses to build rather than
building on your machine; so does a `[komira_re]` with only some of the
required property sets. On a machine that must never build locally, put
`[komira] execution = remote` in your user buckconfig (`~/.buckconfig.local`):
a checkout there with no `.buckconfig.local` then refuses too.

[`.buckconfig`](.buckconfig) caps each batched CAS request at 1 MiB
(`[buck2_re_client] max_total_batch_size`); larger blobs use ByteStream.
Without it buck2 packs up to 4000000 bytes into one BatchReadBlobs request
when the server does not advertise a lower limit, which a server with a
2 MiB gRPC message limit rejects ("Attempted to read a total of at least N
bytes, while a maximum of 2097152 bytes is permitted"). The setting changes no
action digest.

## 4. Run the checks

```sh
tools/build/checks/run_checks.sh                 # everything
tools/build/checks/run_checks.sh --no-umbrella   # skip the umbrella cache check (two scratch checkouts)
tools/build/checks/run_checks.sh --no-run        # skip the `./buck2 run` check (a scratch clone)
tools/build/checks/run_checks.sh --no-uncached   # skip the two uncached bundle builds (check 15)
```

The checks run where your checkout builds. The first line of output says
which: `MODE  remote` with a `.buckconfig.local` (or, as on the CI runner, a
machine-wide buckconfig) naming a service, when every
check runs; `MODE  local` without one, when every action runs on this machine
and the checks that need a remote service (the umbrella cache, `buck2 run`'s
download budget, the multi-NUMA and per-action property-set checks, macOS)
each print a `SKIP` line saying so. Check 3 (a missing `deps` edge fails to
compile) is also skipped locally: it relies on the remote executor staging
only declared inputs, and a local action, which is not sandboxed, may find
the undeclared package in the checkout. Check 25, that a fresh clone with no
`.buckconfig.local` resolves to local execution, runs in both.

`run_checks.sh` runs `./buck2`; `BUCK2=...` overrides it. Besides buck2 it
runs `git`, `readelf`, `objdump`, `curl` and `zstd` on the client, and no
Python: the JSON, tar and Mach-O reads and the doc link check are a Mojo tool
([tools/build/inspect](tools/build/inspect/inspect.mojo)) the checks build on
the farm like any other target. Logs and the scratch checkouts of the umbrella and `./buck2 run`
checks go under `$TMPDIR`; where `/tmp` is memory, point `TMPDIR` at a disk
directory. The scratch checkouts are deleted on exit,
pass or fail (`KEEP_SCRATCH=1` keeps them); logs are kept, and the last line
of output names their directory. It exits non-zero if any check failed.
Each check is described, with how to run it on its own, in
[tools/build/checks/README.md](tools/build/checks/README.md). CI runs the same
script, after `./buck2 build //...` and `./buck2 test //...`; see
[docs/ci.md](docs/ci.md).

## 5. Enable the knowledge-graph hooks

```sh
python3 tools/kg/kg.py setup   # once per clone: core.hooksPath = .githooks
```

The pre-commit hook keeps the generated library pages and docs graph in
step with the tree; the Buck2 graph is re-rendered with
`python3 tools/kg/kg.py graph`. See
[docs/knowledge_graph.md](docs/knowledge_graph.md).

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
  output check does. `./buck2 run` downloads the binary and its runtime
  libraries only, never the compiler.
- **Forcing real execution.** A cache hit records no worker properties and
  runs nothing. To make every action execute, build with
  `--no-remote-cache`, ideally under its own `--isolation-dir` so your normal
  daemon's state is untouched (the action-platform check does this).

## Troubleshooting

- **`komira_local_execution_platforms: local execution runs the pinned linux
  x86_64 toolchain on this machine, which is not Linux x86_64`.** Local builds
  need Linux x86_64; configure a remote service (step 3).
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
  in (step 3), or pass `-c komira.execution=local` to build here.
- **``[komira_re] <key>` is not set``.** You asked for remote execution
  (`.buckconfig.local` names one of the property sets, or `komira.execution =
  remote`) but not all of them; see step 3.
- **Actions sit queued and never start.** The property set names a key or
  value no worker advertises.
- **`.buckconfig.local` seems ignored in a non-root cell.** It configures the
  root cell (`komira`, which holds the rules and toolchains) only; the
  standalone-only `toolchains` and `checks` cells do not read it. Pass a cell-scoped override instead, e.g.
  `-c checks//komira_re.light_properties=...`.
- **`Can't find toolchain_dep execution platform`** for a
  `mojo_multi_numa_test`. No multi-NUMA workers are configured; that is the
  intended refusal
  ([tools/build/platforms/README.md](tools/build/platforms/README.md#multi-numa-runs)).
- **Which worker class did a target get?**
  `./buck2 audit execution-platform-resolution <target>` shows the platform and
  why the others were skipped.
- **Errors from inside the Mojo rules**: `GATED TEST FAILED`, `REFUSING:
  toolchain member ...` (exit 2), an output containing the action's working
  directory (exit 4), `numa_guard: REFUSING to run` (exit 3) -- see
  [tools/build/mojo/README.md](tools/build/mojo/README.md#errors).
