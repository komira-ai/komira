"""The native-reach check of mojo_library (README.md, "Native reach").

A library's conda package requires the packages of its Mojo `deps` and
nothing else (tools/build/package/conda.bzl). So every library whose native
code a library reaches must be in that library's Mojo deps closure, or the
installed package lacks it. The owner of an archive is the mojo_library that
ships it: the library of its own package (`//src/<name>:<name>`) for a
`cxx_library` under src/, and the `THIRD_PARTY_OWNERS` row of its package
(tools/build/one_definition/libraries.bzl) for a vendored one. A library
built with buildrules' `mojo_package` is in a closure by its adopted label
(`//src/<name>:<name>`, adopt.bzl), though the file its dependents import is
the package's `:lib`.

Two validations, each failing the build of the library and of every target
holding it:

  * `native_reach_archives`, decided at analysis: each archive the library's
    own C/C++ `deps` link (with every archive those need, as the prelude's
    link info carries them) has its owner in the closure, or is the
    library's own. An archive of a third_party package with no owner row, or
    with a row naming no owner, is refused. The archives a Mojo dependency
    brings are that dependency's to answer for.
  * `native_reach_calls`, a run of the Zig tool native_reach/: no string in
    the library's sources (its tests are not among them) starts with the
    symbol prefix of an owner outside the closure (an `external_call` of a
    prefixed vendored name). Without a tool (a target platform other than
    linux-x86_64) or with no such owner, its result is written here.

Libraries under src/tests/ are exempt: no package ships them.
"""

load("@prelude//linking:link_info.bzl", "LinkStrategy", "MergedLinkInfo")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/one_definition:libraries.bzl", "THIRD_PARTY_OWNERS")
load(":providers.bzl", "MojoInfo", "mojo_pkg_children")
load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")

NATIVE_REACH_ATTRS = {
    # The Zig scanner (native_reach/), set by the macro on linux-x86_64.
    "native_reach": attrs.option(attrs.exec_dep(providers = [RunInfo]), default = None),
}

def native_reach_kwargs(kwargs):
    """Sets mojo_library's `native_reach` tool."""
    if "native_reach" in kwargs:
        fail("{}: `native_reach` is set by mojo_library; do not pass it".format(kwargs.get("name", "")))
    kwargs["native_reach"] = select({
        "komira//tools/build/package:is_linux_x86_64": "komira//tools/build/mojo/native_reach:native_reach",
        "DEFAULT": None,
    })

def _label(cell, package, name):
    return "{}//{}:{}".format(cell, package, name)

def _owner(label):
    """(owner label or None, refusal or None) of the archive `label` produces."""
    parts = label.package.split("/")
    if parts[0] == "src" and len(parts) == 2 and parts[1] != "tests":
        return _label(label.cell, label.package, parts[1]), None
    if parts[0] == "third_party" and len(parts) >= 2:
        row = THIRD_PARTY_OWNERS.get("third_party/" + parts[1])
        if row == None:
            return None, "third_party/{} has no row in THIRD_PARTY_OWNERS (tools/build/one_definition/libraries.bzl): name the library that ships it".format(parts[1])
        if row.owner == None:
            return None, "no library ships third_party/{} (THIRD_PARTY_OWNERS)".format(parts[1])
        return label.cell + row.owner, None
    return None, None

def _archives(info):
    """The labels of the targets producing each archive or object `info` (a MergedLinkInfo) links."""
    tset = info._infos.get(LinkStrategy("static_pic"))
    if tset == None:
        return []
    out = []
    for infos in tset.traverse():
        for l in infos.default.linkables:
            arts = []
            if hasattr(l, "archive"):
                arts = [l.archive.artifact]
            elif hasattr(l, "objects") and l.objects:
                arts = l.objects
            elif hasattr(l, "lib"):
                arts = [l.lib]
            for a in arts:
                if a.owner != None:
                    out.append(a.owner.raw_target())
    return out

def _result(ctx, name, failed, message):
    return ctx.actions.write_json("native_reach/{}.json".format(name), {
        "data": {"message": message, "status": "failure" if failed else "success"},
        "version": 1,
    })

