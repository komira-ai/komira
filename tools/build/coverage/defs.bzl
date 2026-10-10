"""The directory a coverage gate runs from (README.md, "The build gate";
tools/build/mojo/coverage.bzl): cov_gate.sh, covcheck and the ratchet. And
`coverage_ci_cases`, the cases of the coverage workflow's scripts (README.md,
"The coverage workflow")."""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _gate_dir_impl(ctx):
    exe = ctx.attrs.covcheck[MojoRunnableInfo]
    out = ctx.actions.copied_dir("cov_gate", {
        # The binary and the runtime libraries its run path ($ORIGIN/lib)
        # names, under fixed names.
        "cov_gate.sh": ctx.attrs.script,
        "covcheck/covcheck": exe.run_dir.project(exe.binary),
        "covcheck/lib": exe.run_dir.project("lib"),
        "ratchet.tsv": ctx.attrs.ratchet,
    })
    return [DefaultInfo(default_output = out)]

_cov_gate_dir = rule(
    impl = _gate_dir_impl,
    doc = "The directory a mojo_library's coverage gate runs from (tools/build/mojo/coverage.bzl): `cov_gate.sh` (`script`), `covcheck/` (`covcheck`, a mojo_binary, with its runtime libraries) and `ratchet.tsv` (`ratchet`). The script finds the others beside itself.",
    attrs = {
        "covcheck": attrs.exec_dep(providers = [MojoRunnableInfo], default = "komira//tools/build/coverage:covcheck_bin"),
        "ratchet": attrs.source(default = "komira//tools/build/coverage:ratchet.tsv"),
        "script": attrs.source(default = "komira//tools/build/coverage:cov_gate.sh"),
    },
)

cov_gate_dir = declares_docs(_cov_gate_dir)

def _ci_cases_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    exe = ctx.attrs.covcheck[MojoRunnableInfo]

    # Copies under buck-out, keyed by their path in the package: a source's
    # path in an action differs between a standalone checkout and a repository
    # mounting komira as a cell, and so would the action's digest.
    files = [ctx.attrs.script] + ctx.attrs.srcs
    staged = ctx.actions.copied_dir("ci_cases_srcs", {f.short_path: f for f in files} | {
        name: f
        for name, f in ctx.attrs.data.items()
    })
    covcheck = ctx.actions.copied_dir("ci_cases_covcheck", {
        "covcheck": exe.run_dir.project(exe.binary),
        "lib": exe.run_dir.project("lib"),
    })
    result = ctx.actions.declare_output("validation.json")
    ctx.actions.run(
        cmd_args(bb, "sh", staged.project(ctx.attrs.script.short_path), bb, result.as_output(), staged, covcheck),
        category = "coverage_ci_cases",
        identifier = ctx.label.name,
    )
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

_coverage_ci_cases = rule(
    impl = _ci_cases_impl,
    doc = "Runs `script` under busybox sh as `sh <script> <busybox> <result.json> <dir> <covcheck dir>`, where `<dir>` holds `script` and `srcs` at their paths in the package and each `data` file at its key, and `<covcheck dir>` holds `covcheck` (the binary) and its `lib/`. The script exits non-zero on a wrong result and writes a successful validation result otherwise; the target is a `ValidationInfo`, so building it runs the cases.",
    attrs = {
        "covcheck": attrs.exec_dep(providers = [MojoRunnableInfo], default = "komira//tools/build/coverage:covcheck_bin"),
        "data": attrs.dict(attrs.string(), attrs.source(), default = {}, doc = "Files from other packages, by the path they are staged at."),
        "script": attrs.source(),
        "srcs": attrs.list(attrs.source(), doc = "The files under test, from the declaring package."),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

def coverage_ci_cases(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _coverage_ci_cases(**kwargs)

coverage_ci_cases = declares_docs(coverage_ci_cases)
