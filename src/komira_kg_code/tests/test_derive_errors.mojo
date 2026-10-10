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


comptime _DOC_TWICE = "komira_kg_code: document docs/d.md is added twice with different text"
comptime _DOC_JSON_TWICE = "komira_kg_code: mojo doc JSON for c//p:lib is added twice with different text"


def test_a_document_added_twice_with_other_text() raises:
    # Kept, the title would be the one added last.
    var b = CodeGraphBuilder()
    b.add_markdown("docs/d.md", "# A\n")
    b.add_markdown("docs/d.md", "# B\n")
    assert_equal(_error_of(b), _DOC_TWICE)


def test_a_document_added_twice_with_one_title_and_other_body() raises:
    # Both copies give the same doc node; only the text differs.
    var b = CodeGraphBuilder()
    b.add_markdown("docs/d.md", "# A\n")
    b.add_markdown("docs/d.md", "# A\nother body\n")
    assert_equal(_error_of(b), _DOC_TWICE)


def test_a_document_added_twice_with_one_title_and_other_governs() raises:
    # Merged, the second copy's governs edge would be added to the first's.
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_markdown("docs/d.md", "# A\n")
    b.add_markdown("docs/d.md", "---\ngoverns: [//p:lib]\n---\n# A\n")
    assert_equal(_error_of(b), _DOC_TWICE)


def test_a_doc_json_added_twice_with_other_text() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_mojo_doc_json("c//p:lib", _doc_with_f("A"))
    b.add_mojo_doc_json("c//p:lib", _doc_with_f("B"))
    assert_equal(_error_of(b), _DOC_JSON_TWICE)


def test_a_doc_json_added_twice_with_an_extra_function() raises:
    # Every node of the first copy is in the second, equal; merged, g
    # would be added.
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_mojo_doc_json("c//p:lib", _doc_with_f("A"))
    b.add_mojo_doc_json(
        "c//p:lib",
        '{"decl": {"kind": "package", "name": "lib", "modules": [{"kind": "module", "name": "a", "functions":'
        ' [{"kind": "function", "name": "f", "overloads": [{"signature": "def f()", "summary": "A"}]},'
        ' {"kind": "function", "name": "g", "overloads": [{"signature": "def g()", "summary": ""}]}]}]}}',
    )
    assert_equal(_error_of(b), _DOC_JSON_TWICE)


def _foo_doc() -> String:
    return (
        '{"decl": {"kind": "package", "name": "foo", "modules": [{"kind": "module", "name": "__init__",'
        ' "functions": [{"kind": "function", "name": "f", "overloads": [{"signature": "def f()", "summary":'
        ' ""}]}]}]}}'
    )


def test_one_symbol_id_from_two_files() raises:
    # Two libraries whose packages are both named foo give the symbol
    # foo.f, equal but for its file: only the path tells them apart.
    var b = CodeGraphBuilder()
    b.add_uquery_json(
        '{"c//p:foo": {"buck.type": "mojo_library_rule", "srcs": ["c//p/foo/__init__.mojo"]},'
        ' "c//q:bar": {"buck.type": "mojo_library_rule", "srcs": ["c//q/foo/__init__.mojo"]}}'
    )
    b.add_mojo_doc_json("c//p:foo", _foo_doc())
    b.add_mojo_doc_json("c//q:bar", _foo_doc())
    assert_equal(_error_of(b), "komira_kg_code: two different function nodes have the id foo.f")


def test_a_library_listed_twice_with_other_srcs() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_uquery_json(
        '{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": [], "srcs": ["c//p/lib/__init__.mojo"]}}'
    )
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is listed twice with different srcs")


def test_a_library_listed_twice_with_one_other_source() raises:
    # As many srcs as the first listing, one of them another file.
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_uquery_json(
        '{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": [], "import_name": null,'
        ' "srcs": ["c//p/lib/__init__.mojo", "c//p/lib/b.mojo"], "test_srcs": []}}'
    )
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is listed twice with different srcs")


def test_a_library_listed_twice_with_srcs_in_other_order() raises:
    # srcs compare as an ordered list: uquery prints them in the order
    # the target lists them.
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_uquery_json(
        '{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": [], "import_name": null,'
        ' "srcs": ["c//p/lib/a.mojo", "c//p/lib/__init__.mojo"], "test_srcs": []}}'
    )
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is listed twice with different srcs")


