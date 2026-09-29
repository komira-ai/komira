# Developing komira

The build uses [Buck2](https://buck2.build) with remote execution. Every
action -- unpacking the toolchain, compiling, and running tests -- runs on a
remote-execution service that speaks the Bazel Remote Execution API (for
example Buildbarn). Nothing is compiled on your machine; the client only
downloads the [pinned toolchain files](tools/build/toolchains/README.md) and
uploads them to the remote cache.

## 1. Get buck2

The pinned release is **2026-09-15**. [`tools/buck2`](tools/buck2) is a
[dotslash](https://dotslash-cli.com) file that fetches and verifies it:

```sh
tools/buck2 --version
```

Without dotslash, download the release asset for your platform from
<https://github.com/facebook/buck2/releases/tag/2026-09-15>, check it against
the sha256 in `tools/buck2`, and decompress it with `zstd -d`. The prelude is
the one bundled with that binary (`[external_cells] prelude = bundled` in
[`.buckconfig`](.buckconfig)), so the pin fixes the prelude too.

`tools/buck2` has entries for Linux x86_64 and macOS aarch64. On macOS buck2
works as a client: every action still runs on the Linux workers, but
`buck2 run` (which starts the binary on your machine) needs Linux x86_64.

`buck2` below is either a `buck2` on your `PATH` or `tools/buck2`.

## 2. Point it at your build farm

Committed configuration names no service, worker pool or property set. Your
own settings go in `.buckconfig.local`, which is gitignored:

```sh
cp .buckconfig.local.example .buckconfig.local
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

[`.buckconfig`](.buckconfig) caps each batched CAS request at 1 MiB
(`[buck2_re_client] max_total_batch_size`); larger blobs use ByteStream.
Without it buck2 packs up to 4000000 bytes into one BatchReadBlobs request
when the server does not advertise a lower limit, which a server with a
2 MiB gRPC message limit rejects ("Attempted to read a total of at least N
bytes, while a maximum of 2097152 bytes is permitted"). The setting changes no
action digest.

## 3. Build

```sh
buck2 build //...                                                # every target in the komira cell (rules, toolchains, examples)
buck2 build '//tools/build/examples:hello_pkg_user[run_check]'   # run a binary remotely, compare its stdout
buck2 run //tools/build/examples:hello                           # build remotely, run here (Linux x86_64)
buck2 test //tools/build/examples:test_hellopkg                  # a standalone Mojo test, run remotely
```

The rules, their attributes and sub-targets are described in
[tools/build/mojo/README.md](tools/build/mojo/README.md), with the
[examples](tools/build/examples/) that use each one.

## 4. Run the checks

```sh
tools/build/checks/run_checks.sh                 # everything
tools/build/checks/run_checks.sh --no-umbrella   # skip the umbrella cache check (two scratch checkouts)
tools/build/checks/run_checks.sh --no-run        # skip the `buck2 run` check (a scratch clone)
tools/build/checks/run_checks.sh --no-uncached   # skip the two uncached bundle builds (check 15)
```

`run_checks.sh` uses `buck2` from your `PATH`, falls back to `tools/buck2`,
and takes `BUCK2=...` over both. Besides `buck2` it runs `git`, `python3`
(the doc link check) and `readelf` (the output and runtime-library checks) on
the client. Logs and the scratch checkouts of the umbrella and `buck2 run`
checks go under `$TMPDIR`; where `/tmp` is memory, point `TMPDIR` at a disk
directory. The scratch checkouts are deleted on exit,
pass or fail (`KEEP_SCRATCH=1` keeps them); logs are kept, and the last line
of output names their directory. It exits non-zero if any check failed.
Each check is described, with how to run it on its own, in
[tools/build/checks/README.md](tools/build/checks/README.md). CI runs the same
script on the farm, after static checks you can also run yourself
(`.github/ci/static_checks.sh`); see [docs/ci.md](docs/ci.md).

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

- **Every action runs remotely, and results are cached by the service.** The
  execution platforms disable local execution outright and read the remote
  cache before executing
  ([tools/build/platforms/defs.bzl](tools/build/platforms/defs.bzl)). The
  client never uploads action results of its own; it uploads only inputs,
  such as the pinned downloads and your sources.
- **What an action digest covers:** its command, its inputs and the worker
  property set. Two checkouts at the same revision, with the same buck2
  release and the same property sets, have the same digests and share cache
  entries -- including a repository that uses komira as a cell, as a git
  external cell or a submodule
  ([tools/build/README.md](tools/build/README.md#using-komira-from-another-repository)).
  The host floor is not in the key (see above).
- **Outputs stay remote until needed.** `[buck2] materializations = deferred`
  in [`.buckconfig`](.buckconfig): a build downloads nothing it does not
  have to. Pass `--materializations all` to fetch a target's outputs, as the
  output check does. `buck2 run` downloads the binary and its runtime
  libraries only, never the compiler.
- **Forcing real execution.** A cache hit records no worker properties and
  runs nothing. To make every action execute, build with
  `--no-remote-cache`, ideally under its own `--isolation-dir` so your normal
  daemon's state is untouched (the action-platform check does this).

## Troubleshooting

- **You changed `[buck2_re_client]` (endpoints, batch size) and nothing
  changed.** These settings take effect when the buck2 daemon starts. Run
  `buck2 kill`, then build again.
- **`BatchReadBlobs` fails with "Attempted to read a total of at least N
  bytes, while a maximum of 2097152 bytes is permitted".** The batch size
  limit is missing or was raised above your server's message limit; keep
  `max_total_batch_size = 1048576`, then `buck2 kill`.
- **``[komira_re] <key>` is not set``.** `.buckconfig.local` is missing or
  does not name that property set; see step 2.
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
  `buck2 audit execution-platform-resolution <target>` shows the platform and
  why the others were skipped.
- **Errors from inside the Mojo rules**: `GATED TEST FAILED`, `REFUSING:
  toolchain member ...` (exit 2), an output containing the action's working
  directory (exit 4), `numa_guard: REFUSING to run` (exit 3) -- see
  [tools/build/mojo/README.md](tools/build/mojo/README.md#errors).
