"""`third_party_srcs`: the source lists of a vendored C library, generated
from its pinned release archive by :gen, and held to the committed copy.

    third_party_srcs(
        name = "srcs",
        library = "aws-lc",                 # or "s2n-tls"
        archive = ":aws-lc-1.39.0.tar.gz",  # a pinned_file
        committed = "srcs.bzl",             # the checked-in copy, in this package
    )

declares `:srcs_gen`, the generated file (regenerate the committed copy with
`./buck2 build //<package>:srcs_gen --out <package>/srcs.bzl`), and
`:srcs_drift`, a test that fails, naming the first differing lines, while the
committed copy and the archive disagree. Both run on the farm.

With `committed_files = "files.bzl"` it also declares the same pair for the
explicit file lists a `native_library` stages (`:srcs_files_gen`,
`:srcs_files_drift`) and `:srcs_files_check`, a test that reads the committed
copy and the archive independently of :gen: every file a list names is in the
archive, every list is within FILES, every include directory holds a file, and
each list named in `require` is there and not empty.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _gen_impl(ctx):
    gen = ctx.attrs._gen[MojoRunnableInfo]
    out = ctx.actions.declare_output("files.bzl" if ctx.attrs.library.endswith("-files") else "srcs.bzl")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._tool[RunInfo],
            "srcs-gen",
            "--archive",
            ctx.attrs.archive,
            "--out",
            out.as_output(),
            "--gen",
            gen.run_dir.project(gen.binary),
            "--library",
            ctx.attrs.library,
            "--gen-label",
            ctx.attrs.gen_label,
            "--drift-label",
            ctx.attrs.drift_label,
            "--committed-path",
            ctx.attrs.committed_path,
            hidden = gen.run_dir,
        ),
        category = "third_party_srcs",
    )
    return [DefaultInfo(default_output = out)]

_third_party_srcs_gen = rule(
    impl = _gen_impl,
    doc = "Runs :gen over a .tar.gz release archive. The three strings only fill in the generated file's header.",
    attrs = {
        "archive": attrs.source(),
        "committed_path": attrs.string(),
        "drift_label": attrs.string(),
        "gen_label": attrs.string(),
        "library": attrs.enum(["aws-lc", "s2n-tls", "aws-lc-files", "s2n-tls-files"]),
        "_gen": attrs.dep(default = "komira//tools/build/third_party_srcs:gen", providers = [MojoRunnableInfo]),
        "_tool": attrs.exec_dep(default = "komira//tools/build/third_party_srcs:third_party_act", providers = [RunInfo]),
    },
)

def _drift_impl(ctx):
    generated = ctx.attrs.generated[DefaultInfo].default_outputs[0]
    command = cmd_args(ctx.attrs._tool[RunInfo], "drift", "--generated", generated, "--committed", ctx.attrs.committed, "--regenerate", ctx.attrs.regenerate)
    return [
        DefaultInfo(default_output = generated),
        ExternalRunnerTestInfo(type = "custom", command = [command], labels = ctx.attrs.labels),
    ]

_third_party_srcs_drift_test = rule(
    impl = _drift_impl,
    doc = "Fails while `committed` differs from `generated`, naming the first differing lines.",
    attrs = {
        "committed": attrs.source(),
        "generated": attrs.dep(),
        "labels": attrs.list(attrs.string(), default = []),
        "regenerate": attrs.string(),
        "_tool": attrs.exec_dep(default = "komira//tools/build/third_party_srcs:third_party_act", providers = [RunInfo]),
    },
)

def _check_impl(ctx):
    command = cmd_args(
        ctx.attrs._tool[RunInfo],
        "files-check",
        "--archive",
        ctx.attrs.archive,
        "--files",
        ctx.attrs.committed,
        "--regenerate",
        ctx.attrs.regenerate,
    )
    for r in ctx.attrs.require:
        command.add("--require", r)
    return [
        DefaultInfo(),
        ExternalRunnerTestInfo(type = "custom", command = [command], labels = ctx.attrs.labels),
    ]

_third_party_files_check_test = rule(
    impl = _check_impl,
    doc = "Fails while the committed files.bzl names a file the archive lacks.",
    attrs = {
        "archive": attrs.source(),
        "committed": attrs.source(),
        "labels": attrs.list(attrs.string(), default = []),
        "regenerate": attrs.string(),
        "require": attrs.list(attrs.string(), default = []),
        "_tool": attrs.exec_dep(default = "komira//tools/build/third_party_srcs:third_party_act", providers = [RunInfo]),
    },
)

def third_party_srcs(name, library, archive, committed, committed_files = None, require = [], visibility = None):
    package = package_name()
    gen_label = "//{}:{}_gen".format(package, name)
    committed_path = "{}/{}".format(package, committed) if package else committed
    _third_party_srcs_gen(
        name = name + "_gen",
        exec_compatible_with = LINUX_X86_64,
        library = library,
        archive = archive,
        gen_label = gen_label,
        drift_label = "//{}:{}_drift".format(package, name),
        committed_path = committed_path,
        visibility = visibility,
    )
    _third_party_srcs_drift_test(
        name = name + "_drift",
        exec_compatible_with = LINUX_X86_64,
        generated = ":" + name + "_gen",
        committed = committed,
        regenerate = "./buck2 build {} --out {}".format(gen_label, committed_path),
    )
    if committed_files:
        files_gen_label = "//{}:{}_files_gen".format(package, name)
        files_path = "{}/{}".format(package, committed_files) if package else committed_files
        _third_party_srcs_gen(
            name = name + "_files_gen",
            exec_compatible_with = LINUX_X86_64,
            library = library + "-files",
            archive = archive,
            gen_label = files_gen_label,
            drift_label = "//{}:{}_files_drift".format(package, name),
            committed_path = files_path,
            visibility = visibility,
        )
        _third_party_srcs_drift_test(
            name = name + "_files_drift",
            exec_compatible_with = LINUX_X86_64,
            generated = ":" + name + "_files_gen",
            committed = committed_files,
            regenerate = "./buck2 build {} --out {}".format(files_gen_label, files_path),
        )
        _third_party_files_check_test(
            name = name + "_files_check",
            exec_compatible_with = LINUX_X86_64,
            archive = archive,
            committed = committed_files,
            require = require,
            regenerate = "./buck2 build {} --out {}".format(files_gen_label, files_path),
        )

def _fixture_archive_impl(ctx):
    prefix = ctx.attrs.strip_prefix + "/"
    files = {}
    for f in ctx.attrs.srcs:
        if not f.short_path.startswith(prefix):
            fail("fixture_archive {}: {} is not under {}".format(ctx.label, f.short_path, ctx.attrs.strip_prefix))
        files[f.short_path.removeprefix(prefix)] = f
    tree = ctx.actions.copied_dir("tree", files)
    out = ctx.actions.declare_output(ctx.attrs.top + ".tar.gz")
    ctx.actions.run(
        cmd_args(ctx.attrs._pack[RunInfo], "tar", "--bundle", tree, "--prefix", ctx.attrs.top + "/", "--out", out.as_output()),
        category = "fixture_archive",
    )
    return [DefaultInfo(default_output = out)]

# A .tar.gz of `srcs` (package-relative paths, `strip_prefix` removed) under
# one top directory `top`: a made-up release archive, written by `komira_pack
# tar` (sorted, owner 0, time 0, every file its own bytes). A hard link is not
# a regular file to :gen (nor to tarfile), and `tar` of a tree whose files the
# worker's materializer linked stores the later ones as hard links.
_fixture_archive = rule(
    impl = _fixture_archive_impl,
    attrs = {
        "srcs": attrs.list(attrs.source()),
        "strip_prefix": attrs.string(),
        "top": attrs.string(),
        "_pack": attrs.exec_dep(default = "komira//tools/build/package:komira_pack", providers = [RunInfo]),
    },
)

def fixture_archive(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _fixture_archive(**kwargs)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
fixture_archive = declares_docs(fixture_archive)
third_party_srcs = declares_docs(third_party_srcs)
