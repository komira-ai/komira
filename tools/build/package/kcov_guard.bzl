"""The check that no package format packs kcov (README.md, "kcov is never packed").

kcov (`komira//tools/build/toolchains/kcov:kcov`) is GPL-2.0 and a build-only
tool. Every package format runs `kcov_guard.sh guard` over what it packs, in a
build action whose output its published files depend on, so a package that
holds kcov fails the build:

  * `mojo_bundle`: over the bundle directory. `bundle_tarball` and `oci_image`
    pack that directory (and an image the pinned base's layers), and their
    packing actions take the guard's output as an input (defs.bzl);
  * `conda_package`: over every file `komira_pack conda` copies into the
    package (the `.mojoc`, the README, the licence files); the generated
    JSON is all it adds, and `komira_pack conda-check` refuses any other
    member of the pkg tar. Both published directories are copies made after
    the guard passed (conda.bzl).

The guard refuses a file whose sha256 is `KCOV_BIN_SHA256` or whose bytes
contain `KCOV_USAGE_LINE`, the constants of
tools/build/toolchains/kcov/identity.bzl. It takes no dependency on any kcov
target: a package build neither builds kcov nor waits on its checks, and a
kcov that fails to build blocks no package. What ties the constants to the
built kcov is `komira//tools/build/toolchains/kcov:kcov_identity`, which gates
`:kcov` and fails when `bin/kcov` has another sha256 or lacks the line.

`:kcov_guard` is the script as a dependency of the package rules, gated by
the validation `:kcov_guard_cases`, which runs the guard on inputs whose
answer is known, with a fixture file standing for `bin/kcov`.

The sha256 is that of the one kcov this repository builds (the pinned
version, for linux-x86_64, the same bytes in any configuration:
`:kcov_reproducible`). A kcov built otherwise (another version, another
CPU, patched or stripped) has another sha256; the usage line is what refuses
it.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/toolchains/kcov:identity.bzl", "KCOV_BIN_SHA256", "KCOV_USAGE_LINE")

# The guard's identity arguments, one definition for the package rules and the
# cases, so a wrong constant at one call cannot pass the other.
_IDENTITY_ARGS = [KCOV_BIN_SHA256, KCOV_USAGE_LINE]

# busybox: the busybox executable; script: kcov_guard.sh, staged under
# buck-out.
KcovGuardInfo = provider(fields = ["busybox", "script"])

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _stage(ctx):
    # Copied under buck-out: a source's path in an action differs between a
    # standalone checkout and a repository that mounts komira as a cell, and
    # so would the action's digest.
    return ctx.actions.copy_file("kcov_guard.sh", ctx.attrs.script)

def kcov_guard(ctx, guard, identifier, pairs):
    """Runs the guard over `pairs` ([dest, artifact] lists) and returns its output.

    `guard` is the `:kcov_guard` dependency. The output exists only if no
    file is kcov; every action or copy that publishes what was packed takes
    it as an input.
    """
    info = guard[KcovGuardInfo]
    out = ctx.actions.declare_output(identifier + ".kcov_guard")
    args = []
    for dest, artifact in pairs:
        args.extend([dest, artifact])
    ctx.actions.run(
        cmd_args(info.busybox, "sh", info.script, "guard", info.busybox, _IDENTITY_ARGS, out.as_output(), str(ctx.label.raw_target()), args),
        category = "kcov_guard",
        identifier = identifier,
    )
    return out

def _guard_impl(ctx):
    script = _stage(ctx)
    return [
        DefaultInfo(default_output = script),
        KcovGuardInfo(busybox = _out(ctx.attrs._busybox), script = script),
    ]

_ATTRS = {
    "script": attrs.source(doc = "kcov_guard.sh"),
    "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
}

_kcov_guard_tool = rule(
    impl = _guard_impl,
    doc = "kcov_guard.sh as a dependency of the package rules, gated by the validations in `checks`. Depends on no kcov target: the guard reads the constants of tools/build/toolchains/kcov/identity.bzl.",
    attrs = _ATTRS | {
        "checks": attrs.list(attrs.dep(providers = [ValidationInfo])),
    },
)

def _cases_impl(ctx):
    bb = _out(ctx.attrs._busybox)
    report = ctx.actions.declare_output("report", dir = True)
    ctx.actions.run(
        cmd_args(bb, "sh", _stage(ctx), "cases", bb, _IDENTITY_ARGS, report.as_output()),
        category = "kcov_guard_cases",
    )
    # One output: buck2 refuses a validation result whose action produces
    # more than one.
    result = ctx.actions.copy_file("validation.json", report.project("validation.json"))
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

_kcov_guard_cases = rule(
    impl = _cases_impl,
    doc = "`kcov_guard.sh cases`: the guard on inputs whose answer is known, with a fixture file standing for bin/kcov (malformed constants, the fixture renamed, a file holding the usage line, symlinks to the fixture, near misses, and three through the guard's command line), as a validation. Needs no kcov.",
    attrs = _ATTRS,
)

kcov_guard_tool = declares_docs(_kcov_guard_tool)
kcov_guard_cases = declares_docs(_kcov_guard_cases)
