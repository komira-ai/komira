"""The macOS arm64 Mojo toolchain.

It produces the same `MojoToolchainInfo` as `mojo_toolchain`, so mojo_library,
mojo_binary and mojo_test are unchanged; what differs is what each field holds:

  busybox   tools/build/mojo/darwin/busybox.sh, the busybox calling convention over the
            operating system's /bin and /usr/bin (there is no static busybox
            for macOS). The compile does not run it; the gate, the run
            check and the shared library copy still do.
  compiler  the osx-arm64 compiler closure, unpacked by a linux action
            like the linux one, by the same unpacker.
  link      None: the wrapper's own `cc` mode is the C driver the compiler
            finds on PATH.
  macos_hosts
            the host identities a compile may run on (`[komira_re]
            darwin_macos_hosts`), passed to every compile as `--macos-host=`.
  cc_target the deployment target (MACOSX_DEPLOYMENT_TARGET).
  wrapper   komira//tools/build/mojo:mojo_compile_darwin, the Zig compile wrapper
            (tools/build/mojo/tools/mojo_compile_macos.zig) built for macOS arm64.
  gate      komira//tools/build/run:gate_darwin, the gate built for macOS
            (it sets DYLD_LIBRARY_PATH beside LD_LIBRARY_PATH for the test).
  launcher  launch.sh with tools/build/mojo/darwin/dyld_prelude.sh prepended
            (a `dyld_script`), so it sets DYLD_LIBRARY_PATH. (`launcher` is
            read only by bundles, which are linux only; it is the field's
            macOS form.)

Link story, measured on the macOS workers: the compiler links through the
`cc` on PATH, as it does on linux (where every link goes through the zig cc
shim, although modular.cfg carries an `lld_path` key on both). Here that is
the wrapper's `cc` mode, which runs the host's /usr/bin/cc and so the host's
ld; a cc that fails fails the link, so bin/lld is not part of the closure.

A built binary names its runtime libraries as @rpath/..., and carries one run
path, `@loader_path/lib` (the runnable directory's lib/). System libraries
(/usr/lib, /System), the SDK, the C driver and the linker are the host's; a
digest of them (`mojo_compile host-identity`) identifies a host. The hosts the
root cell names (`[komira_re] darwin_macos_hosts`) are on every compile's
command line, so they are part of every action key, and the wrapper refuses a
host whose identity is not among them.
"""

load(":providers.bzl", "MojoToolchainInfo")
load(":toolchain.bzl", "busybox_sh")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

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
    hosts = sorted([h.strip() for h in ctx.attrs.macos_hosts if h.strip()])
    if not hosts:
        fail(("{}: no macOS host identity. Set `[komira_re] darwin_macos_hosts` of the root cell " +
              "to what `mojo_compile host-identity` (komira//tools/build/mojo:mojo_compile_darwin) " +
              "prints on each worker to build for darwin-arm64.").format(ctx.label))
    return [
        DefaultInfo(),
        MojoToolchainInfo(
            busybox = one(ctx.attrs.busybox),
            compiler = one(ctx.attrs.compiler),
            link = None,
            macos_hosts = hosts,
            cc_target = ctx.attrs.deployment_target,
            target_cpu = ctx.attrs.target_cpu,
            wrapper = one(ctx.attrs._wrapper),
            watchdog_idle_secs = ctx.attrs.watchdog_idle_secs,
            watchdog_sample_secs = ctx.attrs.watchdog_sample_secs,
            gate = one(ctx.attrs.gate),
            act = one(ctx.attrs._act),
            launcher = one(ctx.attrs.launcher),
            runtime = one(ctx.attrs.runtime),
            os = "darwin",
        ),
    ]

mojo_darwin_toolchain_rule = rule(
    impl = _mojo_darwin_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "busybox": attrs.exec_dep(),
        "compiler": attrs.exec_dep(),
        "deployment_target": attrs.string(),
        # The gate built for macOS (komira//tools/build/run:gate_darwin).
        "gate": attrs.exec_dep(),
        # A `dyld_script` of komira//tools/build/mojo:launch.sh.
        "launcher": attrs.exec_dep(),
        # The host identities (what `mojo_compile host-identity` prints) a
        # compile may run on; the wrapper refuses any other host.
        "macos_hosts": attrs.list(attrs.string()),
        "runtime": attrs.exec_dep(),
        "target_cpu": attrs.string(),
        # The compile watchdog of the wrapper, as mojo_toolchain's.
        "watchdog_idle_secs": attrs.int(default = 300),
        "watchdog_sample_secs": attrs.int(default = 30),
        "_act": attrs.dep(default = "komira//tools/build/mojo:act_darwin"),
        "_wrapper": attrs.dep(default = "komira//tools/build/mojo:mojo_compile_darwin"),
    },
)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
dyld_script = declares_docs(dyld_script_rule)
mojo_darwin_toolchain = declares_docs(mojo_darwin_toolchain_rule)
