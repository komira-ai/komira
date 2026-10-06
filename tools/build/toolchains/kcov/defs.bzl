"""kcov built from source on the farm, and the checks that gate it (README.md).

`kcov_dist` runs kcov_build.sh in one build action: it unpacks the pinned
kcov source archive and conda packages, builds the embedded helper libraries
and generated sources, and compiles and links kcov with the pinned zig. Its
output is a directory: `bin/kcov`, `lib/libgcc_s.so.1` (the one library it
loads besides glibc) and `share/licenses/`.

`kcov_check`, `kcov_check_cases` and `kcov_same` each run a mode of
kcov_check.sh in a build action and return a `ValidationInfo`. `kcov_tool` is
the distribution as other targets use it, with those checks as dependencies,
so no build that uses kcov succeeds unless they pass. The checks and the tool
take the distribution as an `exec_dep` with the same `exec_compatible_with`,
so the checked bytes and the handed-out bytes are one configured target.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _stage(ctx, name, files):
    # Sources are copied under buck-out first: a source's path in an action
    # differs between a standalone checkout and a repository that mounts
    # komira as a cell, and so would the action's digest.
    return ctx.actions.copied_dir(name, {f.short_path: f for f in files})

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _dist_impl(ctx):
    staged = _stage(ctx, "build_srcs", [ctx.attrs.script] + ctx.attrs.shim)
    out = ctx.actions.declare_output("kcov", dir = True)
    packages = [cmd_args(name, "=", _out(dep), delimiter = "") for name, dep in sorted(ctx.attrs.packages.items())]
    ctx.actions.run(
        cmd_args(
            _out(ctx.attrs._busybox),
            "sh",
            staged.project(ctx.attrs.script.short_path),
            _out(ctx.attrs._busybox),
            _out(ctx.attrs._zig),
            _out(ctx.attrs.conda_payload),
            _out(ctx.attrs.elf_rpath),
            _out(ctx.attrs.archive),
            ctx.attrs.strip_prefix,
            ctx.attrs.version,
            ctx.attrs.zig_triple,
            staged.project("shim"),
            out.as_output(),
            packages,
        ),
        category = "kcov_build",
    )
    return [DefaultInfo(default_output = out)]

_kcov_dist = rule(
    impl = _dist_impl,
    doc = "kcov built by kcov_build.sh from `archive` (unpacked under `strip_prefix`) against the static libraries of the conda `packages`; the output is a directory holding `bin/kcov`, `lib/libgcc_s.so.1` and `share/licenses/`.",
    attrs = {
        "archive": attrs.dep(doc = "The pinned kcov source archive."),
        "conda_payload": attrs.exec_dep(doc = "The tool that writes a .conda package's payload tar."),
        "elf_rpath": attrs.exec_dep(doc = "The tool that turns bin/kcov's DT_RUNPATH into a DT_RPATH."),
        "packages": attrs.dict(attrs.string(), attrs.dep(), doc = "name -> pinned .conda: elfutils, zlib, bzip2, zstd, lzma, libgcc."),
        "script": attrs.source(),
        "shim": attrs.list(attrs.source(), doc = "shim/: the curl functions kcov calls, without libcurl."),
        "strip_prefix": attrs.string(doc = "The archive's top directory."),
        "version": attrs.string(doc = "What `kcov --version` prints after `kcov `."),
        "zig_triple": attrs.string(doc = "The zig target of the link: the platform row's `zig_triple`."),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_zig": attrs.exec_dep(default = "komira//tools/build/toolchains:zig"),
    },
)

def _validate(ctx, mode, srcs, args):
    # Runs `kcov_check.sh <mode> <busybox> <zig_dir or -> <report_dir> args...`.
    # One output: buck2 refuses a validation result whose action produces
    # more than one. The result is copied out of the directory.
    staged = _stage(ctx, "check_srcs", [ctx.attrs.script] + srcs)
    report = ctx.actions.declare_output("report", dir = True)
    ctx.actions.run(
        cmd_args(
            _out(ctx.attrs._busybox),
            "sh",
            staged.project(ctx.attrs.script.short_path),
            mode,
            _out(ctx.attrs._busybox),
            _out(ctx.attrs._zig) if hasattr(ctx.attrs, "_zig") else "-",
            report.as_output(),
            [staged.project("fixtures") if a == "@FIXTURES@" else a for a in args],
        ),
        category = "kcov_" + mode,
        identifier = ctx.label.name,
    )
    result = ctx.actions.copy_file("validation.json", report.project("validation.json"))
    return [
        DefaultInfo(default_output = result, sub_targets = {"report": [DefaultInfo(default_output = report)]}),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

def _attrs(extra, zig = True):
    out = {
        "script": attrs.source(doc = "kcov_check.sh"),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    }
    if zig:
        out["_zig"] = attrs.exec_dep(default = "komira//tools/build/toolchains:zig")
    out.update(extra)
    return out

def _check_impl(ctx):
    return _validate(ctx, "check", ctx.attrs.fixtures, [
        _out(ctx.attrs.kcov),
        _out(ctx.attrs.archive),
        ctx.attrs.strip_prefix,
        "@FIXTURES@",
        ctx.attrs.version,
        ctx.attrs.zig_triple,
        ctx.attrs.glibc_floor_minor,
    ])

_kcov_check = rule(
    impl = _check_impl,
    doc = "Runs `kcov_check.sh check` against the `kcov` distribution: its files and licences, glibc floor, unwinder, loader closure under a decoy LD_LIBRARY_PATH, version, the golden Cobertura reports of the fixtures (kcov's defaults, and the coverage variant's --replace-src-path regex and full paths), the preload library, and the HTML report's data files. Fails the build on a wrong result; `[report]` holds the fixture's reports.",
    attrs = _attrs({
        "archive": attrs.dep(doc = "The kcov source archive: its data/ files are what the HTML report must write."),
        "fixtures": attrs.list(attrs.source(), doc = "fixtures/cov_fixture.c and its golden report."),
        "glibc_floor_minor": attrs.string(doc = "<n> of the floor GLIBC_2.<n>."),
        "kcov": attrs.exec_dep(),
        "strip_prefix": attrs.string(),
        "version": attrs.string(),
        "zig_triple": attrs.string(),
    }),
)

def _cases_impl(ctx):
    return _validate(ctx, "cases", ctx.attrs.fixtures, [
        _out(ctx.attrs.elf_rpath),
        _out(ctx.attrs.conda_payload),
        "@FIXTURES@",
        ctx.attrs.zig_triple,
        ctx.attrs.glibc_floor_minor,
    ])

_kcov_check_cases = rule(
    impl = _cases_impl,
    doc = "Runs `kcov_check.sh cases`: the glibc-floor and decoy checks, elf_rpath and conda_payload on inputs whose answer is known, wrong ones included. Fails the build on a wrong answer.",
    attrs = _attrs({
        "conda_payload": attrs.exec_dep(),
        "elf_rpath": attrs.exec_dep(),
        "fixtures": attrs.list(attrs.source()),
        "glibc_floor_minor": attrs.string(),
        "zig_triple": attrs.string(),
    }),
)

def _same_impl(ctx):
    return _validate(ctx, "same", [], [_out(ctx.attrs.a), _out(ctx.attrs.b)])

_kcov_same = rule(
    impl = _same_impl,
    doc = "Runs `kcov_check.sh same`: the directories `a` and `b`, two builds of one distribution, hold the same files with the same bytes. Fails the build otherwise.",
    attrs = _attrs({
        "a": attrs.exec_dep(),
        "b": attrs.exec_dep(),
    }, zig = False),
)

def _tool_impl(ctx):
    dist = _out(ctx.attrs.dist)
    return [DefaultInfo(default_output = dist, sub_targets = {"bin": [DefaultInfo(default_output = dist.project("bin/kcov"))]})]

_kcov_tool = rule(
    impl = _tool_impl,
    doc = "The kcov distribution `dist` (configured for the execution platform), gated by the validations in `checks`; `[bin]` is its `bin/kcov`.",
    attrs = {
        "checks": attrs.list(attrs.dep(providers = [ValidationInfo])),
        "dist": attrs.exec_dep(),
    },
)

kcov_dist = declares_docs(_kcov_dist)
kcov_check = declares_docs(_kcov_check)
kcov_check_cases = declares_docs(_kcov_check_cases)
kcov_same = declares_docs(_kcov_same)
kcov_tool = declares_docs(_kcov_tool)
