"""test_weld: every test file runs, and every package with code welds a test.

A lint over the packages under `root`: each directory directly under it, and
each `<root>/tests/<kind>/<name>` (`<root>/tests` is not a package: it holds
the test-only packages by kind). It fails when:

- a `test_*.mojo` under a `tests/` directory is welded by no target, so it
  never runs;
- a package with a `.mojo` source welds no test.

A test file is welded when a target of the build graph runs it: it is among
the WeldedTestsInfo sources (tools/build/mojo/providers.bzl) of a target that
the `welds` pattern matches. A mojo_library gives its `test_srcs` and a
mojo_test its `main` (the one file its binary runs), as the rule received
them: a list a BUCK file computes counts entry by entry, and an entry left in
a comment does not. No BUCK file is read as text. Buck2 says where each
welded file is, so an entry naming another package's file (by label) welds
that file, never a same-named one of its own package.

`welds` is a pattern of the lint's own cell, written from `//` (`//src/...`):
the lint qualifies it with its cell, so it names the same targets from
whichever cell buck2 is run. Every path (of a file, a package, a ledger row)
is a path in that cell.

`known_untested` is the ledger of the test files and packages allowed to
break those rules, each with its reason. It only shrinks: a row whose
test is welded, or whose package welds a test, is a finding, and so is a row
naming nothing. The action is test_weld.sh. It reads the list of the tree's
.mojo paths and the list of welded paths, never the files, so it re-runs
only when one of those lists or the ledger changes.

The files on disk come from `tree` (a doc_tree target: the root one holds
every file of the cell) or, for a fixture, from `files` (sources), never
both. A target with neither fails at analysis.

WHY A BXL SCRIPT CHECKS IT. A rule sees only the targets it names, and a
BUCK file cannot list a package's targets (a query attribute takes labels,
not a pattern such as `//src/...`, nor a file for `owner()`). So a
`test_weld` target only declares the lint (TestWeldInputsInfo) and building it
checks nothing; `buck2 bxl //tools/build/lint/test_weld.bxl:check -- --lint
<target>` checks it: it queries the `welds` pattern, reads the
WeldedTestsInfo of every target it yields, and runs the check as a build
action (test_weld_check.bzl) on Linux x86-64, the platform its busybox is
resolved for (so a test_weld target takes no `exec_compatible_with`). The
pull request's check runs it for every test_weld target of a unit it builds
(release/ci/build_targets.sh). The query is configured for the target
platform, as `buck2 cquery` sees it: a test target incompatible with that
platform welds nothing there.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":doc_tree.bzl", "DocTreeInfo", "declares_docs")
load(":test_weld_check.bzl", "TestWeldInputsInfo")

def _test_weld_impl(ctx):
    if (ctx.attrs.tree == None) == (not ctx.attrs.files):
        fail("test_weld {}: name the files in exactly one of `tree` and `files`".format(ctx.label))
    if not ctx.attrs.welds.startswith("//"):
        fail("test_weld {}: `welds` is a pattern of this cell written from `//` (e.g. `//src/...`), got `{}`".format(ctx.label, ctx.attrs.welds))
    if ctx.attrs.tree != None:
        files = ctx.attrs.tree[DocTreeInfo].files.values()
    else:
        files = ctx.attrs.files
    cell = ctx.label.cell
    return [
        DefaultInfo(),
        TestWeldInputsInfo(
            cell = cell,
            mojo = [f for f in files if f.basename.endswith(".mojo")],
            prefix = cell + "//",
            root = ctx.attrs.root,
            ledger = ctx.attrs.known_untested,
            welds = cell + ctx.attrs.welds,
            busybox = ctx.attrs._busybox[DefaultInfo].default_outputs[0],
            script = ctx.attrs._script,
            exec_compatible_with = LINUX_X86_64,
            label = str(ctx.label.raw_target()),
        ),
    ]

test_weld_rule = rule(
    impl = _test_weld_impl,
    doc = "Declares a test_weld lint: every test file under `root` is welded by a target the `welds` pattern matches, every package with a .mojo source welds a test; `known_untested` lists the exceptions and only shrinks. Checked by test_weld.bxl, not by building it. See test_weld.bzl.",
    attrs = {
        "files": attrs.list(attrs.source(), default = []),
        "known_untested": attrs.source(),
        "root": attrs.string(default = "src"),
        "tree": attrs.option(attrs.dep(providers = [DocTreeInfo]), default = None),
        # A target pattern of this cell, from `//` (`//src/...`): the targets
        # that weld tests.
        "welds": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_script": attrs.source(default = "komira//tools/build/lint:test_weld.sh"),
    },
)

def _test_weld(**kwargs):
    # The check runs on Linux x86-64 (test_weld.bxl); the busybox it runs is
    # resolved for this target's execution platform, so the two are one.
    if "exec_compatible_with" in kwargs:
        fail("test_weld {}: takes no exec_compatible_with: its check runs on Linux x86-64".format(kwargs.get("name", "")))
    test_weld_rule(exec_compatible_with = LINUX_X86_64, **kwargs)

test_weld = declares_docs(_test_weld)
