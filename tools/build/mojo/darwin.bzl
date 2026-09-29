"""The macOS arm64 Mojo toolchain.

It produces the same `MojoToolchainInfo` as `mojo_toolchain`, so mojo_library,
mojo_binary and mojo_test are unchanged; what differs is what each field holds:

  busybox   mojo/darwin/busybox.sh, the busybox calling convention over the
            operating system's /bin and /usr/bin (there is no static busybox
            for macOS).
  compiler  the osx-arm64 compiler closure, unpacked on a linux `light`
            worker like the linux one, with bin/lld kept.
  zig       a `mojo_darwin_link` directory: the `cc` the compiler finds on
            PATH, and the SDK version the execution platform promises.
  cc_target the deployment target (MACOSX_DEPLOYMENT_TARGET).
  wrapper   mojo/darwin/mojo_wrapper.sh.
  gate_runner, launcher
            the shared scripts with mojo/darwin/dyld_prelude.sh prepended
            (a `dyld_script`), so they set DYLD_LIBRARY_PATH.

Link story: a built binary names its runtime libraries as @rpath/..., and
carries one run path, `@loader_path/lib` (the runnable directory's lib/).
System libraries (/usr/lib, /System) and the SDK are the host's; the SDK
version is part of the execution platform's property set, so it is part of
every action key, and the wrapper refuses a host whose SDK differs.
"""

load(":providers.bzl", "MojoToolchainInfo")
load(":toolchain.bzl", "busybox_sh")

def _mojo_darwin_link_impl(ctx):
    sdk = ctx.attrs.macos_sdk.strip()
    if not sdk:
        fail(("{}: no macOS SDK version. Set `macos_sdk=<version>` in the root cell's " +
              "`[komira_re] darwin_mojo_compile_properties` to build for darwin-arm64.").format(ctx.label))
    out = ctx.actions.copied_dir(ctx.label.name, {
        "cc": ctx.attrs.cc,
        "macos_sdk": ctx.actions.write(ctx.label.name + ".macos_sdk", sdk),
    })
    return [DefaultInfo(default_output = out)]

mojo_darwin_link = rule(
    impl = _mojo_darwin_link_impl,
    attrs = {
        "cc": attrs.source(),
        # The host SDK version (`xcrun --show-sdk-version`) the platform promises.
        "macos_sdk": attrs.string(),
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
            zig = one(ctx.attrs.link),
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
