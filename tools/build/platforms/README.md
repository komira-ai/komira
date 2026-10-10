# Platforms: what a target is built for, and where its actions run

Three separate questions decide how Buck2 builds a target. Keep them apart
and the rest of this page follows.

| question | answered by | in komira |
|---|---|---|
| What is this target **built for**? | the **target platform** | the client's own platform (`host`, below), or any registered row with `--target-platforms` |
| **Which tools** build it? | the **toolchain**, chosen by the target platform | `toolchains//:mojo` picks the linux or the macOS Mojo toolchain from the target platform's OS; C/C++, Rust and protobuf are linux x86_64 only |
| **Where do its actions run?** | the **execution platform**, chosen by what the toolchain says it runs on | one per (os, cpu): `linux-x86_64`, and `darwin-arm64` when macOS workers are configured |

## The platform table

A platform is an (os, cpu) pair, and [`table.bzl`](table.bzl) has one row for
each. Everything else is derived from the row: the `platform()` targets in
[`BUCK`](BUCK), the execution platforms and the `[komira_re]` key of each
([`defs.bzl`](defs.bzl)), the toolchains' constraints, zig triple, CPU floor
and runtime library list, the pinned downloads of every toolchain, and the
default platform below. Adding a platform is one row plus its pins.

A row states, all required:

