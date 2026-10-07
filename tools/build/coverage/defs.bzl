"""The directory a coverage gate runs from (README.md, "The build gate";
tools/build/mojo/coverage.bzl): cov_gate.sh, covcheck and the ratchet."""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")

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
