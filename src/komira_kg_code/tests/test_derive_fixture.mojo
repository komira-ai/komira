# The deriver over the frozen fixture repo (tests/fixtures/repo): the
# kgfix library, its welded test, its standalone test target, and a
# document governing it. The inputs are the uquery JSON of the two targets
# (tests/fixtures/kgfix_uquery.json, captured with `buck2 uquery
# 'set(...:kgfix ...:kgfix_dot_test)' --json --output-attribute
# '^(buck\.type|deps|srcs|test_srcs|import_name)$'`), the `mojo doc` JSON
# the build makes of kgfix (the kgfix_doc target, so the compiler's reading,
# not a copy), the six sources and the document.
#
# The golden (tests/fixtures/kgfix_graph.golden) was written by hand from
# those inputs, not printed by the deriver: each node and edge is the one
# the module header of deriver.mojo says that input gives.
from std.testing import assert_equal, assert_true

from komira_kg_code import (
    CodeGraph,
    CodeGraphBuilder,
    EDGE_CONFORMS,
    EDGE_TESTS,
)

comptime _P = "komira//src/komira_kg_code/tests/fixtures/repo/"
comptime _DIR = "src/komira_kg_code/tests/fixtures/"


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _sources() -> List[String]:
    return [
        String("kgfix/__init__.mojo"),
        String("kgfix/shapes.mojo"),
        String("kgfix/sub/__init__.mojo"),
        String("kgfix/sub/leaf.mojo"),
        String("tests/test_dot.mojo"),
        String("tests/test_grid.mojo"),
    ]


def _derive(reverse: Bool) raises -> CodeGraph:
    """The fixture graph; with `reverse`, every input is added in the
    opposite order and the markdown and doc JSON before the uquery JSON."""
    var b = CodeGraphBuilder()
    var srcs = _sources()
    var doc_path = String(_DIR) + "repo/docs/kgfix.md"
    if not reverse:
        b.add_uquery_json(_read(String(_DIR) + "kgfix_uquery.json"))
        b.add_mojo_doc_json(String("komira//src/komira_kg_code/tests/fixtures/repo:kgfix"), _read("kgfix_doc.json"))
        for i in range(len(srcs)):
            b.add_source(String(_P) + srcs[i], _read(String(_DIR) + "repo/" + srcs[i]))
        b.add_markdown(doc_path, _read(doc_path))
    else:
        b.add_markdown(doc_path, _read(doc_path))
        for i in range(len(srcs) - 1, -1, -1):
            b.add_source(String(_P) + srcs[i], _read(String(_DIR) + "repo/" + srcs[i]))
        b.add_mojo_doc_json(String("komira//src/komira_kg_code/tests/fixtures/repo:kgfix"), _read("kgfix_doc.json"))
        b.add_uquery_json(_read(String(_DIR) + "kgfix_uquery.json"))
    return b.build()


def _derive_twice() raises -> CodeGraph:
    """The fixture graph with every input added twice."""
    var b = CodeGraphBuilder()
    var srcs = _sources()
    var doc_path = String(_DIR) + "repo/docs/kgfix.md"
    for _ in range(2):
        b.add_uquery_json(_read(String(_DIR) + "kgfix_uquery.json"))
        b.add_mojo_doc_json(String("komira//src/komira_kg_code/tests/fixtures/repo:kgfix"), _read("kgfix_doc.json"))
        for i in range(len(srcs)):
            b.add_source(String(_P) + srcs[i], _read(String(_DIR) + "repo/" + srcs[i]))
        b.add_markdown(doc_path, _read(doc_path))
    return b.build()


def _first_difference(want: String, got: String) -> String:
    var w = want.split("\n")
    var g = got.split("\n")
    for i in range(max(len(w), len(g))):
        var a = String(w[i]) if i < len(w) else String("<none>")
        var c = String(g[i]) if i < len(g) else String("<none>")
        if a != c:
            return "line " + String(i + 1) + ":\n  golden: " + a + "\n  got:    " + c
    return String("none")


def test_graph_equals_the_golden() raises:
    var got = _derive(False).dump()
    var want = _read(String(_DIR) + "kgfix_graph.golden")
    assert_true(got == want, "the graph differs from the golden, first at " + _first_difference(want, got))


def test_input_order_does_not_change_the_graph() raises:
    assert_equal(_derive(True).dump(), _derive(False).dump())


def test_inputs_added_twice_give_the_graph_of_once() raises:
    # The same target, doc JSON, source and document again are the same
    # nodes and edges: neither refused nor counted twice.
    assert_equal(_derive_twice().dump(), _derive(False).dump())


def test_both_conformers_of_shaped_including_the_multi_line_header() raises:
    # Grid's header spans four lines and its conformances are on the last;
    # Dot's are on its only line. A reader of a header's first line finds
    # Dot and misses Grid.
    var g = _derive(False)
    var c = g.sources_of(EDGE_CONFORMS, "kgfix.shapes.Shaped")
    assert_equal(len(c), 2)
    assert_equal(c[0], "kgfix.shapes.Dot")
    assert_equal(c[1], "kgfix.shapes.Grid")


def test_tests_are_the_welded_file_and_the_standalone_target() raises:
    var g = _derive(False)
    var t = g.targets_of("komira//src/komira_kg_code/tests/fixtures/repo:kgfix", EDGE_TESTS)
    assert_equal(len(t), 2)
    assert_equal(t[0], String(_P) + "tests/test_grid.mojo")
    assert_equal(t[1], "komira//src/komira_kg_code/tests/fixtures/repo:kgfix_dot_test")


def test_batches_hold_the_graph_in_order() raises:
    var g = _derive(False)
    var nb = g.node_batch()
    assert_equal(nb.num_rows(), len(g.nodes))
    assert_equal(nb.num_columns(), 6)
    var ids = nb.column_as_string(0)
    var kinds = nb.column_as_string(1)
    var lines = nb.column_as_primitive_int64(4)
    var texts = nb.column_as_string(5)
    for i in range(len(g.nodes)):
        assert_equal(ids.get(i), g.nodes[i].id)
        assert_equal(kinds.get(i), g.nodes[i].kind)
        assert_equal(Int(lines.get(i)), g.nodes[i].line)
        assert_equal(texts.get(i), g.nodes[i].text)
    var eb = g.edge_batch()
    assert_equal(eb.num_rows(), len(g.edges))
    var src = eb.column_as_string(0)
    var kind = eb.column_as_string(1)
    var dst = eb.column_as_string(2)
    for i in range(len(g.edges)):
        assert_equal(src.get(i), g.edges[i].src)
        assert_equal(kind.get(i), g.edges[i].kind)
        assert_equal(dst.get(i), g.edges[i].dst)


def main() raises:
    test_graph_equals_the_golden()
    test_input_order_does_not_change_the_graph()
    test_inputs_added_twice_give_the_graph_of_once()
    test_both_conformers_of_shaped_including_the_multi_line_header()
    test_tests_are_the_welded_file_and_the_standalone_target()
    test_batches_hold_the_graph_in_order()
    print("OK")
