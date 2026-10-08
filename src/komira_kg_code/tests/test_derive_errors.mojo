# Every input the deriver cannot place is refused with an error naming it,
# never dropped. Each case is one minimal input set; the message is
# asserted whole.
from std.testing import assert_equal

from komira_kg_code import CodeGraphBuilder

comptime _LIB = '{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": [], "import_name": null, "srcs": ["c//p/lib/__init__.mojo", "c//p/lib/a.mojo"], "test_srcs": []}}'

comptime _DOC_MISSING_MODULE = '{"decl": {"kind": "package", "name": "lib", "modules": [{"kind": "module", "name": "__init__"}, {"kind": "module", "name": "b"}], "packages": []}, "version": "1.0.0"}'


def _error_of(b: CodeGraphBuilder) -> String:
    try:
        _ = b.build()
    except e:
        return String(e)
    return String("<no error>")


def test_a_source_no_target_lists() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_source("c//p/lib/z.mojo", "def z(): pass\n")
    assert_equal(_error_of(b), "komira_kg_code: source c//p/lib/z.mojo is in no target's srcs or test_srcs")


def test_doc_json_for_a_label_that_is_no_library() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_mojo_doc_json("c//p:other", _DOC_MISSING_MODULE)
    assert_equal(
        _error_of(b),
        "komira_kg_code: mojo doc JSON for c//p:other, which the uquery output has no mojo_library for",
    )


def test_a_module_with_no_source() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_mojo_doc_json("c//p:lib", _DOC_MISSING_MODULE)
    assert_equal(
        _error_of(b),
        "komira_kg_code: c//p:lib: module lib.b has no source c//p/lib/b.mojo in the target's srcs",
    )


def test_json_that_is_not_mojo_doc_output() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_mojo_doc_json("c//p:lib", '{"version": "1.0.0"}')
    assert_equal(_error_of(b), "komira_kg_code: c//p:lib: the doc JSON has no `decl` package; is it `mojo doc` output?")


def test_uquery_without_attributes() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json('{"c//p:lib": {"name": "lib"}}')
    assert_equal(
        _error_of(b),
        "komira_kg_code: uquery JSON: c//p:lib has no `buck.type`; run uquery with --output-attribute",
    )


def test_two_libraries_with_one_import_name() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_uquery_json('{"c//q:lib": {"buck.type": "mojo_library_rule", "srcs": ["c//q/lib/__init__.mojo"]}}')
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//q:lib and c//p:lib both import as `lib`")


def test_governs_naming_nothing() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_markdown("docs/x.md", "---\ngoverns:\n  - //p:gone\n---\n")
    assert_equal(
        _error_of(b),
        "komira_kg_code: docs/x.md: governs `//p:gone`, which names no target or file of the graph",
    )


def test_uquery_that_is_not_an_object() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json("[]")
    assert_equal(_error_of(b), "komira_kg_code: the uquery JSON is not an object of targets")


def test_attributes_that_are_not_an_object() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json('{"c//p:lib": 3}')
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is not an object of attributes")


def test_a_member_that_is_not_a_string() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json('{"c//p:lib": {"buck.type": 3}}')
    assert_equal(_error_of(b), "komira_kg_code: c//p:lib: `buck.type` is not a string")


def test_a_member_that_is_not_a_list() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json('{"c//p:lib": {"buck.type": "mojo_library_rule", "srcs": "c//p/lib/__init__.mojo"}}')
    assert_equal(_error_of(b), "komira_kg_code: c//p:lib: `srcs` is not a list")


def test_a_list_holding_a_value_that_is_not_a_string() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json('{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": ["c//q:q", 3]}}')
    assert_equal(_error_of(b), "komira_kg_code: c//p:lib: `deps` holds a value that is not a string")


def test_a_function_with_no_overloads() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_mojo_doc_json(
        "c//p:lib",
        '{"decl": {"kind": "package", "name": "lib", "modules": [{"kind": "module", "name": "a", "functions":'
        ' [{"kind": "function", "name": "f"}]}]}}',
    )
    assert_equal(_error_of(b), "komira_kg_code: lib.a.f: a function with no `overloads`")


def test_srcs_with_no_package_init() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json('{"c//p:lib": {"buck.type": "mojo_library_rule", "srcs": ["c//p/lib/a.mojo"]}}')
    b.add_mojo_doc_json("c//p:lib", '{"decl": {"kind": "package", "name": "lib", "modules": [{"kind": "module", "name": "a"}]}}')
    assert_equal(_error_of(b), "komira_kg_code: c//p:lib: the target's srcs hold no __init__.mojo")


