"""The glibc loader's own record of what the compiler loads.

Runs one real compile through the real wrapper (which gives the compiler
`LD_DEBUG=libs` through its --ld-debug-output flag: the compiler sees no
other variable of this action), then the built binary through the real
`act launch` with `LD_DEBUG=libs`, and reports every file the
loader mapped and initialized in each (`compile init <file>`, `run init
<file>`), with the toolchain directory written as `<toolchain>`.
tools/build/tests/run_tests.sh reads the report; it is a diagnostic output, not part of any build.
"""

load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    exe = ctx.actions.declare_output("hello")
    report = ctx.actions.declare_output("loader_report.txt")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._act[RunInfo],
            "loader-trace",
            tc.wrapper,
            tc.act,
            tc.compiler,
            tc.link,
            tc.cc_target,
            tc.target_cpu,
            ctx.attrs.src,
            exe.as_output(),
            report.as_output(),
        ),
        category = "compiler_loader_trace",
    )
    return [DefaultInfo(default_output = report)]

compiler_loader_trace_rule = rule(impl = _impl, attrs = {
    "src": attrs.source(),
    "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    "_act": attrs.exec_dep(default = "tests//tools:tests_act", providers = [RunInfo]),
})

# Declares this package's doc_tree too (tools/build/lint/doc_tree.bzl).
compiler_loader_trace = declares_docs(compiler_loader_trace_rule)
