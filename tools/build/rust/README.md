# Rust rules

```python
load("@komira//tools/build/rust:defs.bzl", "rust_library", "rust_binary", "rust_test", "crates_io_library")
```

The rules are in [`defs.bzl`](defs.bzl). Worked uses are in
[`../examples/rust/BUCK`](../examples/rust/BUCK) and the registry crates in
[`third_party/rust/BUCK`](../../../third_party/rust/BUCK).

| rule | produces |
|---|---|
| `rust_library(srcs, crate_root, deps, edition, features, cfgs, proc_macro, tests)` | `lib<crate>.rlib`, or `lib<crate>.so` for a proc-macro |
| `rust_binary(srcs, crate_root, deps, expected_stdout, tests)` | an executable, and `RunInfo`. With `expected_stdout`, `[run_check]` runs it remotely and compares its stdout exactly. |
| `crates_io_library(name, version, sha256, ...)` | a crates.io crate, downloaded by the sha256 of its `.crate` file, unpacked remotely, and compiled with `rust_library` |
| `rust_test(srcs, crate_root, deps, ..., tests_known_failing)` | the crate compiled with `rustc --test`, RUN as a build action; its output is a `.passed` marker. `[bin]` is the test executable. |

## Tests are part of the build

`tests = [...]` on `rust_library` and `rust_binary` welds `rust_test` targets
to the artifact, as `mojo_library` welds its `test_srcs`: each test is built
and run as an action that writes a `.passed` marker, and the published
`lib<crate>.rlib` or executable is a copy taken by an action whose inputs
include every marker. So the library (and everything that links it) or the
binary cannot be built unless its tests pass. The compile and the tests run
in parallel; without `tests` nothing changes.

A crate's inline `#[test]`s are its unit tests: a `rust_test` over the same
`srcs` and `crate_root` (it does not depend on the library, so it can gate
it). See `//tools/build/proto-codegen:komira_proto_codegen_unit`.

The weld runs the tests when the ARTIFACT IS BUILT: `buck2 build` of the
library, of anything linking it, or of the binary runs each welded test as
an action (or takes its cached `.passed` marker). `buck2 test` is a second,
separate way in. `rust_test` also gives buck2 an `ExternalRunnerTestInfo`
that runs the same runner over the same harness, holds and timeout, writing
no marker; and the `tests` attribute is buck2's own, the targets `buck2 test`
runs for a target. So `buck2 test //pkg:lib` runs the `rust_test`s in the
library's `tests` and reports one result per `rust_test` (stdout carries the
runner's `PASS <label>: <n> passed` line); it does not build or publish the
gated artifact. `buck2 test` of the `rust_test` itself does the same for that
one target.

The runner ([`test_runner.sh`](test_runner.sh)) lists the tests first and
refuses a target that lists none (`EMPTY GATE`). It refuses an unheld
`#[ignore]`d test (a test that does not run is a mute), and a harness
summary that does not count every unheld test as passed.

`tests_known_failing = {"<module>::tests::<name>": {"issue": ..., "reason": ...}}`
holds a red test, and INVERTS rather than mutes: the held test still runs,
alone and with `--include-ignored` (so an `#[ignore]`d test can be held), and
must FAIL, measured: its run must report `0 passed; 1 failed`. A held test
that passes is red (`LEDGER STALE`), naming the row to delete; a held run
that reports anything else (a crash, another count) is refused.

Which refusals happen when:

- At ANALYSIS (`defs.bzl`, so `buck2 targets` and every build refuse them):
  a row with no `issue`, an `issue` that is not a GitHub issue (`123`,
  `#123` or its URL), an empty `reason`, a row field other than `issue` and
  `reason`, a key that is not a libtest test name, two rows with
  byte-identical reasons, and `test_timeout_s` below 1.
- At RUN time (`test_runner.sh`, when the test action runs; a mistyped row
  passes analysis and reds only the build that runs it): a hold naming no
  listed test (`LEDGER STALE`), holding every listed test, no tests
  (`EMPTY GATE`), an unheld `#[ignore]`d test, a summary that does not count
  every unheld test as passed, a held test that passes (`LEDGER STALE`), and
  a held run that does not report `0 passed; 1 failed`.

The planted defects are in
[`tests//negative/rust_test`](../tests/negative/rust_test/BUCK) (test 35).

Each harness invocation (the list, the unheld run, each held run) runs under
`busybox timeout`, `test_timeout_s` seconds (default 600). A test killed at
its timeout is NO VERDICT, exit 142, as a SIGKILL (exit 137) is: the action
fails without a verdict, and the executor may retry it. The harness is
started with `busybox env -i`, so nothing in the action's environment
(`RUST_TEST_*`, `RUST_MIN_STACK`) reaches it.

A test runs with an empty current directory, `HOME` and `TMPDIR`, so it can
read only what it compiles in. A file from another package is a label in
`srcs`, an `export_file` in that package (a bare `//pkg/file` path is
refused when `srcs` is coerced). `srcs` are
staged in one directory, each at its short path: package-relative, for a
file from another package as much as for one of this crate's own. So
`//testdata:model.json` lands beside `src/`, not under `testdata/`, and a
crate root `src/lib.rs` reads it with `include_str!("../model.json")`
(`include_str!` resolves against the including file). Short paths must be
unique across `srcs`; that is not checked, and of two files with the same
short path one is silently dropped.

The toolchain, `toolchains//:rust` (declared by `komira_rust_toolchains()`, see
[toolchains](../toolchains/README.md)), is rustc 1.85.0
and its standard library for `x86_64-unknown-linux-gnu`, both sha256-pinned
release tarballs. rustc runs through [`rustc_wrapper.sh`](rustc_wrapper.sh)
with `--sysroot` set to the unpacked toolchain; links go through zig
(`zig cc -target x86_64-linux-gnu.2.34`), so binaries need glibc 2.34 or
newer and nothing else. rustc itself takes only glibc from the worker:
`libgcc_s.so.1` and `libz.so.1`, which its own libraries need, come from
sha256-pinned conda-forge packages and sit in the sysroot's `lib/`, the run
path of `bin/rustc` and of those libraries
([test 22](../tests/README.md#22-rust-rules) fails on any `NEEDED` entry
outside glibc and the sysroot). No Cargo and no build scripts run: features are
stated per crate, and where a crate's build script would emit a cfg for the
pinned rustc, the cfg is written in `cfgs`. A proc-macro is an ordinary
dependency, compiled once for linux x86_64, which is both the execution and
the target platform. The wrapper refuses an output containing the action's
working directory (exit 4); rustc's own record of it is remapped.
