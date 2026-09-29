"""Providers shared by the Mojo rules."""

def _include_arg(pkg):
    # One `-I` per precompiled package: the directory that holds exactly that
    # `.mojoc`. The artifact itself becomes an input of the action.
    return cmd_args(pkg, format = "-I{}", parent = 1)

# The transitive closure of precompiled packages a consumer must see. The
# compiler needs the FULL closure on `-I`, not only direct deps.
MojoPkgTSet = transitive_set(args_projections = {"include": _include_arg})

MojoInfo = provider(fields = {
    "import_name": provider_field(str),
    "pkgs": provider_field(typing.Any),  # MojoPkgTSet
})

MojoToolchainInfo = provider(fields = {
    # Static busybox: the shell and file utilities every action uses.
    "busybox": provider_field(typing.Any),
    # Directory: the unpacked compiler closure (bin/mojo, lib/, share/max,
    # CLOSURE_MANIFEST).
    "compiler": provider_field(typing.Any),
    # Directory: the unpacked zig distribution, used as the C link driver.
    "zig": provider_field(typing.Any),
    # zig -target triple for link steps.
    "cc_target": provider_field(str),
    "wrapper": provider_field(typing.Any),
    "gate_runner": provider_field(typing.Any),
    "run_check": provider_field(typing.Any),
})