def test_a_library_listed_twice_with_other_deps() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_uquery_json(
        '{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": ["c//z:dep"], "import_name": null,'
        ' "srcs": ["c//p/lib/__init__.mojo", "c//p/lib/a.mojo"], "test_srcs": []}}'
    )
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is listed twice with different deps")


def test_a_library_listed_twice_with_other_test_srcs() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_uquery_json(
        '{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": [], "import_name": null,'
        ' "srcs": ["c//p/lib/__init__.mojo", "c//p/lib/a.mojo"], "test_srcs": ["c//p/lib/t.mojo"]}}'
    )
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is listed twice with different test_srcs")


def test_a_library_listed_twice_with_one_other_dep() raises:
    # As many deps as the first listing, one of them another target.
    var b = CodeGraphBuilder()
    b.add_uquery_json('{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": ["c//z:a"], "srcs": ["c//p/lib/__init__.mojo"]}}')
    b.add_uquery_json('{"c//p:lib": {"buck.type": "mojo_library_rule", "deps": ["c//z:b"], "srcs": ["c//p/lib/__init__.mojo"]}}')
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is listed twice with different deps")


def test_a_library_listed_twice_with_one_other_test_src() raises:
    # As many test_srcs as the first listing, one of them another file.
    var b = CodeGraphBuilder()
    b.add_uquery_json(
        '{"c//p:lib": {"buck.type": "mojo_library_rule", "srcs": ["c//p/lib/__init__.mojo"], "test_srcs": ["c//p/t1.mojo"]}}'
    )
    b.add_uquery_json(
        '{"c//p:lib": {"buck.type": "mojo_library_rule", "srcs": ["c//p/lib/__init__.mojo"], "test_srcs": ["c//p/t2.mojo"]}}'
    )
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is listed twice with different test_srcs")


def test_a_binary_listed_twice_with_other_srcs() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json('{"c//p:app": {"buck.type": "mojo_binary_rule", "srcs": ["c//p/main.mojo"]}}')
    b.add_uquery_json('{"c//p:app": {"buck.type": "mojo_binary_rule", "srcs": ["c//p/main.mojo", "c//p/b.mojo"]}}')
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:app is listed twice with different srcs")


def test_a_target_listed_twice_with_another_rule() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json(_LIB)
    b.add_uquery_json(
        '{"c//p:lib": {"buck.type": "mojo_binary_rule", "deps": [], "import_name": null,'
        ' "srcs": ["c//p/lib/__init__.mojo", "c//p/lib/a.mojo"], "test_srcs": []}}'
    )
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is listed twice with different rules")


def test_a_library_listed_again_with_a_rule_the_deriver_skips() raises:
    # A rule the deriver reads no nodes from still counts as the label's rule.
    var b = CodeGraphBuilder()
    b.add_uquery_json('{"c//p:lib": {"buck.type": "mojo_library_rule", "srcs": ["c//p/lib/__init__.mojo"]}}')
    b.add_uquery_json('{"c//p:lib": {"buck.type": "mojo_shared_lib_rule"}}')
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is listed twice with different rules")


def test_a_skipped_rule_listed_first_then_a_library() raises:
    var b = CodeGraphBuilder()
    b.add_uquery_json('{"c//p:lib": {"buck.type": "mojo_shared_lib_rule"}}')
    b.add_uquery_json('{"c//p:lib": {"buck.type": "mojo_library_rule", "srcs": ["c//p/lib/__init__.mojo"]}}')
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is listed twice with different rules")


def test_two_skipped_rules_for_one_label() raises:
    # Two rules the deriver skips still disagree.
    var b = CodeGraphBuilder()
    b.add_uquery_json('{"c//p:x": {"buck.type": "mojo_shared_lib_rule"}}')
    b.add_uquery_json('{"c//p:x": {"buck.type": "mojo_proto_library_rule"}}')
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:x is listed twice with different rules")


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


