"""A remote action that records what the worker provides.

Everything it inspects outside its own inputs is host state; the report is
the evidence behind the host floor documented in tools/build/toolchains/README.md.
"""

load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    out = ctx.actions.declare_output("report.txt")
    ctx.actions.run(cmd_args(ctx.attrs._act[RunInfo], "re-probe", tc.compiler, out.as_output()), category = "re_probe")
    return [DefaultInfo(default_output = out)]

re_probe_rule = rule(impl = _impl, attrs = {
    "toolchain": attrs.toolchain_dep(providers = [MojoToolchainInfo]),
    "_act": attrs.exec_dep(default = "tests//tools:tests_act", providers = [RunInfo]),
})

# Declares this package's doc_tree too (tools/build/lint/doc_tree.bzl).
re_probe = declares_docs(re_probe_rule)
