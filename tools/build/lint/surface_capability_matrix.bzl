"""surface_capability_matrix: which capability of the plan each surface's end-to-end tests exercise.

komira is reached through surfaces (the pandas and polars frontends, SQL, the
Mojo and TypeScript polars-shaped APIs, Excel). Product coverage is every
capability of the plan exercised through every surface by an end-to-end test
of that surface. This lint holds the ledger of that, one row per
(surface, capability) pair naming the test target that exercises it (or `-`),
and writes the census. The rules are in docs/surface_capability_matrix.md.

The ledger is Starlark data (tests/surface_capability_matrix.bzl for the root
target), not a TSV, because a row's test target must exist and only the
build graph can say so: the macro collects every target the rows name into
`targets`, a dependency attribute, so a target that does not exist fails the
build at graph construction (Buck2's "Unknown target"), before any action.
A rule cannot read a file at load time, and a query attribute takes labels,
not a file, so no other place can feed the graph (test_weld.bzl, "WHY A BXL
SCRIPT CHECKS IT").

Two halves. The analysis checks everything the build graph and the
attributes hold, and fails (`fail()`, every finding at once) before any
action runs. It resolves each named target: the package Buck2 puts it in,
and whether it is a test (it carries ExternalRunnerTestInfo, as every test
rule does, or the WeldedTestsInfo of a mojo_library whose test_srcs run as
build actions). Then a validation, like the lints in defs.bzl, runs the Zig
tool //tools/build/lint/surface_grounding over the grounding files, which
only an action can read. Between them they find:

- (analysis) a row naming an unknown surface or capability, a pair with two
  rows, a pair with none, a row with an empty field;
- (analysis) a target outside its surface's own package,
  `<root>/tests/e2e/<surface>_e2e` of this cell exactly (not a subpackage,
  not a longer name), or one whose default outputs a target of another
  package made (an `alias` forwards its actual target's providers, so an
  alias in the surface's package standing for a test elsewhere is refused),
  a target that is no test, or a target that already fills another cell of
  the same surface (each filled cell names a test of its own);
- a vocabulary that is not grounded in the plan: (analysis) a surface or
  capability name repeated or malformed, a capability with no meaning, a
  not_capabilities row with no reason, a grounding that is not a list of
  identifiers; (the tool) a grounding identifier no grounding file declares (as
  `comptime <ID>: UInt8 = ...` or `comptime <ID> = UInt8(...)`), a
  declared identifier of a grounding family (a prefix `grounding` names for
  its file) that no capability and no `not_capabilities` row names, so a new
  plan tag, join kind or source kind fails here until it is classified, or a
  family identifier declared in a form the lint cannot read;
- (analysis) fewer filled cells than `floor` (that the floor is raised with
  each filled cell and never lowered is a review rule, not this lint's), or
  no surface or no capability at all;

A missing cell (`-`) is never a finding: the census counts and lists it.

The census, `[matrix]` and `[report]`, is written by the analysis.
`expect_matrix` and `expect_report`, for a fixture, are the exact files it
must equal; the tool reports any difference.

The grounding files come from `tree` (a doc_tree target: the root one holds
every file of the cell; only the files `grounding` names are inputs) or, for
a fixture, from `files` ({path in the tree: source}), never both.
"""

