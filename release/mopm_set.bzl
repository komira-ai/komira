"""The packages published to a mopm registry, as one tree.

    mopm_set(
        name = "mopm_set",
        packages = ["komira_encoding", "komira_json"],
    )

A package is a library built with buildrules' `mojo_package` (its BUCK file
has `:lib`, the `.mojoc` that exists only once its tests passed, and `:conda`,
the `.conda` `mopm pack` made of it). The output is one directory with a
subdirectory per package, `<name>/<name>.mojoc` and `<name>/<the .conda>`:
what //release/ci:mopm_publish takes as `--set`. That program publishes
nothing it was not given here, and refuses a `.conda` whose bytes are not the
ones `mopm publish` would pack from this `.mojoc`.

THIS LIST IS THE PUBLISH LIST. It is the only place a package is added to the
publish. //release/ci:mopm_publish holds it to the packages of src/: every
directory there with a mopm.toml must be in this list and the reverse, so a
package moved to mopm and left out (or listed and moved back) is red on every
push to main (`checkSync`, release/ci/release_lib/mopm_publish.zig).

Nothing here runs buck2 or uploads: the targets are dependencies.
"""

def _impl(ctx):
    tree = {}
    for name, lib, conda in zip(ctx.attrs.names, ctx.attrs.libs, ctx.attrs.condas):
        mojoc = lib[DefaultInfo].default_outputs[0]
        file = conda[DefaultInfo].default_outputs[0]
        tree[name + "/" + name + ".mojoc"] = mojoc
        tree[name + "/" + file.basename] = file
    return [DefaultInfo(default_output = ctx.actions.copied_dir("mopm_set", tree))]

_mopm_set = rule(
    impl = _impl,
    attrs = {
        "condas": attrs.list(attrs.dep()),
        "libs": attrs.list(attrs.dep()),
        "names": attrs.list(attrs.string()),
    },
)

def mopm_set(name, packages, **kwargs):
    """See the module documentation. `packages` are directory names under src/."""
    if not packages:
        fail("{}: no package".format(name))
    _mopm_set(
        name = name,
        names = packages,
        libs = ["//src/{}:lib".format(p) for p in packages],
        condas = ["//src/{}:conda".format(p) for p in packages],
        **kwargs
    )
