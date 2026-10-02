"""mojo_proto_library: Mojo generated from `.proto` files, compiled to a `.mojoc`.

`mojo_proto_library(name, srcs, deps, proto_deps, ...)` runs protoc with the
protoc-gen-mojo plugin, writing one `<stem>.mojo` per `.proto` plus an
`__init__.mojo` into gen/<import_name>/, and precompiles that directory like
a mojo_library: other Mojo targets name it in `deps`, and it provides the
same MojoInfo.

  * The generated code imports its runtime (for example `komira_serde`), a
    Mojo library like any other: list it in `deps`.
  * A `.proto` is found by protoc at its import path, `import_prefix`
    joined with its path in the package. Each library's `.proto` files are
    staged at their import paths in one directory; every directory of the
    `proto_deps` closure, and protoc's well-known types, is a `--proto_path`.
  * The generated package is flat, and the plugin writes a reference to a
    message of another `.proto` as `<package_name>.<stem>`: that file's
    module must be in the same package. So an imported file whose messages
    are used is either listed in `srcs`, or brought in with
    `bundle_proto_deps = True`, which generates the whole `proto_deps`
    closure into this package too. Without it, `proto_deps` only let protoc
    resolve the imports (options, for example).

Output layout of a target `L` with import name `I`:

    L/proto/...            the staged `.proto` files (sub-target `[proto]`)
    L/gen/I/...            the generated package (sub-target per file name)
    L/pkg/I.mojoc          the precompiled package

The generation half (`stage_proto_srcs`, `proto_closure`, `select_generated`,
`generate_proto_dir`) is public, for rules that compile the generated files
themselves through `mojo_library` (gcp_client, tools/build/cloud/gcp.bzl).

protoc and the plugin come from `toolchains//:mojo_proto`. Options reach
the plugin as `--mojo_opt` arguments, never from a file, so they are part of
the action key.
"""

load(":providers.bzl", "MojoInfo", "MojoPkgTSet", "MojoToolchainInfo")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

MojoProtoToolchainInfo = provider(fields = {
    "busybox": provider_field(typing.Any),
    # Directory: bin/protoc and include/ (the well-known types).
    "protoc": provider_field(typing.Any),
    # The protoc-gen-mojo executable.
    "plugin": provider_field(typing.Any),
    # The protoc-gen-mojo-db executable (mojo_db_proto_library).
    "db_plugin": provider_field(typing.Any),
})

# What a mojo_proto_library gives the libraries that import from it. Lists,
# not transitive sets: a transitive set's type is per loading cell.
ProtoSrcsInfo = provider(fields = {
    # Staged `.proto` directories of this library and its proto_deps closure.
    "trees": provider_field(list),
    # Import paths of the `.proto` files of this library and its closure.
    "import_paths": provider_field(list),
})

_PRELUDE = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
# Private scratch. A remote action has its working directory to itself; a
# local one runs in the checkout root next to every other local action, so
# it takes the per-action scratch directory buck2 names in BUCK_SCRATCH_PATH.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
"""

def _busybox_sh(busybox, script, *args):
    return cmd_args(busybox, "sh", "-euc", _PRELUDE + script, "sh", busybox, *args)

# ---- toolchain ---------------------------------------------------------------

def _protoc_dist_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("protoc", dir = True)
    script = """
