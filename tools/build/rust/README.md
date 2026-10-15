# Rust rules

```python
load("@komira//tools/build/rust:defs.bzl", "rust_library", "rust_binary", "rust_test", "crates_io_library")
```

The rules are in [`defs.bzl`](defs.bzl). Worked uses are in
[`../examples/rust/BUCK`](../examples/rust/BUCK) and the registry crates in
[`third_party/rust/BUCK`](../../../third_party/rust/BUCK).

| rule | produces |
|---|---|
| `rust_library(srcs, crate_root, deps, edition, features, cfgs, proc_macro, tests, test_srcs)` | `lib<crate>.rlib`, or `lib<crate>.so` for a proc-macro |
| `rust_binary(srcs, crate_root, deps, expected_stdout, tests)` | an executable, and `RunInfo`. With `expected_stdout`, `[run_check]` runs it remotely and compares its stdout exactly, and that check is a validation of the binary: every build holding the binary runs it ([`run_check.bzl`](../mojo/run_check.bzl)). |
| `rust_weld_check(target, markers)` | fails analysis unless the `[tests]` sub-target of `target` (the marker list its rule hands the publishing action) is exactly `markers`: a weld that drops a test still builds green, so this is what shows it. It reads the list, not that action's inputs (see [`examples/rust/ext`](../examples/rust/ext/BUCK)) |
| `crates_io_library(name, version, sha256, size, ...)` | a crates.io crate, downloaded by the sha256 and size in bytes of its `.crate` file, unpacked remotely, and compiled with `rust_library` |
| `rust_test(srcs, crate_root, deps, ..., test_timeout_s)` | the crate compiled with `rustc --test`, RUN as a build action; its output is a `.passed` marker. `[bin]` is the test executable. |

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

A library's external tests (Cargo's `tests/*.rs`) cannot be a `rust_test`
in its `tests`: that test would depend on the library it gates, a cycle
buck2 refuses. They are the library's `test_srcs` instead, as a
`mojo_library`'s are:

```python
rust_library(
    name = "ext",
    srcs = ["src/lib.rs"],
    crate_root = "src/lib.rs",
    test_srcs = ["tests/adds.rs", "tests/common/mod.rs"],
)
```

Each `test_srcs` file at `tests/<name>.rs` is a test crate named `<name>`
(a `-` becomes `_`), compiled with `rustc --test` inside the library rule
against the UNGATED library (`--extern <crate>=ungated/...`), and run by the
same runner; its `.passed` marker joins the gate with those of `tests`, and
`[tests]` lists them all. A test crate sees the library and the library's
`deps`, as a Cargo integration test does, and is compiled with the library's
`edition`, `features`, `cfgs` and `rustc_flags`; there are no
dev-dependencies (`test_deps`) yet. Any other `test_srcs` file is a module
the test crates reach with `mod` (`tests/common/mod.rs`). A file outside
`tests/`, a file directly under `tests/` that is not `.rs`, a
`tests/<name>.rs` whose name is not a Rust identifier, and `test_srcs` with
no test crate are refused at analysis. Each run has the
default 600 s timeout. A failure names the file:
`GATED TEST FAILED: <label> tests/<name>.rs`. `buck2 test` of the library
runs the `rust_test`s in its `tests`, not its `test_srcs`; building the
library runs both. [`examples/rust/ext`](../examples/rust/ext/BUCK) is a
library of each kind (`ext`, test_srcs only; `both`, with `tests` too),
each held to its marker list by a `rust_weld_check`.

The weld runs the tests when the ARTIFACT IS BUILT: `buck2 build` of the
library, of anything linking it, or of the binary runs each welded test as
an action (or takes its cached `.passed` marker). `buck2 test` is a second,
separate way in. `rust_test` also gives buck2 an `ExternalRunnerTestInfo`
that runs the same runner over the same harness and timeout, writing
no marker; and the `tests` attribute is buck2's own, the targets `buck2 test`
runs for a target. So `buck2 test //pkg:lib` runs the `rust_test`s in the
library's `tests` and reports one result per `rust_test` (stdout carries the
runner's `PASS <label>: <n> passed` line); it does not build or publish the
gated artifact. `buck2 test` of the `rust_test` itself does the same for that
one target.

The runner ([`gate rust`](../run/README.md)) lists the tests first and
refuses a target that lists none (`EMPTY GATE`). It then runs every test,
and refuses an `#[ignore]`d test (a test that does not run is a mute) and a
harness summary that does not count every listed test as passed. There are
no holds: a failing test makes the artifact unbuildable until it is fixed
or deleted. `test_timeout_s` below 1 is refused at analysis.

The planted defects are in
[`tests//negative/rust_test`](../tests/negative/rust_test/BUCK) (test 35).

