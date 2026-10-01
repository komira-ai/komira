# Tests

[`run_tests.sh`](run_tests.sh) runs the end-to-end tests of the Mojo rules,
the toolchain and the platforms. Every test can fail, and several exist to
prove that something is refused. Run it from the repository root:

```sh
tools/build/tests/run_tests.sh                 # all tests
tools/build/tests/run_tests.sh --no-umbrella   # skip test 7 (four scratch checkouts)
tools/build/tests/run_tests.sh --no-run        # skip test 9 (a scratch clone)
tools/build/tests/run_tests.sh --no-uncached   # skip the uncached half of test 15
```

It prints one `PASS`, `FAIL` or `SKIP` line per test, then the directory
holding every log, and exits 1 if any test failed. `BUCK2=...`, `TMPDIR` and
`KEEP_SCRATCH=1` are described in
[DEVELOPMENT.md](../../../DEVELOPMENT.md#4-run-the-tests).

## Layout

Each test has a number, its name in every document, and one section below.
What a test builds or runs lives in one of two directories, by what it must
do:

- [`functional/`](functional/): behaviour that must work. Its targets
  build, and its scripts pass on a correct tree.
- [`negative/`](negative/): planted defects that must go red. Every target
  there fails to analyse, to compile or to pass its gate, and
  `run_tests.sh` requires the failure it names (the message, not only the
  exit status); [`lint_weld.sh`](negative/lint_weld.sh) plants its defects
  in a snapshot of the tree.

A test with both halves keeps one package name in each, for example
`tests//functional/test_data` (the test runtime contract that works) and
`tests//negative/test_data` (the declarations and env that must go red).
`functional/` and `negative/` are not packages themselves: their
scripts belong to the root package of the cell, and are linted by `tests//:shell_lint`, which the root `//:tests_lints`
names. At the top of this directory are the driver,
[`tool_lib.sh`](tool_lib.sh), and the sections the driver sources
([`cxx_tests.sh`](cxx_tests.sh), [`rust_tests.sh`](rust_tests.sh),
[`proto_tests.sh`](proto_tests.sh), [`c_libs_tests.sh`](c_libs_tests.sh)).

The tests run where the checkout builds, read from the execution platforms
buck2 registers, and the first line of output names it:

- `MODE  remote`: `.buckconfig.local`, or a machine-wide buckconfig as on the
  CI runner, names a remote-execution service
  ([DEVELOPMENT.md](../../../DEVELOPMENT.md#3-optional-build-on-a-remote-execution-service)).
  Every action runs there, and every test runs. CI runs this way.
- `MODE  local`: no service is configured; every action runs on this
  machine. These need a service and print `SKIP ... needs a remote-execution
  service` instead: 7 (remote cache hits across checkouts), 9 (what a remote
  build downloads), 12 (per-action worker property sets) and 24 (macOS
  workers). Test 3 prints `SKIP ...
  needs remote input isolation`: its red relies on the executor staging only
  declared inputs, and an unsandboxed local action may find the undeclared
  package in the checkout. Tests 1, 22 and 23 require every action to have
  run locally instead of remotely. **The local branch of this script has not
  yet run end to end** (it would compile Mojo locally); until it has, a
  local-mode PASS line is unmeasured.

A mix of local and remote platforms is refused before any test runs, and so
is a client other than Linux x86_64 (test 33).

This directory is the `tests` cell. Its fixtures, several of which must fail
to build, are outside `//...`; they use the rules through their own cell
rather than reusing the [examples](../examples/) (see
[tools/build/README.md](../README.md)). The numbers below are the ones
`run_tests.sh` uses.

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

[`libgate_bad`](negative/libgate_bad/BUCK) has a test that fails on purpose. The library
fails with `GATED TEST FAILED` while its `[ungated]` package builds, so the red
comes from the test and not the compile. A binary depending on it fails the
same way, and a binary naming its `[ungated]` sub-target in `deps` fails
analysis (`MojoInfo`): the gate cannot be bypassed.

```sh
buck2 build tests//negative/libgate_bad:libgate_bad            # must fail: GATED TEST FAILED
buck2 build 'tests//negative/libgate_bad:libgate_bad[ungated]' # must build
buck2 build tests//negative/libgate_bad:gated_consumer         # must fail: GATED TEST FAILED
buck2 build tests//negative/libgate_bad:bypass_consumer        # must fail: MojoInfo
```

## 3. Missing dependency

Packages reach the compiler only through `deps`: [`missing_dep`](negative/missing_dep/BUCK)
imports `hellopkg` without depending on it and must fail with
`unable to locate module 'hellopkg'`.

```sh
buck2 build tests//negative/missing_dep:missing_dep
```

## 4. Closure refusal

The toolchain refuses an incomplete closure (exit 2, `REFUSING: toolchain
member`) instead of falling back to anything on the worker:
[`closure_refusal`](negative/closure_refusal/BUCK) builds with a toolchain missing a
member.

```sh
buck2 build tests//negative/closure_refusal:hello_incomplete_toolchain
```

## 5. Host paths

No action's argv or environment names an absolute host path, read from
`buck2 aquery` over the examples and their run checks, the Rust example and
the protobuf tests (rustc, protoc, the plugin, the generated packages). The
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
[`umbrella_cache.sh`](functional/umbrella_cache.sh) snapshots the working tree, builds
the examples in a fresh standalone clone, then in three scratch repositories
configured from [`consumer.buckconfig`](../consumer.buckconfig) (the external
one from a `file://` bare clone pinned to the snapshot's commit), each with a
fresh daemon; it fails unless every consumer command is a cache hit
(`Commands: N (cached: N, remote: 0, local: 0)`, N > 0), buck2 fetched the
external cell at that commit, and the digests are identical. Skipped with
`--no-umbrella`.

It also holds the consumer's `toolchains` cell to its contract. The consumer
at `./third_party/komira` builds with
[`umbrella/toolchains.BUCK.frozen`](functional/umbrella/toolchains.BUCK.frozen), the
copy a consumer made when komira was first published, not a fresh one, so a
change that needs every consumer to edit its copy fails. Every checkout's
`buck2 targets toolchains//:` must equal
[`umbrella/toolchains_targets.txt`](functional/umbrella/toolchains_targets.txt). And
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
buck-out for the same reason (without it, 3 of 55 actions re-ran).

A fifth consumer, fetched as a git external cell, has no `.buckconfig.local`:
the remote-execution settings are appended to its root `.buckconfig`, and it
runs with no user or system buckconfig and `HOME` in the scratch directory.
Its `app//platforms:default` must register only remote platforms, including
`linux-x86_64`; hello, hellopkg, test_hellopkg, `toolchains//:mojo` and the
zig and conda_unpack targets must resolve to it, with the configuration hash
test 18 pins; and with `-c komira.execution=remote`, clearing `[komira_re]
linux_properties` must refuse, naming the key. Analysis only.
See
[Using komira from another repository](../README.md#using-komira-from-another-repository).

```sh
tools/build/tests/functional/umbrella_cache.sh
```

## 8. Host floor and runtime libraries

During a real compile, and a run of the binary it built, the loader maps
`libstdc++.so.6` and `libgcc_s.so.1` from the toolchain, and nothing from the
worker except glibc's own objects ([`runtime_libs`](functional/runtime_libs/BUCK),
read from `LD_DEBUG`). The toolchain libraries the run loaded are exactly the
ones a runnable directory carries in `lib/` (`komira//tools/build/toolchains:mojo_runtime`), no
more, no fewer, and every run path those libraries carry is
`$ORIGIN`-relative. See the
[host floor](../toolchains/README.md#host-floor).

```sh
buck2 build tests//functional/runtime_libs:loader_trace --show-full-simple-output   # prints the report's path
buck2 build '//tools/build/examples:hello[runnable]' --show-full-simple-output
```

## 9. buck2 run

`buck2 run //tools/build/examples:hello` prints the greeting on this machine
from a fresh clone, downloads only the binary and its runtime libraries (under
a byte limit, and never the compiler), and the runnable directory still starts
after it is moved. [`buck2_run.sh`](functional/buck2_run.sh); skipped with `--no-run`.

```sh
tools/build/tests/functional/buck2_run.sh
```

## 10. Execution platforms

Mojo compiles, gated tests and run checks, the toolchain unpack and copy
targets, and the `third_party_srcs` generation, drift test and fixture
archive all resolve to the one linux execution platform, `linux-x86_64`. See
[platforms/README.md](../platforms/README.md).

```sh
buck2 audit execution-platform-resolution //tools/build/examples:hello //tools/build/toolchains:zig
```

## 11. (Retired)

Retired 2026-09-30 with the multi-NUMA rule and its NUMA guard. The number
is not reused.

## 12. Action platforms

Every action runs with the one linux property set, read per action: an
uncached build of `//tools/build/examples:hello` and
`//tools/build/third_party_srcs:aws_lc_mini_gen` (its own daemon under a fixed
`--isolation-dir`, `--no-remote-cache`, so every action really executes) must
record a remote execution carrying `[komira_re] linux_properties` for every
action it ran, and must have run `zig_unpack`, `zig_build_exe`,
`conda_unpack`, `mojo_runtime`, `fixture_archive`, `third_party_srcs` and
`mojo_build` (`buck2 log what-ran`; a cache hit records no properties, so a
warm build cannot answer this). Costs about 3 minutes of remote execution;
the isolated daemon's `buck-out/komira_tests_uncached` (~50 MB) is reused per
run.

## 13. Bundle parity

A program built as a bundle behaves as its executable: stdout, stderr and exit
status agree byte for byte across argv, environment, `exit()`, an unhandled
error, buffered output, a data file found through `/proc/self/exe`, `abort()`
and `SIGSEGV` (status and stdout exact, the stack dump's first line), and a
symlink invocation with another `argv[0]` (`tests//functional/bundle_parity:parity`, a
remote action).

## 14. Launcher CPU levels

The launcher's CPU level function gives glibc's level for the made-up CPUs of
[`cpu_models.h`](../package/launcher/cpu_models.h): the hand-written ones, and
one per feature glibc requires, a CPU of that level or above with just that
bit cleared (`//tools/build/package:level_test`, a remote action). On an x86-64
glibc host, its level for this host's CPU agrees with this host's glibc loader
([`glibc_level.sh`](functional/glibc_level.sh)).

## 15. Bundle

The bundle of `//tools/build/examples:hello` ([`bundle.sh`](functional/bundle.sh)):
layout, run paths and `SHA256SUMS` against [`bundle_expected`](functional/bundle_expected/);
it runs from a relocated copy and through a symlink on `PATH`; a CPU below
x86-64-v3 gets the one-line refusal (test launcher); two uncached builds give
byte-identical bundles, tarballs and docker archives and the same image digest
(skipped with `--no-uncached`; about 3 minutes of remote execution).

## 16. Package formats

The package formats of `//tools/build/examples:hello` ([`formats.sh`](functional/formats.sh)):
the tarball and the OCI image follow the determinism rules and hold the
bundle; the image's blobs, config (entrypoint, linux/amd64) and pinned base
layers are checked; the base is fetched only by pinned downloads; `docker run`
of the loaded image prints the greeting (SKIP without docker). See
[packaging](../package/README.md).

## 17. Doc links

Markdown links are a validation of the build.
[`markdown_docs`](../lint/defs.bzl) builds nothing; its validation stages the
files it names and requires every relative link and `#fragment` in every
Markdown file among them to resolve to a staged file, directory or heading,
without leaving the staged tree (the Markdown reader of
[`//tools/build/inspect`](../inspect/inspect.mojo)). `//:docs` in the root
[`BUCK`](../../../BUCK) stages the whole repository and so checks every
Markdown file in it: `./buck2 build //...` fails on a dead link, naming it.
No BUCK file lists its files for it: the rules a package's BUCK file calls
declare that package's `doc_tree`, which names the package's own files (a
glob stops at a subpackage) and collects the `doc_tree` of each subpackage
Buck2 finds ([`doc_tree.bzl`](../lint/doc_tree.bzl)); `//:docs` takes the
root package's, and this cell's through `tests//:doc_tree`. The toolchains
cell is not read: it is one BUCK file, the template a consuming repository
copies, whose targets test 7 pins equal to a consumer's.
The test builds `//:docs` and
[`functional/doc_links`](functional/doc_links/BUCK) (a directory, headings and
a file of `tree`, which must resolve), and requires
[`negative/doc_links`](negative/doc_links/BUCK) to fail naming each of its
planted links: a missing file, a bad anchor and a link leaving the tree, and
nothing else. It also requires every package of the komira and tests cells
to be in `//:docs`, the toolchains cell to hold no Markdown, no BUCK file
to declare a `doc_tree` or call `package_docs()` itself, and neither cell to set
`[project] package_boundary_exceptions`: an exception is a path prefix, so
one that covers the root package covers every package, and any target could
then name a file of another package.

```sh
./buck2 build //:docs
```

## 18. Configuration hashes

The configuration hash of `komira//tools/build/platforms:linux-x86_64` (the
target platform, and the configuration of the linux execution platform), read
with `buck2 cquery 'deps(komira//tools/build/examples:hello)'`, equals the pin
in `run_tests.sh`, and it is the only configuration in that closure. A configuration's hash is keyed by its
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
["tests//functional/formats:"]` on `examples:hello` once did). The test fails if a
searched directory is missing, or if it finds fewer than 20 labels, so a scan
that reads nothing cannot pass.

## 20. C and C++ dependencies

[`cxx_tests.sh`](cxx_tests.sh), sourced by `run_tests.sh`. A Mojo binary
calling a C function links and prints the C result when the `cxx_library` is
in `deps` (`tests//functional/c_deps:c_linked`), and its link fails on the undefined
symbol when it is not (`c_missing`); `deps` refuses a target that is neither
a Mojo package nor a C/C++ library (`bad_dep`). The two cshim tests, a gated library
test and a `mojo_test`, use `assert_equal` on `Int32` and index a `List`,
which record the test file's source location in the binary; they build only
because the wrapper strips the staging directory from it
(`-strip-file-prefix`), and fail with exit 4 on the worker's absolute path
without it (`test_source_paths`). C compiles and archives
and the Mojo targets using them resolve to `linux-x86_64`. The
snappy test binary, which links C++ with zig's static libc++, carries
libc++abi and exports no dynamic symbol, so its C++ runtime cannot interpose
on the `libstdc++.so.6` the Mojo runtime loads.

## 21. Location path

`tests//functional/location_path:main[run_check]`: a `mojo_binary` whose main file
indexes a `List`, so the binary records the main file's source location. It
builds only because the wrapper strips the staging directory from recorded
paths, and its run check compares stdout exactly. Test 20 covers the same
for tests with a C dependency; this one is a plain binary.

## 22. Rust rules

[`rust_tests.sh`](rust_tests.sh), sourced by `run_tests.sh`. The example
binary `//tools/build/examples/rust:prost_roundtrip` uses prost's derive
macro, so it compiles registry crates, a proc-macro and the zig link; its run
test compares stdout exactly, and must have run remotely. A binary using
prost without depending on it fails to compile
(`tests//negative/rust_missing_dep:main`): crates reach rustc only through `deps`.
The host floor of rustc: every `NEEDED` entry of the sysroot's `bin/rustc`
and of its shared libraries (read with the host's `readelf`) is glibc's or a
file in a directory named by that object's own `$ORIGIN`-relative run path,
and no run path is absolute.

## 23. Protobuf

[`proto_tests.sh`](proto_tests.sh), sourced by `run_tests.sh`, over
[`functional/proto`](functional/proto/BUCK) (its failures in
[`negative/proto`](negative/proto/BUCK)). Generated packages pass tests that encode and decode
through a minimal runtime (the bytes prost produces), and must have run
remotely. The generated struct follows a field rename in the `.proto`, and
the test written for the old name fails to compile
(`tests//negative/proto:test_person_renamed`). A `.proto` using an imported file's
message compiles only with that file bundled
(`tests//negative/proto:team_unbundled_proto` must fail). `bundle_only` generates part
of the bundled closure: `tests//functional/proto:roster_proto` holds exactly
`roster.mojo` and `person.mojo`, while bundling all of it also generates the
options file its runtime cannot compile (`roster_full_bundle` must fail), and
a selection outside the closure is refused (`roster_bad_selection`).
`mojo_db_proto_library`: the DbStorable code generated for the table of
`db/tasks.proto` passes `tests//functional/proto:test_tasks_db` against a minimal
`komira_db`, and a declared `outs` file the plugin does not write (a `.proto`
without a table) fails the generation (`tasks_db_wrong_outs`).

Generation is deterministic: two uncached builds (an isolated daemon,
`komira_tests_det`, its buck-out cleaned, `--no-remote-cache`) of both
plugins, the generated sources of three packages (one of them
`mojo_db_proto_library`) and two compiled packages give the same bytes. Each
build must have run both plugins' rustc and every generation (remotely, or
locally in a local-only run), or the comparison proves nothing. About 16 minutes;
skipped with `--no-uncached`.

## 25. Local default

[`local_default.sh`](functional/local_default.sh): a fresh clone with no
`.buckconfig.local` builds on this machine. It snapshots the working tree
into a scratch clone (`.buckconfig.local` is gitignored, so it is never
copied) and runs buck2 there with its own daemon, no user or system
buckconfig and `HOME` in the scratch directory. On Linux x86_64, every
platform `[build] execution_platforms` registers is local-only (exactly
`linux-x86_64`); Mojo targets and the toolchain targets resolve to it with
the configuration hash test 18 pins, so a local and a remote build configure
every target identically; `-c komira.execution=remote` refuses, naming `[komira_re]`; a
`[buck2_re_client]` `address`, `engine_address`, `cas_address` or
`action_cache_address` with no `[komira_re]`
refuses instead of building locally (a missing or misspelled `[komira_re]`
fails closed), as does a retired `[komira_re]` key such as
`mojo_compile_properties` (naming `linux_properties`), while
`-c komira.execution=local` still registers the local platform;
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
tools/build/tests/functional/local_default.sh
```

## 26. aws-lc and s2n-tls

[`c_libs_tests.sh`](c_libs_tests.sh), sourced by `run_tests.sh`.
Drift: `//third_party/<lib>:srcs_drift`, the test that holds
`third_party/<lib>/srcs.bzl` to what the Mojo tool
[`third_party_srcs`](../third_party_srcs/) reads out of the pinned archive's
CMake lists, passes.
libcrypto passes aws-lc's own self tests and SHA-256, AES-128 and ChaCha20
known-answer vectors, and an s2n-tls client and server complete a TLS 1.3
handshake with certificate verification, both driven from Mojo in a run
check on a worker. Every probe named in `third_party/s2n-tls/features.bzl`
compiles (`tests//functional/s2n_probes`) and every other probe fails to, so a feature
define cannot be added or dropped without its probe agreeing. Neither test
binary exports a dynamic symbol.

## 28. Compile watchdog

[`watchdog/cases.sh`](functional/watchdog/cases.sh), a remote action
(`tests//functional/watchdog:cases`), runs [`mojo_wrapper.sh`](../mojo/mojo_wrapper.sh)
on a stand-in toolchain whose `mojo` sleeps, spins, or spawns children. A
tree using no CPU is killed with exit 124 and the message, and so are its
child and an orphaned grandchild (a child left in any state but zombie fails
the case); a tree spinning itself or through a child, a short idle and a
disabled watchdog run to completion; a compiler error keeps its status;
malformed knobs exit 2. Every case runs under `timeout 60`, so a watchdog
that never fires is a failed case, not a hung action. Two more signal the
wrapper while its compiler and the compiler's child hang: after TERM the
wrapper must exit 143 with both gone, and after KILL, which it cannot catch,
both must be gone within 5 s (the tether in the compiler's session, a read
of a FIFO only the wrapper holds open, returns when the wrapper dies and
kills the session). The macOS wrapper has the same watchdog, sampling
`ps` rather than `/proc`; test 24 ([`darwin/check.sh`](functional/darwin/check.sh)) runs it on this client
against a stand-in compiler: a hang is killed (124), a spin is not, a killed
wrapper takes its compiler with it, a malformed knob is refused.

## 29. Test data, environment and scratch

[`functional/test_data`](functional/test_data/BUCK): `declared` builds, its test opening a
declared fixture by its repository path from the staged `share/`, and two
further tests each finding `TEST_TMPDIR` set, not under `/tmp`, empty at the
start, equal to `TMPDIR`, and the library's `test_env` value present;
in [`negative/test_data`](negative/test_data/BUCK), `undeclared` must fail
with `GATED TEST FAILED` and the test's
`No such file or directory` for a fixture that exists in the repository but
was not declared. `buck2 test tests//functional/test_data:mojo_test_data` must pass: a
`mojo_test` with dict `data` and `env`. Five `bad_*` targets must each fail
at analysis with their own refusal: a `..` destination, a destination that
is also another's directory, a `test_data` key that is not a test, a
runner-owned env name, an env name that is not a variable name. The gate test
of `komira//tools/build/mojo/runtime_paths:komira_runtime_paths` (built with
the examples) covers the executable-relative helpers.
`runner_cases` also runs the runner on a stand-in that kills itself: with
SIGKILL it must exit 137 and with SIGABRT 134, each with no marker.

## 30. Optimization levels

[`opt_level.sh`](functional/opt_level.sh) reads the `mojo build` command of each target
it names from `buck2 aquery` (analysis only) and requires its
`--optimization-level`: `-O1` for `mojo_test`
(`komira//tools/build/examples:test_hellopkg`), for a library's gated tests
(`libgate_ok`) and for the aws-lc and s2n-tls test programs, which override
the binary default; `-O3` for `mojo_binary` (`hello`, `hello_pkg_user`) and
for every shared library the `hello_bundle` bundle builds; and each override
in [`functional/opt_level`](functional/opt_level/BUCK) (a test and a library's gated test at
`-O3`, a binary at `-O1`). `tests//negative/opt_level:bad_level` must fail analysis:
`fast` is not a level.

```sh
tools/build/tests/functional/opt_level.sh
```

## 31. Lint weld

The lints are validations ([`lint/defs.bzl`](../lint/defs.bzl)), so they are
checked by `buck2 build //...`: the komira cell's directly, and this cell's
shell lints through `//:tests_lints` in the root [`BUCK`](../../../BUCK),
because `//...` does not reach into another cell.
[`lint_weld.sh`](negative/lint_weld.sh) requires the `_script_lint` lists of the Mojo
and Rust toolchains ([`mojo/toolchain.bzl`](../mojo/toolchain.bzl),
[`rust/defs.bzl`](../rust/defs.bzl)) to equal the lists it pins, so a lint
dropped from a toolchain fails it; for each lint target on them it plants
an unused variable (SC2034) in one of that target's scripts, alone, in a
snapshot of the tree, and requires the build of
`//tools/build/examples:hello` (for the Mojo list) and of
`//tools/build/examples/rust:prost_roundtrip` (for the Rust list) to fail
naming that validation: each lint reaches every Mojo or Rust target through
its toolchain, not only the lint target itself.

```sh
tools/build/tests/negative/lint_weld.sh
```

## 32. The ./buck2 bootstrap

[`bootstrap.sh`](functional/bootstrap.sh) runs [`./buck2`](../../../buck2) against a
made-up release (a small script, zstd-compressed, served from a `file://`
URL, with a pin file in the layout of `tools/buck2`): a matching pin installs,
runs with the caller's arguments and is cached under
`komira/buck2/<sha256>/`; a pin with a wrong sha256, or a wrong size, is
refused and leaves the cache empty; and the real `tools/buck2` has a size,
sha256 and `.zst` URL for both platforms. No network.

```sh
tools/build/tests/functional/bootstrap.sh "$(mktemp -d)/bootstrap"
```

## 33. Client

`run_tests.sh` runs binaries the farm built for Linux x86_64 (the inspect
tool, the examples, their bundles) and `readelf`/`objdump` on the client, so
it needs a Linux x86_64 client and refuses any other before it builds
anything (exit 2); `./buck2 build //...` and `./buck2 test //...` work from
any client `tools/buck2` supports. The test runs `run_tests.sh
--host-check-only` with a `uname` reporting macOS arm64, which must refuse,
and with one reporting this machine, which must pass.

```sh
tools/build/tests/run_tests.sh --host-check-only
```

## 34. AWS client generator

[`functional/aws_codegen`](functional/aws_codegen/BUCK) runs
`komira//tools/build/proto-codegen:aws-client-gen` over a copy of the
CloudWatch Logs model as check actions ([`defs.bzl`](functional/aws_codegen/defs.bzl)).
The GetLogEvents module, pure and client, and the layout probe of each, must
equal their goldens under `golden/` byte for byte. The generator must refuse,
naming the reason and writing no file: an empty or missing `--operations`, an
operation the model lacks, a protocol it does not implement (rest-xml), a
missing `--model-sha256`, one that is not 64 lowercase hex digits (upper case,
or one digit short), one that is not the model's, a zero-byte model, and
`--probe-import` without `--probe-out`.

Two negatives in [`negative/aws_codegen`](negative/aws_codegen/BUCK) must fail
their builds: a golden that differs from the generated module (`golden_differs`),
and a refusal check given inputs the generator accepts (`accepted`).

```sh
buck2 build tests//functional/aws_codegen:
buck2 build tests//negative/aws_codegen:golden_differs   # must fail: differs from the golden
buck2 build tests//negative/aws_codegen:accepted         # must fail: expected a refusal
```

To update a golden after a deliberate change to the emitter, build the
golden's `[gen]` sub-target and copy its output over the golden (and
likewise for `logs_pure`):

```sh
out=$(buck2 build 'tests//functional/aws_codegen:logs_client[gen]' --show-full-simple-output)
cp "$out/komira_aws_logs.mojo" tools/build/tests/functional/aws_codegen/golden/logs_client.mojo
cp "$out/_layout_probe.mojo" tools/build/tests/functional/aws_codegen/golden/logs_client_probe.mojo
```

## Diagnostics

[`re_probe`](re_probe/BUCK) is not a check: `buck2 build tests//re_probe:probe`
records what a remote worker provides, the evidence behind the
[host floor](../toolchains/README.md#host-floor).
