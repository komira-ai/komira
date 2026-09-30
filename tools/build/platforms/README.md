# Platforms

`komira//tools/build/platforms` ([`BUCK`](BUCK), [`defs.bzl`](defs.bzl))
declares the target platform, two abstract execution constraints, and three
execution configurations built from them. Nothing here names a service, a
worker pool or a property set: the platforms that realize these
configurations are registered by [`default/BUCK`](default/BUCK) for a
standalone checkout (on this machine, or on a remote-execution service when
`.buckconfig.local` names one), and by any repository that mounts komira.

## Target platform

`linux-x86_64` (Linux, x86_64). `[parser] target_platform_detector_spec` in
[`.buckconfig`](../../../.buckconfig) maps every komira cell to it.

## Execution classes

| constraint setting | values | meaning |
|---|---|---|
| `exec_class` | `light` | unpacking and copying toolchain files: little CPU, memory bounded by the archive being unpacked |
| | `mojo_compile` | running the Mojo compiler, and running what it built (gated tests, run checks): many cores and a lot of memory |
| `numa` | `numa_single` | the worker's CPUs and memory lie on one NUMA node; the default for every Mojo action |
| | `numa_multi` | the worker spans more than one NUMA node, for tests that measure or depend on cross-node placement |

| configuration | constraints | runs |
|---|---|---|
| `exec-mojo` | `mojo_compile`, `numa_single` | Mojo compiles, gated library tests, run checks, `buck2 test` of a `mojo_test`; also any target that states no constraint |
| `exec-light` | `light` | unpacking and copying toolchain files (`komira//tools/build/toolchains:zig`, `:conda_unpack`, `:mojo_compiler`, `:mojo_runtime`) |
| `exec-mojo-multi-numa` | `mojo_compile`, `numa_multi` | `mojo_multi_numa_test` only |

The Mojo rules get their constraints from their toolchain
([`toolchains/defs.bzl`](../toolchains/defs.bzl)): `toolchains//:mojo` states
`mojo_compile` + `numa_single`, and `toolchains//:mojo_multi_numa` (the
private toolchain of `mojo_multi_numa_test`) states `mojo_compile` +
`numa_multi`. A toolchain's `exec_compatible_with` binds every target that
uses it. The toolchain unpack and copy targets state `light` themselves.

Buck2 chooses the execution platform per target, not per action, so all of a
target's actions run on one class of worker
([mojo/README.md](../mojo/README.md#multi-numa-tests) shows what that means
for multi-NUMA tests). `buck2 audit execution-platform-resolution <target>`
shows which configuration a target got and why the others were skipped.
[Test 10](../tests/README.md#10-execution-platforms) pins the resolution of
the examples and the toolchain targets, and
[test 12](../tests/README.md#12-action-platforms) that each action really
ran with its platform's property set.

## Local or remote

[`default/BUCK`](default/BUCK) calls `komira_default_execution_platforms`
([`defs.bzl`](defs.bzl)), which registers one of two sets:

- **Local (the default).** When `[komira_re]` names no `light_properties` or
  `mojo_compile_properties`, `komira_local_execution_platforms` registers
  `exec-mojo` and `exec-light` with a local executor only: every action runs
  on this machine, with no remote cache. It refuses a host that is not Linux
  x86_64, since every toolchain action is a Linux x86_64 binary. It registers
  no `exec-mojo-multi-numa` (nothing knows how many NUMA nodes the host has,
  so a `mojo_multi_numa_test` fails to configure) and no macOS platform.
- **Remote.** When `.buckconfig.local` names those property sets, it
  registers exactly what `komira_execution_platforms` registers from them
  (below).

`[komira] execution = local | remote` (or `-c komira.execution=...` on one
command) overrides the choice; the default is `auto`. Both sets register each
platform under the label of the configuration it realizes, so a target's
configuration, its output paths and its commands are the same either way: a
remote action's digest does not depend on whether local execution exists.
What a local action does and does not guarantee is in
[DEVELOPMENT.md](../../../DEVELOPMENT.md#what-a-local-build-guarantees).

## Your own worker pools

`komira_execution_platforms(name, light, mojo_compile, mojo_compile_multi_numa = None)`
([`defs.bzl`](defs.bzl)) registers one remote execution platform per
configuration, given the exact REAPI platform property dict of the workers
that realize it. Every platform it registers runs remotely only (local
execution disabled), reads the remote cache, and uploads no results of its
own.

A standalone checkout reads those sets from `[komira_re]` in
`.buckconfig.local`, via `re_properties("<key>")`
([`default/BUCK`](default/BUCK), through `komira_default_execution_platforms`):

| `[komira_re]` key | configuration | required |
|---|---|---|
| `light_properties` | `exec-light` | yes |
| `mojo_compile_properties` | `exec-mojo` | yes |
| `mojo_compile_multi_numa_properties` | `exec-mojo-multi-numa` | no |

Each value is comma-separated `key=value` pairs matching the properties your
workers advertise, e.g. `pool=light`. Two keys may name the same set if you
have one kind of worker (except the multi-NUMA one, below). A repository
using komira calls the same macro with its own sets, written inline or read
the same way ([tools/build/README.md](../README.md#using-komira-from-another-repository)).

Two details keep action digests portable:

- **Registration order.** A target that states no execution constraint gets
  the first platform, so `exec-mojo` comes first: an unconstrained action lands
  on a worker able to run anything komira runs.
- **Platform names.** Each registered platform is named after the abstract
  configuration it realizes (`komira//tools/build/platforms:exec-mojo`, ...),
  not after the target that registers it. The name keys the configuration of
  every exec dep, and so appears in their output paths; naming it this way
  keeps the digests of a mounting repository equal to a standalone checkout's.
- **macOS workers.** `darwin_mojo_compile_properties` registers
  `exec-mojo-darwin-arm64` for the `darwin-arm64` target platform; it needs
  `darwin_macos_hosts` as well. See [the toolchain README](../toolchains/README.md),
  "macOS".

## Multi-NUMA runs

`exec-mojo-multi-numa` is registered only when
`mojo_compile_multi_numa_properties` is set. Without it, a target requiring
`numa_multi` fails to configure (`Can't find toolchain_dep execution
platform`, with `exec-mojo` skipped because `numa_multi` is not satisfied),
before any action runs. A repository that sets it must point it at workers
that can each place a process across more than one NUMA node: every CPU and
all memory of at least two nodes visible to the action (no cpuset or memory
binding narrowing it to one node), with the same OS image and runtime floor
as the `mojo_compile` workers, since the binary it runs was built there.

The constraint is only a claim about those workers, so the hardware is
checked too. `komira_execution_platforms` fails if the multi-NUMA property
set equals the `mojo_compile` one. And every multi-NUMA run (the build's run
check and the `buck2 test` command) starts through
[`mojo/numa_guard.sh`](../mojo/numa_guard.sh), which exits 3 with
`numa_guard: REFUSING to run` unless the action can use at least
`numa_nodes` (default 2) NUMA nodes: online and with memory
(`/sys/devices/system/node`), in its own `Mems_allowed_list`, and holding a
CPU in its own `Cpus_allowed_list` (`/proc/<pid>/status`). A property set
that routes to a single-NUMA worker, or a worker narrowed to one node by a
cpuset, affinity mask or memory binding, goes red instead of green.
[Test 11](../tests/README.md#11-multi-numa-hardware) exercises each of
these refusals, using the stand-in platform in
[`tests/negative/numa_standin`](../tests/negative/numa_standin/BUCK).
