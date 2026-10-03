# =============================================================================
# src/kci_release_set/tests/test_conda_metadata.mojo
#   `metadata.json`: the real shapes komira_pack writes, and every refusal by
#   its message.
# =============================================================================
#
# tests/data holds metadata.json files komira_pack wrote on the farm
# (stamped 7, commit 0123..., timestamp 86400000, as
# tools/build/tests/functional/conda_set.sh stamps them): a library with a
# set dependency (komira_name_registry), one without (komira_hash), and the
# metapackage `conda-meta` made of the two. Each refusal case changes ONE key
# of a real file (through komira_json, so the rest stays byte-identical in
# meaning) and asserts the message.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_json import JsonValue, parse_json_value

from kci_release_set import (
    KIND_LIBRARY,
    KIND_METAPACKAGE,
    parse_conda_metadata,
    read_conda_metadata,
)

comptime _DATA = "src/kci_release_set/tests/data/"
comptime _LIB = "src/kci_release_set/tests/data/library.metadata.json"
comptime _LIB0 = "src/kci_release_set/tests/data/library_nodeps.metadata.json"
comptime _META = "src/kci_release_set/tests/data/komira/metadata.json"
comptime _SRC = "m.json"
comptime _PFX = "conda metadata 'm.json': "


def _text(path: String) raises -> String:
    return Path(path).read_text()


def _edit(path: String, key: String, raw: String = String(""), drop: Bool = False) raises -> String:
    """The file at `path` with member `key` removed (`drop`), replaced by the
    JSON `raw`, or (absent before) appended with it."""
    var doc = parse_json_value(_text(path))
    var out = JsonValue.empty_object()
    var seen = False
    for i in range(doc.num_members()):
        var k = doc.key_at(i)
        if k == key:
            seen = True
            if drop:
                continue
            out.set_member(k^, parse_json_value(raw))
        else:
            out.set_member(k^, doc.value_at(i))
    if not seen and not drop:
        out.set_member(key.copy(), parse_json_value(raw))
    return out.serialize()


def _refusal(text: String) -> String:
    try:
        _ = parse_conda_metadata(text, String(_SRC))
    except e:
        return String(e)
    return String("<parsed>")


def _expect(text: String, why: String) raises:
    assert_equal(_refusal(text), String(_PFX) + why)


def test_real_library_metadata_parses() raises:
    var md = read_conda_metadata(String(_LIB))
    assert_equal(md.schema, 1)
    assert_equal(md.kind, String(KIND_LIBRARY))
    assert_equal(md.name, String("komira_name_registry"))
    assert_equal(md.version, String("0.1.7"))
    assert_equal(md.subdir, String("linux-64"))
    assert_equal(md.build, String("0"))
    assert_equal(md.build_number, 0)
    assert_equal(md.file_name, String("komira_name_registry-0.1.7-0.conda"))
    assert_equal(md.size, 62966)
    assert_equal(len(md.depends), 3)
    assert_equal(md.depends[0], String("__linux"))
    assert_equal(md.depends[1], String("mojo-compiler ==1.0.0"))
    assert_equal(md.depends[2], String("komira_hash ==0.1.7"))
    assert_equal(md.timestamp_ms, 86400000)
    assert_equal(md.source_commit, String("0123456789abcdef0123456789abcdef01234567"))
    assert_true(md.stamped)
    assert_equal(md.label, String("komira//src/komira_name_registry:komira_name_registry_conda"))
    assert_equal(md.import_name, String("komira_name_registry"))
    assert_equal(md.mojo_pin, String("1.0.0"))
    assert_equal(md.payload_path, String("lib/mojo/komira_name_registry.mojoc"))
    assert_equal(
        md.payload_sha256, String("a30329bcaa0ef57c36f2e87ea1352bd82ddfc546d4b785325993f18001ec0941")
    )
    assert_equal(len(md.members), 0)
    assert_false(md.is_metapackage())
    assert_equal(md.source, String(_LIB))