mkdir -p "$2"
unzip -q "$1" -d "$2"
chmod 0755 "$2/bin/protoc"
test -s "$2/include/google/protobuf/descriptor.proto"
rm -rf "$T"
"""
    ctx.actions.run(
        _busybox_sh(bb, script, ctx.attrs.archive[DefaultInfo].default_outputs[0], out.as_output()),
        category = "protoc_unpack",
    )
    return [DefaultInfo(default_output = out)]

protoc_dist_rule = rule(
    impl = _protoc_dist_impl,
    attrs = {
        "archive": attrs.dep(),
        "busybox": attrs.dep(),
    },
)

def _mojo_proto_toolchain_impl(ctx):
    return [
        DefaultInfo(),
        MojoProtoToolchainInfo(
            busybox = ctx.attrs.busybox[DefaultInfo].default_outputs[0],
            protoc = ctx.attrs.protoc[DefaultInfo].default_outputs[0],
            plugin = ctx.attrs.plugin[DefaultInfo].default_outputs[0],
            db_plugin = ctx.attrs.db_plugin[DefaultInfo].default_outputs[0],
        ),
    ]

mojo_proto_toolchain = rule(
    impl = _mojo_proto_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "busybox": attrs.exec_dep(),
        "db_plugin": attrs.exec_dep(),
        "plugin": attrs.exec_dep(),
        "protoc": attrs.exec_dep(),
    },
)

# ---- .proto sources ------------------------------------------------------------

def stage_proto_srcs(ctx):
    """Stage `srcs` at their import paths: (directory, import paths)."""
    prefix = ctx.attrs.import_prefix.strip("/")
    staged = {}
    own_paths = []
    for s in ctx.attrs.srcs:
        path = s.short_path if not prefix else prefix + "/" + s.short_path
        staged[path] = s
        own_paths.append(path)
    return ctx.actions.copied_dir("proto", staged), own_paths

def proto_closure(ctx, tree, own_paths):
    """The staged directories of this target and its proto_deps closure, and the closure's import paths."""
    trees = [tree]
    dep_paths = []
    seen = {}
    for d in ctx.attrs.proto_deps:
        info = d[ProtoSrcsInfo]
        for t in info.trees:
            if t not in seen:
                seen[t] = True
                trees.append(t)
        for p in info.import_paths:
            if p not in seen and p not in own_paths:
                seen[p] = True
                dep_paths.append(p)
    return trees, dep_paths

def _proto_srcs_impl(ctx):
    tree, own_paths = stage_proto_srcs(ctx)
    trees, dep_paths = proto_closure(ctx, tree, own_paths)
    return [
        DefaultInfo(default_output = tree),
        ProtoSrcsInfo(trees = trees, import_paths = own_paths + dep_paths),
    ]

# `.proto` files that other `.proto` files import but no Mojo is generated
# from, for example a file declaring custom options: a `proto_deps` entry
# of the proto rules.
proto_srcs_rule = rule(
    impl = _proto_srcs_impl,
    attrs = {
        "import_prefix": attrs.string(default = ""),
        "proto_deps": attrs.list(attrs.dep(providers = [ProtoSrcsInfo]), default = []),
        "srcs": attrs.list(attrs.source()),
    },
)

# ---- generation and precompile, shared by the two library rules ------------------

_GEN_SCRIPT = """
# $1 protoc dir, $2 plugin, $3 plugin name (the NAME of --NAME_out), $4
# output package directory, $5 plugin options; $6 number of --proto_path
# dirs, then those dirs; then the number of expected files, then their
# names; then the import paths to generate code for.
PROTOC="$1"; PLUGIN="$2"; NAME="$3"; OUT="$4"; OPT="$5"; N="$6"; shift 6
case "$PLUGIN" in /*) ;; *) PLUGIN="$PWD/$PLUGIN" ;; esac
mkdir -p "$OUT" "$T/tmp"
PATHS=""
while [ "$N" -gt 0 ]; do
    PATHS="$PATHS --proto_path=$1"
    shift; N=$((N - 1))
done
N="$1"; shift
EXPECTED=""
while [ "$N" -gt 0 ]; do
    EXPECTED="$EXPECTED $1"
    shift; N=$((N - 1))
done
TMPDIR="$T/tmp"; HOME="$T"; export TMPDIR HOME
# protoc looks the plugin up as protoc-gen-NAME. It hands the plugin the
# descriptors of the whole import closure, custom options included, so no
# descriptor-set flag is needed (protoc refuses --include_imports here).
# shellcheck disable=SC2086
"$PROTOC/bin/protoc" $PATHS "--proto_path=$PROTOC/include" \\
    "--plugin=protoc-gen-$NAME=$PLUGIN" "--${NAME}_out=$OUT" "--${NAME}_opt=$OPT" "$@"
printf '%s\\n' '# Generated by the Mojo proto rules: the package of the modules generated' \\
    '# from this target'"'"'s .proto files. Do not edit.' > "$OUT/__init__.mojo"
# Exactly the expected files, none empty: an empty module is a silent
# plugin failure, and an unexpected one would not be compiled.
n=1
for f in $EXPECTED; do
    if [ ! -s "$OUT/$f" ]; then
        echo "protoc-gen-$NAME wrote no code (or an empty file) for the expected $f" >&2
        exit 1
    fi
    n=$((n + 1))
done
if [ "$(ls -A "$OUT" | wc -l)" != "$n" ]; then
    echo "protoc-gen-$NAME wrote files that were not declared:" >&2
    ls -A "$OUT" >&2
    exit 1
fi
rm -rf "$T"
"""

