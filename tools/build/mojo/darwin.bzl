"""The macOS arm64 Mojo toolchain.

It produces the same `MojoToolchainInfo` as `mojo_toolchain`, so mojo_library,
mojo_binary and mojo_test are unchanged; what differs is what each field holds:

  busybox   tools/build/mojo/darwin/busybox.sh, the busybox calling convention over the
            operating system's /bin and /usr/bin (there is no static busybox
            for macOS).
  compiler  the osx-arm64 compiler closure, unpacked on a linux `light`
            worker like the linux one, by the same unpacker.
  link      a `mojo_darwin_link` directory: the `cc` the compiler finds on
            PATH, host_identity.sh, and `macos_hosts`, the host identities a
            compile may run on.
  cc_target the deployment target (MACOSX_DEPLOYMENT_TARGET).
  wrapper   tools/build/mojo/darwin/mojo_wrapper.sh.
  gate_runner, launcher
            the shared scripts with tools/build/mojo/darwin/dyld_prelude.sh prepended
            (a `dyld_script`), so they set DYLD_LIBRARY_PATH. (`launcher` is read
            only by bundles, which are linux only; it is the field's macOS
            form.)

Link story, measured on the macOS workers: the compiler links through the
`cc` on PATH, as it does on linux (where every link goes through the zig cc
shim, although modular.cfg carries an `lld_path` key on both). Here that is
tools/build/mojo/darwin/cc, the host's /usr/bin/cc, which runs the host's
ld; a cc that fails fails the link, so bin/lld is not part of the closure.

A built binary names its runtime libraries as @rpath/..., and carries one run
path, `@loader_path/lib` (the runnable directory's lib/). System libraries
(/usr/lib, /System), the SDK, the C driver and the linker are the host's; a
digest of them (host_identity.sh) identifies a host. The hosts the root cell
names (`[komira_re] darwin_macos_hosts`) are written into every compile's
inputs, so they are part of every action key, and the wrapper refuses a host
whose identity is not among them.
"""

load(":providers.bzl", "MojoToolchainInfo")
load(":toolchain.bzl", "busybox_sh")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _mojo_darwin_link_impl(ctx):
    hosts = sorted([h.strip() for h in ctx.attrs.macos_hosts if h.strip()])
    if not hosts:
        fail(("{}: no macOS host identity. Set `[komira_re] darwin_macos_hosts` of the root cell " +
              "to what tools/build/mojo/darwin/host_identity.sh prints on each worker to build " +
              "for darwin-arm64.").format(ctx.label))
    out = ctx.actions.copied_dir(ctx.label.name, {
        "cc": ctx.attrs.cc,
        "host_identity.sh": ctx.attrs.host_identity,
        "macos_hosts": ctx.actions.write(ctx.label.name + ".macos_hosts", "\n".join(hosts) + "\n"),
    })
    return [DefaultInfo(default_output = out)]

mojo_darwin_link_rule = rule(
    impl = _mojo_darwin_link_impl,
    attrs = {
        "cc": attrs.source(),
        "host_identity": attrs.source(),
        # The host identities (what host_identity.sh prints) a compile may
        # run on; any other host is refused.
        "macos_hosts": attrs.list(attrs.string()),
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
dyld_script_rule = rule(
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
            watchdog_idle_secs = ctx.attrs.watchdog_idle_secs,
            watchdog_sample_secs = ctx.attrs.watchdog_sample_secs,
            gate_runner = one(ctx.attrs.gate_runner),
            run_check = one(ctx.attrs._run_check),
            numa_guard = one(ctx.attrs._numa_guard),
            launcher = one(ctx.attrs.launcher),
            runtime = one(ctx.attrs.runtime),
        ),
    ]

mojo_darwin_toolchain_rule = rule(
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
        # The compile watchdog of darwin/mojo_wrapper.sh, as mojo_toolchain's.
        "watchdog_idle_secs": attrs.int(default = 300),
        "watchdog_sample_secs": attrs.int(default = 30),
        "_numa_guard": attrs.dep(default = "komira//tools/build/mojo:numa_guard.sh"),
        "_run_check": attrs.dep(default = "komira//tools/build/mojo:run_check.sh"),
        "_wrapper": attrs.dep(default = "komira//tools/build/mojo/darwin:mojo_wrapper.sh"),
    },
)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
dyld_script = declares_docs(dyld_script_rule)
mojo_darwin_link = declares_docs(mojo_darwin_link_rule)
mojo_darwin_toolchain = declares_docs(mojo_darwin_toolchain_rule)
