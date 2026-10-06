"""The planted tree of test 39 (test_weld), as {path in the tree: file}.

komira_a welds two test files (three test functions: two `fn test_` and one
`def test_`), has a helper under tests/ that is not a test file, and a
test_dead.mojo its BUCK file names only in a comment. komira_b has a source
and no test. komira_c welds one test, through a mojo_test in a subpackage,
whose only test function is an indented method. komira_gen has a BUCK file
and no .mojo, so it is no package with code. The files are exported by
functional/test_weld/BUCK, so negative/test_weld plants its defects in the
same tree.
"""

_DIR = "tests//functional/test_weld:"

TEST_WELD_TREE = {
    "src/komira_a/BUCK": _DIR + "a.BUCK.txt",
    "src/komira_a/a.mojo": _DIR + "src.txt",
    "src/komira_a/tests/helper.mojo": _DIR + "a_helper.txt",
    "src/komira_a/tests/sub/test_two.mojo": _DIR + "a_test_two.txt",
    "src/komira_a/tests/test_dead.mojo": _DIR + "a_test_dead.txt",
    "src/komira_a/tests/test_one.mojo": _DIR + "a_test_one.txt",
    "src/komira_b/BUCK": _DIR + "b.BUCK.txt",
    "src/komira_b/b.mojo": _DIR + "src.txt",
    "src/komira_c/BUCK": _DIR + "c.BUCK.txt",
    "src/komira_c/c.mojo": _DIR + "src.txt",
    "src/komira_c/wire/BUCK": _DIR + "c_wire.BUCK.txt",
    "src/komira_c/wire/tests/test_wire.mojo": _DIR + "c_test_wire.txt",
    "src/komira_gen/BUCK": _DIR + "gen.BUCK.txt",
}

# The ledger and floor that hold the tree exactly: no finding.
TEST_WELD_LEDGER = _DIR + "known_untested.tsv"
TEST_WELD_FLOOR = _DIR + "coverage_floor.tsv"
