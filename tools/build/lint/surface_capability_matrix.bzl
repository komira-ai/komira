"""surface_capability_matrix: which capability of the plan each surface's end-to-end tests exercise.

komira is reached through surfaces (the pandas and polars frontends, SQL, the
Mojo and TypeScript polars-shaped APIs, Excel). Product coverage is every
capability of the plan exercised through every surface by an end-to-end test
of that surface. This lint holds the ledger of that, one row per
(surface, capability) pair naming the test target that exercises it (or `-`),
and writes the census. The rules are in docs/surface_capability_matrix.md
and in the action, surface_capability_matrix.sh.

The ledger is Starlark data (tests/surface_capability_matrix.bzl for the root
target), not a TSV, because a row's test target must exist and only the
build graph can say so: the macro collects every target the rows name into
`targets`, a dependency attribute, so a target that does not exist fails the
build at graph construction (Buck2's "Unknown target"), before any action.
A rule cannot read a file at load time, and a query attribute takes labels,
not a file, so no other place can feed the graph (test_weld.bzl, "WHY A BXL
SCRIPT CHECKS IT").

A validation, like the lints in defs.bzl. Its analysis resolves each named
target: the package Buck2 puts it in, and whether it is a test (it carries
ExternalRunnerTestInfo, as every test rule does, or the WeldedTestsInfo of a
mojo_library whose test_srcs run as build actions). The action reads that,
the vocabulary and the grounding files, and finds:

- a row naming an unknown surface or capability, a pair with two rows, a
  pair with none, a row with an empty field;
- a target outside its surface's own package,
  `<root>/tests/e2e/<surface>_e2e` of this cell exactly (not a subpackage,
  not a longer name), or one whose default outputs a target of another
  package made (an `alias` forwards its actual target's providers, so an
  alias in the surface's package standing for a test elsewhere is refused),
  a target that is no test, or a target that already fills another cell of
  the same surface (each filled cell names a test of its own);
- a vocabulary that is not grounded in the plan: a capability name repeated
  or malformed, a grounding identifier no grounding file declares (as
  `comptime <ID>: UInt8 = ...` or `comptime <ID> = UInt8(...)`), a
  declared identifier of a grounding family (a prefix `grounding` names for
  its file) that no capability and no `not_capabilities` row names, so a new
  plan tag, join kind or source kind fails here until it is classified, or a
  family identifier declared in a form the lint cannot read;
- fewer filled cells than `floor` (that the floor is raised with each filled
  cell and never lowered is a review rule, not this lint's);

A missing cell (`-`) is never a finding: the census counts and lists it.

`expect_matrix` and `expect_report`, for a fixture, are the exact `[matrix]`
and `[report]` files the census must write; any difference is a finding.

The grounding files come from `tree` (a doc_tree target: the root one holds
every file of the cell; only the files `grounding` names are inputs) or, for
a fixture, from `files` ({path in the tree: source}), never both.
"""

