# =============================================================================
# src/kci_release_set/tests/test_conda_metadata_native.mojo
#   `metadata.json` of kind `native` (the package of libkomira_native.so.1)
#   and `lib_files`: the real shape komira_pack writes, and every refusal by
#   its message.
# =============================================================================
#
# tests/data/native.metadata.json is the metadata.json
# //tools/build/native:komira_native_conda wrote on the farm (unstamped:
# build h00000000_0, source_commit ""). Each refusal case changes ONE key of
# that file, or of the real library file (tests/data/library.metadata.json),
# and asserts the message.
#
# ROWS
#   (1) the real native file parses: kind, depends (the guard and the glibc
#       floor, no compiler pin), lib_files (the link name, then the shared
#       object), no Mojo field, nothing ignored; `is_member_kind` holds for a
#       library and the native package, not for a metapackage;
#   (2) a key of another kind is refused on a native package (each library
#       key, doc_files, members), and lib_files on a metapackage;
#   (3) a native package missing `lib_files`, or holding no file in it;
#   (4) every lib_files row refusal: not an array, not an object, a key
#       twice, missing path, a path not under lib/ or with an empty, '.' or
#       '..' component, a path twice, both sha256 and target, neither, a bad
#       sha256, an empty target, a target that is not a bare file name, a
#       link whose target no file row installs (a link to a link counts as
#       none); an unknown row key is ignored and listed;
#   (5) a library: lib_files absent is recorded, [] and a file row parse, a
#       malformed row is refused as on the native package.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_json import JsonValue, parse_json_value

from kci_release_set import (
    KIND_LIBRARY,
    KIND_METAPACKAGE,
    KIND_NATIVE,
    is_member_kind,
    parse_conda_metadata,
    read_conda_metadata,
)

comptime _LIB = "src/kci_release_set/tests/data/library.metadata.json"
comptime _META = "src/kci_release_set/tests/data/komira/metadata.json"
comptime _NATIVE = "src/kci_release_set/tests/data/native.metadata.json"
comptime _SRC = "m.json"
comptime _PFX = "conda metadata 'm.json': "
comptime _H = "a9ab5e8e7b9054f1f9357d8c21e72706252eddbf89d84622e852ff898e9179e3"
comptime _SO = "lib/libkomira_native.so.1"


def _edit(path: String, key: String, raw: String = String(""), drop: Bool = False) raises -> String:
    """The file at `path` with member `key` removed (`drop`), replaced by the
    JSON `raw`, or (absent before) appended with it."""
    var doc = parse_json_value(Path(path).read_text())
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


def _libs(rows: String, path: String = String(_NATIVE)) raises -> String:
    return _edit(path, String("lib_files"), rows)


def _file(path: String, sha: String = String(_H)) -> String:
    return String('{"path":"') + path + String('","sha256":"') + sha + String('"}')


def _link(path: String, target: String) -> String:
    return String('{"path":"') + path + String('","target":"') + target + String('"}')


def test_real_native_metadata_parses() raises:
    var md = read_conda_metadata(String(_NATIVE))
    assert_equal(md.schema_version, 1)
    assert_equal(len(md.ignored_keys), 0)
    assert_equal(md.kind, String(KIND_NATIVE))
    assert_true(md.is_native())
    assert_false(md.is_metapackage())
    assert_equal(md.name, String("komira_native"))
    assert_equal(md.version, String("1.0.0"))
    assert_equal(md.subdir, String("linux-64"))
    assert_equal(md.build, String("h00000000_0"))
    assert_equal(md.file_name, String("komira_native-1.0.0-h00000000_0.conda"))
    assert_equal(len(md.depends), 2)
    assert_equal(md.depends[0], String("__linux"))
    assert_equal(md.depends[1], String("__glibc >=2.34"))
    assert_false(md.stamped)
    assert_equal(md.source_commit, String(""))
    assert_equal(md.label, String("komira//tools/build/native:komira_native_conda"))
    assert_true(md.has_lib_files)
    assert_equal(len(md.lib_files), 2)
    assert_equal(md.lib_files[0].path, String("lib/libkomira_native.so"))
    assert_true(md.lib_files[0].is_link())
    assert_equal(md.lib_files[0].target, String("libkomira_native.so.1"))
    assert_equal(md.lib_files[0].sha256_hex, String(""))
    assert_equal(md.lib_files[1].path, String(_SO))
    assert_false(md.lib_files[1].is_link())
    assert_equal(md.lib_files[1].sha256_hex, String(_H))
    # no Mojo: none of a library's fields, no member rows
    assert_equal(md.import_name, String(""))
    assert_equal(md.mojo_pin, String(""))
    assert_equal(md.payload_path, String(""))
    assert_equal(md.payload_sha256, String(""))
    assert_false(md.has_doc_files)
    assert_equal(len(md.members), 0)
    assert_true(is_member_kind(String(KIND_NATIVE)))
    assert_true(is_member_kind(String(KIND_LIBRARY)))
    assert_false(is_member_kind(String(KIND_METAPACKAGE)))


def test_refuses_a_key_of_another_kind() raises:
    for k in ["import_name", "mojo_pin", "payload_path"]:
        _expect(
            _edit(String(_NATIVE), String(k), String('"x"')),
            String("'") + String(k) + String("' does not belong to a native"),
        )
    _expect(
        _edit(String(_NATIVE), String("payload_sha256"), String('"') + String(_H) + String('"')),
        String("'payload_sha256' does not belong to a native"),
    )
    _expect(_edit(String(_NATIVE), String("doc_files"), String("[]")), String("'doc_files' does not belong to a native"))
    _expect(_edit(String(_NATIVE), String("members"), String("[]")), String("'members' does not belong to a native"))
    _expect(_edit(String(_META), String("lib_files"), String("[]")), String("'lib_files' does not belong to a metapackage"))


