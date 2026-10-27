"""googleapis .proto files, checked by protoc to be exactly an import closure.

    proto_check(
        name = "logging_v2",
        roots = ["google/logging/v2/logging.proto"],
        srcs = [":googleapis[google/logging/v2/logging.proto]", ...],
        strip_prefix = "files",
    )

The files are not committed: `srcs` are files extracted at build time from
the googleapis archive at one pinned commit (BUCK: a `pinned_file`, whose
sha256 buck2 checks on download, and an `archive_files`). `proto_check`
stages `srcs` at their import paths (less `strip_prefix`) and runs
`proto_check check` (proto_check.zig) over them, one action on a light
worker: protoc (`toolchains//:mojo_proto`, the protoc every
mojo_proto_library runs) must parse the roots with nothing on its path but
the tree and its own well-known types, writing a descriptor set
(--include_imports) whose files are exactly the tree's. So a file the closure
needs and the tree lacks fails here (as after a bump that adds an import),
and so does a listed file nothing imports.

The default output is that descriptor set; `[tree]` is the checked copy of
the tree, written only when every check passes. `ProtoSrcsInfo` carries that
copy, so a mojo_proto_library may take the target as a `proto_deps` entry and
read only checked files.

`proto_check_case` runs the same check over a fixture and asserts its verdict:
accepted when `expect` is empty, otherwise refused with a message holding
`expect`. BUCK holds the cases over testdata/; every proto_check target
depends on them, so a check that stops refusing fails the build of every
checked tree, not only of its own test.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:proto.bzl", "MojoProtoToolchainInfo", "ProtoSrcsInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")

# Checking runs on the one Linux execution platform: it parses a few files and compiles nothing.
_LINUX = LINUX_X86_64

def _stage(ctx):
    """`srcs` staged at their import paths: (directory, import paths)."""
    prefix = ctx.attrs.strip_prefix.strip("/")
    staged = {}
    for s in ctx.attrs.srcs:
        path = s.short_path
        if prefix:
            if not path.startswith(prefix + "/"):
                fail("proto_check {}: {} is not under strip_prefix {}".format(ctx.label.name, path, prefix))
            path = path[len(prefix) + 1:]
        staged[path] = s
    return ctx.actions.copied_dir(ctx.attrs.name + ".srcs", staged), sorted(staged.keys())

def _check_args(ctx):
    """The import paths, and proto_check's arguments up to the outputs: protoc and the staged tree."""
    tc = ctx.attrs._proto_toolchain[MojoProtoToolchainInfo]
    tree, paths = _stage(ctx)
    return paths, cmd_args(tc.protoc, tree)

def _proto_check_impl(ctx):
    out_set = ctx.actions.declare_output(ctx.attrs.name + ".descriptor_set.pb")
    out_tree = ctx.actions.declare_output(ctx.attrs.name + ".tree", dir = True)
    paths, args = _check_args(ctx)
    ctx.actions.run(
        cmd_args(
            ctx.attrs._tool[RunInfo],
            "check",
            args,
            out_set.as_output(),
            out_tree.as_output(),
            ctx.attrs.roots,
            # The self-test's verdicts: the check runs only once it has
            # refused every bad fixture (BUCK, proto_check_selftest).
            hidden = [d[DefaultInfo].default_outputs for d in ctx.attrs._selftest],
        ),
        category = "proto_check",
        identifier = ctx.attrs.name,
    )
    return [
        DefaultInfo(default_output = out_set, sub_targets = {"tree": [DefaultInfo(default_output = out_tree)]}),
        ProtoSrcsInfo(trees = [out_tree], import_paths = paths),
    ]

_COMMON = {
    "roots": attrs.list(attrs.string()),
    "srcs": attrs.list(attrs.source()),
    "strip_prefix": attrs.string(default = ""),
    "_proto_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_proto", providers = [MojoProtoToolchainInfo]),
    "_tool": attrs.exec_dep(default = "komira//tools/vendor/googleapis:proto_check_bin", providers = [RunInfo]),
    # A validation: the lint of upstream_version.sh.
    "_script_lint": attrs.list(attrs.dep(), default = ["komira//tools/vendor/googleapis:shell_lint"]),
}

_proto_check = rule(
    impl = _proto_check_impl,
    doc = ".proto files (`srcs`, staged at their import paths less `strip_prefix`), refused unless they are exactly the import closure protoc parses for `roots`. The default output is the descriptor set; `[tree]` is the checked copy, which ProtoSrcsInfo carries.",
    attrs = _COMMON | {
        "_selftest": attrs.list(attrs.dep(), default = ["komira//tools/vendor/googleapis:proto_check_selftest"]),
    },
)

def _proto_check_case_impl(ctx):
    report = ctx.actions.declare_output(ctx.attrs.name + ".verdict.txt")
    _, args = _check_args(ctx)
    ctx.actions.run(
        cmd_args(ctx.attrs._tool[RunInfo], "case", ctx.attrs.expect, report.as_output(), args, ctx.attrs.roots),
        env = rerun_env(ctx),
        category = "proto_check_case",
        identifier = ctx.attrs.name,
    )
    return [DefaultInfo(default_output = report), rerun_info(ctx)]

_proto_check_case = rule(
    impl = _proto_check_case_impl,
    doc = "The proto_check check over a fixture, with its verdict asserted: accepted when `expect` is empty, otherwise refused with a message holding `expect`.",
    attrs = _COMMON | {
        "expect": attrs.string(default = ""),
    } | RERUN_ATTRS,
)

def proto_check(**kwargs):
    _proto_check(exec_compatible_with = _LINUX, **kwargs)

def proto_check_case(**kwargs):
    _proto_check_case(exec_compatible_with = _LINUX, **kwargs)

proto_check = declares_docs(proto_check)
proto_check_case = declares_docs(proto_check_case)