def test_real_library_without_deps_parses() raises:
    var md = read_conda_metadata(String(_LIB0))
    assert_equal(md.name, String("komira_hash"))
    assert_equal(len(md.depends), 2)


def test_real_metapackage_metadata_parses() raises:
    var md = read_conda_metadata(String(_META))
    assert_equal(md.kind, String(KIND_METAPACKAGE))
    assert_true(md.is_metapackage())
    assert_equal(md.name, String("komira"))
    assert_equal(md.file_name, String("komira-0.1.7-0.conda"))
    assert_equal(md.size, 17854)
    assert_equal(md.import_name, String(""))
    assert_equal(md.payload_sha256, String(""))
    assert_equal(len(md.members), 2)
    assert_equal(md.members[0].name, String("komira_hash"))
    assert_equal(md.members[0].version, String("0.1.7"))
    assert_equal(
        md.members[0].sha256_hex,
        String("94a65a7d5ca61240531cfc9271b1ccceaacd7f5e79ff88c8976edc5695bf15ce"),
    )
    assert_false(md.members[0].has_build)
    assert_equal(md.members[1].name, String("komira_name_registry"))
    assert_equal(len(md.depends), 3)


def test_member_row_with_build_parses() raises:
    var rows = (
        String('[{"build":"h01234567_7","name":"komira_hash","sha256":"')
        + String("94a65a7d5ca61240531cfc9271b1ccceaacd7f5e79ff88c8976edc5695bf15ce")
        + String('","version":"0.1.7"}]')
    )
    var md = parse_conda_metadata(_edit(String(_META), String("members"), rows), String(_SRC))
    assert_true(md.members[0].has_build)
    assert_equal(md.members[0].build, String("h01234567_7"))


def test_unstamped_may_have_an_empty_source_commit() raises:
    var t = _edit(String(_LIB), String("stamped"), String("false"))
    var md = parse_conda_metadata(_edit_text(t, String("source_commit"), String('""')), String(_SRC))
    assert_false(md.stamped)
    assert_equal(md.source_commit, String(""))


def _edit_text(text: String, key: String, raw: String) raises -> String:
    var doc = parse_json_value(text)
    var out = JsonValue.empty_object()
    for i in range(doc.num_members()):
        var k = doc.key_at(i)
        if k == key:
            out.set_member(k^, parse_json_value(raw))
        else:
            out.set_member(k^, doc.value_at(i))
    return out.serialize()


def test_refuses_not_json_and_not_an_object() raises:
    assert_true(_refusal(String("{")).startswith(String(_PFX) + String("not JSON: ")))
    _expect(String("[]"), String("not a JSON object"))


def test_refuses_a_key_twice() raises:
    var t = _text(String(_LIB))
    _expect(String('{"label":"x",') + String(t[byte = 1:]), String("'label' is given twice"))


def test_refuses_an_unknown_key() raises:
    _expect(_edit(String(_LIB), String("zzz"), String("1")), String("unknown key 'zzz'"))


def test_refuses_a_key_of_the_other_kind() raises:
    _expect(
        _edit(String(_LIB), String("members"), String("[]")),
        String("'members' does not belong to a library"),
    )
    _expect(
        _edit(String(_META), String("import_name"), String('"komira"')),
        String("'import_name' does not belong to a metapackage"),
    )


def test_refuses_an_unknown_kind() raises:
    _expect(
        _edit(String(_LIB), String("kind"), String('"binary"')),
        String("kind 'binary' is neither 'library' nor 'metapackage'"),
    )


def test_refuses_every_missing_key() raises:
    var lib_keys = List[String]()
    for k in [
        "schema", "kind", "name", "version", "subdir", "build", "build_number", "file_name",
        "size", "depends", "timestamp_ms", "source_commit", "stamped", "label",
        "import_name", "mojo_pin", "payload_path", "payload_sha256",
    ]:
        lib_keys.append(String(k))
    for i in range(len(lib_keys)):
        _expect(
            _edit(String(_LIB), lib_keys[i], drop=True),
            String("missing '") + lib_keys[i] + String("'"),
        )
    _expect(_edit(String(_META), String("members"), drop=True), String("missing 'members'"))


