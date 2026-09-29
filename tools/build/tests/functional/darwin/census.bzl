"""Which macOS hosts the darwin execution platform's actions land on.

`count` actions, each with its own key, run tools/build/mojo/darwin/host_identity.sh
on the macOS execution platform and record what it prints. Build with
`--target-platforms komira//tools/build/platforms:darwin-arm64 --no-remote-cache`
so every action really runs (tools/build/tests/functional/darwin/check.sh does). Each
value must be one of `[komira_re] darwin_macos_hosts`, or every compile on
that host refuses; a listed value that never appears may name a host that
left the pool.
"""

load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")

_SCRIPT = """
BB="$1"; LINK="$2"; OUT="$3"
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
"$BB" sh "$LINK/host_identity.sh" > "$OUT"
"""

def _impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    outs = []
    for i in range(ctx.attrs.count):
        out = ctx.actions.declare_output("host.{}".format(i))
        script = ctx.actions.write("census.{}.sh".format(i), "# census action {}\n".format(i) + _SCRIPT)
        ctx.actions.run(
            cmd_args(tc.busybox, "sh", script, tc.busybox, tc.link, out.as_output()),
            category = "darwin_host_census",
            identifier = str(i),
        )
        outs.append(out)
    return [DefaultInfo(default_outputs = outs)]

darwin_host_census = rule(
    impl = _impl,
    attrs = {
        "count": attrs.int(default = 8),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)
