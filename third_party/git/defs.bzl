"""git built from source on the farm, and the checks that gate it (README.md).

`git_build` runs one mode of git_build.sh in one build action:
  - `deps`: GNU make, zlib and an HTTP-only libcurl, built with the pinned zig
    from their pinned source archives. The output is a directory: `bin/make`,
    `lib/libz.a`, `lib/libcurl.a`, their headers under `include/`, and the
    licences of zlib and curl under `share/licenses/`.
  - `git`: git built with that make against those libraries. The output is a
    directory: `bin/git`, `libexec/git-core/`, `share/git-core/templates/` and
    `share/licenses/`.

`git_check` runs git_check.sh against the built git and the pinned git-lfs in
a build action and returns a `ValidationInfo`. `git_tool` is the distribution
as other targets use it, with the checks as dependencies, so no build that uses
the git oracle succeeds unless they pass. The check and the tool take the
distribution as an `exec_dep` with the same `exec_compatible_with`, so the
checked bytes and the handed-out bytes are one configured target.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _stage(ctx, name, files):
    # Sources are copied under buck-out first: a source's path in an action
    # differs between a standalone checkout and a repository that mounts
    # komira as a cell, and so would the action's digest.
    return ctx.actions.copied_dir(name, {f.short_path: f for f in files})

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _build_impl(ctx):
    staged = _stage(ctx, "build_srcs", [ctx.attrs.script])
    out = ctx.actions.declare_output(ctx.attrs.mode, dir = True)
    inputs = [cmd_args(name, "=", _out(dep), delimiter = "") for name, dep in sorted(ctx.attrs.inputs.items())]
    ctx.actions.run(
        cmd_args(
            _out(ctx.attrs._busybox),
            "sh",
            staged.project(ctx.attrs.script.short_path),
            ctx.attrs.mode,
            _out(ctx.attrs._busybox),
            _out(ctx.attrs._zig),
            ctx.attrs.zig_triple,
            out.as_output(),
            inputs,
        ),
        category = "git_build_" + ctx.attrs.mode,
    )
    return [DefaultInfo(default_output = out)]

_git_build = rule(
    impl = _build_impl,
    doc = "One mode of git_build.sh: `deps` (GNU make, zlib and an HTTP-only libcurl from their pinned archives) or `git` (git against `deps`). The output is a directory.",
    attrs = {
        "inputs": attrs.dict(attrs.string(), attrs.exec_dep(), doc = "name -> input. deps: make, zlib, curl (source archives). git: git (source archive), deps (the `deps` directory)."),
        "mode": attrs.enum(["deps", "git"]),
        "script": attrs.source(doc = "git_build.sh"),
        "zig_triple": attrs.string(doc = "The zig target of every compile and link: the platform row's `zig_triple`."),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_zig": attrs.exec_dep(default = "komira//tools/build/toolchains:zig"),
    },
)

def _check_impl(ctx):
    # One output: buck2 refuses a validation result whose action produces
    # more than one. The result is copied out of the report directory.
    staged = _stage(ctx, "check_srcs", [ctx.attrs.script])
    report = ctx.actions.declare_output("report", dir = True)
    ctx.actions.run(
        cmd_args(
            _out(ctx.attrs._busybox),
            "sh",
            staged.project(ctx.attrs.script.short_path),
            _out(ctx.attrs._busybox),
            report.as_output(),
            _out(ctx.attrs.git),
            _out(ctx.attrs.git_lfs),
            ctx.attrs.version,
            ctx.attrs.lfs_version,
            ctx.attrs.glibc_floor_minor,
        ),
        category = "git_check",
        identifier = ctx.label.name,
    )
    result = ctx.actions.copy_file("validation.json", report.project("validation.json"))
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

_git_check = rule(
    impl = _check_impl,
    doc = "Runs git_check.sh against the `git` distribution and the `git_lfs` binary: files and licences, version, glibc floor, loader closure, no host git (decoys on PATH), object ids against sha1sum, clone and push over the pack protocol, the HTTP transport, and git-lfs. Fails the build on a wrong result.",
    attrs = {
        "git": attrs.exec_dep(doc = "The `git` mode output of git_build."),
        "git_lfs": attrs.exec_dep(doc = "The pinned git-lfs binary."),
        "glibc_floor_minor": attrs.string(doc = "<n> of the floor GLIBC_2.<n>."),
        "lfs_version": attrs.string(doc = "What `git-lfs version` prints after `git-lfs/`, up to the space."),
        "script": attrs.source(doc = "git_check.sh"),
        "version": attrs.string(doc = "What `git --version` prints after `git version `."),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

def _tool_impl(ctx):
    dist = _out(ctx.attrs.dist)
    return [DefaultInfo(default_output = dist, sub_targets = {"bin": [DefaultInfo(default_output = dist.project("bin/git"))]})]

_git_tool = rule(
    impl = _tool_impl,
    doc = "The git distribution `dist` (configured for the execution platform), gated by the validations in `checks`; `[bin]` is its `bin/git`.",
    attrs = {
        "checks": attrs.list(attrs.dep(providers = [ValidationInfo])),
        "dist": attrs.exec_dep(),
    },
)

git_build = declares_docs(_git_build)
git_check = declares_docs(_git_check)
git_tool = declares_docs(_git_tool)
