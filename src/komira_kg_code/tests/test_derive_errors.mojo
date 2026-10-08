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


def main() raises:
    test_a_source_no_target_lists()
    test_doc_json_for_a_label_that_is_no_library()
    test_a_module_with_no_source()
    test_json_that_is_not_mojo_doc_output()
    test_uquery_without_attributes()
    test_two_libraries_with_one_import_name()
    test_governs_naming_nothing()
    print("OK")