Each harness invocation (the list, then the run) has `test_timeout_s`
seconds (default 600), after which the gate sends the harness SIGALRM. A test
killed at its timeout is NO VERDICT, exit 142, as a SIGKILL (exit 137) is: the
action fails without a verdict, and the executor may retry it. The harness is
started with exactly `PATH`, `TMPDIR` and `HOME`, so nothing in the action's
environment (`RUST_TEST_*`, `RUST_MIN_STACK`) reaches it, in a session of its
own whose process group is killed after each invocation.

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
[toolchains](../toolchains/README.md)), is rustc 1.99.0
and its standard library for `x86_64-unknown-linux-gnu`, both sha256-pinned
release tarballs. They are the `.tar.gz` of the release, not the `.tar.xz`:
the pinned busybox unpacks xz with a dictionary of at most 64 MiB, and the
`.tar.xz` of 1.99.0 uses 128 MiB ("corrupted data"). The sysroot is refused
unless its `bin/rustc --version` prints the pinned line
([`version_check.zig`](../toolchains/rust/version_check.zig), a validation of
`toolchains/rust:sysroot` that every build holding the toolchain runs), so a pin
that names one release over the tarballs of another fails every Rust target.
rustc runs through [`rustc_wrapper.sh`](rustc_wrapper.sh)
with `--sysroot` set to the unpacked toolchain (and `-C linker-features=-lld`:
since 1.90 rustc links x86_64 linux with its own rust-lld, which the sysroot does
not keep); links go through zig
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

## Cargo crates

A crate from a registry is built by Cargo's rules: its build script runs, and
what the script learned about the compiler or the target decides the cfgs, the
environment and the generated files. Nothing here runs a build script; what
the script would decide for the pinned rustc is stated on the target instead,
and `kpin cargo` ([kpin](../kpin/README.md)) writes it. Five attributes of
`rust_library`, `rust_binary` and `rust_test` carry it. Worked uses:
[`tests//functional/rust_cargo`](../tests/functional/rust_cargo/BUCK), and
their planted defects in [`negative/rust_cargo`](../tests/negative/rust_cargo/BUCK)
(test [35b](../tests/README.md#35b-rust-attributes-cargo-needs)).

| attribute | what it does | Cargo's equivalent |
|---|---|---|
| `env = {"K": "v"}` | variables of the rustc action, for `env!` and `option_env!`. Names the wrapper sets itself (`PATH`, `HOME`, `TMPDIR`, `LD_*`, `RUSTFLAGS`, ..) are refused. A target without `env` has the action it always had. It is the compile environment only, not that of a test run. | `CARGO_PKG_NAME`, `CARGO_PKG_VERSION`, `CARGO_PKG_VERSION_MAJOR/MINOR/PATCH/PRE`, `CARGO_CRATE_NAME`, and a build script's `cargo:rustc-env` |
| `renamed_deps = {"alias": ":dep"}` | `--extern=alias=<lib>`: the dependency is reached under `alias`, not its crate name. Two crates of one name (two versions) are told apart this way. | `package = "http"` under another name in `[dependencies]` |
| `native_deps = [":c[static-pic]"]` | `-Clink-arg=<archive>` on the link of a `rust_binary` or `rust_test`, and of the test crates of a library's `test_srcs`. A library's `native_deps` travel with it: every binary or test that depends on the library (however indirectly) links them too, once each, as a `-sys` crate's `cargo:rustc-link-lib` reaches the final link. The `rlib` itself is not linked. | a build script's `cargo:rustc-link-lib` / `-link-search` |
| `patch = {"copy": [..], "sub": [..], "add": [..]}` | run by [`crate_patch`](crate_patch.zig) before rustc, over the sources (`src_dir` or `srcs`): `copy` keeps only those entries (everything when empty), `sub` entries `{file, from, to, count}` are exact text substitutions, `add` entries `{file, content}` are generated files. `count` (default 1) is how many times `from` must match; any other number fails the build, so a patch that stops matching after a crate upgrade is an error. A `sub` on a file not copied, an `add` of a file the crate has, and a path with `..` are errors. | a build script writing to `OUT_DIR` |
| `proc_macro_extern = True` | with `proc_macro = True`, `--extern=proc_macro`, so the crate can name `proc_macro::..` without `extern crate proc_macro;` (editions 2018 and later). Opt-in so that a proc-macro crate that compiled before keeps its action. | passed to every proc-macro crate |

`OUT_DIR` itself is not defined: a crate that does
`include!(concat!(env!("OUT_DIR"), "/x.rs"))` is patched to `include!("x.rs")`
(`sub`, with its `count`) and the file is added beside it (`add`). `include!`
resolves a relative name against the including file, so an `OUT_DIR` naming a
build directory could not work for the crates that include from several
directories, and a path naming the action's working directory would differ on
every run (the wrapper refuses an output that holds it).
