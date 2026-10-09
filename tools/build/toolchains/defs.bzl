"""The Mojo, C/C++, Rust and protobuf toolchains, declared in the `toolchains` cell of whichever repository is at the project root.

The Mojo rules take their toolchain from `toolchains//:mojo`, the prelude's
convention: the `toolchains` cell belongs to the root repository, so a
repository using komira as a cell can override any toolchain attribute. A
standalone komira checkout declares them in tools/build/cells/toolchains/BUCK;
a repository using komira as a cell copies that file
(tools/build/consumer.buckconfig).

Each toolchain states the OS and CPU its actions run on
(`exec_compatible_with`), which picks the one execution platform of that OS.
It states nothing else about the worker: which machine of a remote service
runs an action is the service's choice.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/platforms:table.bzl", "row")

load("@komira//tools/build/mojo:cxx.bzl", "no_python_bootstrap_toolchain", "zig_cxx_toolchain")
load("@komira//tools/build/mojo:proto.bzl", "mojo_proto_toolchain")
load("@komira//tools/build/mojo:toolchain.bzl", "mojo_toolchain")
load("@komira//tools/build/rust:defs.bzl", "rust_toolchain")

_TOOLCHAINS = "komira//tools/build/toolchains:"
_TOOLCHAINS_RUST = "komira//tools/build/toolchains/rust:"

MOJO_TOOLCHAIN_ATTRS = dict(
    busybox = _TOOLCHAINS + "busybox",
    cc_target = row("linux-x86_64")["zig_triple"],
    compiler = _TOOLCHAINS + "mojo_compiler",
    runtime = _TOOLCHAINS + "mojo_runtime",
    # Every compile targets this CPU, whatever worker runs it. x86-64-v3
    # (AVX2, BMI2, FMA): built binaries and gated tests need a worker, and a
    # deployment host, that implements it.
    target_cpu = row("linux-x86_64")["target_cpu"],
    zig = _TOOLCHAINS + "zig",
)

# What a linux x86_64 toolchain compiles for, and where its actions run: a
# target for any other platform that reaches it is incompatible rather than
# built for the wrong one.
_LINUX_X86_64 = LINUX_X86_64

def komira_mojo_toolchains(darwin = "komira//tools/build/toolchains/darwin:mojo", **overrides):
    """Declare `:mojo` in the calling package.

    Each keyword in `overrides` replaces the `mojo_toolchain` attribute of that
    name (see MOJO_TOOLCHAIN_ATTRS), e.g. `compiler = ...` to pin a different
    compiler for every Mojo target of the repository. They apply to the linux
    x86_64 toolchain; `darwin` names the toolchain `:mojo` selects for a macOS
    target platform.
    """
    attrs = dict(MOJO_TOOLCHAIN_ATTRS)
    attrs.update(overrides)

    # The toolchain of mojo_library, mojo_binary and mojo_test, chosen by the
    # target platform's os. A target platform with neither os fails to
    # configure.
    native.toolchain_alias(
        name = "mojo",
        actual = select({
            "prelude//os/constraints:linux": ":mojo_linux_x86_64",
            "prelude//os/constraints:macos": darwin,
        }),
        visibility = ["PUBLIC"],
    )

    # linux x86_64: compiles, gated tests and run checks.
    mojo_toolchain(
        name = "mojo_linux_x86_64",
        target_compatible_with = _LINUX_X86_64,  # komira-limit:mojo-toolchain-x86-64
        exec_compatible_with = _LINUX_X86_64,
        visibility = ["PUBLIC"],
        **attrs
    )

CXX_TOOLCHAIN_ATTRS = dict(
    busybox = _TOOLCHAINS + "busybox",
    launcher = _TOOLCHAINS + "zig_cc_launcher",
    # The same target and CPU as the Mojo link steps, so C objects link into
    # Mojo binaries.
    target = MOJO_TOOLCHAIN_ATTRS["cc_target"],
    target_cpu = MOJO_TOOLCHAIN_ATTRS["target_cpu"],
    zig = _TOOLCHAINS + "zig",
)

def komira_cxx_toolchains(**overrides):
    """Declare `:cxx`, `:cxx_no_default_deps` and `:python_bootstrap` in the calling package.

    The prelude's `cxx_library` looks its toolchain up as `toolchains//:cxx`,
    and configures a tool that needs `toolchains//:python_bootstrap`. This
    declares both: a C/C++ toolchain on zig's clang, and a Python bootstrap
    toolchain that refuses when run (workers have no Python; nothing komira
    builds runs it), plus `:cxx_no_default_deps`, an alias of `:cxx` that
    unconfigured queries need (see below). A repository that already has its
    own `:cxx` does not call this, and declares its own `:cxx_no_default_deps`.
    Each keyword in `overrides` replaces the `zig_cxx_toolchain` attribute of
    that name (see CXX_TOOLCHAIN_ATTRS).
    """
    attrs = dict(CXX_TOOLCHAIN_ATTRS)
    attrs.update(overrides)
    zig_cxx_toolchain(
        name = "cxx",
        # It builds for linux x86_64 only (see _LINUX_X86_64).
        target_compatible_with = _LINUX_X86_64,  # komira-limit:cxx-toolchain-x86-64
        exec_compatible_with = _LINUX_X86_64,
        visibility = ["PUBLIC"],
        **attrs
    )
    # The prelude's C/C++ rules take their toolchain from a select whose
    # other branch, never taken in a configured graph, is
    # `toolchains//:cxx_no_default_deps` (prelude/decls/toolchains_common.bzl,
    # `_cxx_toolchain`): the C/C++ toolchain without the default deps a
    # repository's macros may add to every target. An unconfigured query
    # (`buck2 uquery deps(...)`, `rdeps(...)`) follows every branch and fails
    # on a label no package declares. `:cxx` adds no default deps, so the
    # variant is `:cxx` itself; an alias adds no action, and configured builds
    # never reach it, so no action digest changes.
    native.toolchain_alias(
        name = "cxx_no_default_deps",
        actual = ":cxx",
        visibility = ["PUBLIC"],
    )
    no_python_bootstrap_toolchain(
        name = "python_bootstrap",
        exec_compatible_with = _LINUX_X86_64,
        busybox = attrs["busybox"],
        visibility = ["PUBLIC"],
    )

RUST_TOOLCHAIN_ATTRS = dict(
    busybox = _TOOLCHAINS + "busybox",
    # Links go through zig to the same glibc floor as the Mojo link steps.
    cc_target = MOJO_TOOLCHAIN_ATTRS["cc_target"],
    sysroot = _TOOLCHAINS_RUST + "sysroot",
    zig = _TOOLCHAINS + "zig",
)

def komira_rust_toolchains(**overrides):
    """Declare `:rust`, the toolchain of rust_library and rust_binary, in the calling package.

    rustc 1.85.0 from `komira//tools/build/toolchains/rust:sysroot`. Compiles
    run on the linux execution platform, like Mojo compiles. rustc loads only glibc from the worker (everything
    else it needs is in the sysroot); links target glibc 2.34 through zig, so
    the binaries run on any worker with glibc 2.34 or newer. Each keyword in
    `overrides` replaces the `rust_toolchain` attribute of that name (see
    RUST_TOOLCHAIN_ATTRS).
    """
    attrs = dict(RUST_TOOLCHAIN_ATTRS)
    attrs.update(overrides)
    rust_toolchain(
        name = "rust",
        # It builds for linux x86_64 only (see _LINUX_X86_64).
        target_compatible_with = _LINUX_X86_64,  # komira-limit:rust-toolchain-x86-64
        exec_compatible_with = _LINUX_X86_64,
        visibility = ["PUBLIC"],
        **attrs
    )

PROTO_TOOLCHAIN_ATTRS = dict(
    busybox = _TOOLCHAINS + "busybox",
    db_plugin = "komira//tools/build/proto-codegen:protoc-gen-mojo-db",
    plugin = "komira//tools/build/proto-codegen:protoc-gen-mojo",
    protoc = "komira//tools/build/toolchains/proto:protoc",
    routes_plugin = "komira//tools/build/proto-codegen:protoc-gen-mojo-routes",
)

def komira_proto_toolchains(**overrides):
    """Declare `:mojo_proto`, the toolchain of mojo_proto_library, in the calling package.

    protoc 29.1, protoc-gen-mojo, protoc-gen-mojo-db and protoc-gen-mojo-routes, built from source with `:rust`. It
    states no execution constraint: a mojo_proto_library also precompiles the
    generated package, and one target has one execution platform, so code
    generation runs where the Mojo toolchain puts that target (the linux
    execution platform). Each keyword in `overrides` replaces the `mojo_proto_toolchain`
    attribute of that name (see PROTO_TOOLCHAIN_ATTRS).
    """
    attrs = dict(PROTO_TOOLCHAIN_ATTRS)
    attrs.update(overrides)
    mojo_proto_toolchain(
        name = "mojo_proto",
        # It builds for linux x86_64 only (see _LINUX_X86_64).
        target_compatible_with = _LINUX_X86_64,  # komira-limit:proto-toolchain-x86-64
        visibility = ["PUBLIC"],
        **attrs
    )

# The toolchain families komira_toolchains declares, each by its own macro.
_FAMILIES = {
    "cxx": komira_cxx_toolchains,
    "mojo": komira_mojo_toolchains,
    "proto": komira_proto_toolchains,
    "rust": komira_rust_toolchains,
}

def komira_toolchains(mojo = None, cxx = None, rust = None, proto = None, omit = []):
    """Declare every komira toolchain in the calling package: the whole `toolchains/BUCK` of a repository.

    A standalone checkout, and a repository using komira as a cell, calls
    this and nothing else, so a family komira adds later is declared without
    editing the copied file. Each family keyword is a dict of overrides for
    that family's macro, e.g. `mojo = {"compiler": "//third_party/mojo:compiler"}`
    or `mojo = {"darwin": ...}` for komira_mojo_toolchains, `cxx = {...}` for
    komira_cxx_toolchains, `rust = {...}`, `proto = {...}`. `omit` names the
    families the repository declares itself, e.g. `omit = ["cxx"]` to keep
    its own `:cxx`, `:cxx_no_default_deps` and `:python_bootstrap`. `proto`
    builds its plugin with `:rust`, so omitting `rust` needs a `:rust` of the
    repository's own.
    Calling it with no arguments gives the same action digests as a
    standalone checkout.
    """
    overrides = {"cxx": cxx, "mojo": mojo, "proto": proto, "rust": rust}
    for family in omit:
        if family not in _FAMILIES:
            fail("komira_toolchains: omit names {}, which is not a toolchain family ({})".format(
                repr(family),
                ", ".join(sorted(_FAMILIES)),
            ))
        if overrides[family] != None:
            fail("komira_toolchains: {} is both omitted and given overrides".format(family))
    for family in sorted(_FAMILIES):
        if family not in omit:
            _FAMILIES[family](**(overrides[family] or {}))
