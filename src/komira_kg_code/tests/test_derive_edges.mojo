# The edges the fixture repo does not reach: which targets give a `tests`
# edge, a library whose import name is not its target name, and stubs (labels
# named only in `deps`) that share a target name. Also the lines it does not
# reach: a symbol whose source is not added (and the module after it, whose
# source is), a method whose struct header is not found (and the struct after
# it, whose header is), and the escapes of `dump`.
from std.testing import assert_equal, assert_false, assert_true

from komira_kg_code import CodeGraph, CodeGraphBuilder, EDGE_IMPORTS, EDGE_TESTS, KgEdge, KgNode

# lib imports as libx. tool is a binary on lib; lib_test is a test target on
# c//q:helper, which no uquery output defines (a stub), and on the libraries
# lib and other. The stub is listed first, so a tests edge from the first dep
# alone gives neither library a test.
comptime _UQ = (
    '{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": [], "import_name": "libx",'
    ' "srcs": ["c//p/lib/__init__.mojo"], "test_srcs": []},'
    ' "c//p:tool": {"buck.type": "mojo_binary_rule", "deps": ["c//p:lib"], "srcs": ["c//p/tool.mojo"]},'
    ' "c//p:other": {"buck.type": "mojo_library_rule", "deps": [], "srcs": ["c//p/other/__init__.mojo"]},'
    ' "c//p:lib_test": {"buck.type": "mojo_test_rule", "deps": ["c//q:helper", "c//p:lib", "c//p:other"],'
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
    # Every library the test target lists has it as a test, not the first only.
    var o = g.targets_of("c//p:other", EDGE_TESTS)
    assert_equal(len(o), 1)
    assert_equal(o[0], "c//p:lib_test")


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


# A library c//p:lib (import name lib) and a stub c//q:lib that t depends on:
# the name lib is the library's, so the stub takes no import name.
comptime _UQ_LIB_AND_STUB = (
    '{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": [], "srcs": ["c//p/lib/__init__.mojo"]},'
    ' "c//p:t": {"buck.type": "mojo_binary_rule", "deps": ["c//q:lib"], "srcs": ["c//p/t.mojo"]}}'
)


def test_a_stub_never_takes_a_library_import_name() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_UQ_LIB_AND_STUB)
    b.add_source("c//p/t.mojo", "import lib\n")
    var i = b.build().targets_of("c//p/t.mojo", EDGE_IMPORTS)
    assert_equal(len(i), 1)
    assert_equal(i[0], "c//p:lib")


# c//p:lib with one module, __init__, declaring the function f and the
# struct S with the method area.
comptime _UQ_ONE = (
    '{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": [], "srcs": ["c//p/lib/__init__.mojo"]}}'
)
comptime _DOC_ONE = (
    '{"decl": {"kind": "package", "name": "lib", "modules": [{"kind": "module", "name": "__init__",'
    ' "functions": [{"name": "f", "overloads": [{"signature": "def f()", "summary": "F."}]}],'
    ' "structs": [{"name": "S", "signature": "struct S", "summary": "S.",'
    ' "functions": [{"name": "area", "overloads": [{"signature": "def area(self) -> Int", "summary": "A."}]}]}]}],'
    ' "packages": []}, "version": "1.0.0"}'
)


def _line(g: CodeGraph, id: String) raises -> Int:
    var i = g.node_index(id)
    assert_true(i >= 0, id)
    return g.nodes[i].line


def test_a_symbol_whose_source_is_not_added_has_line_0() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_UQ_ONE)
    b.add_mojo_doc_json("c//p:lib", _DOC_ONE)
    var g = b.build()
    assert_equal(_line(g, "lib.f"), 0)
    assert_equal(_line(g, "lib.S"), 0)
    assert_equal(_line(g, "lib.S.area"), 0)


def test_a_method_whose_struct_header_is_not_found_has_line_0() raises:
    # The source has a method-shaped line but no `struct S` header: S's
    # line is unknown, so area's is too (not the first `    def area` of
    # the file). f is found, so the source was read.
    var b = CodeGraphBuilder()
    b.add_uquery_json(_UQ_ONE)
    b.add_mojo_doc_json("c//p:lib", _DOC_ONE)
    b.add_source("c//p/lib/__init__.mojo", "    def area(self) -> Int:\n        return 0\ndef f():\n    pass\n")
    var g = b.build()
    assert_equal(_line(g, "lib.f"), 3)
    assert_equal(_line(g, "lib.S"), 0)
    assert_equal(_line(g, "lib.S.area"), 0)