def check_proto_import_name(ctx, name):
    if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
        fail("{}: import name `{}` is not a Mojo identifier; set `import_name`".format(ctx.label, name))

def generate_proto_dir(ctx, plugin, plugin_name, opt, trees, generate, names, import_name):
    """Run protoc with `plugin` over `generate`: the generation half, no compile.

    Writes `gen/<import_name>/`: `__init__.mojo` and exactly `names` (the
    files the plugin must write), none empty. Returns that directory. Reads
    `ctx.attrs.proto_toolchain`. Shared by the proto library rules here and
    by rules that compile the result themselves (tools/build/cloud/gcp.bzl).
    """
    ptc = ctx.attrs.proto_toolchain[MojoProtoToolchainInfo]

    # One directory output: every file of a package must share one
    # directory, and separately declared outputs need not.
    gen_dir = ctx.actions.declare_output("gen/" + import_name, dir = True)
    ctx.actions.run(
        _busybox_sh(
            ptc.busybox,
            _GEN_SCRIPT,
            ptc.protoc,
            plugin,
            plugin_name,
            gen_dir.as_output(),
            opt,
            str(len(trees)),
            trees,
            str(len(names)),
            names,
            generate,
        ),
        category = plugin_name + "_proto_gen",
    )
    return gen_dir

def _generate_package(ctx, plugin, plugin_name, opt, tree, trees, generate, names):
    """Run protoc with `plugin` over `generate` and precompile the result.

    `names` are the files the plugin must write (without `__init__.mojo`).
    Returns the providers of a generated Mojo package.
    """
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    import_name = ctx.attrs.import_name or ctx.label.name
    check_proto_import_name(ctx, import_name)
    gen_dir = generate_proto_dir(ctx, plugin, plugin_name, opt, trees, generate, names, import_name)

    # Precompile the generated directory, as mojo_library does.
    deps = [d[MojoInfo].pkgs for d in ctx.attrs.deps]
    pkg = ctx.actions.declare_output("pkg/" + import_name + ".mojoc")
    dep_closure = ctx.actions.tset(MojoPkgTSet, children = deps)
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            tc.wrapper,
            tc.busybox,
            tc.compiler,
            tc.link,
            tc.cc_target,
            "--",
            "precompile",
            dep_closure.project_as_args("include"),
            gen_dir,
            "-o",
            pkg.as_output(),
        ),
        category = "mojo_precompile",
    )

    files = {n: gen_dir.project(n) for n in ["__init__.mojo"] + names}
    return [
        DefaultInfo(
            default_output = pkg,
            sub_targets = {
                "gen": [DefaultInfo(default_output = gen_dir)],
                "proto": [DefaultInfo(default_output = tree)],
            } | {k: [DefaultInfo(default_output = v)] for k, v in files.items()},
        ),
        MojoInfo(
            direct = sorted([d[MojoInfo].import_name for d in ctx.attrs.deps]),
            import_name = import_name,
            pkgs = ctx.actions.tset(MojoPkgTSet, value = pkg, children = deps),
        ),
    ]

def proto_stem(ctx, path):
    b = path.rsplit("/", 1)[-1]
    if not b.endswith(".proto"):
        fail("{}: `{}` is not a .proto file".format(ctx.label, path))
    return b[:-len(".proto")]

_COMMON_ATTRS = {
    # Mojo libraries the generated code imports (its runtime).
    "deps": attrs.list(attrs.dep(providers = [MojoInfo]), default = []),
    # The Mojo package name; default: the target name.
    "import_name": attrs.option(attrs.string(), default = None),
    "import_prefix": attrs.string(default = ""),
    # The plugin's `package_prefix`; default: the import name.
    "package_name": attrs.option(attrs.string(), default = None),
    # Targets (mojo_proto_library, proto_srcs) whose .proto files these import.
    "proto_deps": attrs.list(attrs.dep(providers = [ProtoSrcsInfo]), default = []),
    "proto_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_proto", providers = [MojoProtoToolchainInfo]),
    "srcs": attrs.list(attrs.source()),
    "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
}

# ---- mojo_proto_library --------------------------------------------------------

