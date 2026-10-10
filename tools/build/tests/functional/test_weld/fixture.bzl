"""The planted tree of test 39 (test_weld) and the targets that weld its tests.

On disk, under functional/test_weld/src (TEST_WELD_ROOT): komira_a has a
source, two test files (one nested under tests/sub/), a test_dead.mojo, and a
helper under tests/ that is not a test file. komira_b has a source and a
test-free tree. komira_c has a source and, under wire/, a test file. komira_gen
holds no .mojo, so it is no package with code. src/tests is no package: it
holds packages by kind, as the repository's src/tests does; komira_d_e2e
(under tests/e2e) has a source and a welded test, and komira_e (under
tests/helpers) a source and no test. functional/test_weld/BUCK
exports each file (TEST_WELD_FILES), so negative/test_weld plants its defects
in the same tree.

What is welded comes from the graph, as for //:test_weld: the
`welded_fixture` targets of functional/test_weld/BUCK (TEST_WELD_WELDS
matches them), each giving the WeldedTestsInfo a mojo_library or mojo_test
would. komira_a's list is computed and holds test_dead.mojo only in a
comment; komira_c's test is welded by a target of its own. The real rules'
WeldedTestsInfo is exercised by negative/test_weld/real.
"""

load("@komira//tools/build/mojo:providers.bzl", "welded_tests_info")

_DIR = "tests//functional/test_weld:"

# The files of the tree, as paths in functional/test_weld.
TEST_WELD_TREE = [
    "src/komira_a/a.mojo",
    "src/komira_a/tests/helper.mojo",
    "src/komira_a/tests/sub/test_two.mojo",
    "src/komira_a/tests/test_dead.mojo",
    "src/komira_a/tests/test_one.mojo",
    "src/komira_b/b.mojo",
    "src/komira_c/c.mojo",
    "src/komira_c/wire/tests/test_wire.mojo",
    "src/komira_gen/gen.txt",
    "src/tests/e2e/komira_d_e2e/d.mojo",
    "src/tests/e2e/komira_d_e2e/tests/test_d.mojo",
    "src/tests/helpers/komira_e/e.mojo",
]

# The `files` of every test_weld over the tree, its `root` (a path in the
# tests cell), the ledger that holds it exactly (no finding), and its
# `welds`: the welded_fixture targets of functional/test_weld/BUCK (its other
# targets weld nothing).
TEST_WELD_FILES = [_DIR + f for f in TEST_WELD_TREE]
TEST_WELD_ROOT = "functional/test_weld/src"
TEST_WELD_LEDGER = _DIR + "known_untested.tsv"
TEST_WELD_WELDS = "//functional/test_weld:"

def _welded_fixture_impl(ctx):
    return [DefaultInfo(), welded_tests_info(ctx.attrs.test_srcs)]

# A stand-in for a mojo_library or mojo_test of the planted tree: the
# WeldedTestsInfo those rules give, of `test_srcs` (files of the tree).
# Nothing is built.
welded_fixture = rule(
    impl = _welded_fixture_impl,
    attrs = {
        "test_srcs": attrs.list(attrs.source(), default = []),
    },
)
