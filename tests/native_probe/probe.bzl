"""native_probe: EXPERIMENT, never merged. See BUCK.

Stages a conda-shaped prefix (lib/mojo/*.mojoc, lib/libkomira_probe.a,
lib/libkomira_probe.so.1) and runs each case of case.sh against it as its own
action. A case action always succeeds and writes a log; the default output is
every log concatenated, in case order.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")

def _native_probe_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    prefix = ctx.actions.copied_dir("prefix", {
        "lib/libkomira_probe.a": ctx.attrs.archive,
        "lib/libkomira_probe.so.1": ctx.attrs.shared,
        "lib/mojo/probe_dl.mojoc": ctx.attrs.dl_pkg,
        "lib/mojo/probe_static.mojoc": ctx.attrs.static_pkg,
    })
    srcs = ctx.actions.copied_dir("consumers", {s.basename: s for s in ctx.attrs.consumers})
    wd_idle = str(tc.watchdog_idle_secs) if tc.watchdog_idle_secs != None else "300"
    wd_sample = str(tc.watchdog_sample_secs) if tc.watchdog_sample_secs != None else "30"
    logs = []
    subs = {}
    for case in ctx.attrs.cases:
        log = ctx.actions.declare_output("logs/{}.log".format(case))
        ctx.actions.run(
            cmd_args(
                tc.busybox,
                "sh",
                ctx.attrs.script,
                tc.busybox,
                tc.wrapper,
                tc.compiler,
                tc.link,
                tc.cc_target,
                tc.target_cpu,
                wd_idle,
                wd_sample,
                prefix,
                srcs,
                case,
                log.as_output(),
            ),
            category = "native_probe",
            identifier = case,
        )
        logs.append(log)
        subs[case] = [DefaultInfo(default_output = log)]
    report = ctx.actions.declare_output("report.txt")
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            "-c",
            "out=$1; shift; \"$0\" cat \"$@\" > \"$out\"",
            tc.busybox,
            report.as_output(),
            logs,
        ),
        category = "native_probe_report",
    )
    subs["prefix"] = [DefaultInfo(default_output = prefix)]
    return [DefaultInfo(default_output = report, sub_targets = subs)]

_native_probe = rule(
    impl = _native_probe_impl,
    attrs = {
        "archive": attrs.source(),
        "cases": attrs.list(attrs.string()),
        "consumers": attrs.list(attrs.source()),
        "dl_pkg": attrs.source(),
        "script": attrs.source(),
        "shared": attrs.source(),
        "static_pkg": attrs.source(),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

native_probe = declares_docs(_native_probe)
