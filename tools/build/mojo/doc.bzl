"""mojo_doc_json: the `mojo doc` JSON of one Mojo library, as a build output.

The action runs the pinned compiler's `mojo doc` through mojo_compile
(the hermetic environment, the compile watchdog, and its refusal of a
missing or empty output, or of one holding the action's working directory)
on the library's staged sources (`[src]` of the mojo_library), with the
precompiled packages of its `deps` on `-I`. The library's own package is not
an input: the JSON is read from the sources, so it does not wait for the
library's welded tests. A source that does not compile fails the action
(`mojo doc` exits non-zero: "could not generate documentation").

With `golden` or `symbols`, a second action checks the JSON, and the target's
output is the checked copy:

- `golden`: the JSON must equal this file byte for byte.
- `symbols`: each entry, a dotted path inside the package
  (`<module>.<name>`, `<module>.<struct>.<method>`, a subpackage's name
  first), must name a declaration of the JSON. The JSON is read by
  //tools/build/inspect (`inspect json`), not by matching text.

What the JSON holds (mojo 1.0.0): per package its modules, per module its
functions, structs, traits and aliases with signatures, parameters and doc
strings. It holds no source location, and no declaration whose name starts
with `_` (a struct's dunder methods excepted).
"""

load(":defs.bzl", "mojo_compile_cmd")
load(":providers.bzl", "MojoInfo", "MojoToolchainInfo")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")

def _impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    lib = ctx.attrs.lib
    src = lib[DefaultInfo].sub_targets.get("src")
    if src == None:
        fail("{}: lib {} is not a mojo_library (it has no [src] sub-target)".format(ctx.label.raw_target(), lib.label.raw_target()))

    # The library's own package is the value of its MojoPkgTSet; the rest is
    # the closure of its deps, which `mojo doc` resolves imports against.
    pkgs = list(lib[MojoInfo].pkgs.traverse())
    own = lib[MojoInfo].import_name + ".mojoc"
    if not pkgs or pkgs[0].basename != own:
        fail("{}: the first package of {} is not {}".format(ctx.label.raw_target(), lib.label.raw_target(), own))
    checked = ctx.attrs.golden != None or len(ctx.attrs.symbols) > 0
    name = ctx.label.name + ".json"
    raw = ctx.actions.declare_output("raw/" + name if checked else name)
    ctx.actions.run(
        mojo_compile_cmd(tc, [
            "doc",
            [cmd_args(p, format = "-I{}", parent = 1) for p in pkgs[1:]],
            src[DefaultInfo].default_outputs[0],
            "-o",
            raw.as_output(),
        ]),
        env = salted(),
        category = "mojo_doc",
    )
    if not checked:
        return [DefaultInfo(default_output = raw)]
    out = ctx.actions.declare_output(name)
    inspect = ctx.attrs._inspect[DefaultInfo].default_outputs[0] if ctx.attrs.symbols else "-"
    # The checks (golden, symbols) and the copy are tools/build/mojo/tools/doc_check.zig.
    ctx.actions.run(
        cmd_args(
            ctx.attrs._doc_check[RunInfo],
            raw,
            ctx.attrs.golden or "-",
            inspect,
            out.as_output(),
            str(ctx.label.raw_target()),
            ctx.attrs.symbols,
        ),
        env = salted(),
        category = "mojo_doc_check",
    )
    return [DefaultInfo(default_output = out, sub_targets = {"raw": [DefaultInfo(default_output = raw)]})]

mojo_doc_json_rule = rule(
    impl = _impl,
    doc = "The `mojo doc` JSON of the mojo_library `lib`, as `<name>.json`; with `golden` it must equal that file byte for byte, and with `symbols` it must declare each dotted path. See doc.bzl.",
    attrs = {
        "golden": attrs.option(attrs.source(), default = None),
        "lib": attrs.dep(providers = [MojoInfo]),
        "symbols": attrs.list(attrs.string(), default = []),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
        "_doc_check": attrs.exec_dep(default = "komira//tools/build/mojo:doc_check"),
        "_inspect": attrs.exec_dep(default = "komira//tools/build/inspect:inspect[runnable]"),
    },
)

mojo_doc_json = declares_docs(mojo_doc_json_rule)
