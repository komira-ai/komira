"""The Rust sysroot, refused unless its rustc prints the pinned version.

`rust_version_check` stands in front of a `rust_sysroot`: the same directory,
and a `ValidationInfo` that runs `<sysroot>/bin/rustc --version` (version_check.zig,
no shell) and fails unless it prints exactly `expected`. Every build whose graph
holds the toolchain runs it, so a sysroot unpacked from the wrong release, or a
pin that names one release while its tarballs hold another, fails every Rust
target instead of compiling with a compiler nobody pinned.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _impl(ctx):
    sysroot = ctx.attrs.sysroot[DefaultInfo].default_outputs[0]
    result = ctx.actions.declare_output(ctx.label.name + ".rustc_version.json")
    ctx.actions.run(
        cmd_args(
            ctx.attrs.checker[RunInfo],
            sysroot.project("bin/rustc"),
            ctx.attrs.expected,
            result.as_output(),
            # The whole sysroot is an input: rustc loads lib/ beside bin/.
            hidden = sysroot,
        ),
        category = "rust_version_check",
    )
    return [
        DefaultInfo(default_output = sysroot),
        ValidationInfo(validations = [ValidationSpec(name = "rustc_version", validation_result = result)]),
    ]

_rust_version_check = rule(
    impl = _impl,
    doc = "`sysroot`, and a validation that its rustc prints `expected` for `--version`.",
    attrs = {
        "checker": attrs.exec_dep(providers = [RunInfo], doc = "version_check: `<rustc> <expected> <result>`."),
        "expected": attrs.string(doc = "The whole line `rustc --version` prints, e.g. `rustc 1.99.0 (b940084d7 2026-09-28)`."),
        "sysroot": attrs.dep(doc = "A rust_sysroot."),
    },
)

rust_version_check = declares_docs(_rust_version_check)
