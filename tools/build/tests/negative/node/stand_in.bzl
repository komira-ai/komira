"""Stand-ins for the planted defects of test 54.

`stand_in_npm` provides NpmPackageInfo (loaded from komira, so the provider is
the one the rules require) over a checked-in file, at the name and version a
fixture gives it. Nothing reads the file: analysis refuses each fixture first.

`stand_in_archive` builds a `.tar.gz` whose one top directory holds the files
a fixture names: `files` are written with one line of text (mode 644),
`programs` are copies of the pinned busybox (mode 755), which, run under a
name that is none of its applets (`node`), fails with "applet not found".

`npm_repack` writes a built npm tarball again with one defect that the
package rule (npm_tarball) refuses to write: files left out (`drop`), files
added (`add`, {path: file}) or scripts in its package.json (`scripts`, {name:
command}), paths below the tarball's top directory. Its output has the
tarball's file name.
"""

load("@komira//tools/build/node:defs.bzl", "NpmPackageInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _impl(ctx):
    return [
        DefaultInfo(),
        NpmPackageInfo(
            name = ctx.attrs.package,
            version = ctx.attrs.version,
            closure = {ctx.attrs.package: (ctx.attrs.version, ctx.attrs.dir)},
        ),
    ]

stand_in_npm = rule(
    impl = _impl,
    attrs = {
        "dir": attrs.source(),
        "package": attrs.string(),
        "version": attrs.string(),
    },
)

def _archive_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".tar.gz")
    entries = ["file:" + f for f in ctx.attrs.files] + ["program:" + f for f in ctx.attrs.programs]
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    ctx.actions.run(cmd_args(ctx.attrs._act[RunInfo], "stand-in-archive", bb, out.as_output(), ctx.attrs.top, entries), category = "stand_in_archive")
    return [DefaultInfo(default_output = out)]

_stand_in_archive = rule(
    impl = _archive_impl,
    attrs = {
        "files": attrs.list(attrs.string(), default = []),
        "programs": attrs.list(attrs.string(), default = []),
        "top": attrs.string(),
        "_act": attrs.exec_dep(default = "tests//tools:tests_act", providers = [RunInfo]),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

def stand_in_archive(**kwargs):
    _stand_in_archive(exec_compatible_with = LINUX_X86_64, **kwargs)

def _repack_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + "/" + ctx.attrs.tarball.basename)
    edits = []
    for m in ctx.attrs.drop:
        edits += ["--drop", m]
    for path, f in sorted(ctx.attrs.add.items()):
        edits += ["--add", cmd_args(f, format = path + "={}")]
    for name, command in sorted(ctx.attrs.scripts.items()):
        edits += ["--script", "{}={}".format(name, command)]
    ctx.actions.run(cmd_args(ctx.attrs._act[RunInfo], "npm-repack", ctx.attrs.tarball, out.as_output(), edits), category = "npm_repack")
    return [DefaultInfo(default_output = out)]

_npm_repack = rule(
    impl = _repack_impl,
    attrs = {
        "add": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "drop": attrs.list(attrs.string(), default = []),
        "scripts": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "tarball": attrs.source(),
        "_act": attrs.exec_dep(default = "tests//tools:tests_act", providers = [RunInfo]),
    },
)

def npm_repack(**kwargs):
    _npm_repack(exec_compatible_with = LINUX_X86_64, **kwargs)
