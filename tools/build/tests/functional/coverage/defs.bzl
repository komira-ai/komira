"""Checks of coverage binaries (test 41), as build actions: check.sh over the
binaries, with debug_relocate, which refuses a file holding a compressed
section."""

load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")

def _impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            ctx.attrs.script,
            tc.busybox,
            out.as_output(),
            ctx.attrs._relocate[DefaultInfo].default_outputs[0],
            ctx.attrs.mode,
            [cmd_args(n, format = "--name={}") for n in ctx.attrs.names],
            [cmd_args(d, format = "--dir={}") for d in ctx.attrs.dirs],
            ctx.attrs.bins,
        ),
        category = "cov_debug_check",
    )
    return [DefaultInfo(default_output = out)]

cov_debug_check = rule(
    impl = _impl,
    attrs = {
        # Coverage binaries ([coverage][bin][<test>] sub-targets).
        "bins": attrs.list(attrs.source()),
        # `hermetic`: each binary has line tables and no sandbox path; `same`:
        # the binaries are the same bytes (see check.sh).
        # hermetic: extended regular expressions, each matched by a whole
        # string of each binary: the relative directories of the line tables.
        "dirs": attrs.list(attrs.string(), default = []),
        "mode": attrs.enum(["hermetic", "same"]),
        # hermetic: strings each binary must hold whole (strings(1)): the
        # file name of a library source the test calls, which only the
        # compile's line tables put there.
        "names": attrs.list(attrs.string(), default = []),
        "script": attrs.source(),
        "_relocate": attrs.exec_dep(default = "komira//tools/build/coverage/kcov:debug_relocate"),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

def _set_impl(ctx):
    want = sorted([m.short_path for m in ctx.attrs.members])
    for agg in ctx.attrs.aggregates:
        got = sorted([a.short_path for a in agg[DefaultInfo].default_outputs])
        if got != want:
            fail("{}: {} has the outputs {}, but must have exactly {}, one coverage binary per test".format(ctx.label, agg.label, got, want))
    out = ctx.actions.write(ctx.label.name + ".txt", ["ok: {} = {}".format(agg.label, want) for agg in ctx.attrs.aggregates])
    return [DefaultInfo(default_output = out)]

# Fails at analysis unless the default outputs of each of `aggregates` (a
# library's [coverage] and [coverage][bin]) are exactly `members`, the
# per-test binaries ([coverage][bin][<test>]) of every test.
cov_set_check = rule(
    impl = _set_impl,
    attrs = {
        "aggregates": attrs.list(attrs.dep()),
        "members": attrs.list(attrs.source()),
    },
)