def test_a_label_listed_with_two_rules_of_one_length() raises:
    # The two rules have the same byte length (11), so a check that
    # compares lengths instead of text lets them through.
    var b = CodeGraphBuilder()
    b.add_uquery_json('{"c//p:x": {"buck.type": "python_test"}}')
    b.add_uquery_json('{"c//p:x": {"buck.type": "cxx_library"}}')
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:x is listed twice with different rules")


def test_a_library_listed_twice_with_import_names_of_one_length() raises:
    # `liba` and `libb` have one length: only a text compare refuses them.
    var b = CodeGraphBuilder()
    b.add_uquery_json('{"c//p:lib": {"buck.type": "mojo_library_rule", "import_name": "liba", "srcs": ["c//p/lib/__init__.mojo"]}}')
    b.add_uquery_json('{"c//p:lib": {"buck.type": "mojo_library_rule", "import_name": "libb", "srcs": ["c//p/lib/__init__.mojo"]}}')
    assert_equal(_error_of(b), "komira_kg_code: uquery JSON: c//p:lib is listed twice with different import names")


def _foo_doc_summary(summary: String) -> String:
    return (
        '{"decl": {"kind": "package", "name": "foo", "modules": [{"kind": "module", "name": "__init__",'
        ' "functions": [{"kind": "function", "name": "f", "overloads": [{"signature": "def f()", "summary": "'
        + summary
        + '"}]}]}]}}'
    )


def test_one_symbol_id_from_one_file_with_two_texts() raises:
    # Two libraries list one file; their doc JSONs give foo.f at the same
    # path with summaries A and B. Only the node text tells them apart.
    var b = CodeGraphBuilder()
    b.add_uquery_json(
        '{"c//p:a": {"buck.type": "mojo_library_rule", "srcs": ["c//p/foo/__init__.mojo"]},'
        ' "c//p:b": {"buck.type": "mojo_library_rule", "srcs": ["c//p/foo/__init__.mojo"]}}'
    )
    b.add_mojo_doc_json("c//p:a", _foo_doc_summary("A"))
    b.add_mojo_doc_json("c//p:b", _foo_doc_summary("B"))
    assert_equal(_error_of(b), "komira_kg_code: two different function nodes have the id foo.f")


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
    _run("document_twice_body", test_a_document_added_twice_with_one_title_and_other_body, failed)
    _run("document_twice_governs", test_a_document_added_twice_with_one_title_and_other_governs, failed)
    _run("doc_json_twice_extra_function", test_a_doc_json_added_twice_with_an_extra_function, failed)
    _run("symbol_two_files", test_one_symbol_id_from_two_files, failed)
    _run("library_twice_srcs", test_a_library_listed_twice_with_other_srcs, failed)
    _run("library_twice_one_other_src", test_a_library_listed_twice_with_one_other_source, failed)
    _run("library_twice_srcs_order", test_a_library_listed_twice_with_srcs_in_other_order, failed)
    _run("library_twice_deps", test_a_library_listed_twice_with_other_deps, failed)
    _run("library_twice_test_srcs", test_a_library_listed_twice_with_other_test_srcs, failed)
    _run("library_twice_one_other_dep", test_a_library_listed_twice_with_one_other_dep, failed)
    _run("library_twice_one_other_test_src", test_a_library_listed_twice_with_one_other_test_src, failed)
    _run("binary_twice_srcs", test_a_binary_listed_twice_with_other_srcs, failed)
    _run("target_twice_rule", test_a_target_listed_twice_with_another_rule, failed)
    _run("library_then_skipped_rule", test_a_library_listed_again_with_a_rule_the_deriver_skips, failed)
    _run("skipped_rule_then_library", test_a_skipped_rule_listed_first_then_a_library, failed)
    _run("two_skipped_rules", test_two_skipped_rules_for_one_label, failed)
    _run("library_twice_import", test_a_library_listed_twice_with_other_import_names, failed)
    _run("source_twice", test_a_source_added_twice_with_other_text, failed)
    _run("rules_one_length", test_a_label_listed_with_two_rules_of_one_length, failed)
    _run("import_names_one_length", test_a_library_listed_twice_with_import_names_of_one_length, failed)
    _run("symbol_one_file_two_texts", test_one_symbol_id_from_one_file_with_two_texts, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("OK")