| field | what it is |
|---|---|
| `os`, `cpu`, `constraints` | the constraint values that name the platform; also the `exec_compatible_with` of the tools that run on it |
| `host` | what `host_info()` reports on a machine of this platform; it only SELECTS the row |
| `re_key`, `pool` | the `[komira_re]` key of this platform's worker property set (the value is the client's, never committed), and the pool a client sets it to (`pool=mojo-sized`); every key and every pool is unique to its row |
| `zig_triple`, `unpack_triple` | the zig target of its links (`<arch>-<os>-<abi>.<os floor>`) and of the static tools that unpack archives |
| `target_cpu`, `target_features` | the CPU floor every compile targets, whatever worker runs it |
| `cache_line_bytes`, `page_bytes`, `features`, `applets` | the cache line and page size of the platform, what it has that tests select on (`epoll`, `erms`, `futex`, `kqueue`, `neon`, `thp`, `ulock`, `x86_simd`), and the utilities a wrapper script may call (a list, or `none(reason)` where a pinned busybox carries them) |
| `golden_config_hash`, `zig_exe_sha256` | the configuration hash of the row's platform (what every output path and action key carries; `pending` for a row with no platform), and the sha256 of the `zig` executable inside the zig archive, which the bootstrap checks after unpacking |
| `object_format`, `runtime_libs`, `os_floor` | `elf` or `macho`; what a built binary loads from the toolchain's `lib/`; the oldest OS it runs on |
| `assets` | every pinned download, by role (`zig`, `mojo_compiler`, `pixi`, `rustc`, `rust_std`, `protoc`, `shellcheck`, `actionlint`, `busybox`, the conda runtime libraries `libgcc`, `libstdcxx`, `libzlib`, and kcov's source and static libraries `kcov_src`, `kcov_elfutils`, `kcov_zlib`, `kcov_bzip2`, `kcov_lzma`, `kcov_zstd`, [linux-x86_64 only](../toolchains/kcov/README.md), and branch coverage's LLVM 23 packages `llvm_branch_tools`, `llvm_branch_libllvm`, `llvm_branch_libxml2`, `llvm_branch_libiconv`, `llvm_branch_zstd`, `llvm_branch_rt`, [linux-x86_64 only](../toolchains/llvm_branch/README.md)): the name of its `pinned_file`, URL, sha256 and size in bytes, or `none(reason)` where a platform needs nothing |
| `oci_base`, `bundles` | the container base (its manifest, and its blobs' digests and sizes), and whether bundles, OCI images and the launcher are products of this platform (Linux server artifacts) |
| `registered` | `True`: a build key. `False`: reserved |

**The table checks itself when it loads**: a row missing a field or a pin, a
pin that is not an https URL with a 64-digit lowercase sha256 and a positive
`size`, a `pending` pin
in a registered row, two rows sharing a key or a host, an executable pin (`busybox`, `pixi`)
not pinned `executable = True`, or `pixi` pinned at two releases across rows, fail every package that
reads the table, naming the row and the pin. [`tests//functional/platform_table`](../tests/functional/platform_table/BUCK)
holds the cases, each a table with one defect, and
[`check.sh`](../tests/functional/platform_table/check.sh) is test 37 of
`run_tests.sh`. It also checks that each registered row's `golden_config_hash`
is the hash buck2 gives the platform, and that the macOS row's `applets` are
those of [`busybox.sh`](../mojo/darwin/busybox.sh).

Not in the table yet, each with the PR that adds it: the compression-library
source pins (PR 7), the `buck2` binary pin and the unpack-tier `-target` (PR 2),
and `link_driver` (PR 3).

### Limits, and the golden

Every place the build says it builds for one platform only is a **limit**:
a `target_compatible_with` or a refusal. Each is declared at its site by a
`komira-limit:<id>` marker and listed in [`limits.tsv`](limits.tsv) with the
PR that deletes it. [`limits_retired.sh`](../tests/functional/platform_table/limits_retired.sh)
refuses a `target_compatible_with` with no marker, a marker with no row, a row
with no marker, and a row whose retiring PR has merged (a commit subject on
main contains `[native-pr:<n>]`) while its marker is still there. A PR that
deletes a limit deletes its marker and its row; `never` is only for product
statements (images are a Linux product), including a test whose subject is
one OS's features (the farm capability probe tests the Linux kernel features
the Linux server products' end-to-end tests need).

The **golden** ([`tools/build/tests/golden`](../tests/golden/golden.sh)) is the
zero-execution check for `linux-x86_64`: its configuration, and a hash of the
`buck2 aquery` (command, category, identifier, kind of every action) of eight
targets the build system owns. A PR that must not change what linux-x86_64
runs shows an empty diff of `linux-x86_64.golden`; one that does says so and
regenerates it with `golden.sh gen`.

Rows today:

| row | state | CPU floor | notes |
|---|---|---|---|
| `linux-x86_64` | registered | `x86-64-v3` | the pinned configuration every cached action is keyed by; served by `pool=mojo-sized` |
| `darwin-arm64` | registered | `apple-m1` | served by `pool=darwin-sized`; links through the host's `cc` for now (see the toolchain README); its zig, rustc, protoc and linter pins are recorded for the unpack tier |
| `linux-arm64` | **reserved** | `generic` ARMv8-A with outline atomics | Ampere Altra servers (Neoverse N1) are the main build machines and a Raspberry Pi must run what they build, so the floor is generic ARMv8-A, chosen at run time (outline atomics and dispatch) for anything wider. A tuned `neoverse-n1` build is a later, opt-in variant, not this row. Declared and pinned, not a build key: no `platform()` target, no execution platform, and `[komira_re] linux_arm64_properties` is refused |

## Target platforms

[`BUCK`](BUCK) declares one `platform()` per registered row, each an OS and a
CPU and nothing else, and `host`:

| platform | constraints | used |
|---|---|---|
| `host` | an alias of the row `host_info()` selects | the default target platform of every target (`[parser]` in `.buckconfig`): the client's own |
| `linux-x86_64` | `prelude//os/constraints:linux`, `prelude//cpu/constraints:x86_64` | on a Linux x86_64 client, by default; anywhere with `--target-platforms komira//tools/build/platforms:linux-x86_64` |
| `darwin-arm64` | `prelude//os/constraints:macos`, `prelude//cpu/constraints:arm64` | on a macOS arm64 client, by default; anywhere with `--target-platforms komira//tools/build/platforms:darwin-arm64` |

`host` is an alias, so the label, configuration and output paths of a Linux
x86_64 client's build are `linux-x86_64`'s own, unchanged. It supplies no tool,
path or flag: a machine is only ever used to pick a row. On a machine no
registered row matches (a Linux arm64 machine, for now), analysing `host`
fails naming why, and stating `--target-platforms` still works from it.
Building for another OS or CPU stays explicit.

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
komira registers **one per (os, cpu)**, under the label and with the configuration
of the target platform of the same name. A tool built to run inside an
action is therefore configured exactly like a target built for that platform.

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
  `komira_local_execution_platforms` registers the row that matches this
  host (`linux-x86_64` on a Linux x86_64 machine) with a local executor only:
  every action runs on this machine, with no remote cache. A host no
  registered row matches is refused, naming why. On a Mac it registers
  `darwin-arm64`, but every toolchain action that unpacks is still a Linux
  x86_64 binary, so a darwin target does not build there until the unpack
  tier has a darwin row of its own.
- **Remote.** When `[komira_re]` names the property set of this client's own
  platform, it registers exactly what `komira_execution_platforms` registers
  from it (below): that platform's pool, and every other platform that names
  one.

**Where actions run is decided by the platform a build defaults to, which is
the client's own.** With `execution = auto` (the default):

| `[komira_re]` names | a build with no `--target-platforms` runs |
|---|---|
| nothing | on this machine, for this machine's platform |
| this machine's platform's key (`linux_x86_64_properties` on Linux x86_64, `darwin_arm64_properties` on a Mac) | on that platform's remote pool |
| only ANOTHER platform's key | on this machine; the other key is read only by a build that states that platform with `--target-platforms`. It never sends host-platform work to the wrong pool, and never fails |

So a Mac with the Mac pool configured builds on the Mac farm, a Linux x86_64
machine with the Linux pool builds on the Linux farm, and a contributor with
no configuration builds on their own machine. A machine no registered row
matches cannot run locally, so any property set there selects remote.

`[komira] execution = local | remote` (or `-c komira.execution=...` on one
command) overrides the choice, and `remote` requires this client's own
platform's key. `auto` also refuses a checkout whose `[buck2_re_client]` names
a service but whose `[komira_re]` names no property set at all.

Both sets register the same labels and
configurations, so a target's output paths and commands are the same either
way: a remote action's digest does not depend on whether local execution
exists. What a local action does and does not guarantee is in
[DEVELOPMENT.md](../../../DEVELOPMENT.md#what-a-local-build-guarantees).

## Remote workers

`komira_execution_platforms(name, linux = None, darwin = None)`
([`defs.bzl`](defs.bzl)) registers one remote execution platform per (os, cpu),
given the exact REAPI platform property dict every action of that OS
carries. Every platform it registers runs remotely only (local execution
disabled), reads the remote cache, and uploads no results of its own.

A standalone checkout reads those sets from `[komira_re]` in
`.buckconfig.local` ([`.buckconfig.local.example`](../../../.buckconfig.local.example)):

| `[komira_re]` key | execution platform | required |
|---|---|---|
| `linux_x86_64_properties` | `linux-x86_64` | one of the two, for remote execution |
| `darwin_arm64_properties` | `darwin-arm64` | one of the two; needs `darwin_macos_hosts` as well |
| `linux_arm64_properties` | `linux-arm64` | **reserved**: refused if set, until that row is registered |
| `darwin_macos_hosts` | (the macOS hosts a compile may run on) | with `darwin_arm64_properties` |

Each property value is comma-separated `key=value` pairs matching what the
service routes on, e.g. `pool=mojo-sized`. The macOS set must differ from the
linux one, so a macOS action can never match a linux worker. A platform with
no set is not registered, so its actions cannot run remotely. Keys of the
earlier layouts (`linux_properties` and `darwin_properties`, which named a
platform by its OS alone, and the per-class `light_properties`, `mojo_compile_properties`,
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

`darwin_arm64_properties` registers the `darwin-arm64` execution platform; it
needs `darwin_macos_hosts` too, since a macOS host's SDK and tools are not
inputs of the action. Setting up the workers is in
[the toolchain README](../toolchains/README.md), "macOS".
