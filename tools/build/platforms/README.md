# Platforms: what a target is built for, and where its actions run

Three separate questions decide how Buck2 builds a target. Keep them apart
and the rest of this page follows.

| question | answered by | in komira |
|---|---|---|
| What is this target **built for**? | the **target platform** | `linux-x86_64` (the default), or `darwin-arm64` with `--target-platforms` |
| **Which tools** build it? | the **toolchain**, chosen by the target platform | `toolchains//:mojo` picks the linux or the macOS Mojo toolchain from the target platform's OS; C/C++, Rust and protobuf are linux x86_64 only |
| **Where do its actions run?** | the **execution platform**, chosen by what the toolchain says it runs on | one per OS: `linux-x86_64`, and `darwin-arm64` when macOS workers are configured |

## Target platforms

[`BUCK`](BUCK) declares two, each an OS and a CPU and nothing else:

| platform | constraints | used |
|---|---|---|
| `linux-x86_64` | `prelude//os/constraints:linux`, `prelude//cpu/constraints:x86_64` | for every target, by default (`[parser]` in `.buckconfig`) |
| `darwin-arm64` | `prelude//os/constraints:macos`, `prelude//cpu/constraints:arm64` | `buck2 build --target-platforms komira//tools/build/platforms:darwin-arm64 <targets>` |

A target that only makes sense on one OS says so with
`target_compatible_with`; a wildcard build for the other platform skips it
rather than failing.

## Toolchains

A rule takes its tools from a toolchain target (`toolchains//:mojo`,
`toolchains//:cxx`, ...; see [the toolchain README](../toolchains/README.md)).
Each toolchain is hermetic: every tool it runs is a pinned download, never
something found on the machine running the action. `toolchains//:mojo` is a
`select` on the target platform's OS, so a linux target gets the linux
compiler closure and a darwin target the macOS one.

A toolchain also states, in `exec_compatible_with`, the OS and CPU of the
machine its actions need: the linux toolchains state
`LINUX_X86_64`, the macOS Mojo toolchain `DARWIN_ARM64` (both in
[`defs.bzl`](defs.bzl)). That statement binds every target using the
toolchain, and it is the only thing any rule says about where an action
runs. Targets that only unpack or copy files, including the macOS
toolchain's files, state `LINUX_X86_64` themselves: they run linux tools.

## Execution platforms

An execution platform is a place actions can run: a configuration plus an
executor (this machine, or a remote-execution service with a property set).
komira registers **one per OS**, under the label and with the configuration
of the target platform of the same name. A tool built to run inside an
action is therefore configured exactly like a target built for that OS.

For each target, Buck2 takes the first registered execution platform that
satisfies the target's `exec_compatible_with` (its own and its toolchains').
In practice: everything linux runs on `linux-x86_64`; the compiles, gated
tests and run checks of a darwin target run on `darwin-arm64`.

The build rules say nothing about worker pools, worker sizes or NUMA
placement. Which machine of a remote service runs an action is the
service's decision, made from the one property set of the platform (a
service that learns each action's memory size, for example, places it by
that). Multi-NUMA and performance runs are not part of the build graph;
they run on reserved hardware outside it.

To see what a target got, and why the others were skipped:

```sh
buck2 audit execution-platform-resolution //tools/build/examples:hello
```

[Test 10](../tests/README.md#10-execution-platforms) pins the resolution of
the examples and the toolchain targets, and
[test 12](../tests/README.md#12-action-platforms) that every action really
ran with the linux property set.

## Local or remote

[`default/BUCK`](default/BUCK) calls `komira_default_execution_platforms`
([`defs.bzl`](defs.bzl)), which registers one of two sets:

- **Local (the default).** When `[komira_re]` names no property set,
  `komira_local_execution_platforms` registers `linux-x86_64` with a local
  executor only: every action runs on this machine, with no remote cache. It
  refuses a host that is not Linux x86_64, since every toolchain action is a
  Linux x86_64 binary, and registers no macOS platform.
- **Remote.** When `.buckconfig.local` names the linux property set, it
  registers exactly what `komira_execution_platforms` registers from it
  (below).

`[komira] execution = local | remote` (or `-c komira.execution=...` on one
command) overrides the choice; the default is `auto`, which also refuses a
checkout whose `[buck2_re_client]` names a service but whose `[komira_re]`
names no property set. Both sets register the same labels and
configurations, so a target's output paths and commands are the same either
way: a remote action's digest does not depend on whether local execution
exists. What a local action does and does not guarantee is in
[DEVELOPMENT.md](../../../DEVELOPMENT.md#what-a-local-build-guarantees).

## Remote workers

`komira_execution_platforms(name, linux, darwin = None)`
([`defs.bzl`](defs.bzl)) registers one remote execution platform per OS,
given the exact REAPI platform property dict every action of that OS
carries. Every platform it registers runs remotely only (local execution
disabled), reads the remote cache, and uploads no results of its own.

A standalone checkout reads those sets from `[komira_re]` in
`.buckconfig.local` ([`.buckconfig.local.example`](../../../.buckconfig.local.example)):

| `[komira_re]` key | execution platform | required |
|---|---|---|
| `linux_properties` | `linux-x86_64` | yes, for remote execution |
| `darwin_properties` | `darwin-arm64` | no; needs `darwin_macos_hosts` as well |
| `darwin_macos_hosts` | (the macOS hosts a compile may run on) | with `darwin_properties` |

Each property value is comma-separated `key=value` pairs matching what the
service routes on, e.g. `pool=default`. The macOS set must differ from the
linux one, so a macOS action can never match a linux worker. Keys of the
earlier per-class layout (`light_properties`, `mojo_compile_properties`,
`mojo_compile_multi_numa_properties`, `darwin_mojo_compile_properties`) are
refused at load, naming their replacement. A repository using komira calls
the same macro with its own sets, written inline or read the same way
([tools/build/README.md](../README.md#using-komira-from-another-repository)).

Two details keep action digests portable:

- **Registration order.** A target that states no execution constraint gets
  the first platform, so `linux-x86_64` comes first, and `darwin-arm64`
  last: a platform added later must never become the first match of an
  action that states no OS.
- **Platform names.** Each registered platform is named after the target
  platform whose configuration it uses (`komira//tools/build/platforms:linux-x86_64`),
  not after the target that registers it. The name keys the configuration of
  every exec dep, and so appears in their output paths; naming it this way
  keeps the digests of a mounting repository equal to a standalone checkout's.

## macOS

`darwin_properties` registers the `darwin-arm64` execution platform; it
needs `darwin_macos_hosts` too, since a macOS host's SDK and tools are not
inputs of the action. Setting up the workers is in
[the toolchain README](../toolchains/README.md), "macOS".