def select_generated(ctx, own_paths, dep_paths):
    """The import paths to generate code for, and the `<stem>.mojo` each writes.

    `own_paths`, then the files `ctx.attrs.bundle_proto_deps` and
    `ctx.attrs.bundle_only` select from the proto_deps closure `dep_paths`.
    """
    bundled = []
    if ctx.attrs.bundle_only:
        if not ctx.attrs.bundle_proto_deps:
            fail("{}: `bundle_only` selects files of the bundled closure; set `bundle_proto_deps = True`".format(ctx.label))
        for p in ctx.attrs.bundle_only:
            if p not in dep_paths:
                fail("{}: `bundle_only` names `{}`, which is not a .proto of the proto_deps closure: {}".format(
                    ctx.label,
                    p,
                    ", ".join(dep_paths) or "(empty)",
                ))
            if p in bundled:
                fail("{}: `bundle_only` names `{}` twice".format(ctx.label, p))
            bundled.append(p)
    elif ctx.attrs.bundle_proto_deps:
        bundled = dep_paths
    generate = own_paths + bundled

    # One `<stem>.mojo` per `.proto`, the directory dropped (the plugin's
    # output is flat).
    names = []
    for p in generate:
        name = proto_stem(ctx, p) + ".mojo"
        if name in names:
            fail("{}: two .proto files generate `{}`; the generated package is flat".format(ctx.label, name))
        names.append(name)
    return generate, names

def _mojo_proto_library_impl(ctx):
    ptc = ctx.attrs.proto_toolchain[MojoProtoToolchainInfo]
    tree, own_paths = stage_proto_srcs(ctx)
    trees, dep_paths = proto_closure(ctx, tree, own_paths)
    generate, names = select_generated(ctx, own_paths, dep_paths)

    import_name = ctx.attrs.import_name or ctx.label.name
    opt = ",".join([
        "default_wire=" + ctx.attrs.default_wire,
        "default_protocol=" + ctx.attrs.default_protocol,
        "package_prefix=" + (ctx.attrs.package_name or import_name),
    ])
    return _generate_package(ctx, ptc.plugin, "mojo", opt, tree, trees, generate, names) + [
        ProtoSrcsInfo(trees = trees, import_paths = own_paths + dep_paths),
    ]

mojo_proto_library_rule = rule(
    impl = _mojo_proto_library_impl,
    attrs = _COMMON_ATTRS | {
        # Generate code for the proto_deps closure into this package too.
        "bundle_proto_deps": attrs.bool(default = False),
        # With bundle_proto_deps: generate only these files of the closure
        # (import paths), not all of it.
        "bundle_only": attrs.list(attrs.string(), default = []),
        # Plugin options.
        "default_protocol": attrs.string(default = "connect"),
        "default_wire": attrs.string(default = "proto"),
    },
)

# ---- mojo_db_proto_library -----------------------------------------------------

def _mojo_db_proto_library_impl(ctx):
    ptc = ctx.attrs.proto_toolchain[MojoProtoToolchainInfo]
    tree, own_paths = stage_proto_srcs(ctx)
    trees, _dep_paths = proto_closure(ctx, tree, own_paths)

    # protoc-gen-mojo-db writes `<stem>_db.mojo` only for a .proto declaring
    # a `(komira.db.table)` message, so the outputs are stated, not derived.
    if not ctx.attrs.outs:
        fail("{}: `outs` must list the `<stem>_db.mojo` files, one per .proto of `srcs` that declares a table".format(ctx.label))
    stems = [proto_stem(ctx, p) for p in own_paths]
    seen = {}
    for o in ctx.attrs.outs:
        if "/" in o or not o.endswith("_db.mojo") or o[:-len("_db.mojo")] not in stems:
            fail("{}: `outs` entry `{}` is not `<stem>_db.mojo` for a .proto of `srcs` ({})".format(
                ctx.label,
                o,
                ", ".join([s + ".proto" for s in stems]),
            ))
        if o in seen:
            fail("{}: `outs` lists `{}` twice".format(ctx.label, o))
        seen[o] = True

    import_name = ctx.attrs.import_name or ctx.label.name
    opt = "package_prefix=" + (ctx.attrs.package_name or import_name)
    return _generate_package(ctx, ptc.db_plugin, "mojo_db", opt, tree, trees, own_paths, ctx.attrs.outs)

mojo_db_proto_library_rule = rule(
    impl = _mojo_db_proto_library_impl,
    attrs = _COMMON_ATTRS | {
        # The generated files: `<stem>_db.mojo` for each .proto of `srcs`
        # that declares a table message.
        "outs": attrs.list(attrs.string()),
    },
)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
mojo_db_proto_library = declares_docs(mojo_db_proto_library_rule)
mojo_proto_library = declares_docs(mojo_proto_library_rule)
proto_srcs = declares_docs(proto_srcs_rule)
protoc_dist = declares_docs(protoc_dist_rule)
