"""The planted tree of test 47 (the registry lint), as {path in the tree: file}.

The BUCK files are text files here, staged at src/<package>/BUCK by the
lint, so none is a package of this cell. physical.tsv is the fixture's set:
the real ledger's three prefixes and one listed package (komira_pipeline).

komira_op_scan, komira_dispatch_run and komira_pipeline are the
physical-plan packages, and none reaches the registry: op_scan.BUCK.txt names
it only in a comment, a dep's trailing comment and its visibility list, and
scan.txt only in a docstring, a comment and a longer module name;
komira_dispatch_run depends on komira_op_scan. komira_plan_ir, a logical-plan
package, depends on the registry, as do komira_optimizer (named like the
komira_op_ prefix, through a cell-qualified label) and komira_sdk (named like
the komira_sdk_exec prefix): all three are allowed. functional/fs_registry_deps/BUCK
exports the files, so negative/fs_registry_deps plants its defects in the
same tree.
"""

_DIR = "tests//functional/fs_registry_deps:"

FS_REGISTRY_TREE = {
    "src/komira_dispatch_run/BUCK": _DIR + "dispatch_run.BUCK.txt",
    "src/komira_fs/BUCK": _DIR + "fs.BUCK.txt",
    "src/komira_fs_registry/BUCK": _DIR + "registry.BUCK.txt",
    "src/komira_op_scan/BUCK": _DIR + "op_scan.BUCK.txt",
    "src/komira_op_scan/scan.mojo": _DIR + "scan.txt",
    "src/komira_optimizer/BUCK": _DIR + "optimizer.BUCK.txt",
    "src/komira_pipeline/BUCK": _DIR + "pipeline.BUCK.txt",
    "src/komira_plan_ir/BUCK": _DIR + "plan_ir.BUCK.txt",
    "src/komira_sdk/BUCK": _DIR + "sdk.BUCK.txt",
}

FS_REGISTRY_PHYSICAL = _DIR + "physical.tsv"
