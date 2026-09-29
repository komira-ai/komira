"""The macOS arm64 Mojo toolchain.

It produces the same `MojoToolchainInfo` as `mojo_toolchain`, so mojo_library,
mojo_binary and mojo_test are unchanged; what differs is what each field holds:

  busybox   mojo/darwin/busybox.sh, the busybox calling convention over the
            operating system's /bin and /usr/bin (there is no static busybox
            for macOS).
  compiler  the osx-arm64 compiler closure, unpacked on a linux `light`
            worker like the linux one, with bin/lld kept (see below).
  link      a `mojo_darwin_link` directory: the `cc` the compiler finds on
            PATH, host_identity.sh, and the host identity the execution
            platform promises.
  cc_target the deployment target (MACOSX_DEPLOYMENT_TARGET).
  wrapper   mojo/darwin/mojo_wrapper.sh.
  gate_runner, launcher
            the shared scripts with mojo/darwin/dyld_prelude.sh prepended
            (a `dyld_script`), so they set DYLD_LIBRARY_PATH. (No rule reads
            `launcher` yet, on either platform; it is the field's macOS form.)

Link story, as wired: the compiler links through the `cc` on PATH, as it
does on linux (where the closure has no bin/lld and every link goes through
the zig cc shim, although modular.cfg carries the same `lld_path` key). Here
that is mojo/darwin/cc, the host's /usr/bin/cc, which runs the host's ld.
bin/lld is kept only as a hedge, in case the osx-arm64 compiler links through
`lld_path` instead; which of the two it uses is unverified until the first
compile on a macOS worker.

A built binary names its runtime libraries as @rpath/..., and carries one run
path, `@loader_path/lib` (the runnable directory's lib/). System libraries
(/usr/lib, /System), the SDK, the C driver and the linker are the host's; a
digest of them (host_identity.sh) is the `macos_host` property of the
execution platform, so it is part of every action key, and the wrapper
refuses a host whose identity differs.
"""

load(":providers.bzl", "MojoToolchainInfo")
load(":toolchain.bzl", "busybox_sh")

def _mojo_darwin_link_impl(ctx):
    host = ctx.attrs.macos_host.strip()
    if not host:
        fail(("{}: no macOS host identity. Set `macos_host=<value>` (what " +
              "mojo/darwin/host_identity.sh prints on the workers) in the root cell's " +
              "`[komira_re] darwin_mojo_compile_properties` to build for darwin-arm64.").format(ctx.label))
    out = ctx.actions.copied_dir(ctx.label.name, {
        "cc": ctx.attrs.cc,
        "host_identity.sh": ctx.attrs.host_identity,
        "macos_host": ctx.actions.write(ctx.label.name + ".macos_host", host),
    })
    return [DefaultInfo(default_output = out)]

mojo_darwin_link = rule(
    impl = _mojo_darwin_link_impl,
    attrs = {
        "cc": attrs.source(),
        "host_identity": attrs.source(),
        # The host identity (what host_identity.sh prints) the platform promises.
        "macos_host": attrs.string(),
    },
)

def _dyld_script_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".sh")
    ctx.actions.run(
        busybox_sh(bb, 'BB="$1"; "$BB" cat "$2" "$3" > "$4"', ctx.attrs.prelude, ctx.attrs.src, out.as_output()),
        category = "dyld_script",
    )
    return [DefaultInfo(default_output = out)]

# `prelude` followed by `src`, as one script.
dyld_script = rule(
    impl = _dyld_script_impl,
    attrs = {
        "busybox": attrs.exec_dep(),
        "prelude": attrs.source(),
        "src": attrs.source(),
    },
)

def _mojo_darwin_toolchain_impl(ctx):
    def one(dep):
        return dep[DefaultInfo].default_outputs[0]
    return [
        DefaultInfo(),
        MojoToolchainInfo(
            busybox = one(ctx.attrs.busybox),
            compiler = one(ctx.attrs.compiler),
            link = one(ctx.attrs.link),
            cc_target = ctx.attrs.deployment_target,
            target_cpu = ctx.attrs.target_cpu,
            wrapper = one(ctx.attrs._wrapper),
            gate_runner = one(ctx.attrs.gate_runner),
            run_check = one(ctx.attrs._run_check),
            numa_guard = one(ctx.attrs._numa_guard),
            launcher = one(ctx.attrs.launcher),
            runtime = one(ctx.attrs.runtime),
        ),
    ]

mojo_darwin_toolchain = rule(
    impl = _mojo_darwin_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "busybox": attrs.exec_dep(),
        "compiler": attrs.exec_dep(),
        "deployment_target": attrs.string(),
        # `dyld_script`s of komira//tools/build/mojo:gate_runner.sh and komira//tools/build/mojo:launch.sh.
        "gate_runner": attrs.exec_dep(),
        "launcher": attrs.exec_dep(),
        # A `mojo_darwin_link`.
        "link": attrs.exec_dep(),
        "runtime": attrs.exec_dep(),
        "target_cpu": attrs.string(),
        "_numa_guard": attrs.dep(default = "komira//tools/build/mojo:numa_guard.sh"),
        "_run_check": attrs.dep(default = "komira//tools/build/mojo:run_check.sh"),
        "_wrapper": attrs.dep(default = "komira//tools/build/mojo/darwin:mojo_wrapper.sh"),
    },
)