def native_reach(ctx, src_dir, deps):
    """(providers, sub-targets) of the check: a ValidationInfo, and
    `[native_reach]`, its two results, which build without the library's
    tests. ([], {}) for a library under src/tests/.

    `src_dir` is the staged library sources, `deps` the MojoPkgTSet children
    of the library's Mojo deps (its closure)."""
    me = ctx.label.raw_target()
    if (ctx.label.package + "/").startswith("src/tests/"):
        return [], {}
    self_label = _label(me.cell, me.package, me.name)
    closure = {self_label: True}
    for t in deps:
        for pkg in t.traverse():
            if pkg.owner != None:
                o = pkg.owner.raw_target()
                closure[_label(o.cell, o.package, o.name)] = True

                # A library built with buildrules (adopt.bzl) makes its file as `:lib` of its package, and the label its
                # dependents name, `//src/<name>:<name>`, is the adopted one: the owner rows name that label.
                parts = o.package.split("/")
                if o.name == "lib" and len(parts) == 2 and parts[0] == "src":
                    closure[_label(o.cell, o.package, parts[1])] = True

    findings = []
    checked = {}
    for d in ctx.attrs.deps:
        if MojoInfo in d or MergedLinkInfo not in d:
            continue
        for a in _archives(d[MergedLinkInfo]):
            checked[str(a)] = True
            owner, refusal = _owner(a)
            via = "" if a == d.label.raw_target() else " through {}".format(d.label.raw_target())
            if refusal != None:
                findings.append("links {}{}: {}".format(a, via, refusal))
            elif owner != None and owner not in closure:
                findings.append("links {}{}, which {} owns; {} is not in its Mojo deps closure: depend on {}".format(a, via, owner, owner, owner))
    findings = sorted({f: True for f in findings}.keys())
    if findings:
        msg = "{} reaches native code its package would not require (tools/build/mojo/native_reach.bzl):\n{}".format(self_label, "\n".join(findings))
    else:
        msg = "{}: {} linked archive(s) checked; each owner is in its Mojo deps closure".format(self_label, len(checked))
    archives = _result(ctx, "archives", len(findings) > 0, msg)
    specs = [ValidationSpec(name = "native_reach_archives", validation_result = archives)]

    # The vendored archives are the komira cell's, so are their owners.
    refuse = []
    for _package, row in sorted(THIRD_PARTY_OWNERS.items()):
        if row.prefix and row.owner != None and "komira" + row.owner not in closure:
            refuse.append("{}={}".format(row.prefix, "komira" + row.owner))
    if refuse and ctx.attrs.native_reach != None:
        calls = ctx.actions.declare_output("native_reach/calls.json")
        ctx.actions.run(
            cmd_args(
                ctx.attrs.native_reach[RunInfo],
                "--out",
                calls.as_output(),
                "--library",
                self_label,
                "--src",
                src_dir,
                [["--refuse", r] for r in refuse],
            ),
            env = salted(),
            category = "native_reach",
        )
    else:
        why = "no tool on this platform" if refuse else "every prefixed owner is in its Mojo deps closure"
        calls = _result(ctx, "calls", False, "{}: sources not read ({})".format(self_label, why))
    specs.append(ValidationSpec(name = "native_reach_calls", validation_result = calls))
    return [ValidationInfo(validations = specs)], {"native_reach": [DefaultInfo(default_outputs = [archives, calls])]}

# The check's own cases (tools/build/tests/negative/native_reach): a
# `native_reach_case` runs `native_reach` above, unchanged, on its own
# `srcs` and `deps` as a `mojo_library` with them would, and passes only when
# each half answers as its case says: refused, naming every text of
# `expect_archives` (or `expect_calls`), or passed when the list is empty.
# The library's own validations are not returned, so a refusal is the case's
# green, and a check that stops refusing is its red.

def _case_impl(actions, archives, calls, out, expect):
    wrong = []
    for half, value in [("archives", archives), ("calls", calls)]:
        data = value.read_json()["data"]
        want = expect[half]
        if not want:
            if data["status"] != "success":
                wrong.append("native_reach_{} refused a case it must pass: {}".format(half, data["message"]))
        elif data["status"] != "failure":
            wrong.append("native_reach_{} passed a case it must refuse naming {}: {}".format(half, want, data["message"]))
        else:
            missing = [w for w in want if w not in data["message"]]
            if missing:
                wrong.append("native_reach_{} refused without naming {}: {}".format(half, missing, data["message"]))
    actions.write_json(out, {
        "data": {
            "message": "\n".join(wrong) if wrong else "each half answered as the case expects",
            "status": "failure" if wrong else "success",
        },
        "version": 1,
    })
    return []

_case = dynamic_actions(
    impl = _case_impl,
    attrs = {
        "archives": dynattrs.artifact_value(),
        "calls": dynattrs.artifact_value(),
        "expect": dynattrs.value(typing.Any),
        "out": dynattrs.output(),
    },
)

def _native_reach_case_impl(ctx):
    src_dir = ctx.actions.copied_dir("src", {s.short_path: s for s in ctx.attrs.srcs})
    deps = mojo_pkg_children(ctx, [d[MojoInfo] for d in ctx.attrs.deps if MojoInfo in d])
    _providers, subs = native_reach(ctx, src_dir, deps)
    if "native_reach" not in subs:
        fail("{}: native_reach checked nothing (a case under src/tests/?)".format(ctx.label))
    archives, calls = subs["native_reach"][0].default_outputs
    out = ctx.actions.declare_output("native_reach_case/{}.json".format(ctx.label.name))
    ctx.actions.dynamic_output_new(_case(
        archives = archives,
        calls = calls,
        expect = {"archives": ctx.attrs.expect_archives, "calls": ctx.attrs.expect_calls},
        out = out.as_output(),
    ))
    return [
        DefaultInfo(default_output = out),
        ValidationInfo(validations = [ValidationSpec(name = "native_reach_case", validation_result = out)]),
    ]

_native_reach_case_rule = rule(
    impl = _native_reach_case_impl,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = []),
        "expect_archives": attrs.list(attrs.string(), default = []),
        "expect_calls": attrs.list(attrs.string(), default = []),
        "srcs": attrs.list(attrs.source(), default = []),
    } | NATIVE_REACH_ATTRS,
)

def _native_reach_case(**kwargs):
    """A case of the check (above): `srcs`, `deps`, `expect_archives`, `expect_calls`."""
    native_reach_kwargs(kwargs)
    _native_reach_case_rule(**kwargs)

# Through declares_docs, as every komira rule a BUCK file calls: a package
# holding only cases (tests//src/native_reach) still declares its doc_tree.
native_reach_case = declares_docs(_native_reach_case)
