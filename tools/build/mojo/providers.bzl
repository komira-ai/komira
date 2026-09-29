"""Providers shared by the Mojo rules."""

def _include_arg(pkg):
    # One `-I` per precompiled package: the directory that holds exactly that
    # `.mojoc`. The artifact itself becomes an input of the action.
    return cmd_args(pkg, format = "-I{}", parent = 1)

# The transitive closure of precompiled packages a consumer must see. The
# compiler needs the FULL closure on `-I`, not only direct deps.
MojoPkgTSet = transitive_set(args_projections = {"include": _include_arg})

MojoInfo = provider(fields = {
    # C/C++ libraries (the prelude's MergedLinkInfo, e.g. from `cxx_library`)
    # that code in this package calls, with those of every package it depends
    # on: what a binary linking this package must also link. None when there
    # are none.
    "c_link": provider_field(typing.Any, default = None),
    "import_name": provider_field(str),
    "pkgs": provider_field(typing.Any),  # MojoPkgTSet
})

MojoToolchainInfo = provider(fields = {
    # Static busybox: the shell and file utilities every action uses.
    "busybox": provider_field(typing.Any),
    # Directory: the unpacked compiler closure (bin/mojo, lib/, share/max,
    # CLOSURE_MANIFEST).
    "compiler": provider_field(typing.Any),
    # Directory: what the compile's link step runs. On linux, the unpacked
    # zig distribution (the C link driver); on macOS, a `mojo_darwin_link`
    # (the cc shim and the host identity the execution platform promises).
    "link": provider_field(typing.Any),
    # The link target: a zig -target triple on linux, the deployment target
    # (MACOSX_DEPLOYMENT_TARGET) on macOS.
    "cc_target": provider_field(str),
    # `--target-cpu` for every compile. Pinned, because the compiler's default
    # is the CPU of the machine the action runs on, which is not part of the
    # action key.
    "target_cpu": provider_field(str),
    "wrapper": provider_field(typing.Any),
    # The compile watchdog of the wrapper (mojo_wrapper.sh): kill a compile
    # whose process tree used no CPU for this long (0: off), sampling every
    # `watchdog_sample_secs`. None where the wrapper has no watchdog.
    "watchdog_idle_secs": provider_field(typing.Any, default = None),
    "watchdog_sample_secs": provider_field(typing.Any, default = None),
    "gate_runner": provider_field(typing.Any),
    "run_check": provider_field(typing.Any),
    # Runs a command only if the action can use enough NUMA nodes
    # (mojo_multi_numa_test).
    "numa_guard": provider_field(typing.Any),
    "launcher": provider_field(typing.Any),
    # Directory: only the shared libraries a built binary loads (a
    # `mojo_runtime`). A runnable binary carries a copy of it as lib/.
    "runtime": provider_field(typing.Any),
})

# A built binary that starts on its own: `run_dir` holds the binary and lib/,
# its runtime libraries, and `command` runs it from there with no launcher.
MojoRunnableInfo = provider(fields = {
    "binary": provider_field(str),  # the binary's file name inside run_dir
    "command": provider_field(typing.Any),  # cmd_args
    "run_dir": provider_field(typing.Any),  # artifact (directory)
})

# A mojo_binary's program as a shared library, for packaging (komira//tools/build/package).
MojoProgramInfo = provider(fields = {
    "name": provider_field(str),  # the program's name: bin/<name>, lib<name>.so
    "shared": provider_field(typing.Any),  # artifact lib<name>.so
    "runtime": provider_field(typing.Any),  # artifact: directory of runtime libraries
    "target_cpu": provider_field(str),  # the CPU the program was compiled for
})
