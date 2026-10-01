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

The runner ([`test_runner.sh`](test_runner.sh)) lists the tests first and
refuses a target that lists none (`EMPTY GATE`). It refuses an `#[ignore]`d
test (a test that does not run is a mute), and a harness summary that does
not count every unheld test as passed.

`tests_known_failing = {"<module>::tests::<name>": {"issue": ..., "reason": ...}}`
holds a red test, and INVERTS rather than mutes: the held test still runs,
alone, and must FAIL; a held test that passes is red (`LEDGER STALE`), naming
the row to delete, and so is a row naming no listed test. `issue` is a
GitHub issue (`123`, `#123` or its URL) and `reason` says why THIS test
fails; both are refused empty at analysis, as are two byte-identical reasons
and holding every test. The planted defects are in
[`tests//negative/rust_test`](../tests/negative/rust_test/BUCK) (test 35).

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
