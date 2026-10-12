# The files of komira_real (BUCK), exported by reference for
# tests//functional/test_weld/real:ok, the green half of test 39 over the
# real rules. The package's BUCK holds the list to its glob
# (check_real_tree).
REAL_TREE = [
    "src/komira_real/__init__.mojo",
    "src/komira_real/tests/test_commented.mojo",
    "src/komira_real/tests/test_imported.mojo",
    "src/komira_real/tests/test_listed.mojo",
    "src/komira_real/tests/test_main.mojo",
    "src/komira_real/tests/test_shared.mojo",
]

def check_real_tree(files):
    """Fails unless `files` (the package's glob of src/komira_real) is REAL_TREE."""
    unlisted = sorted([f for f in files if f not in REAL_TREE])
    absent = sorted([f for f in REAL_TREE if f not in files])
    if unlisted or absent:
        fail("tools/build/tests/negative/test_weld/real: REAL_TREE (tree.bzl) is not the files of komira_real: not listed {}, listed but absent {}; list every file, so the green half tests//functional/test_weld/real:ok lints it too".format(unlisted, absent))
