"""Checks of coverage builds, as build actions: check.sh over the binaries
(test 41), with debug_relocate, which refuses a file holding a compressed
section; report.sh over the per-test reports of the coverage runs (test 43);
and cov_plant, a copy of a script with one planted defect, and kcov_stub_dir,
a kcov distribution whose bin/kcov is a stand-in (test 43)."""

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

def _report_impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    if ctx.attrs.mode == "golden":
        if len(ctx.attrs.goldens) != len(ctx.attrs.reports):
            fail("{}: one golden per report".format(ctx.label))
        args = [["--golden", g, r] for g, r in zip(ctx.attrs.goldens, ctx.attrs.reports)]
    elif ctx.attrs.mode == "result":
        if len(ctx.attrs.reports) != 1:
            fail("{}: result reads one gate result".format(ctx.label))
        args = [[["--expect", e] for e in ctx.attrs.expect], "--json", ctx.attrs.reports[0]]
    else:
        if ctx.attrs.covcheck == None:
            fail("{}: census needs covcheck".format(ctx.label))
        args = [
            ["--covcheck", ctx.attrs.covcheck[RunInfo]],
            ["--package", ctx.attrs.package],
            [["--file", p, f] for p, f in sorted(ctx.attrs.files.items())],
            [["--expect", e] for e in ctx.attrs.expect],
            [["--cobertura", r] for r in ctx.attrs.reports],
        ]
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", ctx.attrs.script, tc.busybox, out.as_output(), ctx.attrs.mode, args),
        category = "cov_report_check",
    )
    return [DefaultInfo(default_output = out)]

# Checks of the per-test reports of a coverage run (test 43), as a build
# action (report.sh): `golden`, each report is its golden file byte for byte;
# `census`, covcheck's build gate in census mode reads the reports over the
# package's sources (`files`, {repository path: source}) and its result JSON
# holds each `expect` string; `result` (test 45), the result JSON of a
# library's own gate (its [coverage][gate][result], the one `reports` entry)
# holds each `expect` string.
cov_report_check = rule(
    impl = _report_impl,
    attrs = {
        "covcheck": attrs.option(attrs.exec_dep(providers = [RunInfo]), default = None),
        "expect": attrs.list(attrs.string(), default = []),
        "files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "goldens": attrs.list(attrs.source(), default = []),
        "mode": attrs.enum(["golden", "census", "result"]),
        "package": attrs.string(default = ""),
        # [coverage][tests][<test>] sub-targets.
        "reports": attrs.list(attrs.source()),
        "script": attrs.source(),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

def _plant_impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    out = ctx.actions.declare_output(ctx.attrs.out)
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            "-c",
            # The copy must differ from the original, so a sed expression
            # that no longer matches fails here, not as a plant that plants nothing.
            '"$1" sed -e "$2" "$3" > "$4" && ! "$1" cmp -s "$3" "$4"',
            "cov_plant",
            tc.busybox,
            ctx.attrs.expr,
            ctx.attrs.src,
            out.as_output(),
        ),
        category = "cov_plant",
    )
    return [DefaultInfo(default_output = out)]

# A copy of `src` changed by the sed expression `expr`, which must change
# it: one planted defect, or a generated source (covgen).
cov_plant = rule(
    impl = _plant_impl,
    attrs = {
        "expr": attrs.string(),
        "out": attrs.string(),
        "src": attrs.source(),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

def _stub_impl(ctx):
    keep = ctx.actions.write("lib/.keep", "")
    out = ctx.actions.copied_dir("kcov", {
        "bin/kcov": ctx.attrs.kcov[DefaultInfo].default_outputs[0],
        "lib/.keep": keep,
    })
    return [DefaultInfo(default_output = out)]

# A kcov distribution (bin/kcov, lib/) whose bin/kcov is `kcov`, a stand-in
# that fails as kcov does on an executor that refuses it: a cov_run_dir's
# `kcov`.
kcov_stub_dir = rule(
    impl = _stub_impl,
    attrs = {
        "kcov": attrs.exec_dep(),
    },
)