def test_a_native_package_ships_a_file() raises:
    _expect(_edit(String(_NATIVE), String("lib_files"), drop=True), String("missing 'lib_files'"))
    _expect(_libs(String("[]")), String("a native package's 'lib_files' holds no file"))
    for k in ["name", "version", "build", "depends", "label"]:
        _expect(_edit(String(_NATIVE), String(k), drop=True), String("missing '") + String(k) + String("'"))


def test_refuses_bad_lib_files_rows() raises:
    _expect(_libs(String('"lib/libkomira_native.so.1"')), String("'lib_files' is not an array"))
    _expect(_libs(String("[1]")), String("lib_files[0]: not an object"))
    _expect(
        _libs(String('[{"path":"') + String(_SO) + String('","path":"x","sha256":"') + String(_H) + String('"}]')),
        String("lib_files[0]: 'path' is given twice"),
    )
    _expect(_libs(String('[{"sha256":"') + String(_H) + String('"}]')), String("lib_files[0]: missing 'path'"))
    _expect(_libs(String("[") + _file(String("")) + String("]")), String("lib_files[0]: 'path' is EMPTY"))
    for bad in ["share/libkomira_native.so.1", "lib/", "lib/../x.so", "lib//x.so", "lib/./x.so", "libx.so"]:
        _expect(
            _libs(String("[") + _file(String(bad)) + String("]")),
            String("lib_files[0]: 'path' ") + String(bad) + String(" is not under lib/ with no empty, '.' or '..' component"),
        )
    _expect(
        _libs(String("[") + _file(String(_SO)) + String(",") + _file(String(_SO)) + String("]")),
        String("lib_files[1]: 'path' ") + String(_SO) + String(" is given twice"),
    )
    _expect(
        _libs(
            String('[{"path":"') + String(_SO) + String('","sha256":"') + String(_H) + String('","target":"y"}]')
        ),
        String("lib_files[0]: has both 'sha256' (a file) and 'target' (a link)"),
    )
    _expect(
        _libs(String('[{"path":"') + String(_SO) + String('"}]')),
        String("lib_files[0]: missing 'sha256' (a file) or 'target' (a link)"),
    )
    _expect(
        _libs(String("[") + _file(String(_SO), String("A9AB")) + String("]")),
        String("lib_files[0]: 'sha256' is not 64 lowercase hex characters"),
    )
    _expect(
        _libs(String("[") + _file(String(_SO)) + String(",") + _link(String("lib/x.so"), String("")) + String("]")),
        String("lib_files[1]: 'target' is EMPTY"),
    )
    for bad in ["../libkomira_native.so.1", "sub/libkomira_native.so.1", ".", ".."]:
        _expect(
            _libs(String("[") + _file(String(_SO)) + String(",") + _link(String("lib/x.so"), String(bad)) + String("]")),
            String("lib_files[1]: 'target' ") + String(bad) + String(" is not a file name in the link's directory"),
        )
    # a link whose target no file row installs: absent, in another directory,
    # or itself a link
    _expect(
        _libs(String("[") + _link(String("lib/libkomira_native.so"), String("libkomira_native.so.2")) + String(",") + _file(String(_SO)) + String("]")),
        String("lib_files[0]: link lib/libkomira_native.so -> libkomira_native.so.2: no file row of 'lib_files' is lib/libkomira_native.so.2"),
    )
    _expect(
        _libs(String("[") + _file(String(_SO)) + String(",") + _link(String("lib/sub/libkomira_native.so"), String("libkomira_native.so.1")) + String("]")),
        String("lib_files[1]: link lib/sub/libkomira_native.so -> libkomira_native.so.1: no file row of 'lib_files' is lib/sub/libkomira_native.so.1"),
    )
    _expect(
        _libs(String("[") + _link(String("lib/a.so"), String("b.so")) + String(",") + _link(String("lib/b.so"), String("a.so")) + String("]")),
        String("lib_files[0]: link lib/a.so -> b.so: no file row of 'lib_files' is lib/b.so"),
    )
    # an unknown key in a row of a known major is ignored and listed
    var md = parse_conda_metadata(
        _libs(String('[{"mode":1,"path":"') + String(_SO) + String('","sha256":"') + String(_H) + String('"}]')),
        String(_SRC),
    )
    assert_equal(len(md.ignored_keys), 1)
    assert_equal(md.ignored_keys[0], String("lib_files[0].mode"))
    assert_equal(len(md.lib_files), 1)


def test_a_library_may_carry_lib_files() raises:
    var absent = read_conda_metadata(String(_LIB))
    assert_false(absent.has_lib_files)
    assert_equal(len(absent.lib_files), 0)
    var empty = parse_conda_metadata(_libs(String("[]"), String(_LIB)), String(_SRC))
    assert_true(empty.has_lib_files)
    assert_equal(len(empty.lib_files), 0)
    assert_equal(len(empty.ignored_keys), 0, "lib_files is a known key of a library")
    var one = parse_conda_metadata(
        _libs(String("[") + _file(String("lib/libkomira_log_holder.a")) + String("]"), String(_LIB)), String(_SRC)
    )
    assert_equal(len(one.lib_files), 1)
    assert_equal(one.lib_files[0].path, String("lib/libkomira_log_holder.a"))
    _expect(
        _libs(String("[") + _file(String("bin/x")) + String("]"), String(_LIB)),
        String("lib_files[0]: 'path' bin/x is not under lib/ with no empty, '.' or '..' component"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
