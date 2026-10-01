"""gcp_client: a Google Cloud client generated from `.proto` files at build time.

    gcp_client(
        name = "komira_gcp_logging",
        protos = [...],                 # .proto files of this package (may be empty)
        proto_deps = [...],             # proto_srcs / mojo_proto_library targets
        bundle_proto_deps = True,
        bundle_only = ["google/logging/v2/log_entry.proto", ...],
        methods = ["LoggingServiceV2.ListLogEntries"],   # or roots = [...]
        messages_only = True,
        deps = ["komira//src/komira_serde:komira_serde", ...],
    )

is two targets:

  * `<name>_gen`, the GENERATION half of the Mojo proto rules
    (tools/build/mojo/proto.bzl: `stage_proto_srcs`, `proto_closure`,
    `select_generated`, `generate_proto_dir`): protoc-gen-mojo writes
    `gen/<name>/` with `__init__.mojo`, one `<stem>.mojo` per generated
    `.proto`, and `_layout_probe.mojo`. Nothing is compiled there.
  * `<name>`, an ordinary `mojo_library` over those files, so the library is
    welded exactly like a hand-written one: its `test_srcs` gate its `.mojoc`.
    The generator's layout probe (one `size_of` per emitted struct) is its
    first test, so a library whose generated code does not lay out cannot be
    built. `<name>[gen]` is the generated directory (`gen` attr of
    mojo_library); `<name>[gen][<file>]` one file of it.

Scope. A Google API package declares far more than a client calls, so the
generated code is restricted to the transitive closure of `roots` (messages
or enums) and `methods` (`Service.Method`); at least one of them is
required. `messages_only = True` emits no service. The items are joined
with protoc-gen-mojo's list separator `+`, the options with `,`; an item
holding either, `=` or whitespace is refused here rather than mis-split.

Bundling. The plugin writes a reference to a message of another `.proto` as
`<name>.<stem>`, so every file the closure reaches is generated into this
package: googleapis files such as monitored_resource, logging/type or
rpc/status are listed in `bundle_only` (import paths of the `proto_deps`
closure). Both `bundle_proto_deps` and `bundle_only` must be stated: with
`bundle_proto_deps = True`, `bundle_only` is required and non-empty
(bundling a whole googleapis closure would generate files the scope leaves
empty, which the plugin refuses); with `False`, it must be empty.

Runtime. `deps` is required and non-empty, and nothing is added to it: the
generated code imports its runtime (komira_serde, komira_wkt, and with
services the transport), which the caller names as `komira//` labels, or as
stubs in a test.

Every refusal happens at analysis, in `<name>_gen`, so a BUCK file with one
wrong gcp_client still loads.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:defs.bzl", "mojo_library")
load("@komira//tools/build/mojo:providers.bzl", "MojoInfo")
load(
    "@komira//tools/build/mojo:proto.bzl",
    "MojoProtoToolchainInfo",
    "ProtoSrcsInfo",
    "check_proto_import_name",
    "generate_proto_dir",
    "proto_closure",
    "select_generated",
    "stage_proto_srcs",
)

# protoc-gen-mojo's list separator (tools/build/proto-codegen/src/lib.rs,
# LIST_SEPARATOR) and the generated layout probe (emit.rs, LAYOUT_PROBE_FILE).
_LIST_SEPARATOR = "+"
_LAYOUT_PROBE = "_layout_probe.mojo"

def _check_items(ctx, attr, items):
    seen = {}
    for item in items:
        if not item or not regex_match("^[.]?[A-Za-z_][A-Za-z0-9_.]*$", item):
            fail("{}: `{}` item `{}` is not a proto name (`Name`, `pkg.Name` or `.pkg.Name`); items are separate list entries, never joined with `{}` or `,`".format(
                ctx.label,
                attr,
                item,
                _LIST_SEPARATOR,
            ))
        if item in seen:
            fail("{}: `{}` names `{}` twice".format(ctx.label, attr, item))
        seen[item] = True

def _gcp_client_gen_impl(ctx):
    ptc = ctx.attrs.proto_toolchain[MojoProtoToolchainInfo]
    import_name = ctx.attrs.import_name
    check_proto_import_name(ctx, import_name)

    if not ctx.attrs.runtime_deps:
        fail("{}: `deps` is empty. The generated code imports its runtime (komira_serde, komira_wkt, ...); name it, as komira// labels. No runtime is added by default.".format(ctx.label))
    if not ctx.attrs.roots and not ctx.attrs.methods:
        fail("{}: neither `roots` nor `methods` is set. A gcp_client generates the closure of the messages and methods it names, never a whole API".format(ctx.label))
    _check_items(ctx, "roots", ctx.attrs.roots)
    _check_items(ctx, "methods", ctx.attrs.methods)
    if ctx.attrs.bundle_proto_deps and not ctx.attrs.bundle_only:
        fail("{}: `bundle_proto_deps = True` with an empty `bundle_only`. List the files of the proto_deps closure the scope reaches; the whole closure is never bundled".format(ctx.label))
    if not ctx.attrs.bundle_proto_deps and ctx.attrs.bundle_only:
        fail("{}: `bundle_only` is set but `bundle_proto_deps = False`".format(ctx.label))

    tree, own_paths = stage_proto_srcs(ctx)
    trees, dep_paths = proto_closure(ctx, tree, own_paths)
    generate, names = select_generated(ctx, own_paths, dep_paths)
    if not generate:
        fail("{}: nothing to generate: `protos` and `bundle_only` are both empty".format(ctx.label))
    if _LAYOUT_PROBE in names:
        fail("{}: a .proto generates `{}`, the layout probe's name".format(ctx.label, _LAYOUT_PROBE))

    opt = [
        "default_protocol=rest",
        "package_prefix=" + import_name,
        "messages_only=" + ("true" if ctx.attrs.messages_only else "false"),
        "layout_probe=true",
    ]
    if ctx.attrs.roots:
        opt.append("roots=" + _LIST_SEPARATOR.join(ctx.attrs.roots))
    if ctx.attrs.methods:
        opt.append("methods=" + _LIST_SEPARATOR.join(ctx.attrs.methods))
    expected = names + [_LAYOUT_PROBE]
    gen_dir = generate_proto_dir(ctx, ptc.plugin, "mojo", ",".join(opt), trees, generate, expected, import_name)

    files = ["__init__.mojo"] + expected
    return [
        DefaultInfo(
            default_output = gen_dir,
            sub_targets = {"proto": [DefaultInfo(default_output = tree)]} |
                          {f: [DefaultInfo(default_output = gen_dir.project(f))] for f in files},
        ),
        ProtoSrcsInfo(trees = trees, import_paths = own_paths + dep_paths),
    ]

_gcp_client_gen = rule(
    impl = _gcp_client_gen_impl,
    attrs = {
        "bundle_only": attrs.list(attrs.string()),
        "bundle_proto_deps": attrs.bool(),
        "import_name": attrs.string(),
        "import_prefix": attrs.string(default = ""),
        "messages_only": attrs.bool(default = False),
        "methods": attrs.list(attrs.string(), default = []),
        "proto_deps": attrs.list(attrs.dep(providers = [ProtoSrcsInfo]), default = []),
        "proto_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_proto", providers = [MojoProtoToolchainInfo]),
        "roots": attrs.list(attrs.string(), default = []),
        # The library's `deps`, read here only so an empty list is refused at
        # analysis; the library compiles against them.
        "runtime_deps": attrs.list(attrs.dep(providers = [MojoInfo])),
        "srcs": attrs.list(attrs.source()),
    },
)

def _stem(path):
    b = path.rsplit("/", 1)[-1]
    return b[:-len(".proto")] if b.endswith(".proto") else b

def _gcp_client(
        name,
        protos,
        deps,
        bundle_proto_deps,
        bundle_only,
        roots = [],
        methods = [],
        messages_only = False,
        proto_deps = [],
        import_prefix = "",
        test_srcs = [],
        visibility = None,
        **kwargs):
    """See the module docstring. `kwargs` go to the mojo_library (test_data, test_env, tests_known_failing)."""
    gen = name + "_gen"
    vis = {"visibility": visibility} if visibility != None else {}
    _gcp_client_gen(
        name = gen,
        srcs = protos,
        bundle_only = bundle_only,
        bundle_proto_deps = bundle_proto_deps,
        import_name = name,
        import_prefix = import_prefix,
        messages_only = messages_only,
        methods = methods,
        proto_deps = proto_deps,
        roots = roots,
        runtime_deps = deps,
        **vis
    )

    # The file names the generation action is held to (generate_proto_dir
    # refuses a missing, empty or extra file), so they can be named here.
    stems = [_stem(p) for p in protos] + [_stem(p) for p in bundle_only]
    srcs = [":{}[__init__.mojo]".format(gen)] + [":{}[{}.mojo]".format(gen, s) for s in stems]
    mojo_library(
        name = name,
        srcs = srcs,
        deps = deps,
        gen = ":" + gen,
        test_srcs = [":{}[{}]".format(gen, _LAYOUT_PROBE)] + test_srcs,
        **(vis | kwargs)
    )

gcp_client = declares_docs(_gcp_client)
