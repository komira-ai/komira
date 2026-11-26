"""The rule that assembles the Python package's changelog (python/BUCK, `:changelog`).

`changelog_file(name, changelog, fragments, readme)` stages `changelog` (python/CHANGELOG.md) and `fragments`
(the files of python/changelog.d) as one tree and runs the changelog tool (python/changelog/src/cli.zig) over it
as a build action. The default output is the changelog with the new section of the build: `## 0.1.<n>` for a
build stamped with `-c komira.package_stamp=<n>` (the stamp the wheel reads), `## Unreleased` for an unstamped
one. The sub-target `[description]` is `readme` followed by that changelog with its headings one level down,
the text of the wheel's page; `[sources]` is the staged tree, which does not depend on the stamp, for a test
that reads the files themselves. The action fails, naming the file and the line, on a fragment or a changelog
the tool refuses, so building the target is checking the entries.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _changelog_file_impl(ctx):
    package = ctx.label.package + "/" if ctx.label.package else ""
    files = {"CHANGELOG.md": ctx.attrs.changelog}
    for f in ctx.attrs.fragments:
        files[f.short_path] = f
    tree = ctx.actions.copied_dir("tree", files)
    tool = ctx.attrs._tool[RunInfo]

    def run(command, out, extra):
        ctx.actions.run(
            cmd_args(tool, command, "--root", tree, "--prefix", package, "--stamp", ctx.attrs.stamp, extra, "--out", out.as_output()),
            category = "changelog_" + command,
        )

    assembled = ctx.actions.declare_output("CHANGELOG.md")
    run("assemble", assembled, [])
    subs = {"sources": [DefaultInfo(default_output = tree)]}
    if ctx.attrs.readme != None:
        description = ctx.actions.declare_output("description.md")
        run("description", description, ["--readme", ctx.attrs.readme])
        subs["description"] = [DefaultInfo(default_output = description)]
    return [DefaultInfo(default_output = assembled, sub_targets = subs)]

_changelog_file = rule(
    impl = _changelog_file_impl,
    attrs = {
        "changelog": attrs.source(),
        "fragments": attrs.list(attrs.source(), default = []),
        "readme": attrs.option(attrs.source(), default = None),
        # The stamp (-c komira.package_stamp), set by the macro.
        "stamp": attrs.string(),
        "_tool": attrs.exec_dep(default = "komira//python/changelog:changelog", providers = [RunInfo]),
    },
)

def _changelog_file_macro(**kwargs):
    # The stamp is read here, in the macro, so it keys only this target, as the wheel's does.
    _changelog_file(
        stamp = read_config("komira", "package_stamp", "0"),
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )

changelog_file = declares_docs(_changelog_file_macro)
