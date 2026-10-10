"""mojo_gcp_client: a Google Cloud client generated from `.proto` files at build time.

    mojo_gcp_client(
        name = "komira_gcp_logging",
        protos = [...],                 # .proto files of this package (may be empty)
        proto_deps = [...],             # proto_srcs / mojo_proto_library targets
        bundle_proto_deps = True,
        bundle_only = ["google/logging/v2/log_entry.proto", ...],
        methods = ["LoggingServiceV2.ListLogEntries"],   # or roots = [...]
        messages_only = True,
        protocol = "rest",              # the default, or "grpc"
        service_config = "logging_v2.yaml",   # optional, REST: "Service configuration"
        deps = ["komira//src/komira_proto_codec:komira_proto_codec", ...],
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

`omit_fields` names fields (`pkg.Message.field`) left out of their
message: a field whose type the runtime cannot represent and no caller
reads, such as Service Usage's `Service.config` (its `ServiceConfig` reaches
`google.protobuf.Api`, which komira_wkt does not provide, and
`map<string, int64>` fields, which komira_proto_codec does not decode). The
message is generated without it, so a response's value for it is skipped
like any unknown key, a request never sends it, and the closure no longer
reaches its type. A name that is not a field of a generated message is
refused at generation, including a field of a message the scope prunes.

Protocol. `protocol` is the wire protocol of the generated service code,
passed to protoc-gen-mojo as `default_protocol`. It is "rest" (JSON over
HTTP, the default) or "grpc"; any other value is refused naming the
accepted ones. Both service shapes are Google Cloud clients (the plugin is
passed `gcp=true`): `<Service>Client[C: Connector, T: GcpTokenSource]`, whose
token source (komira_gcp_core) supplies each request's bearer token. Under
"rest" the client builds the JSON request over komira_http_client and maps a
non-2xx response through `gcp_status_error`; it starts at the service's
`(google.api.default_host)`, and a client of a service that declares none
refuses every call, before any dial, until `set_rest_host` names a host. A
server-streaming method returns a `List` of its responses (over REST the
whole stream is one HTTP response, a JSON array). A client-streaming or
bidirectional method has no REST form: any such method a "rest" target keeps
is refused by name at generation (so a `methods` entry naming one is
refused, and a plugin run with no `methods` filter over a service holding one
fails rather than skipping it). Under "grpc" it calls
komira_grpc's `GrpcClient` with classic gRPC, sets
`authorization: Bearer <token>` on each call's `CallOptions.raw_metadata`
before the call (the token hook), and raises a non-OK gRPC status through
`gcp_grpc_status_error`; its `deps` then name komira_grpc, komira_gcp_core,
komira_http_core and komira_async beside komira_proto_codec. The plugin
branches on the protocol only for service code, so `messages_only = True`
generates the same messages under both. The attribute is a string checked in
`<name>_gen`, not an `attrs.enum`: an enum is coerced when the BUCK file is
evaluated, so one wrong value would fail the whole package to load.

Service configuration. `service_config` (a `google.api.Service` YAML, the
`<api>_<version>.yaml` googleapis keeps beside an API's protos; a source
path or a label) is passed to protoc-gen-mojo as `service_config`, and the
generator reads two things from it (proto-codegen's service_config.rs):
its `http.rules`, each binding the method its `selector` names in full
(`google.longrunning.Operations.GetOperation`) to a verb and path, `body`
and `additional_bindings`, in place of the method's own
`(google.api.http)`; and its `name`, the host a service starts at when
its `apis` lists it or a rule binds one of its generated methods (every
rule is served at the API's host, listed or not). That is how a mixin
(google.longrunning.Operations, google.iam.v1.IAMPolicy,
google.cloud.location.Locations), whose protos bind it to its own generic
paths and host, is generated at the API's paths and host: name in
`methods` mixin methods the configuration binds, bundle the mixin's
`.proto`, and give the API's configuration. A rule for a method the target
does not generate is not used. Refused at generation: a generated method
with no rule whose service moves off its own host (its proto path is the
mixin's, which the API's host does not serve), a rule or additional
binding with `response_body`, the `custom` verb, a wildcard selector, YAML
outside the block subset the reader takes (proto-codegen's
yaml_subset.rs), and a `service_config` with `protocol = "grpc"` (the
rules bind REST methods).

Bundling. The plugin writes a reference to a message of another `.proto` as
`<name>.<stem>`, so every file the closure reaches is generated into this
package: googleapis files such as monitored_resource, logging/type or
rpc/status are listed in `bundle_only` (import paths of the `proto_deps`
closure). Both `bundle_proto_deps` and `bundle_only` must be stated: with
`bundle_proto_deps = True`, `bundle_only` is required and non-empty
(bundling a whole googleapis closure would generate files the scope leaves
empty, which the plugin refuses); with `False`, it must be empty.

Module names. Each generated `.proto` is the module `<stem>`, its basename
without `.proto`. Where that cannot be the module, `module_names` names one
(import path -> module, passed to the plugin as `module_names`): a basename
that is not a Mojo module name (`google/cloud/run/v2/k8s.min.proto`, or a
Mojo keyword such as `import`), or two bundled files with one basename
(`google/rpc/status.proto` beside `google/cloud/run/v2/status.proto`), which
the flat package cannot hold apart. A generated file whose stem is not a module name and is not renamed is
refused, and so is a `module_names` entry for a file the target does not
generate; two files generating one module are refused as before.

Runtime. `deps` is required and non-empty, and nothing is added to it: the
generated code imports its runtime (komira_proto_codec, komira_wkt, and with
services the transport), which the caller names as `komira//` labels, or as
stubs in a test. They are the library's `deps`, so they take what
`mojo_library.deps` takes (C and C++ libraries too); `<name>_gen` sees only
their count.

Sources. `protos` takes source paths of `.proto` files only, never a label
(even one to a generated `.proto`): the library's file names
(`<stem>.mojo`) are derived from those paths, so anything else is refused.

Every refusal happens at analysis, in `<name>_gen`, so a BUCK file with one
wrong mojo_gcp_client still loads.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:defs.bzl", "mojo_library")
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

# Values of `protocol`.
_PROTOCOLS = ["rest", "grpc"]

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

_MODULE_NAME = "^[A-Za-z_][A-Za-z0-9_]*$"

# Mojo keywords: an identifier no import can name. The plugin refuses the
# same list (proto-codegen's mojo_names.rs `KEYWORDS`); this one reports it
# at analysis, against the target's own attribute.
_MOJO_KEYWORDS = [
    "alias", "and", "as", "async", "await", "break", "comptime", "continue",
    "def", "del", "elif", "else", "except", "False", "fieldwise_init",
    "finally", "fn", "for", "from", "global", "if", "import", "in", "is",
    "lambda", "mut", "None", "nonlocal", "not", "or", "out", "owned", "pass",
    "raise", "raises", "read", "ref", "return", "self", "struct", "trait",
    "True", "try", "var", "while", "with", "yield",
    "imm", "deinit",
]

def _is_module_name(m):
    return regex_match(_MODULE_NAME, m) and m not in _MOJO_KEYWORDS

def _check_module_names(ctx, generate, module_names):
    for p, m in module_names.items():
        if p not in generate:
            fail("{}: `module_names` names `{}`, which this target does not generate".format(ctx.label, p))
        if not _is_module_name(m) or m in ["__init__", _LAYOUT_PROBE[:-len(".mojo")]]:
            fail("{}: `module_names` gives `{}` the module `{}`, which is not a Mojo module name the generated package can hold".format(ctx.label, p, m))
        if _LIST_SEPARATOR in p or "," in p or ":" in p:
            fail("{}: `module_names` path `{}` holds `{}`, `,` or `:`, which the plugin option cannot carry".format(ctx.label, p, _LIST_SEPARATOR))
    for p in generate:
        if p in module_names:
            continue
        stem = p.rsplit("/", 1)[-1][:-len(".proto")]
        if not _is_module_name(stem):
            fail("{}: `{}` would be generated as module `{}`, which is not a Mojo module name: give it one in `module_names`".format(ctx.label, p, stem))

def _gcp_client_gen_impl(ctx):
    ptc = ctx.attrs.proto_toolchain[MojoProtoToolchainInfo]
    import_name = ctx.attrs.import_name
    check_proto_import_name(ctx, import_name)

    for p in ctx.attrs.proto_paths:
        if ":" in p or not p.endswith(".proto"):
            fail("{}: `protos` entry `{}` is not a source path of a `.proto` file. `protos` takes source paths only, never a label (not even one to a generated .proto): the library's `<stem>.mojo` file names are derived from these paths".format(ctx.label, p))
    if ctx.attrs.runtime_dep_count == 0:
        fail("{}: `deps` is empty. The generated code imports its runtime (komira_proto_codec, komira_wkt, ...); name it, as komira// labels. No runtime is added by default.".format(ctx.label))
    if not ctx.attrs.roots and not ctx.attrs.methods:
        fail("{}: neither `roots` nor `methods` is set. A mojo_gcp_client generates the closure of the messages and methods it names, never a whole API".format(ctx.label))
    if ctx.attrs.protocol not in _PROTOCOLS:
        fail("{}: `protocol` `{}` is not one of {}".format(ctx.label, ctx.attrs.protocol, ", ".join(['"{}"'.format(p) for p in _PROTOCOLS])))
    _check_items(ctx, "roots", ctx.attrs.roots)
    _check_items(ctx, "methods", ctx.attrs.methods)
    _check_items(ctx, "omit_fields", ctx.attrs.omit_fields)
    if ctx.attrs.bundle_proto_deps and not ctx.attrs.bundle_only:
        fail("{}: `bundle_proto_deps = True` with an empty `bundle_only`. List the files of the proto_deps closure the scope reaches; the whole closure is never bundled".format(ctx.label))
    if not ctx.attrs.bundle_proto_deps and ctx.attrs.bundle_only:
        fail("{}: `bundle_only` is set but `bundle_proto_deps = False`".format(ctx.label))

    tree, own_paths = stage_proto_srcs(ctx)
    trees, dep_paths = proto_closure(ctx, tree, own_paths)
    module_names = ctx.attrs.module_names
    generate, names = select_generated(ctx, own_paths, dep_paths, module_names)
    if not generate:
        fail("{}: nothing to generate: `protos` and `bundle_only` are both empty".format(ctx.label))
    _check_module_names(ctx, generate, module_names)
    if _LAYOUT_PROBE in names:
        fail("{}: a .proto generates `{}`, the layout probe's name".format(ctx.label, _LAYOUT_PROBE))

    opt = [
        "default_protocol=" + ctx.attrs.protocol,
        "package_prefix=" + import_name,
        "messages_only=" + ("true" if ctx.attrs.messages_only else "false"),
        "layout_probe=true",
        "gcp=true",
    ]
    if ctx.attrs.roots:
        opt.append("roots=" + _LIST_SEPARATOR.join(ctx.attrs.roots))
    if ctx.attrs.methods:
        opt.append("methods=" + _LIST_SEPARATOR.join(ctx.attrs.methods))
    if module_names:
        opt.append("module_names=" + _LIST_SEPARATOR.join(["{}:{}".format(p, m) for p, m in sorted(module_names.items())]))
    if ctx.attrs.omit_fields:
        opt.append("omit_fields=" + _LIST_SEPARATOR.join(ctx.attrs.omit_fields))
    if ctx.attrs.service_config:
        # The file is an input of the generation action, named by its path
        # in the action's working directory, where protoc runs the plugin.
        opt.append(cmd_args("service_config=", ctx.attrs.service_config, delimiter = ""))
    expected = names + [_LAYOUT_PROBE]
    gen_dir = generate_proto_dir(ctx, ptc.plugin, "mojo", cmd_args(opt, delimiter = ","), trees, generate, expected, import_name)

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
        # Import path -> the module that file is generated as (module docstring).
        "module_names": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "omit_fields": attrs.list(attrs.string(), default = []),
        "proto_deps": attrs.list(attrs.dep(providers = [ProtoSrcsInfo]), default = []),
        # `protos` as written, so an entry the macro cannot derive a file
        # name from is refused here (`srcs` is the same list, resolved).
        "proto_paths": attrs.list(attrs.string()),
        "proto_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_proto", providers = [MojoProtoToolchainInfo]),
        # Checked at analysis rather than an attrs.enum (module docstring).
        "protocol": attrs.string(default = "rest"),
        "roots": attrs.list(attrs.string(), default = []),
        # The API's service configuration YAML (module docstring).
        "service_config": attrs.option(attrs.source(), default = None),
        # `len(deps)` of the library, so an empty runtime is refused at
        # analysis. A count, not the labels: the generator has no edge to the
        # runtime, and `deps` keeps every kind `mojo_library.deps` accepts.
        "runtime_dep_count": attrs.int(),
        "srcs": attrs.list(attrs.source()),
    },
)

def _stem(path):
    return path.rsplit("/", 1)[-1][:-len(".proto")]

def _gcp_client(
        name,
        protos,
        deps,
        bundle_proto_deps,
        bundle_only,
        roots = [],
        methods = [],
        omit_fields = [],
        messages_only = False,
        proto_deps = [],
        import_prefix = "",
        module_names = {},
        protocol = "rest",
        service_config = None,
        test_srcs = [],
        visibility = None,
        **kwargs):
    """See the module docstring. `kwargs` go to the mojo_library (test_data, test_env, readme)."""
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
        module_names = module_names,
        omit_fields = omit_fields,
        proto_deps = proto_deps,
        proto_paths = protos,
        protocol = protocol,
        roots = roots,
        runtime_dep_count = len(deps),
        service_config = service_config,
        **vis
    )

    # The file names the generation action is held to (generate_proto_dir
    # refuses a missing, empty or extra file), so they can be named here. An
    # entry that is not a `.proto` path is left out rather than turned into a
    # sub-target name: `<name>_gen` refuses it, and that refusal is what the
    # build reports. A file named in `module_names` is that module, keyed by
    # its import path (an own `.proto`'s is its path under `import_prefix`).
    prefix = import_prefix.strip("/")
    own = [(prefix + "/" + p) if prefix else p for p in protos]
    stems = [
        module_names.get(ip, _stem(p))
        for p, ip in zip(protos + bundle_only, own + bundle_only)
        if p.endswith(".proto") and ":" not in p
    ]
    srcs = [":{}[__init__.mojo]".format(gen)] + [":{}[{}.mojo]".format(gen, s) for s in stems]
    mojo_library(
        name = name,
        srcs = srcs,
        deps = deps,
        gen = ":" + gen,
        test_srcs = [":{}[{}]".format(gen, _LAYOUT_PROBE)] + test_srcs,
        **(vis | kwargs)
    )

mojo_gcp_client = declares_docs(_gcp_client)
