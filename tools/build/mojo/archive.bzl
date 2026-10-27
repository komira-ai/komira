"""`archive_files`: named files out of a sha256-pinned source archive.

A remote action unpacks the archive (tools/archive_files.zig) and copies out
exactly the files listed in `files` (and `templates`); each becomes its own
output and a sub-target named by its path, so a `cxx_library` can name
`:<target>[snappy.cc]` as a source. A listed file missing from the archive
fails the action.

With `one_tree`, the files are one directory output instead, and each
sub-target is a projection of it (see the attribute).

`templates` maps an output path to a file in the archive; every key of
`substitutions` is replaced, literally, by its value in each template (the
configure step of a CMake `configure_file`, without CMake).
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _archive_files_impl(ctx):
    archive = ctx.attrs.archive[DefaultInfo].default_outputs[0]
    lines = []
    for k, v in sorted(ctx.attrs.substitutions.items()):
        if not k or "\t" in k or "\n" in k or "\t" in v or "\n" in v:
            fail("{}: a substitution key is not empty and neither it nor its value holds a tab or a newline: {}".format(ctx.label, repr(k)))
        lines.append("{}\t{}".format(k, v))
    subst = ctx.actions.write("substitutions.tsv", "\n".join(lines) + "\n")
    args = []
    sub_targets = {}
    outs = []
    tree = None
    if ctx.attrs.one_tree:
        tree = ctx.actions.declare_output("files", dir = True)
        args.extend(["--tree", tree.as_output()])
        outs.append(tree)
        for d in ctx.attrs.tree_dirs:
            sub_targets[d] = [DefaultInfo(default_output = tree.project(d))]
    elif ctx.attrs.tree_dirs:
        fail("{}: tree_dirs needs one_tree = True".format(ctx.label))
    for kind, pairs in [("file", [(f, f) for f in ctx.attrs.files]), ("template", sorted(ctx.attrs.templates.items()))]:
        for name, rel in pairs:
            if name in sub_targets:
                fail("{}: {} is listed twice".format(ctx.label, name))
            if tree:
                args.extend([kind, rel, name])
                sub_targets[name] = [DefaultInfo(default_output = tree.project(name))]
            else:
                out = ctx.actions.declare_output("files/" + name)
                args.extend([kind, rel, out.as_output()])
                sub_targets[name] = [DefaultInfo(default_output = out)]
                outs.append(out)
    ctx.actions.run(
        # tools/build/mojo/tools/archive_files.zig: extracts, copies, substitutes. No shell.
        cmd_args(ctx.attrs._tool[RunInfo], archive, ctx.attrs.strip_prefix, subst, args),
        category = "archive_files",
    )
    return [DefaultInfo(default_outputs = outs, sub_targets = sub_targets)]

archive_files_rule = rule(
    impl = _archive_files_impl,
    attrs = {
        # A pinned_file holding the archive; its name must end in the format.
        "archive": attrs.dep(),
        "files": attrs.list(attrs.string(), default = []),
        # One output, a directory holding every file at its path in the
        # archive (each file's sub-target is a projection of it), so that a
        # source finds what it includes by relative path ("../internal.h").
        # Separate outputs may each get a content-based path of their own.
        "one_tree": attrs.bool(default = False),
        "strip_prefix": attrs.string(default = ""),
        "substitutions": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "templates": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # With one_tree: directories of the tree that are sub-targets of their
        # own, for an -I flag ($(location :<target>[include])).
        "tree_dirs": attrs.list(attrs.string(), default = []),
        "_tool": attrs.exec_dep(default = "komira//tools/build/mojo:archive_files"),
    },
)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
archive_files = declares_docs(archive_files_rule)
