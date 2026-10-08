# The edges the fixture repo does not reach: which targets give a `tests`
# edge, a library whose import name is not its target name, and stubs (labels
# named only in `deps`) that share a target name.
from std.testing import assert_equal, assert_false, assert_true

from komira_kg_code import CodeGraph, CodeGraphBuilder, EDGE_IMPORTS, EDGE_TESTS

# lib imports as libx. tool is a binary on lib; lib_test is a test target on
# lib and on c//q:helper, which no uquery output defines (a stub).
comptime _UQ = (
    '{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": [], "import_name": "libx",'
    ' "srcs": ["c//p/lib/__init__.mojo"], "test_srcs": []},'
    ' "c//p:tool": {"buck.type": "mojo_binary_rule", "deps": ["c//p:lib"], "srcs": ["c//p/tool.mojo"]},'
    ' "c//p:lib_test": {"buck.type": "mojo_test_rule", "deps": ["c//p:lib", "c//q:helper"],'
    ' "srcs": ["c//p/lib_test.mojo"]}}'
)


def _derive() raises -> CodeGraph:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_UQ)
    b.add_source("c//p/tool.mojo", "from libx import f\n")
    b.add_source("c//p/lib_test.mojo", "import lib\n")
    return b.build()


def test_only_a_test_target_on_a_library_is_a_tests_edge() raises:
    var g = _derive()
    # The binary on lib is no test of it; the test target's stub dep is no
    # library, so it has no tests.
    var t = g.targets_of("c//p:lib", EDGE_TESTS)
    assert_equal(len(t), 1)
    assert_equal(t[0], "c//p:lib_test")
    assert_false(g.has_edge("c//p:lib", EDGE_TESTS, "c//p:tool"))
    assert_equal(len(g.targets_of("c//q:helper", EDGE_TESTS)), 0)


def test_a_library_imports_under_its_import_name() raises:
    var g = _derive()
    assert_true(g.has_edge("c//p/tool.mojo", EDGE_IMPORTS, "c//p:lib"))
    # Its target name is not an import name of it.
    assert_equal(len(g.targets_of("c//p/lib_test.mojo", EDGE_IMPORTS)), 0)


# Two uquery outputs, each with a library depending on a stub named util:
# c//a:util and c//b:util.
comptime _UQ_A = (
    '{"c//x:one": {"buck.type": "mojo_library_rule", "deps": ["c//a:util"], "srcs": ["c//x/one/__init__.mojo"]}}'
)
comptime _UQ_B = (
    '{"c//y:two": {"buck.type": "mojo_library_rule", "deps": ["c//b:util"], "srcs": ["c//y/two/__init__.mojo"]}}'
)


def _derive_stubs(a_first: Bool) raises -> CodeGraph:
    var b = CodeGraphBuilder()
    if a_first:
        b.add_uquery_json(_UQ_A)
        b.add_uquery_json(_UQ_B)
    else:
        b.add_uquery_json(_UQ_B)
        b.add_uquery_json(_UQ_A)
    b.add_source("c//x/one/__init__.mojo", "import util\n")
    return b.build()


def test_stubs_sharing_a_name_give_the_same_graph_in_either_order() raises:
    assert_equal(_derive_stubs(True).dump(), _derive_stubs(False).dump())
    # Neither stub is the one `util` names, so the import gives no edge.
    assert_equal(len(_derive_stubs(True).targets_of("c//x/one/__init__.mojo", EDGE_IMPORTS)), 0)


def test_a_stub_alone_imports_under_its_name() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_UQ_A)
    b.add_source("c//x/one/__init__.mojo", "import util\n")
    assert_true(b.build().has_edge("c//x/one/__init__.mojo", EDGE_IMPORTS, "c//a:util"))


def _run(name: String, f: def() raises thin -> None, mut failed: List[String]):
    """Runs one case; a failure is printed, not fatal, so one build names
    every case a planted defect breaks."""
    try:
        f()
    except e:
        print("FAIL", name, ":", e)
        failed.append(name)


def main() raises:
    var failed = List[String]()
    _run("tests_edge", test_only_a_test_target_on_a_library_is_a_tests_edge, failed)
    _run("import_name", test_a_library_imports_under_its_import_name, failed)
    _run("stub_order", test_stubs_sharing_a_name_give_the_same_graph_in_either_order, failed)
    _run("stub_alone", test_a_stub_alone_imports_under_its_name, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("OK")
