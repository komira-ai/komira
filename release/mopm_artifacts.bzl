"""The build artifacts `mopm stage` packs: one `.mojoc` per package moved to mopm.

    mopm_artifacts(
        name = "mopm_artifacts",
        packages = ["komira_encoding", "komira_json"],
        natives = {"komira_libc": {"komira_libc_posix": "//src/komira_libc:native_komira_libc_posix"}},
    )

A package is a library built with buildrules' `mojo_package` (its BUCK file has
`:lib`, the `.mojoc` that exists only once its tests passed). The output is one
directory in the layout `mopm stage --artifacts` reads, `linux-64/<name>.mojoc`
(the farm builds for linux-64), so what is packed and published is the library
the tests passed, not a rebuild.

A package with a `[native.<id>] kind = "static"` in its mopm.toml also has `natives = {"<package>":
{"<id>": "<archive target>"}}`: the archive is `linux-64/<package>.native/lib<id>.a`, the file
`mopm stage` packs as the package's native. The target is the one the package's `mojo_conda` passes
to `--native`, so the archive staged is the one that was linked into the tests and packed into the
`.conda`. `mopm stage` refuses a package whose manifest names a native that this directory does not
hold ("has no archive for linux-64: expected ...").

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
    for package, archives in ctx.attrs.natives.items():
        for native_id, archive in archives.items():
            tree["linux-64/{}.native/lib{}.a".format(package, native_id)] = archive[DefaultInfo].default_outputs[0]
    return [DefaultInfo(default_output = ctx.actions.copied_dir("mopm_artifacts", tree))]

_mopm_artifacts = rule(
    impl = _impl,
    attrs = {
        "libs": attrs.list(attrs.dep()),
        "names": attrs.list(attrs.string()),
        "natives": attrs.dict(attrs.string(), attrs.dict(attrs.string(), attrs.dep()), default = {}),
    },
)

def mopm_artifacts(name, packages, natives = {}, **kwargs):
    """See the module documentation. `packages` are directory names under src/; `natives` is `{package: {id: archive target}}`."""
    if not packages:
        fail("{}: no package".format(name))
    for package in natives:
        if package not in packages:
            fail("{}: natives names {}, which is not in packages".format(name, package))
    _mopm_artifacts(
        name = name,
        names = packages,
        libs = ["//src/{}:lib".format(p) for p in packages],
        natives = natives,
        **kwargs
    )
