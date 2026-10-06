"""run_capture: EXPERIMENT (branch exp/mojo-trivial-copy-repro, never merged).

Runs a mojo_binary once per entry of `runs` (each a space-separated argv), as
its own remote action. An action always succeeds: its log holds the argv, the
program's output and RUN_RC=. The default output is every log, in order.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo", "MojoToolchainInfo")

_SCRIPT = """
log=$1; dir=$2; bin=$3; shift 3
{
  echo "=== $bin $*"
  rc=0
  "$dir/$bin" "$@" < /dev/null || rc=$?
  echo "RUN_RC=$rc"
} > "$log" 2>&1
exit 0
"""

def _run_capture_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    r = ctx.attrs.bin[MojoRunnableInfo]
    logs = []
    subs = {}
    for i, run in enumerate(ctx.attrs.runs):
        name = "run{}".format(i)
        log = ctx.actions.declare_output("logs/{}.log".format(name))
        ctx.actions.run(
            cmd_args(tc.busybox, "sh", "-c", _SCRIPT, "run_capture", log.as_output(), r.run_dir, r.binary, run.split(" ") if run else []),
            category = "run_capture",
            identifier = name,
        )
        logs.append(log)
        subs[name] = [DefaultInfo(default_output = log)]
    report = ctx.actions.declare_output("report.txt")
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", "-c", 'out=$1; shift; "$0" cat "$@" > "$out"', tc.busybox, report.as_output(), logs),
        category = "run_capture_report",
    )
    return [DefaultInfo(default_output = report, sub_targets = subs)]

_run_capture = rule(
    impl = _run_capture_impl,
    attrs = {
        "bin": attrs.dep(providers = [MojoRunnableInfo]),
        "runs": attrs.list(attrs.string()),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

run_capture = declares_docs(_run_capture)

def _compiler_version_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    log = ctx.actions.declare_output("version.txt")
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", "-c", 'out=$1; c=$2; { ls "$c" "$c/bin"; "$c/bin/mojo" --version; echo "RC=$?"; } > "$out" 2>&1; exit 0', "v", log.as_output(), tc.compiler),
        category = "mojo_version",
    )
    return [DefaultInfo(default_output = log)]

_compiler_version = rule(
    impl = _compiler_version_impl,
    attrs = {
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

compiler_version = declares_docs(_compiler_version)