def test_refuses_wrong_types() raises:
    _expect(_edit(String(_LIB), String("schema"), String('"1"')), String("'schema' is not an integer"))
    _expect(_edit(String(_LIB), String("size"), String("1.5")), String("'size' is not an integer"))
    _expect(
        _edit(String(_LIB), String("build_number"), String("true")),
        String("'build_number' is not an integer"),
    )
    _expect(
        _edit(String(_LIB), String("timestamp_ms"), String('"86400000"')),
        String("'timestamp_ms' is not an integer"),
    )
    _expect(_edit(String(_LIB), String("stamped"), String('"true"')), String("'stamped' is not a boolean"))
    _expect(_edit(String(_LIB), String("depends"), String('"__linux"')), String("'depends' is not an array"))
    _expect(
        _edit(String(_LIB), String("depends"), String('["__linux",1]')),
        String("depends[1] is not a non-empty string"),
    )
    _expect(
        _edit(String(_LIB), String("depends"), String('[""]')),
        String("depends[0] is not a non-empty string"),
    )
    _expect(_edit(String(_LIB), String("name"), String("5")), String("'name' is not a string"))
    _expect(_edit(String(_LIB), String("label"), String("null")), String("'label' is not a string"))
    _expect(_edit(String(_META), String("members"), String("{}")), String("'members' is not an array"))


def test_refuses_empty_strings() raises:
    _expect(_edit(String(_LIB), String("name"), String('""')), String("'name' is EMPTY"))
    _expect(_edit(String(_LIB), String("build"), String('""')), String("'build' is EMPTY"))
    _expect(
        _edit(String(_LIB), String("source_commit"), String('""')),
        String("'source_commit' is EMPTY"),
    )


def test_refuses_bad_values() raises:
    _expect(_edit(String(_LIB), String("schema"), String("2")), String("schema 2 is not 1"))
    _expect(_edit(String(_LIB), String("build_number"), String("-1")), String("'build_number' is negative"))
    _expect(_edit(String(_LIB), String("size"), String("0")), String("'size' is not positive"))
    _expect(
        _edit(String(_LIB), String("payload_sha256"), String('"ABC"')),
        String("'payload_sha256' is not 64 lowercase hex characters"),
    )


def test_refuses_bad_member_rows() raises:
    var h = String("94a65a7d5ca61240531cfc9271b1ccceaacd7f5e79ff88c8976edc5695bf15ce")
    _expect(
        _edit(String(_META), String("members"), String("[1]")),
        String("members[0]: not an object"),
    )
    _expect(
        _edit(
            String(_META),
            String("members"),
            String('[{"name":"a","version":"1","sha256":"') + h + String('","extra":1}]'),
        ),
        String("members[0]: unknown key 'extra'"),
    )
    _expect(
        _edit(
            String(_META),
            String("members"),
            String('[{"name":"a","version":"1","sha256":"') + h + String('","name":"b"}]'),
        ),
        String("members[0]: 'name' is given twice"),
    )
    _expect(
        _edit(String(_META), String("members"), String('[{"name":"a","version":"1"}]')),
        String("members[0]: missing 'sha256'"),
    )
    _expect(
        _edit(String(_META), String("members"), String('[{"name":"a","version":"1","sha256":"00"}]')),
        String("members[0]: 'sha256' is not 64 lowercase hex characters"),
    )
    _expect(
        _edit(
            String(_META),
            String("members"),
            String('[{"name":"a","version":"1","build":"","sha256":"') + h + String('"}]'),
        ),
        String("members[0]: 'build' is EMPTY"),
    )


def test_read_names_an_unreadable_file() raises:
    try:
        _ = read_conda_metadata(String(_DATA) + String("absent.json"))
    except e:
        assert_true(
            String(e).startswith(
                String("conda metadata '") + String(_DATA) + String("absent.json' cannot be read: ")
            )
        )
        return
    assert_true(False, "an absent file was read")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
