"""kpin_cargo: the crates of a Cargo workspace as `crates_io_library` targets, generated and drift-checked.

    load("@komira//tools/build/kpin:cargo.bzl", "kpin_cargo")
    load(":crates.bzl", "crates")

    kpin_cargo(
        name = "crates_gen",
        cargo_lock = "workspace/Cargo.lock",
        cargo_metadata = "workspace/metadata.json",
        overrides = "overrides.json",
        sizes = "workspace/sizes.txt",
        committed = "crates.bzl",
    )

    crates()

`kpin cargo` (tools/build/kpin/README.md, "Cargo") reads Cargo's outputs and
the overrides; it resolves nothing. Building `:crates_gen` writes the
generated file (copy it over `crates.bzl` to update it), and the build of
`:crates_gen` fails unless `committed` is exactly that file: a hand edit, a
stale file or a changed input shows up as a red build, as a validation of the
target. The compiler the overrides must have been derived for is the one the
Rust toolchain unpacks, so a compiler bump makes this red until the overrides
are re-derived.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/rust:defs.bzl", "RustToolchainInfo")

def _kpin_cargo_impl(ctx):
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    kpin = ctx.attrs._kpin[RunInfo]
    base = cmd_args(
        kpin,
        "cargo",
        "--cargo-lock",
        ctx.attrs.cargo_lock,
        "--metadata",
        ctx.attrs.cargo_metadata,
        "--overrides",
        ctx.attrs.overrides,
        "--sizes",
        ctx.attrs.sizes,
        "--rustc",
        tc.version,
    )
    out = ctx.actions.declare_output(ctx.label.name + ".bzl")
    ctx.actions.run(cmd_args(base, "--cargo-out", out.as_output()), category = "kpin_cargo")
    drift = ctx.actions.declare_output(ctx.label.name + ".drift.json")
    ctx.actions.run(
        cmd_args(base, "--check", "--cargo-out", ctx.attrs.committed, "--stamp", drift.as_output()),
        category = "kpin_cargo_drift",
    )
    return [
        DefaultInfo(default_output = out, sub_targets = {"drift": [DefaultInfo(default_output = drift)]}),
        ValidationInfo(validations = [ValidationSpec(name = "drift", validation_result = drift)]),
    ]

kpin_cargo_rule = rule(
    impl = _kpin_cargo_impl,
    attrs = {
        "cargo_lock": attrs.source(),
        # The file the build is checked against.
        "committed": attrs.source(),
        "cargo_metadata": attrs.source(),
        "overrides": attrs.source(),
        "sizes": attrs.source(),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:rust", providers = [RustToolchainInfo]),
        "_kpin": attrs.exec_dep(default = "komira//tools/build/kpin:kpin"),
    },
)

kpin_cargo = declares_docs(kpin_cargo_rule)
