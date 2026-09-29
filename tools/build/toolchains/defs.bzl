"""The Mojo, C/C++, Rust and protobuf toolchains, declared in the `toolchains` cell of whichever repository is at the project root.

The Mojo rules take their toolchain from `toolchains//:mojo` and
`toolchains//:mojo_multi_numa`, the prelude's convention: the `toolchains`
cell belongs to the root repository. A standalone komira checkout declares
them in tools/build/cells/toolchains/BUCK; a repository using komira as a cell
copies that file (tools/build/consumer.buckconfig).

They are declared there, and not in `komira//tools/build/toolchains` beside
the downloads they are built from, because `mojo_multi_numa` only configures
where an execution platform realizes `numa_multi`. In the komira cell it
would fail `buck2 build //...` on every checkout without multi-NUMA workers;
in a cell of its own it is analyzed only when a `mojo_multi_numa_test` uses
it, which is the intended refusal.
"""

load("@komira//tools/build/mojo:cxx.bzl", "no_python_bootstrap_toolchain", "zig_cxx_toolchain")
load("@komira//tools/build/mojo:proto.bzl", "mojo_proto_toolchain")
load("@komira//tools/build/mojo:toolchain.bzl", "mojo_toolchain")
load("@komira//tools/build/rust:defs.bzl", "rust_toolchain")

_TOOLCHAINS = "komira//tools/build/toolchains:"
_PLATFORMS = "komira//tools/build/platforms:"
_TOOLCHAINS_RUST = "komira//tools/build/toolchains/rust:"

MOJO_TOOLCHAIN_ATTRS = dict(
    busybox = _TOOLCHAINS + "busybox",
    cc_target = "x86_64-linux-gnu.2.34",
    compiler = _TOOLCHAINS + "mojo_compiler",
    runtime = _TOOLCHAINS + "mojo_runtime",
    # Every compile targets this CPU, whatever worker runs it. x86-64-v3
    # (AVX2, BMI2, FMA): built binaries and gated tests need a worker, and a
    # deployment host, that implements it.
    target_cpu = "x86-64-v3",
    zig = _TOOLCHAINS + "zig",
)

# What a linux x86_64 toolchain compiles for, and where its actions run: a
# target for any other platform that reaches it is incompatible rather than
# built for the wrong one.
_LINUX_X86_64 = [
    "prelude//os/constraints:linux",
    "prelude//cpu/constraints:x86_64",
]

def komira_mojo_toolchains(darwin = "komira//tools/build/toolchains/darwin:mojo", **overrides):
    """Declare `:mojo` and `:mojo_multi_numa` in the calling package.

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

    # linux x86_64: compiles, gated tests and run checks on one NUMA node.
    mojo_toolchain(
        name = "mojo_linux_x86_64",
        target_compatible_with = _LINUX_X86_64,
        exec_compatible_with = [_PLATFORMS + "mojo_compile", _PLATFORMS + "numa_single"] + _LINUX_X86_64,
        visibility = ["PUBLIC"],
        **attrs
    )

    # The toolchain of mojo_multi_numa_test: runs a built binary on a worker
    # spanning more than one NUMA node. Only an execution platform realizing
    # `komira//tools/build/platforms:exec-mojo-multi-numa` satisfies it; with
    # none registered, its users fail to configure. The constraint is only a
    # claim: the rule's runs also start through numa_guard.sh, which refuses
    # a worker where the action can use fewer than two NUMA nodes. linux
    # x86_64 only.
    mojo_toolchain(
        name = "mojo_multi_numa",
        target_compatible_with = _LINUX_X86_64,
        exec_compatible_with = [_PLATFORMS + "mojo_compile", _PLATFORMS + "numa_multi"] + _LINUX_X86_64,
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
    """Declare `:cxx` and `:python_bootstrap` in the calling package.

    The prelude's `cxx_library` looks its toolchain up as `toolchains//:cxx`,
    and configures a tool that needs `toolchains//:python_bootstrap`. This
    declares both: a C/C++ toolchain on zig's clang, and a Python bootstrap
    toolchain that refuses when run (workers have no Python; nothing komira
    builds runs it). A repository that already has its own `:cxx` does not
    call this. Each keyword in `overrides` replaces the `zig_cxx_toolchain`
    attribute of that name (see CXX_TOOLCHAIN_ATTRS).
    """
    attrs = dict(CXX_TOOLCHAIN_ATTRS)
    attrs.update(overrides)
    zig_cxx_toolchain(
        name = "cxx",
        exec_compatible_with = [_PLATFORMS + "light"],
        visibility = ["PUBLIC"],
        **attrs
    )
    no_python_bootstrap_toolchain(
        name = "python_bootstrap",
        exec_compatible_with = [_PLATFORMS + "light"],
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
    run on the compile workers (the `mojo_compile` class, one NUMA node),
    like Mojo compiles. rustc loads only glibc from the worker (everything
    else it needs is in the sysroot); links target glibc 2.34 through zig, so
    the binaries run on any worker with glibc 2.34 or newer. Each keyword in
    `overrides` replaces the `rust_toolchain` attribute of that name (see
    RUST_TOOLCHAIN_ATTRS).
    """
    attrs = dict(RUST_TOOLCHAIN_ATTRS)
    attrs.update(overrides)
    rust_toolchain(
        name = "rust",
        exec_compatible_with = [_PLATFORMS + "mojo_compile", _PLATFORMS + "numa_single"],
        visibility = ["PUBLIC"],
        **attrs
    )

PROTO_TOOLCHAIN_ATTRS = dict(
    busybox = _TOOLCHAINS + "busybox",
    plugin = "komira//tools/build/proto-codegen:protoc-gen-mojo",
    protoc = "komira//tools/build/toolchains/proto:protoc",
)

def komira_proto_toolchains(**overrides):
    """Declare `:mojo_proto`, the toolchain of mojo_proto_library, in the calling package.

    protoc 29.1 and protoc-gen-mojo, built from source with `:rust`. It
    states no execution constraint: a mojo_proto_library also precompiles the
    generated package, and one target has one execution platform, so code
    generation runs where the Mojo toolchain puts that target (the compile
    workers). Each keyword in `overrides` replaces the `mojo_proto_toolchain`
    attribute of that name (see PROTO_TOOLCHAIN_ATTRS).
    """
    attrs = dict(PROTO_TOOLCHAIN_ATTRS)
    attrs.update(overrides)
    mojo_proto_toolchain(
        name = "mojo_proto",
        visibility = ["PUBLIC"],
        **attrs
    )
