"""Golden checks of protoc-gen-mojo, as build actions.

`proto_codegen_golden` runs protoc with the toolchain's protoc-gen-mojo (or
protoc-gen-mojo-db, `plugin = "mojo-db"`) over a
`.proto` corpus with one option string (searching `import_roots`, such as the
pinned googleapis protos, after the corpus), then checks the result in a
second action whose output is the target's default output, so `buck2 build`
of the target IS the check:

  * with `golden`: protoc succeeded and the generated files are exactly the
    golden files (`<name>.mojo.golden` holds `<name>.mojo`), byte for byte;
  * with `expect_error`: protoc failed, its stderr holds that text, and the
    plugin wrote nothing;
  * no generated file holds a string of `absent`, and some generated file
    holds each string of `present` (which keeps an absence check from
    passing over an empty output).

With `service_config`, that file is passed to the plugin as its
`service_config` option, after `options`.

`proto_codegen_rest_helpers` cuts the REST URL helpers block out of one
generated file, for a mojo_library whose welded test runs them.

A generated file over the plugin's line limit is written as a facade and its
parts in `_parts/` (komira_proto_codegen's `split`); a golden of a part lies in
a directory named `_parts`. No generated `.mojo` file may reach 1000 lines,
golden or not: the check refuses it.

The `out` sub-target is the generated directory itself, checked or not:
`buck2 build '<target>[out]' --out <dir>` is how a golden is (re)written.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:proto.bzl", "MojoProtoToolchainInfo")

def _rel(ctx, src, under):
    """`src`'s path below `under/` of this package."""
    p = src.short_path
    pkg = ctx.label.package + "/"
    if p.startswith(pkg):
        p = p[len(pkg):]
    if not p.startswith(under + "/"):
        fail("{}: `{}` is not under {}/".format(ctx.label, src.short_path, under))
    return p[len(under) + 1:]

def _proto_codegen_golden_impl(ctx):
    ptc = ctx.attrs._proto_toolchain[MojoProtoToolchainInfo]
    if ctx.attrs.golden and ctx.attrs.expect_error:
        fail("{}: state `golden` or `expect_error`, not both".format(ctx.label))
    corpus = ctx.actions.copied_dir(
        "corpus",
        {_rel(ctx, s, "corpus"): s for s in ctx.attrs.srcs},
    )
    if ctx.attrs.plugin == "mojo":
        plugin = ptc.plugin
    elif ctx.attrs.plugin == "mojo-db":
        plugin = ptc.db_plugin
    else:
        fail("{}: `plugin` is `mojo` or `mojo-db`, not `{}`".format(ctx.label, ctx.attrs.plugin))
    gen = ctx.actions.declare_output("gen", dir = True)
    options = ctx.attrs.options
    if ctx.attrs.service_config:
        options = cmd_args(options, ",service_config=", ctx.attrs.service_config, delimiter = "")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._act[RunInfo],
            "proto-gen",
            ptc.protoc,
            plugin,
            corpus,
            gen.as_output(),
            options,
            str(len(ctx.attrs.import_roots)),
            ctx.attrs.import_roots,
            ctx.attrs.generate,
        ),
        category = "proto_codegen_gen",
    )

    golden_dir = ""
    if not ctx.attrs.expect_error:
        # No golden file is an empty golden directory: the diff then names
        # every generated file.
        mapping = {}
        for g in ctx.attrs.golden:
            name = g.basename
            if not name.endswith(".golden"):
                fail("{}: golden file `{}` is not `<generated name>.golden`".format(ctx.label, g.short_path))

            # A part of a split module is generated in `_parts/`, and its
            # golden is a file of a directory of that name.
            dirs = g.short_path.split("/")
            if len(dirs) >= 2 and dirs[-2] == "_parts":
                name = "_parts/" + name
            mapping[name[:-len(".golden")]] = g
        golden_dir = ctx.actions.copied_dir("golden", mapping)

    mark = ctx.actions.declare_output("checked")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._act[RunInfo],
            "proto-check",
            gen,
            golden_dir,
            ctx.attrs.expect_error,
            mark.as_output(),
            str(len(ctx.attrs.absent)),
            ctx.attrs.absent,
            ctx.attrs.present,
        ),
        category = "proto_codegen_check",
    )
    return [DefaultInfo(
        default_output = mark,
        sub_targets = {"out": [DefaultInfo(default_output = gen)]},
    )]

proto_codegen_golden_rule = rule(
    impl = _proto_codegen_golden_impl,
    attrs = {
        "absent": attrs.list(attrs.string(), default = []),
        "expect_error": attrs.string(default = ""),
        # Import paths (below corpus/) to generate.
        "generate": attrs.list(attrs.string()),
        "golden": attrs.list(attrs.source(), default = []),
        # Directories protoc searches after the corpus, in order, each holding
        # .proto files at their import paths: the pinned googleapis protos a
        # REST fixture imports (//tools/vendor/googleapis:api_client[tree]).
        "import_roots": attrs.list(attrs.source(allow_directory = True), default = []),
        # The `--mojo_opt` string, as the Mojo proto rules pass it.
        "options": attrs.string(),
        # The plugin run: protoc-gen-mojo (`mojo`) or protoc-gen-mojo-db
        # (`mojo-db`), both from the proto toolchain.
        "plugin": attrs.string(default = "mojo"),
        "present": attrs.list(attrs.string(), default = []),
        # A service configuration YAML, passed as the `service_config` option.
        "service_config": attrs.option(attrs.source(), default = None),
        # The corpus, every file under corpus/ at its import path.
        "srcs": attrs.list(attrs.source()),
        "_act": attrs.exec_dep(default = "tests//tools:tests_act", providers = [RunInfo]),
        "_proto_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_proto", providers = [MojoProtoToolchainInfo]),
    },
)

def _all_impl(ctx):
    return [DefaultInfo(default_outputs = [d[DefaultInfo].default_outputs[0] for d in ctx.attrs.checks])]

# Every check of the package, by one name.
proto_codegen_goldens_rule = rule(
    impl = _all_impl,
    attrs = {"checks": attrs.list(attrs.dep())},
)

# Exported wrapped, so a BUCK file using them declares its doc_tree: the
# tests cell's doc_tree reads every subpackage's.
proto_codegen_golden = declares_docs(proto_codegen_golden_rule)
proto_codegen_goldens = declares_docs(proto_codegen_goldens_rule)

# ---- the emitted URL helpers, as Mojo the check below compiles ---------------

def _extract_impl(ctx):
    out = ctx.actions.declare_output(ctx.attrs.out)
    src = ctx.attrs.gen.project(ctx.attrs.file)
    ctx.actions.run(
        cmd_args(ctx.attrs._act[RunInfo], "rest-extract", src, out.as_output()),
        category = "proto_codegen_extract",
    )
    return [DefaultInfo(default_output = out)]

# The URL helpers block of one generated file (`file`, inside the `[out]`
# directory `gen`, so `files/<name>.mojo`), written to `out`: the source a
# mojo_library compiles so its welded test can run the helpers the plugin
# emits.
proto_codegen_rest_helpers_rule = rule(
    impl = _extract_impl,
    attrs = {
        "file": attrs.string(),
        "gen": attrs.source(),
        "out": attrs.string(),
        "_act": attrs.exec_dep(default = "tests//tools:tests_act", providers = [RunInfo]),
    },
)

proto_codegen_rest_helpers = declares_docs(proto_codegen_rest_helpers_rule)
