# Checks

[`run_checks.sh`](run_checks.sh) runs end-to-end checks of the Mojo rules,
the toolchain and the platforms. Every check can fail, and several exist to
prove that something is refused. Run it from the repository root:

```sh
tools/build/checks/run_checks.sh                 # all checks
tools/build/checks/run_checks.sh --no-umbrella   # skip check 7 (four scratch checkouts)
tools/build/checks/run_checks.sh --no-run        # skip check 9 (a scratch clone)
tools/build/checks/run_checks.sh --no-uncached   # skip the uncached half of check 15
```

It prints one `PASS`, `FAIL` or `SKIP` line per check, then the directory
holding every log, and exits 1 if any check failed. `BUCK2=...`, `TMPDIR` and
`KEEP_SCRATCH=1` are described in
[DEVELOPMENT.md](../../../DEVELOPMENT.md#4-run-the-checks).

The checks run where the checkout builds, read from the execution platforms
buck2 registers, and the first line of output names it:

- `MODE  remote`: `.buckconfig.local` names a remote-execution service
  ([DEVELOPMENT.md](../../../DEVELOPMENT.md#3-optional-build-on-a-remote-execution-service)).
  Every action runs there, and every check runs. CI runs this way.
- `MODE  local`: no service is configured; every action runs on this
  machine. These need a service and print `SKIP ... needs a remote-execution
  service` instead: 7 (remote cache hits across checkouts), 9 (what a remote
  build downloads), the registered-platform half of 10 and the stand-in half
  of 11 (both built from the `[komira_re]` worker sets), 12 (per-action
  worker property sets) and 24 (macOS workers). Check 3 prints `SKIP ...
  needs remote input isolation`: its red relies on the executor staging only
  declared inputs, and an unsandboxed local action may find the undeclared
  package in the checkout. Checks 1, 22 and 23 require every action to have
  run locally instead of remotely. **The local branch of this script has not
  yet run end to end** (it would compile Mojo locally); until it has, a
  local-mode PASS line is unmeasured.

A mix of local and remote platforms is refused before any check runs.

This directory is the `checks` cell. Its fixtures, several of which must fail
to build, are outside `//...`; they use the rules through their own cell
rather than reusing the [examples](../examples/) (see
[tools/build/README.md](../README.md)). The numbers below are the ones
`run_checks.sh` uses.

## 1. Examples

The [examples](../examples/BUCK) build, their run checks pass (stdout
compared byte for byte), and every action that executed ran remotely or was a
remote cache hit -- or, in a local-only run, ran locally (read from `buck2 log
what-ran`; an invocation that executed nothing says so instead of passing).

```sh
buck2 build //tools/build/examples:hello //tools/build/examples:hellopkg //tools/build/examples:hello_pkg_user \
    //tools/build/examples/libgate_ok:libgate_ok //tools/build/examples:test_hellopkg
buck2 build '//tools/build/examples:hello[run_check]' '//tools/build/examples:hello_pkg_user[run_check]'
```

Sub-targets are built in their own invocation: `buck2 build //... 'T[sub]'`
was observed to skip the sub-target.

## 2. Gate

[`libgate_bad`](libgate_bad/BUCK) has a test that fails on purpose. The library
fails with `GATED TEST FAILED` while its `[ungated]` package builds, so the red
comes from the test and not the compile. A binary depending on it fails the
same way, and a binary naming its `[ungated]` sub-target in `deps` fails
analysis (`MojoInfo`): the gate cannot be bypassed.

```sh
buck2 build checks//libgate_bad:libgate_bad            # must fail: GATED TEST FAILED
buck2 build 'checks//libgate_bad:libgate_bad[ungated]' # must build
buck2 build checks//libgate_bad:gated_consumer         # must fail: GATED TEST FAILED
buck2 build checks//libgate_bad:bypass_consumer        # must fail: MojoInfo
```

## 3. Missing dependency

Packages reach the compiler only through `deps`: [`missing_dep`](missing_dep/BUCK)
imports `hellopkg` without depending on it and must fail with
`unable to locate module 'hellopkg'`.

```sh
buck2 build checks//missing_dep:missing_dep
```

## 4. Closure refusal

The toolchain refuses an incomplete closure (exit 2, `REFUSING: toolchain
member`) instead of falling back to anything on the worker:
[`closure_refusal`](closure_refusal/BUCK) builds with a toolchain missing a
member.

```sh
buck2 build checks//closure_refusal:hello_incomplete_toolchain
```

## 5. Host paths

No action's argv or environment names an absolute host path, read from
`buck2 aquery` over the examples and their run checks, the Rust example and
the protobuf checks (rustc, protoc, the plugin, the generated packages). The
scan first proves it detects a planted absolute path.

## 6. Outputs

Built outputs are path-free: the linked binary's only run path is DT_RUNPATH
`$ORIGIN/lib`, and no string in it names a `buck-out` directory. (Inside every
compile action the wrapper also refuses an output containing that action's
working directory, exit 4.) Needs `readelf` on the client.

```sh
buck2 build //tools/build/examples:hello --materializations all --show-full-simple-output
```

## 7. Umbrella cache

A repository using komira as its `komira` cell -- mounted as a git submodule
at `./komira` or `./third_party/komira`, or fetched as a git external cell --
gets remote cache hits with the same action digests as a standalone checkout.
[`umbrella_cache.sh`](umbrella_cache.sh) snapshots the working tree, builds
the examples in a fresh standalone clone, then in three scratch repositories
configured from [`consumer.buckconfig`](../consumer.buckconfig) (the external
one from a `file://` bare clone pinned to the snapshot's commit), each with a
fresh daemon; it fails unless every consumer command is a cache hit
(`Commands: N (cached: N, remote: 0, local: 0)`, N > 0), buck2 fetched the
external cell at that commit, and the digests are identical. Skipped with
`--no-umbrella`.

It also holds the consumer's `toolchains` cell to its contract. The consumer
at `./third_party/komira` builds with
[`umbrella/toolchains.BUCK.frozen`](umbrella/toolchains.BUCK.frozen), the
copy a consumer made when komira was first published, not a fresh one, so a
change that needs every consumer to edit its copy fails. Every checkout's
`buck2 targets toolchains//:` must equal
[`umbrella/toolchains_targets.txt`](umbrella/toolchains_targets.txt). And
before building, the `./komira` submodule consumer and the external consumer
each plant `komira_toolchains(mojo = {"target_cpu": "x86-64-v2"})`: `buck2
aquery` of the hello example's `mojo_build` must show `--target-cpu
x86-64-v2` there and `x86-64-v3` standalone. Digest equality alone passes
whichever `toolchains` cell the rules read; this fails if a rule default
stops naming the consumer's cell, e.g. a `komira//` toolchain label, which
would silently ignore every consumer override. The examples include C and C++ (`cshim:cadd_user`,
`snappy:test_snappy`): a C source read from the project tree is an action
input at a path that depends on the mount point, so komira's `cxx_library`
targets take their sources through `staged_files` (the first run of this check
with C targets had 8 of 28 actions re-run in a submodule). They also include
Rust (`rust:prost_roundtrip` and the protobuf plugin,
`proto-codegen:protoc-gen-mojo`), whose compiles copy their sources into
buck-out for the same reason (without it, 3 of 55 actions re-ran). See
[Using komira from another repository](../README.md#using-komira-from-another-repository).

```sh
tools/build/checks/umbrella_cache.sh
```

## 8. Host floor and runtime libraries

During a real compile, and a run of the binary it built, the loader maps
`libstdc++.so.6` and `libgcc_s.so.1` from the toolchain, and nothing from the
worker except glibc's own objects ([`runtime_libs`](runtime_libs/BUCK),
read from `LD_DEBUG`). The toolchain libraries the run loaded are exactly the
ones a runnable directory carries in `lib/` (`komira//tools/build/toolchains:mojo_runtime`), no
more, no fewer, and every run path those libraries carry is
`$ORIGIN`-relative. See the
[host floor](../toolchains/README.md#host-floor).

```sh
buck2 build checks//runtime_libs:loader_trace --show-full-simple-output   # prints the report's path
buck2 build '//tools/build/examples:hello[runnable]' --show-full-simple-output
```

## 9. buck2 run

`buck2 run //tools/build/examples:hello` prints the greeting on this machine
from a fresh clone, downloads only the binary and its runtime libraries (under
a byte limit, and never the compiler), and the runnable directory still starts
after it is moved. [`buck2_run.sh`](buck2_run.sh); skipped with `--no-run`.

```sh
tools/build/checks/buck2_run.sh
```

## 10. Execution platforms

Mojo compiles, gated tests and run checks resolve to `exec-mojo`
(`mojo_compile`, `numa_single`), and the toolchain unpack and copy targets to
`exec-light`. A target requiring `numa_multi` ([`numa`](numa/BUCK)), with no
platform providing it, fails to configure and runs no action; given one
(resolution only, nothing is built), it resolves to it. See
[platforms/README.md](../platforms/README.md).

```sh
buck2 audit execution-platform-resolution -c komira_re.mojo_compile_multi_numa_properties= \
    //tools/build/examples:hello checks//numa:hello_multi_numa
```

## 11. Multi-NUMA hardware

The multi-NUMA run checks the hardware it got, not only its label:

- [`numa_guard.sh`](../mojo/numa_guard.sh) gives the right verdict on 12
  made-up topologies (`checks//numa:guard_cases`, a remote action;
  [`guard_cases.sh`](numa/guard_cases.sh));
- `komira_execution_platforms` refuses a multi-NUMA property set equal to the
  `mojo_compile` one;
- on a stand-in platform whose multi-NUMA workers are the single-NUMA
  `mojo_compile` workers ([`numa/standin`](numa/standin/BUCK)), both the
  build's run check and `buck2 test` refuse to start
  (`numa_guard: REFUSING to run`).

```sh
buck2 build checks//numa:guard_cases --show-full-simple-output
```

## 12. Action platforms

Actions run with their platform's property set, read per action: an uncached
build of `//tools/build/examples:hello` (its own daemon under a fixed
`--isolation-dir`, `--no-remote-cache`, so every action really executes) must
record the `light` set for `zig_unpack`, `zig_build_exe`, `conda_unpack` and
`mojo_runtime`, and the `mojo_compile` set for `mojo_build` (`buck2 log
what-ran`; a cache hit records no properties, so a warm build cannot answer
this). Costs about 80 s of remote execution; the isolated daemon's
`buck-out/komira_checks_uncached` (~50 MB) is reused per run.

## 13. Bundle parity

A program built as a bundle behaves as its executable: stdout, stderr and exit
status agree byte for byte across argv, environment, `exit()`, an unhandled
error, buffered output, a data file found through `/proc/self/exe`, `abort()`
and `SIGSEGV` (status and stdout exact, the stack dump's first line), and a
symlink invocation with another `argv[0]` (`checks//bundle_parity:parity`, a
remote action).

## 14. Launcher CPU levels

The launcher's CPU level function gives glibc's level for the made-up CPUs of
[`cpu_models.h`](../package/launcher/cpu_models.h): the hand-written ones, and
one per feature glibc requires, a CPU of that level or above with just that
bit cleared (`//tools/build/package:level_test`, a remote action). On an x86-64
glibc host, its level for this host's CPU agrees with this host's glibc loader
([`glibc_level.sh`](glibc_level.sh)).

## 15. Bundle

The bundle of `//tools/build/examples:hello` ([`bundle.sh`](bundle.sh)):
layout, run paths and `SHA256SUMS` against [`bundle_expected`](bundle_expected/);
it runs from a relocated copy and through a symlink on `PATH`; a CPU below
x86-64-v3 gets the one-line refusal (test launcher); two uncached builds give
byte-identical bundles, tarballs and docker archives and the same image digest
(skipped with `--no-uncached`; about 3 minutes of remote execution).

## 16. Package formats

The package formats of `//tools/build/examples:hello` ([`formats.sh`](formats.sh)):
the tarball and the OCI image follow the determinism rules and hold the
bundle; the image's blobs, config (entrypoint, linux/amd64) and pinned base
layers are checked; the base is fetched only by pinned downloads; `docker run`
of the loaded image prints the greeting (SKIP without docker). See
[packaging](../package/README.md).

## 17. Doc links

Every relative link in the repository's Markdown resolves: the target is a
file tracked by git, or a directory holding one (a link to an ignored file
such as `.buckconfig.local` resolves in a working tree and is dead in a fresh
clone), it stays inside the repository, and a `#fragment` names a heading of
the target file. [`doc_links.sh`](doc_links.sh) runs on its own and needs no
build farm, but needs `git` and `python3` on the client and a git work tree
to read. `run_checks.sh` first runs it on a planted git tree and requires it
to name each of a missing file, a bad anchor, a link leaving the tree and a
link to an untracked file, and nothing else.

```sh
tools/build/checks/doc_links.sh            # the repository
tools/build/checks/doc_links.sh <dir>      # any other git work tree
```

## 18. Configuration hashes

The configuration hashes of `komira//tools/build/platforms:exec-light`, `:exec-mojo` and
`:linux-x86_64`, read with `buck2 cquery 'deps(komira//tools/build/examples:hello)'`,
equal the pins in `run_checks.sh`. A configuration's hash is keyed by its
platform's label and constraints and appears in the output paths, and so in
the digest, of every configured action, product code included. Moving the
`platforms` package, renaming a platform or changing a constraint therefore
invalidates every cached action here and in every repository using
komira; the pins make that a deliberate edit. Upgrading buck2 may change the
hashes too.

## 19. Exported cells

Every label outside a comment in the BUCK and `.bzl` files a repository
using komira loads or copies -- those under `tools/build/{mojo,rust,proto-codegen,toolchains,platforms,package,examples,cells}`
and `third_party` -- names the `komira`, `prelude` or `toolchains` cell, the only cells such a
repository has. A label naming `checks`, which exists only in a standalone
checkout, would load here and fail to load there (as `visibility =
["checks//formats:"]` on `examples:hello` once did). The check fails if a
searched directory is missing, or if it finds fewer than 20 labels, so a scan
that reads nothing cannot pass.

## 20. C and C++ dependencies

[`cxx_checks.sh`](cxx_checks.sh), sourced by `run_checks.sh`. A Mojo binary
calling a C function links and prints the C result when the `cxx_library` is
in `deps` (`checks//c_deps:c_linked`), and its link fails on the undefined
symbol when it is not (`c_missing`); `deps` refuses a target that is neither
a Mojo package nor a C/C++ library (`bad_dep`). The two cshim tests, a gated library
test and a `mojo_test`, use `assert_equal` on `Int32` and index a `List`,
which record the test file's source location in the binary; they build only
because the wrapper strips the staging directory from it
(`-strip-file-prefix`), and fail with exit 4 on the worker's absolute path
without it (`test_source_paths`). C compiles and archives
resolve to `exec-light`, the Mojo targets using them to `exec-mojo`. The
snappy test binary, which links C++ with zig's static libc++, carries
libc++abi and exports no dynamic symbol, so its C++ runtime cannot interpose
on the `libstdc++.so.6` the Mojo runtime loads.

## 21. Location path

`checks//location_path:main[run_check]`: a `mojo_binary` whose main file
indexes a `List`, so the binary records the main file's source location. It
builds only because the wrapper strips the staging directory from recorded
paths, and its run check compares stdout exactly. Check 20 covers the same
for tests with a C dependency; this one is a plain binary.

## 22. Rust rules

[`rust_checks.sh`](rust_checks.sh), sourced by `run_checks.sh`. The example
binary `//tools/build/examples/rust:prost_roundtrip` uses prost's derive
macro, so it compiles registry crates, a proc-macro and the zig link; its run
check compares stdout exactly, and must have run remotely. A binary using
prost without depending on it fails to compile
(`checks//rust_missing_dep:main`): crates reach rustc only through `deps`.
The host floor of rustc: every `NEEDED` entry of the sysroot's `bin/rustc`
and of its shared libraries (read with the host's `readelf`) is glibc's or a
file in a directory named by that object's own `$ORIGIN`-relative run path,
and no run path is absolute.

## 23. Protobuf

[`proto_checks.sh`](proto_checks.sh), sourced by `run_checks.sh`, over
[`proto/`](proto/BUCK). Generated packages pass tests that encode and decode
through a minimal runtime (the bytes prost produces), and must have run
remotely. The generated struct follows a field rename in the `.proto`, and
the test written for the old name fails to compile
(`checks//proto:test_person_renamed`). A `.proto` using an imported file's
message compiles only with that file bundled
(`checks//proto:team_unbundled_proto` must fail).

Generation is deterministic: two uncached builds (an isolated daemon,
`komira_checks_det`, its buck-out cleaned, `--no-remote-cache`) of the
plugin, the generated sources of two packages and one compiled package give
the same bytes. Each build must have run the plugin's rustc and both
generations remotely, or the comparison proves nothing. About 16 minutes;
skipped with `--no-uncached`.

## 25. Local default

[`local_default.sh`](local_default.sh): a fresh clone with no
`.buckconfig.local` builds on this machine. It snapshots the working tree
into a scratch clone (`.buckconfig.local` is gitignored, so it is never
copied) and runs buck2 there with its own daemon, no user or system
buckconfig and `HOME` in the scratch directory. On Linux x86_64, every
platform `[build] execution_platforms` registers is local-only (exactly
`exec-mojo`, `exec-light`); Mojo targets and the toolchain targets resolve to
them with the configuration hashes check 18 pins, so a local and a remote
build configure every target identically; a `numa_multi` target does not
configure; `-c komira.execution=remote` refuses, naming `[komira_re]`; a
`[buck2_re_client]` `address`, `engine_address`, `cas_address` or
`action_cache_address` with no `[komira_re]`
refuses instead of building locally (a missing or misspelled `[komira_re]`
fails closed), as does a `[komira_re]` without `light_properties`, while
`-c komira.execution=local` still registers the local platforms;
`[komira] execution = remote` in a user `~/.buckconfig.local` refuses; and an
unknown mode refuses. On any other host the clone must refuse local
execution, naming the host and `.buckconfig.local`. Last, on Linux x86_64,
it builds `komira//tools/build/toolchains:conda_unpack` and `:zig_cc_launcher`
locally, from a daemon started with an empty environment and `PATH`: zig is
unpacked, then the two zig programs are built at once, and every action must
have run locally. Local actions share the checkout root as their working
directory, so this is what fails if two of them share scratch space. It
downloads about 45 MB, compiles no Mojo, and runs in both modes.

```sh
tools/build/checks/local_default.sh
```

## 26. aws-lc and s2n-tls

[`c_libs_checks.sh`](c_libs_checks.sh), sourced by `run_checks.sh`.
Drift: `third_party/<lib>/srcs.bzl` must equal what
[`third_party/gen_srcs.py`](../../../third_party/gen_srcs.py) reads out of
the pinned archive's CMake lists (the archive is fetched through its
`pinned_file` target; the generator runs on the machine running the checks).
libcrypto passes aws-lc's own self tests and SHA-256, AES-128 and ChaCha20
known-answer vectors, and an s2n-tls client and server complete a TLS 1.3
handshake with certificate verification, both driven from Mojo in a run
check on a worker. Every probe named in `third_party/s2n-tls/features.bzl`
compiles (`checks//s2n_probes`) and every other probe fails to, so a feature
define cannot be added or dropped without its probe agreeing. Neither test
binary exports a dynamic symbol.

## Diagnostics

[`re_probe`](re_probe/BUCK) is not a check: `buck2 build checks//re_probe:probe`
records what a remote worker provides, the evidence behind the
[host floor](../toolchains/README.md#host-floor).