def test_governs_naming_two_targets() raises:
    # Two cells hold a target at p:lib (the second imports as dlib, so the
    # import names do not collide); `//p:lib` names both.
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_uquery_json('{"d//p:lib": {"buck.type": "mojo_library_rule", "import_name": "dlib", "srcs": ["d//p/lib/__init__.mojo"]}}')
    b.add_markdown("docs/x.md", "---\ngoverns:\n  - //p:lib\n---\n")
    assert_equal(
        _error_of(b),
        "komira_kg_code: docs/x.md: governs `//p:lib`, which names 2 targets or files; give the cell",
    )


def test_two_nodes_of_different_kinds_with_one_id() raises:
    # A document whose path is a source's id would replace the file node.
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_markdown("c//p/lib/a.mojo", "# A\n")
    assert_equal(_error_of(b), "komira_kg_code: two nodes have the id c//p/lib/a.mojo: a file and a doc")


def _doc_with_f(summary: String) -> String:
    return (
        '{"decl": {"kind": "package", "name": "lib", "modules": [{"kind": "module", "name": "a", "functions":'
        ' [{"kind": "function", "name": "f", "overloads": [{"signature": "def f()", "summary": "'
        + summary
        + '"}]}]}]}}'
    )


def test_a_document_added_twice_with_other_text() raises:
    # Kept, the title would be the one added last.
    var b = CodeGraphBuilder()
    b.add_markdown("docs/d.md", "# A\n")
    b.add_markdown("docs/d.md", "# B\n")
    assert_equal(_error_of(b), "komira_kg_code: two different doc nodes have the id docs/d.md")


def test_a_doc_json_added_twice_with_other_text() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_mojo_doc_json("c//p:lib", _doc_with_f("A"))
    b.add_mojo_doc_json("c//p:lib", _doc_with_f("B"))
    assert_equal(_error_of(b), "komira_kg_code: two different function nodes have the id lib.a.f")


def test_a_library_listed_twice_with_other_srcs() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_uquery_json(
        '{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": [], "srcs": ["c//p/lib/__init__.mojo"]}}'
    )
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is listed twice with different srcs")


def test_a_library_listed_twice_with_other_import_names() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_uquery_json(
        '{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": [], "import_name": "libx",'
        ' "srcs": ["c//p/lib/__init__.mojo", "c//p/lib/a.mojo"]}}'
    )
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is listed twice with different import names")


def test_a_source_added_twice_with_other_text() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_source("c//p/lib/a.mojo", "def f(): pass\n")
    b.add_source("c//p/lib/a.mojo", "\ndef f(): pass\n")
    assert_equal(_error_of(b), "komira_kg_code: source c//p/lib/a.mojo is added twice with different text")


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
    _run("source_no_target_lists", test_a_source_no_target_lists, failed)
    _run("doc_json_no_library", test_doc_json_for_a_label_that_is_no_library, failed)
    _run("module_with_no_source", test_a_module_with_no_source, failed)
    _run("not_mojo_doc_output", test_json_that_is_not_mojo_doc_output, failed)
    _run("uquery_without_attributes", test_uquery_without_attributes, failed)
    _run("one_import_name", test_two_libraries_with_one_import_name, failed)
    _run("governs_nothing", test_governs_naming_nothing, failed)
    _run("uquery_not_object", test_uquery_that_is_not_an_object, failed)
    _run("attributes_not_object", test_attributes_that_are_not_an_object, failed)
    _run("member_not_string", test_a_member_that_is_not_a_string, failed)
    _run("member_not_list", test_a_member_that_is_not_a_list, failed)
    _run("list_non_string", test_a_list_holding_a_value_that_is_not_a_string, failed)
    _run("no_overloads", test_a_function_with_no_overloads, failed)
    _run("no_package_init", test_srcs_with_no_package_init, failed)
    _run("governs_two_targets", test_governs_naming_two_targets, failed)
    _run("one_id_two_kinds", test_two_nodes_of_different_kinds_with_one_id, failed)
    _run("document_twice", test_a_document_added_twice_with_other_text, failed)
    _run("doc_json_twice", test_a_doc_json_added_twice_with_other_text, failed)
    _run("library_twice_srcs", test_a_library_listed_twice_with_other_srcs, failed)
    _run("library_twice_import", test_a_library_listed_twice_with_other_import_names, failed)
    _run("source_twice", test_a_source_added_twice_with_other_text, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("OK")
