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
  act       komira//tools/build/mojo:act_darwin, the same tool built for macOS;
            its `launch` points the loader at the compiler's lib/ with
            DYLD_LIBRARY_PATH.

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

With no host named and the execution mode local on a Mac, the one host is the
sentinel `local` (DARWIN_LOCAL_HOST): the wrapper then skips the identity
comparison, because the compile runs on the machine that runs Buck2. The
sentinel never reaches a farm action: it appears only when no host is named
and the mode is local, only alone, and the rule refuses it otherwise; the
wrapper refuses it beside a real identity. Its action key does not name the
host (a local result is not shareable across Macs).
"""

load(":providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/platforms:defs.bzl", "DARWIN_LOCAL_HOST")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _mojo_darwin_toolchain_impl(ctx):
    def one(dep):
        return dep[DefaultInfo].default_outputs[0]
    hosts = sorted([h.strip() for h in ctx.attrs.macos_hosts if h.strip()])
    if hosts and (hosts == [DARWIN_LOCAL_HOST]) != ctx.attrs.local_execution:
        # The sentinel is for a build on this machine only: alone, and only
        # where the BUCK file found the execution mode local on a Mac.
        fail(("{}: the local host sentinel `{}` {} (local_execution = {}); a farm's hosts " +
              "are real identities and never mix with it.").format(
            ctx.label,
            DARWIN_LOCAL_HOST,
            "is missing" if ctx.attrs.local_execution else "is not allowed here",
            ctx.attrs.local_execution,
        ))
    if not hosts:
        fail(("{}: no macOS host identity. Set `[komira_re] darwin_macos_hosts` of the root cell " +
              "to what `mojo_compile host-identity` (komira//tools/build/mojo:mojo_compile_darwin) " +
              "prints on each worker to build for darwin-arm64, or build on a Mac with " +
              "`-c komira.execution=local` and no worker property set.").format(ctx.label))
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
        # The host identities (what `mojo_compile host-identity` prints) a
        # compile may run on; the wrapper refuses any other host.
        "macos_hosts": attrs.list(attrs.string()),
        # True when macos_hosts is the local sentinel (a build on this Mac;
        # darwin_toolchain_hosts_here in platforms/defs.bzl decides).
        "local_execution": attrs.bool(default = False),
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
mojo_darwin_toolchain = declares_docs(mojo_darwin_toolchain_rule)
