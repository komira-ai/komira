"""What native code a library's Mojo closure links, and which library ships it.

docs/design/native_packaging.md, slice 8 ("the packer"). A library that owns
C ships it in its own conda package: `native = ":<name>_native"` names its
shared library (tools/build/native/shared.bzl), whose `archives` must be
exactly the library's C `deps`; `native_static = True` ships those C `deps` as
static archives instead, for per-library state only (komira_log's holder:
docs/design/native_packaging.md, "Per-library state"). Either way the library
SHIPS each C library among its direct `deps`.

`native_facts` carries three sets up the Mojo closure (MojoInfo.native):

  * `linked`: every C library a library of the closure lists in its
    `deps` (by label);
  * `shipped`: those of them a library of the closure ships, mapped to
    its import name;
  * `sonames`: the SONAME of each shared library the closure ships,
    mapped to its import name: the komira owners a packed `.so` may name in
    `NEEDED` (`komira_pack conda --closure-owner`).

A library whose closure links a C library no library of the closure ships has
no conda package (`native_refusal`, read by `_conda_facts` in defs.bzl): a
`.mojoc` holds no machine code, so its consumers would fail at their link.
"""

load("@prelude//linking:link_info.bzl", "MergedLinkInfo")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load(":providers.bzl", "MojoInfo")

NATIVE_ATTRS = {
    # The library's own shared library, `<name>_native` (a label, not a dep:
    # that target reads this library's sources, so a dep would be a cycle).
    # Its conda package depends on it (tools/build/package/conda.bzl).
    "native": attrs.option(attrs.label(), default = None),
    # Ship the C `deps` as static archives (lib/lib<name>.a): per-library
    # state only, which a shared copy would merge across images.
    "native_static": attrs.bool(default = False),
}

def native_soname(import_name):
    """The SONAME of a library's own shared library (shared.bzl writes it)."""
    return "lib{}_native.so.1".format(import_name)

def _c_deps(ctx):
    return [d for d in ctx.attrs.deps if MojoInfo not in d and MergedLinkInfo in d]

def native_facts(ctx, import_name):
    """struct of the library's native facts: the three closure sets above,
    `c_direct` (the labels of its own C deps), `soname` (its own shared
    library's, or None) and `static` (a list of [package path, archive])."""
    c_deps = _c_deps(ctx)
    c_direct = sorted([str(d.label.raw_target()) for d in c_deps])
    if ctx.attrs.native != None and ctx.attrs.native_static:
        fail("{}: `native` and `native_static` both set; a library ships its C one way".format(ctx.label))
    ships = ctx.attrs.native != None or ctx.attrs.native_static
    if ships and not c_direct:
        fail("{}: `native` or `native_static` is set, but no dep is a C library".format(ctx.label))
    linked = {}
    shipped = {}
    sonames = {}
    for d in ctx.attrs.deps:
        if MojoInfo in d and d[MojoInfo].native != None:
            facts = d[MojoInfo].native
            linked.update(facts.linked)
            shipped.update(facts.shipped)
            sonames.update(facts.sonames)
    for c in c_direct:
        linked[c] = True
        if ships:
            shipped[c] = import_name
    soname = None
    if ctx.attrs.native != None:
        soname = native_soname(import_name)
        sonames[soname] = import_name
    static = []
    if ctx.attrs.native_static:
        for d in c_deps:
            subs = d[DefaultInfo].sub_targets
            if "static-pic" not in subs:
                fail("{}: native_static: {} has no [static-pic] archive (not a cxx_library?)".format(ctx.label, d.label.raw_target()))
            static.append(["lib/lib{}.a".format(d.label.name), subs["static-pic"][DefaultInfo].default_outputs[0]])
    return struct(c_direct = c_direct, linked = linked, shipped = shipped, sonames = sonames, soname = soname, static = static)

def native_unshipped(facts):
    """The C libraries the closure links that no library of it ships, sorted."""
    return sorted([c for c in facts.linked if c not in facts.shipped])

def native_refusal(label, facts):
    """Why the library has no conda package for its native code, or None."""
    unshipped = native_unshipped(facts)
    if not unshipped:
        return None
    return "{} links native code that no library of its Mojo deps closure ships ({}). A `.mojoc` holds none, so a consumer would fail at its own link; the library owning it ships it (`native` or `native_static` on that mojo_library) and is a dep".format(label.raw_target(), ", ".join(unshipped))

def _native_refusal_test_impl(ctx):
    info = ctx.attrs.lib[MojoInfo]
    lib = ctx.attrs.lib.label.raw_target()
    want = sorted([str(l.raw_target()) for l in ctx.attrs.unshipped])
    got = native_unshipped(info.native) if info.native != None else []
    if got != want:
        fail("{}: {} links {} that no library of its closure ships; the test states {}".format(ctx.label, lib, got, want))
    refusal = info.conda_refusal or ""
    for w in want:
        if "links native code" not in refusal or w not in refusal:
            fail("{}: the conda refusal of {} is `{}`; it must say it links native code no library ships, naming {}".format(ctx.label, lib, refusal, w))
    if not want and "links native code" in refusal:
        fail("{}: {} is refused for native code its closure ships: {}".format(ctx.label, lib, refusal))
    out = ctx.actions.write(ctx.label.name + ".passed", "{}: unshipped {}\n".format(lib, want))
    return [DefaultInfo(default_output = out)]

# Fails at analysis unless `lib`'s closure links exactly `unshipped` without
# a library of the closure shipping it, and its conda package is refused for
# native code exactly when that is not empty (tools/build/native/BUCK).
_native_refusal_test = rule(
    impl = _native_refusal_test_impl,
    attrs = {
        "lib": attrs.dep(providers = [MojoInfo]),
        "unshipped": attrs.list(attrs.label(), default = []),
    },
)

native_refusal_test = declares_docs(_native_refusal_test)
