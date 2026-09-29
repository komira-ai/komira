# Rust rules

```python
load("@komira//tools/build/rust:defs.bzl", "rust_library", "rust_binary", "crates_io_library")
```

The rules are in [`defs.bzl`](defs.bzl). Worked uses are in
[`../examples/rust/BUCK`](../examples/rust/BUCK) and the registry crates in
[`third_party/rust/BUCK`](../../../third_party/rust/BUCK).

| rule | produces |
|---|---|
| `rust_library(srcs, crate_root, deps, edition, features, cfgs, proc_macro)` | `lib<crate>.rlib`, or `lib<crate>.so` for a proc-macro |
| `rust_binary(srcs, crate_root, deps, expected_stdout)` | an executable, and `RunInfo`. With `expected_stdout`, `[run_check]` runs it remotely and compares its stdout exactly. |
| `crates_io_library(name, version, sha256, ...)` | a crates.io crate, downloaded by the sha256 of its `.crate` file, unpacked remotely, and compiled with `rust_library` |

The toolchain, `komira//tools/build/toolchains/rust:rust`, is rustc 1.85.0
and its standard library for `x86_64-unknown-linux-gnu`, both sha256-pinned
release tarballs. rustc runs through [`rustc_wrapper.sh`](rustc_wrapper.sh)
with `--sysroot` set to the unpacked toolchain; links go through zig
(`zig cc -target x86_64-linux-gnu.2.34`), so binaries need glibc 2.34 or
newer and nothing else. rustc itself takes only glibc from the worker:
`libgcc_s.so.1` and `libz.so.1`, which its own libraries need, come from
sha256-pinned conda-forge packages and sit in the sysroot's `lib/`, the run
path of `bin/rustc` and of those libraries
([check 22](../checks/README.md#22-rust-rules) fails on any `NEEDED` entry
outside glibc and the sysroot). No Cargo and no build scripts run: features are
stated per crate, and where a crate's build script would emit a cfg for the
pinned rustc, the cfg is written in `cfgs`. A proc-macro is an ordinary
dependency, compiled once for linux x86_64, which is both the execution and
the target platform. The wrapper refuses an output containing the action's
working directory (exit 4); rustc's own record of it is remapped.
