"""The Mojo toolchains, declared in the `toolchains` cell of whichever repository is at the project root.

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

load("@komira//tools/build/mojo:toolchain.bzl", "mojo_toolchain")

_TOOLCHAINS = "komira//tools/build/toolchains:"
_PLATFORMS = "komira//tools/build/platforms:"

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

def komira_mojo_toolchains(**overrides):
    """Declare `:mojo` and `:mojo_multi_numa` in the calling package.

    Each keyword in `overrides` replaces the `mojo_toolchain` attribute of that
    name (see MOJO_TOOLCHAIN_ATTRS), e.g. `compiler = ...` to pin a different
    compiler for every Mojo target of the repository.
    """
    attrs = dict(MOJO_TOOLCHAIN_ATTRS)
    attrs.update(overrides)

    # The toolchain of mojo_library, mojo_binary and mojo_test: compiles,
    # gated tests and run checks on one NUMA node.
    mojo_toolchain(
        name = "mojo",
        exec_compatible_with = [_PLATFORMS + "mojo_compile", _PLATFORMS + "numa_single"],
        visibility = ["PUBLIC"],
        **attrs
    )

    # The toolchain of mojo_multi_numa_test: runs a built binary on a worker
    # spanning more than one NUMA node. Only an execution platform realizing
    # `komira//tools/build/platforms:exec-mojo-multi-numa` satisfies it; with
    # none registered, its users fail to configure. The constraint is only a
    # claim: the rule's runs also start through numa_guard.sh, which refuses
    # a worker where the action can use fewer than two NUMA nodes.
    mojo_toolchain(
        name = "mojo_multi_numa",
        exec_compatible_with = [_PLATFORMS + "mojo_compile", _PLATFORMS + "numa_multi"],
        visibility = ["PUBLIC"],
        **attrs
    )
