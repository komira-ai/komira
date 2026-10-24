"""The build artifacts `mopm stage` packs: one `.mojoc` per package moved to mopm.

    mopm_artifacts(
        name = "mopm_artifacts",
        packages = ["komira_encoding", "komira_json"],
    )

A package is a library built with buildrules' `mojo_package` (its BUCK file has
`:lib`, the `.mojoc` that exists only once its tests passed). The output is one
directory in the layout `mopm stage --artifacts` reads, `linux-64/<name>.mojoc`
(the farm builds for linux-64), so what is packed and published is the library
the tests passed, not a rebuild.

The list is the one of //release/readme_e2e:packages.bzl (every `src/<name>`
that has a `mopm.toml`), which //:readme_e2e_complete holds to the files of the
checkout in both directions. `mopm stage` itself refuses a member of the
workspace that has no `.mojoc` here, so the two cannot disagree unseen.

Nothing here runs buck2 or sends anything: the targets are dependencies.
"""

def _impl(ctx):
    tree = {}
    for name, lib in zip(ctx.attrs.names, ctx.attrs.libs):
        tree["linux-64/" + name + ".mojoc"] = lib[DefaultInfo].default_outputs[0]
    return [DefaultInfo(default_output = ctx.actions.copied_dir("mopm_artifacts", tree))]

_mopm_artifacts = rule(
    impl = _impl,
    attrs = {
        "libs": attrs.list(attrs.dep()),
        "names": attrs.list(attrs.string()),
    },
)

def mopm_artifacts(name, packages, **kwargs):
    """See the module documentation. `packages` are directory names under src/."""
    if not packages:
        fail("{}: no package".format(name))
    _mopm_artifacts(
        name = name,
        names = packages,
        libs = ["//src/{}:lib".format(p) for p in packages],
        **kwargs
    )
