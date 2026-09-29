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

protoc and the plugin come from `toolchains//:mojo_proto`. Options reach
the plugin as `--mojo_opt` arguments, never from a file, so they are part of
the action key.
"""

load(":providers.bzl", "MojoInfo", "MojoPkgTSet", "MojoToolchainInfo")

MojoProtoToolchainInfo = provider(fields = {
    "busybox": provider_field(typing.Any),
    # Directory: bin/protoc and include/ (the well-known types).
    "protoc": provider_field(typing.Any),
    # The protoc-gen-mojo executable.
    "plugin": provider_field(typing.Any),
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
T="$PWD/.komira_action"
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

protoc_dist = rule(
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
        ),
    ]

mojo_proto_toolchain = rule(
    impl = _mojo_proto_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "busybox": attrs.exec_dep(),
        "plugin": attrs.exec_dep(),
        "protoc": attrs.exec_dep(),
    },
)

# ---- mojo_proto_library --------------------------------------------------------

# One `--mojo_out` file per `.proto`: `<dir>/<name>.proto` -> `<name>.mojo`,
# the directory dropped (the plugin's output is flat).
def _generated_name(ctx, path):
    b = path.rsplit("/", 1)[-1]
    if not b.endswith(".proto"):
        fail("{}: `{}` is not a .proto file".format(ctx.label, path))
    return b[:-len(".proto")] + ".mojo"

_GEN_SCRIPT = """
# $1 protoc dir, $2 plugin, $3 output package directory, $4 --mojo_opt
# value, $5 number of --proto_path dirs; then those dirs; then the import
# paths to generate code for.
PROTOC="$1"; PLUGIN="$2"; OUT="$3"; OPT="$4"; N="$5"; shift 5
case "$PLUGIN" in /*) ;; *) PLUGIN="$PWD/$PLUGIN" ;; esac
mkdir -p "$OUT" "$T/tmp"
PATHS=""
while [ "$N" -gt 0 ]; do
    PATHS="$PATHS --proto_path=$1"
    shift; N=$((N - 1))
done
TMPDIR="$T/tmp"; HOME="$T"; export TMPDIR HOME
# shellcheck disable=SC2086
"$PROTOC/bin/protoc" $PATHS "--proto_path=$PROTOC/include" \\
    "--plugin=protoc-gen-mojo=$PLUGIN" "--mojo_out=$OUT" "--mojo_opt=$OPT" "$@"
printf '%s\\n' '# Generated by mojo_proto_library: the package of the modules generated' \\
    '# from this target'"'"'s .proto files. Do not edit.' > "$OUT/__init__.mojo"
# Exactly the expected files, none empty: an empty module is a silent
# plugin failure, and an unexpected one would not be compiled.
for p in "$@"; do
    b=${p##*/}; f="$OUT/${b%.proto}.mojo"
    if [ ! -s "$f" ]; then
        echo "mojo_proto_library: protoc-gen-mojo wrote no code (or an empty file) for $p" >&2
        exit 1
    fi
done
if [ "$(ls -A "$OUT" | wc -l)" != "$(( $# + 1 ))" ]; then
    echo "mojo_proto_library: protoc-gen-mojo wrote files that were not declared:" >&2
    ls -A "$OUT" >&2
    exit 1
fi
rm -rf "$T"
"""

def _check_import_name(ctx, name):
    if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
        fail("{}: import name `{}` is not a Mojo identifier; set `import_name`".format(ctx.label, name))

def _mojo_proto_library_impl(ctx):
    ptc = ctx.attrs.proto_toolchain[MojoProtoToolchainInfo]
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    import_name = ctx.attrs.import_name or ctx.label.name
    _check_import_name(ctx, import_name)

    # Stage this library's .proto files at their import paths.
    prefix = ctx.attrs.import_prefix.strip("/")
    staged = {}
    own_paths = []
    for s in ctx.attrs.srcs:
        path = s.short_path if not prefix else prefix + "/" + s.short_path
        staged[path] = s
        own_paths.append(path)
    tree = ctx.actions.copied_dir("proto", staged)

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

    generate = own_paths + (dep_paths if ctx.attrs.bundle_proto_deps else [])
    # One directory output: every file of a package must share one
    # directory, and separately declared outputs need not.
    gen_dir = ctx.actions.declare_output("gen/" + import_name, dir = True)
    names = ["__init__.mojo"]
    for p in generate:
        name = _generated_name(ctx, p)
        if name in names:
            fail("{}: two .proto files generate `{}`; the generated package is flat".format(ctx.label, name))
        names.append(name)

    opt = ",".join([
        "default_wire=" + ctx.attrs.default_wire,
        "default_protocol=" + ctx.attrs.default_protocol,
        "package_prefix=" + (ctx.attrs.package_name or import_name),
    ])
    ctx.actions.run(
        _busybox_sh(
            ptc.busybox,
            _GEN_SCRIPT,
            ptc.protoc,
            ptc.plugin,
            gen_dir.as_output(),
            opt,
            str(len(trees)),
            trees,
            generate,
        ),
        category = "mojo_proto_gen",
    )

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

    files = {n: gen_dir.project(n) for n in names}
    return [
        DefaultInfo(
            default_output = pkg,
            sub_targets = {
                "gen": [DefaultInfo(default_output = gen_dir)],
                "proto": [DefaultInfo(default_output = tree)],
            } | {k: [DefaultInfo(default_output = v)] for k, v in files.items()},
        ),
        MojoInfo(
            import_name = import_name,
            pkgs = ctx.actions.tset(MojoPkgTSet, value = pkg, children = deps),
        ),
        ProtoSrcsInfo(trees = trees, import_paths = own_paths + dep_paths),
    ]

mojo_proto_library = rule(
    impl = _mojo_proto_library_impl,
    attrs = {
        # Generate code for the proto_deps closure into this package too.
        "bundle_proto_deps": attrs.bool(default = False),
        # Plugin options.
        "default_protocol": attrs.string(default = "connect"),
        "default_wire": attrs.string(default = "proto"),
        # Mojo libraries the generated code imports (its runtime).
        "deps": attrs.list(attrs.dep(providers = [MojoInfo]), default = []),
        # The Mojo package name; default: the target name.
        "import_name": attrs.option(attrs.string(), default = None),
        "import_prefix": attrs.string(default = ""),
        # The plugin's `package_prefix`; default: the import name.
        "package_name": attrs.option(attrs.string(), default = None),
        # mojo_proto_library targets whose .proto files these import.
        "proto_deps": attrs.list(attrs.dep(providers = [ProtoSrcsInfo]), default = []),
        "proto_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_proto", providers = [MojoProtoToolchainInfo]),
        "srcs": attrs.list(attrs.source()),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)