# c//p:lib with the modules a (function fa) and b (function fb, struct U with
# method m), listed in that order: the doc JSON keeps module order, so a's file is read first.
comptime _UQ_TWO = (
    '{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": [],'
    ' "srcs": ["c//p/lib/__init__.mojo", "c//p/lib/a.mojo", "c//p/lib/b.mojo"]}}'
)
comptime _DOC_TWO = (
    '{"decl": {"kind": "package", "name": "lib", "modules": ['
    '{"kind": "module", "name": "a",'
    ' "functions": [{"name": "fa", "overloads": [{"signature": "def fa()", "summary": "Fa."}]}]},'
    ' {"kind": "module", "name": "b",'
    ' "functions": [{"name": "fb", "overloads": [{"signature": "def fb()", "summary": "Fb."}]}],'
    ' "structs": [{"name": "U", "signature": "struct U", "summary": "U.",'
    ' "functions": [{"name": "m", "overloads": [{"signature": "def m(self)", "summary": "M."}]}]}]}],'
    ' "packages": []}, "version": "1.0.0"}'
)


def test_a_module_whose_source_is_not_added_leaves_later_modules_lines() raises:
    # a's source is not added, so fa has line 0; b's is, so fb, U and U.m
    # have their lines. A missing source zeroes its own file only, not the
    # top-level declarations or the methods of the files after it.
    var b = CodeGraphBuilder()
    b.add_uquery_json(_UQ_TWO)
    b.add_mojo_doc_json("c//p:lib", _DOC_TWO)
    b.add_source("c//p/lib/b.mojo", "# b\ndef fb():\n    pass\nstruct U:\n    def m(self):\n        pass\n")
    var g = b.build()
    assert_equal(_line(g, "lib.a.fa"), 0)
    assert_equal(_line(g, "lib.b.fb"), 2)
    assert_equal(_line(g, "lib.b.U"), 4)
    assert_equal(_line(g, "lib.b.U.m"), 5)


# _DOC_ONE's module with a second struct T after S: per file the declarations
# go functions, then each struct followed by its methods, so T comes after
# S.area.
comptime _DOC_S_THEN_T = (
    '{"decl": {"kind": "package", "name": "lib", "modules": [{"kind": "module", "name": "__init__",'
    ' "functions": [],'
    ' "structs": [{"name": "S", "signature": "struct S", "summary": "S.",'
    ' "functions": [{"name": "area", "overloads": [{"signature": "def area(self) -> Int", "summary": "A."}]}]},'
    ' {"name": "T", "signature": "struct T", "summary": "T.",'
    ' "functions": [{"name": "m", "overloads": [{"signature": "def m(self)", "summary": "M."}]}]}]}],'
    ' "packages": []}, "version": "1.0.0"}'
)


def test_a_struct_after_a_method_whose_header_is_not_found_has_its_line() raises:
    # S's header is not in the source, so area has line 0; T's header is,
    # and T is no member of S, so T and its method m have their lines. A
    # missing struct header zeroes only that struct's methods.
    var b = CodeGraphBuilder()
    b.add_uquery_json(_UQ_ONE)
    b.add_mojo_doc_json("c//p:lib", _DOC_S_THEN_T)
    b.add_source(
        "c//p/lib/__init__.mojo",
        "    def area(self) -> Int:\n        return 0\nstruct T:\n    def m(self):\n        pass\n",
    )
    var g = b.build()
    assert_equal(_line(g, "lib.S"), 0)
    assert_equal(_line(g, "lib.S.area"), 0)
    assert_equal(_line(g, "lib.T"), 3)
    assert_equal(_line(g, "lib.T.m"), 4)


def test_dump_escapes_backslash_tab_and_newline() raises:
    var nodes = List[KgNode]()
    nodes.append(KgNode(String("a\\b"), String("doc"), String("t\tu"), String("p"), 7, String("x\ny")))
    var edges = List[KgEdge]()
    edges.append(KgEdge(String("a\\b"), String("k\tk"), String("d")))
    var g = CodeGraph(nodes^, edges^)
    assert_equal(g.dump(), "N\ta\\\\b\tdoc\tt\\tu\tp\t7\tx\\ny\nE\ta\\\\b\tk\\tk\td\n")


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
    _run("stub_vs_library", test_a_stub_never_takes_a_library_import_name, failed)
    _run("no_source_line", test_a_symbol_whose_source_is_not_added_has_line_0, failed)
    _run("method_no_header", test_a_method_whose_struct_header_is_not_found_has_line_0, failed)
    _run("later_module_line", test_a_module_whose_source_is_not_added_leaves_later_modules_lines, failed)
    _run("struct_after_no_header", test_a_struct_after_a_method_whose_header_is_not_found_has_its_line, failed)
    _run("dump_escapes", test_dump_escapes_backslash_tab_and_newline, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("OK")
