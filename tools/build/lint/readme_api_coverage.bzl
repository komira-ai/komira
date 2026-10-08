"""readme_api_coverage: how much of each package's public API its README's examples use.

A package's README `mojo` examples run as the welded `[tests][readme]` test
(tools/build/mojo/README.md, "README examples"), so a public name an example
uses in code is a public name that is smoke-tested (an import line alone, or
the README declaring the same name, is not a use). This lint counts, per package
under `root` (each directory directly under it but `<root>/tests`, which
holds the test-only packages), the public API (the names
its `__init__.mojo` re-exports, and the public methods of the structs among
them) and which of it the README's examples use, reading each README through
the same tool the gate runs (//tools/build/readme_examples:tool, `generate`),
so hidden lines count and prose does not. The rules are in
docs/readme_api_coverage.md and in the action, readme_api_coverage.sh.

A validation, like the lints in defs.bzl. It writes the census as outputs:
`[packages]` (one TSV row per package), `[symbols]` (one TSV row per public
symbol, with where it is declared) and `[report]` (the human summary), the
three together being the default outputs. A second action turns the census's
findings into the validation result (a validation's action writes one file).

It is REPORT-ONLY unless `enforce`: an undocumented symbol is counted and
listed, never a failure. It always fails on its ledger, `exceptions`
(`<package><TAB><symbol><TAB><reason>`, shrink-only): a malformed or
duplicate row, or a row for a symbol that is no longer exported or that a
README example uses now. With `enforce = True`, an undocumented symbol with
no ledger row is a finding too.

`expect_packages`, `expect_symbols` and `expect_report`, for a fixture, are
the exact `[packages]`, `[symbols]` and `[report]` files the census must
write; any difference is a finding.

The files come from `tree` (a doc_tree target: the root one holds every file
of the cell) or, for a fixture, from `files` ({path in the tree: source}),
never both.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":doc_tree.bzl", "DocTreeInfo", "declares_docs")

def _named(ctx, f):
    """`f` and the name findings give it: its path in the cell for a source
    of this package, the target that makes it otherwise (an export_file of
    another package)."""
    if f == None:
        return ["-", "-"]
    if f.owner != None:
        return [f, str(f.owner.raw_target())]
    package = "{}//{}".format(ctx.label.cell, ctx.label.package + "/" if ctx.label.package else "")
    return [f, package + f.short_path]

def _readme_api_coverage_impl(ctx):
    if (ctx.attrs.tree == None) == (not ctx.attrs.files):
        fail("readme_api_coverage {}: name the files in exactly one of `tree` and `files`".format(ctx.label))
    if ctx.attrs.tree != None:
        tree = ctx.attrs.tree[DefaultInfo].default_outputs[0]
        prefix = "{}//".format(ctx.label.cell)
    else:
        tree = ctx.actions.copied_dir("tree", ctx.attrs.files)
        prefix = "{}[files]/".format(ctx.label.raw_target())
    findings = ctx.actions.declare_output("findings.txt")
    packages = ctx.actions.declare_output("readme_api_packages.tsv")
    symbols = ctx.actions.declare_output("readme_api_symbols.tsv")
    report = ctx.actions.declare_output("readme_api_coverage.txt")
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            ctx.attrs._script,
            "census",
            bb,
            ctx.attrs._tool[RunInfo],
            findings.as_output(),
            packages.as_output(),
            symbols.as_output(),
            report.as_output(),
            tree,
            prefix,
            ctx.attrs.root,
            _named(ctx, ctx.attrs.exceptions),
            "1" if ctx.attrs.enforce else "0",
            _named(ctx, ctx.attrs.expect_packages),
            _named(ctx, ctx.attrs.expect_symbols),
            _named(ctx, ctx.attrs.expect_report),
        ),
        category = "lint_readme_api_coverage",
    )
    # A validation's action writes exactly one file: the verdict reads the findings.
    result = ctx.actions.declare_output("validation.json")
    ctx.actions.run(
        cmd_args(bb, "sh", ctx.attrs._script, "verdict", bb, result.as_output(), findings, report),
        category = "lint_readme_api_coverage_verdict",
    )
    return [
        DefaultInfo(
            default_outputs = [packages, symbols, report],
            sub_targets = {
                "packages": [DefaultInfo(default_output = packages)],
                "report": [DefaultInfo(default_output = report)],
                "symbols": [DefaultInfo(default_output = symbols)],
            },
        ),
        ValidationInfo(validations = [ValidationSpec(name = "readme_api_coverage", validation_result = result)]),
    ]

_readme_api_coverage_rule = rule(
    impl = _readme_api_coverage_impl,
    doc = "README API coverage: per package under `root`, its public API and which of it the README's examples use; report-only unless `enforce`; fails on a malformed or stale `exceptions` row. See readme_api_coverage.bzl.",
    attrs = {
        # Report-only when False: undocumented symbols are listed, not findings.
        "enforce": attrs.bool(default = False),
        "exceptions": attrs.source(),
        "expect_packages": attrs.option(attrs.source(), default = None),
        "expect_report": attrs.option(attrs.source(), default = None),
        "expect_symbols": attrs.option(attrs.source(), default = None),
        "files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "root": attrs.string(default = "src"),
        "tree": attrs.option(attrs.dep(providers = [DocTreeInfo]), default = None),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_script": attrs.source(default = "komira//tools/build/lint:readme_api_coverage.sh"),
        "_tool": attrs.exec_dep(default = "komira//tools/build/readme_examples:tool", providers = [RunInfo]),
    },
)

def _readme_api_coverage(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _readme_api_coverage_rule(**kwargs)

readme_api_coverage = declares_docs(_readme_api_coverage)
