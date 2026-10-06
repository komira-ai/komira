"""The check behind the test_weld lint, shared by its rule and its BXL.

test_weld.bzl declares a lint (`test_weld` target): what to check, as a
TestWeldInputsInfo. test_weld.bxl checks it: it reads which test files the
build graph welds, works out the path of every file in the lint's cell, and
runs `test_weld_action` on the two path lists. This module defines no rule,
so the BXL script can load it.
"""

TestWeldInputsInfo = provider(
    doc = "A test_weld lint as declared: its files, its ledger and where the welds come from. See test_weld.bzl.",
    fields = {
        # The cell the lint checks: its files, its `welds` pattern and its
        # paths are all of this cell.
        "cell": provider_field(str),
        # The .mojo files of the tree the lint reads (source artifacts); the
        # BXL script asks Buck2 for the path of each in `cell`.
        "mojo": provider_field(list[Artifact]),
        # Findings name a file of the tree as <prefix><path>.
        "prefix": provider_field(str),
        # The packages are the directories directly under it (a path in `cell`).
        "root": provider_field(str),
        # The ledger (a source); findings name it by its path in `cell`.
        "ledger": provider_field(typing.Any),
        # A target pattern with its cell (`komira//src/...`): every target of
        # `cell` it matches that has WeldedTestsInfo
        # (tools/build/mojo/providers.bzl) welds the test files it lists.
        "welds": provider_field(str),
        # The pinned busybox and test_weld.sh, and the constraints of the
        # execution platform that runs them.
        "busybox": provider_field(typing.Any),
        "script": provider_field(typing.Any),
        "exec_compatible_with": provider_field(list[str]),
        "label": provider_field(str),
    },
)

def test_weld_action(actions, info, ledger_name, mojo, welded):
    """Runs test_weld.sh over `info` (its ledger called `ledger_name`), the
    .mojo files of its tree `mojo` and the welded test files `welded` (both
    paths in the cell). Its inputs are
    those two lists and the ledger, never the files themselves, so it re-runs
    only when a .mojo file is added, removed or renamed, a weld changes, or
    the ledger does. Returns its output, which exists only if the lint found
    nothing: the action fails, printing the findings, otherwise."""
    mojo_list = actions.write("test_weld/mojo.txt", sorted(mojo) + [""])
    welded_list = actions.write("test_weld/welded.txt", sorted(welded) + [""])
    result = actions.declare_output("test_weld/validation.json")
    actions.run(
        cmd_args(
            info.busybox,
            "sh",
            info.script,
            info.busybox,
            result.as_output(),
            mojo_list,
            info.prefix,
            info.root,
            info.ledger,
            ledger_name,
            welded_list,
        ),
        category = "lint_test_weld",
    )
    return result