load("@komira//tools/build/mojo:providers.bzl", "WeldedTestsInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":doc_tree.bzl", "DocTreeInfo", "declares_docs")

def _named(ctx, f):
    """`f` and the name findings give it (see readme_api_coverage.bzl)."""
    if f == None:
        return ["-", "-"]
    if f.owner != None:
        return [f, str(f.owner.raw_target())]
    package = "{}//{}".format(ctx.label.cell, ctx.label.package + "/" if ctx.label.package else "")
    return [f, package + f.short_path]

def _is_test(dep):
    if ExternalRunnerTestInfo in dep:
        return True
    return WeldedTestsInfo in dep and len(dep[WeldedTestsInfo].srcs) > 0

def _made_by(dep):
    """Where `dep`'s default outputs were made: the comma-separated packages,
    and the comma-separated targets, that declared them (source files have
    no maker), each `-` when none has one. An `alias` forwards its actual
    target's providers, so its outputs name the target it stands for, not
    itself."""
    packages, targets = {}, {}
    for out in dep[DefaultInfo].default_outputs:
        if out.owner != None:
            packages["{}//{}".format(out.owner.cell, out.owner.package)] = True
            targets[str(out.owner.raw_target())] = True
    return ",".join(sorted(packages.keys())) or "-", ",".join(sorted(targets.keys())) or "-"

def _tsv(fields):
    for f in fields:
        if "\t" in f or "\n" in f:
            fail("a field holds a tab or a newline: {}".format(repr(f)))
    return "\t".join(fields)

def _lines(lines):
    return "".join([l + "\n" for l in lines])

def _surface_capability_matrix_impl(ctx):
    if (ctx.attrs.tree == None) == (not ctx.attrs.files):
        fail("surface_capability_matrix {}: name the files in exactly one of `tree` and `files`".format(ctx.label))
    if not ctx.attrs.grounding:
        fail("surface_capability_matrix {}: `grounding` names no file, so no capability is grounded".format(ctx.label))
    if ctx.attrs.floor < 0:
        fail("surface_capability_matrix {}: `floor` is a count of filled cells, not {}".format(ctx.label, ctx.attrs.floor))
    available = ctx.attrs.tree[DocTreeInfo].files if ctx.attrs.tree != None else ctx.attrs.files
    staged = {}
    families = []
    for path, prefixes in ctx.attrs.grounding.items():
        if path not in available:
            fail("surface_capability_matrix {}: `grounding` names {}, which is no file of the tree".format(ctx.label, path))
        staged[path] = available[path]
        families.append(_tsv([path, ",".join(prefixes) or "-"]))
    ground = ctx.actions.copied_dir("grounding", staged)

    # The rows as the action reads them: what the ledger says, then what the
    # graph says of its target (the package Buck2 puts it in, whether it is
    # a test, the packages that made its default outputs, and which test it
    # is), `-` for an empty cell.
    rows = []
    for i, row in enumerate(ctx.attrs.rows):
        surface, capability, target, note = row
        package, test, made, ident = "-", "-", "-", "-"
        if target not in ("-", ""):
            dep = ctx.attrs.targets[target]
            package = "{}//{}".format(dep.label.cell, dep.label.package)
            test = "yes" if _is_test(dep) else "no"
            made, makers = _made_by(dep)

            # The test a row names, however it is spelt: the targets that
            # made its outputs, else its own label.
            ident = makers if makers != "-" else str(dep.label.raw_target())
        rows.append(_tsv([str(i + 1), surface, capability, target, note, package, test, made, ident]))
    caps = [_tsv([c[0], c[1], c[2]]) for c in ctx.attrs.capabilities]
    nots = [_tsv([n[0], n[1]]) for n in ctx.attrs.not_capabilities]
    inputs = ctx.actions.write("inputs/rows.tsv", _lines(rows))
    surfaces = ctx.actions.write("inputs/surfaces.txt", _lines([_tsv([s]) for s in ctx.attrs.surfaces]))
    capabilities = ctx.actions.write("inputs/capabilities.tsv", _lines(caps))
    not_capabilities = ctx.actions.write("inputs/not_capabilities.tsv", _lines(nots))
    family_file = ctx.actions.write("inputs/families.tsv", _lines(families))

    findings = ctx.actions.declare_output("findings.txt")
    matrix = ctx.actions.declare_output("surface_capability_matrix.tsv")
    report = ctx.actions.declare_output("surface_capability_matrix.txt")
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            ctx.attrs._script,
            "census",
            bb,
            findings.as_output(),
            matrix.as_output(),
            report.as_output(),
            surfaces,
            capabilities,
            not_capabilities,
            inputs,
            family_file,
            ground,
            "{}//{}".format(ctx.label.cell, ctx.attrs.root),
            str(ctx.attrs.floor),
            _named(ctx, ctx.attrs.expect_matrix),
            _named(ctx, ctx.attrs.expect_report),
        ),
        category = "lint_surface_capability_matrix",
    )
    result = ctx.actions.declare_output("validation.json")
    ctx.actions.run(
        cmd_args(bb, "sh", ctx.attrs._script, "verdict", bb, result.as_output(), findings, report),
        category = "lint_surface_capability_matrix_verdict",
    )
    return [
        DefaultInfo(
            default_outputs = [matrix, report],
            sub_targets = {
                "matrix": [DefaultInfo(default_output = matrix)],
                "report": [DefaultInfo(default_output = report)],
            },
        ),
        ValidationInfo(validations = [ValidationSpec(name = "surface_capability_matrix", validation_result = result)]),
    ]

_surface_capability_matrix_rule = rule(
    impl = _surface_capability_matrix_impl,
    doc = "The surface x capability matrix: one row per (surface, capability) naming the surface e2e test target that exercises it, or `-`; writes the census, fails on a malformed or lying row, an ungrounded vocabulary, or fewer filled cells than `floor`. See surface_capability_matrix.bzl.",
    attrs = {
        # (name, grounding, meaning): grounding is `contract` (a promise of
        # every surface the plan holds no node for) or comma-separated
        # identifiers a grounding file declares.
        "capabilities": attrs.list(attrs.tuple(attrs.string(), attrs.string(), attrs.string())),
        "expect_matrix": attrs.option(attrs.source(), default = None),
        "expect_report": attrs.option(attrs.source(), default = None),
        "files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        # The build fails with fewer filled cells. Raising it with each filled
        # cell, and never lowering it, is a review rule.
        "floor": attrs.int(default = 0),
        # {path in the tree: identifier prefixes}: the files that declare the
        # grounding identifiers; every declared `comptime <prefix>...: UInt8`
        # must be named by a capability or a `not_capabilities` row.
        "grounding": attrs.dict(attrs.string(), attrs.list(attrs.string())),
        # (comma-separated identifiers, reason): plan constants that are no capability.
        "not_capabilities": attrs.list(attrs.tuple(attrs.string(), attrs.string()), default = []),
        # A surface's tests live in <root>/tests/e2e/<surface>_e2e of this cell.
        "root": attrs.string(default = "src"),
        # (surface, capability, test target or `-`, note).
        "rows": attrs.list(attrs.tuple(attrs.string(), attrs.string(), attrs.string(), attrs.string())),
        "surfaces": attrs.list(attrs.string()),
        # Filled by the macro: every target the rows name, keyed as written.
        "targets": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "tree": attrs.option(attrs.dep(providers = [DocTreeInfo]), default = None),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_script": attrs.source(default = "komira//tools/build/lint:surface_capability_matrix.sh"),
    },
)

def _surface_capability_matrix(**kwargs):
    if "targets" in kwargs:
        fail("surface_capability_matrix {}: `targets` is filled from `rows`; name the tests there".format(kwargs.get("name", "")))
    targets = {}
    for row in kwargs.get("rows", []):
        if len(row) == 4 and row[2] not in ("-", ""):
            targets[row[2]] = row[2]
    kwargs["targets"] = targets
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _surface_capability_matrix_rule(**kwargs)

surface_capability_matrix = declares_docs(_surface_capability_matrix)