load("@komira//tools/build/mojo:providers.bzl", "WeldedTestsInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":doc_tree.bzl", "DocTreeInfo", "declares_docs")

def _name_of(ctx, f):
    """The name findings give the source `f` (see readme_api_coverage.bzl)."""
    if f.owner != None:
        return str(f.owner.raw_target())
    package = "{}//{}".format(ctx.label.cell, ctx.label.package + "/" if ctx.label.package else "")
    return package + f.short_path

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

def _isname(s):
    return regex_match("^[a-z][a-z0-9_]*$", s)

def _left(s, width):
    return s + " " * (width - len(s)) if len(s) < width else s

def _right(s, width):
    return " " * (width - len(s)) + s if len(s) < width else s

def _pct(x, y):
    """100 * x / y to one decimal, then `%`, as C's `%.1f%%` prints it: a tie
    goes to the even tenth (below 2000 cells every tie is a quarter, exact in
    binary, so this is what printf gives). `-` when y is 0."""
    if y == 0:
        return "-"
    tenths = 1000 * x // y
    rest = 1000 * x % y
    if 2 * rest > y or (2 * rest == y and tenths % 2 == 1):
        tenths += 1
    return "{}.{}%".format(tenths // 10, tenths % 10)

def _grounded(what, grounding, bad, named):
    """Checks `grounding` (comma-separated identifiers) of `what`, appending
    each identifier, as `what<TAB>id`, to `named` for the tool."""
    ids = grounding.split(",") if grounding else []
    if not ids:
        bad.append(what + ": no grounding identifier")
    for i in ids:
        if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", i):
            bad.append("{}: grounding `{}` is not an identifier".format(what, i))
            continue
        named.append(_tsv([what, i]))

def _report(floor, cells):
    """The human summary of `cells`, (surface, capability, status) in matrix
    order; its third line is the totals."""
    surfaces, capabilities = [], []
    scell, sfill, ccell, cfill, cby = {}, {}, {}, {}, {}
    missing = []
    filled = 0
    for s, c, status in cells:
        if s not in scell:
            surfaces.append(s)
            scell[s], sfill[s] = 0, 0
        if c not in ccell:
            capabilities.append(c)
            ccell[c], cfill[c], cby[c] = 0, 0, ""
        scell[s] += 1
        ccell[c] += 1
        if status == "filled":
            filled += 1
            sfill[s] += 1
            cfill[c] += 1
            cby[c] += " " + s
        else:
            missing.append("  {} {}".format(s, c))
    out = [
        "Surface capability matrix (floor {})".format(floor),
        "",
        "cells: {}; filled: {} ({}); missing: {}".format(len(cells), filled, _pct(filled, len(cells)), len(cells) - filled),
        "",
        "by surface: filled/cells, percent",
    ]
    for s in surfaces:
        out.append("  {} {}/{} {}".format(_left(s, 16), _right(str(sfill[s]), 4), _left(str(scell[s]), 4), _right(_pct(sfill[s], scell[s]), 7)))
    out += ["", "by capability: filled/surfaces, the surfaces filled"]
    for c in capabilities:
        out.append("  {} {}/{} {}".format(_left(c, 16), _right(str(cfill[c]), 4), _left(str(ccell[c]), 4), cby[c] or " -"))
    out += ["", "missing (surface capability):"] + missing
    return out

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

    # Every finding the attributes and the build graph show, collected and
    # then failed at once, in this order: the vocabulary, the rows, the pairs
    # with no row, the floor.
    bad = []
    named = []
    surfaces = []
    for s in ctx.attrs.surfaces:
        if not _isname(s):
            bad.append("surfaces: `{}` is not a name ([a-z][a-z0-9_]*)".format(s))
        elif s in surfaces:
            bad.append("surfaces: {} is listed twice".format(s))
        else:
            surfaces.append(s)
    capabilities = []
    for name, grounding, meaning in ctx.attrs.capabilities:
        if not _isname(name):
            bad.append("capabilities: `{}` is not a name ([a-z][a-z0-9_]*)".format(name))
            continue
        if name in capabilities:
            bad.append("capabilities: {} is listed twice".format(name))
            continue
        capabilities.append(name)
        if not meaning.strip():
            bad.append("capability {}: no meaning".format(name))
        if grounding != "contract":
            _grounded("capability " + name, grounding, bad, named)
    for i, row in enumerate(ctx.attrs.not_capabilities):
        ids, reason = row
        if not reason.strip():
            bad.append("not_capabilities row {} ({}): no reason".format(i + 1, ids))
        _grounded("not_capabilities row {}".format(i + 1), ids, bad, named)

    # Each row against the vocabulary, and its target against the build
    # graph: the package Buck2 puts it in, whether it is a test, the packages
    # that made its default outputs, and which test it is however spelt.
    root = "{}//{}".format(ctx.label.cell, ctx.attrs.root)
    first, status, target, note_of, filler = {}, {}, {}, {}, {}
    filled = 0
    for i, row in enumerate(ctx.attrs.rows):
        s, c, t, note = row
        n = i + 1
        key = (s, c)
        where = "matrix row {} ({}, {})".format(n, s, c)
        if s == "" or c == "" or t == "":
            bad.append(where + ": an empty field (surface, capability and target are required; the target is `-` when none)")

            # The pair has its row, a malformed one: not also "no row".
            if key not in first:
                first[key], status[key], target[key], note_of[key] = n, "missing", t, note
            continue
        ok = True
        if s not in surfaces:
            bad.append("{}: unknown surface `{}`".format(where, s))
            ok = False
        if c not in capabilities:
            bad.append("{}: unknown capability `{}`".format(where, c))
            ok = False
        if not ok:
            continue
        if key in first:
            bad.append("{}: a second row for the pair, first at row {}".format(where, first[key]))
            continue
        first[key] = n
        if t != "-":
            dep = ctx.attrs.targets[t]
            package = "{}//{}".format(dep.label.cell, dep.label.package)
            want = root + "/tests/e2e/" + s + "_e2e"
            made, makers = _made_by(dep)
            if package != want:
                bad.append("{}: {} is in {}, not {}, the surface's own package".format(where, t, package, want))
            elif made != "-":
                for mk in made.split(","):
                    if mk != want:
                        bad.append("{}: {} stands for a target of {} (its outputs are made there, as an alias's are), not of {}".format(where, t, mk, want))
            if not _is_test(dep):
                bad.append("{}: {} is no test (it has no ExternalRunnerTestInfo and welds no test_srcs)".format(where, t))

            # The test a row names, however it is spelt: the targets that
            # made its outputs, else its own label.
            ident = makers if makers != "-" else str(dep.label.raw_target())
            if (s, ident) in filler:
                at, cap = filler[(s, ident)]
                bad.append("{}: {} fills ({}, {}) already, at row {}; each filled cell of a surface names a test of its own".format(where, t, s, cap, at))
            else:
                filler[(s, ident)] = (n, c)
            filled += 1
            status[key] = "filled"
        else:
            status[key] = "missing"
        target[key], note_of[key] = t, note

    matrix = ["surface\tcapability\tstatus\ttarget\tnote"]
    cells = []
    for s in surfaces:
        for c in capabilities:
            key = (s, c)
            if key not in status:
                bad.append("matrix: no row for ({}, {}); every pair has one, its target `-` when no test exercises it".format(s, c))
                continue
            matrix.append(_tsv([s, c, status[key], target[key], note_of[key]]))
            cells.append((s, c, status[key]))
    if filled < ctx.attrs.floor:
        bad.append("floor: {} cell(s) are filled and the floor is {}: a filled cell was emptied or lost its test (lowering the floor is for review to refuse)".format(filled, ctx.attrs.floor))
    if not surfaces or not capabilities:
        bad.append("surface_capability_matrix: checked nothing (no surface or no capability)")
    if bad:
        fail("surface_capability_matrix: {} finding line(s)\n{}".format(len(bad), "\n".join(bad[:200])))

    report = _report(ctx.attrs.floor, cells)
    matrix_file = ctx.actions.write("surface_capability_matrix.tsv", _lines(matrix))
    report_file = ctx.actions.write("surface_capability_matrix.txt", _lines(report))

    # The grounding files, which only an action can read, and a fixture's
    # census against its expected files: the tool's validation.
    compare = []
    for got, want in [(matrix_file, ctx.attrs.expect_matrix), (report_file, ctx.attrs.expect_report)]:
        if want != None:
            compare += ["--got", got, "--want", want, "--want-name", _name_of(ctx, want)]
    result = ctx.actions.declare_output("validation.json")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._tool[RunInfo],
            "--grounding",
            ground,
            "--families",
            ctx.actions.write("inputs/families.tsv", _lines(families)),
            "--named",
            ctx.actions.write("inputs/named.tsv", _lines(named)),
            "--totals",
            report[2],
            "--out",
            result.as_output(),
            compare,
        ),
        category = "lint_surface_capability_matrix",
    )
    return [
        DefaultInfo(
            default_outputs = [matrix_file, report_file],
            sub_targets = {
                "matrix": [DefaultInfo(default_output = matrix_file)],
                "report": [DefaultInfo(default_output = report_file)],
            },
        ),
        ValidationInfo(validations = [ValidationSpec(name = "surface_capability_matrix", validation_result = result)]),
    ]

_surface_capability_matrix_rule = rule(
    impl = _surface_capability_matrix_impl,
    doc = "The surface x capability matrix: one row per (surface, capability) naming the surface e2e test target that exercises it, or `-`; writes the census, fails analysis on a malformed or lying row or fewer filled cells than `floor`, and its validation on an ungrounded vocabulary. See surface_capability_matrix.bzl.",
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
        "_tool": attrs.exec_dep(default = "komira//tools/build/lint/surface_grounding:surface_grounding", providers = [RunInfo]),
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
