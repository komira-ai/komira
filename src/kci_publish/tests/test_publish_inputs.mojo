# =============================================================================
# src/kci_publish/tests/test_publish_inputs.mojo -- contract 0.1, 0.2, 0.6:
#   `load_release` over a release directory, each refusal caused by ONE
#   change to a good directory.
# =============================================================================
#
# ROWS
#   (0) control: the good directory (two libraries and a metapackage)
#       loads, in declaration order, and its recomputed set hash is the one
#       release.json records;
#   (1) a declared artifact with no directory; an undeclared directory;
#   (2) a manifest whose name is not the declaration's; a file whose bytes
#       are not the manifest's sha256; metadata disagreeing with the
#       manifest (size); a `file` that is not a bare name (0.6: nothing
#       outside the member directory can be named);
#   (3) release.json missing; release.json of another set (stale).
#
# Written under TEST_TMPDIR by `ExampleRelease`; no network.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import assert_equal, assert_true

from kci_publish.inputs import load_release
from kci_publish.release_fixture import (
    ExampleRelease,
    example_declarations,
    example_loaded,
    write_text_file,
)
from kci_artifact_declaration import parse_artifact_declarations


def _root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pin_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _read(path: String) raises -> String:
    return open(path, "r").read()


def _refused(r: ExampleRelease, dir: String, needle: String) raises:
    var raised = False
    try:
        _ = example_loaded(r, dir)
    except e:
        raised = True
        assert_true(String(e).find(needle) >= 0, String("'") + String(e) + String("' does not say '") + needle + String("'"))
    assert_true(raised, String("not refused; expected: ") + needle)


def test_control_loads() raises:
    var r = ExampleRelease()
    var d = _root(String("control"))
    r.write(d)
    var loaded = example_loaded(r, d)
    assert_equal(len(loaded.members), 3)
    assert_equal(loaded.members[0].declaration, String("komira_alpha"))
    assert_equal(loaded.members[1].declaration, String("komira_beta"))
    assert_equal(loaded.members[2].declaration, String("komira"))
    assert_equal(loaded.set_hash(), r.set_hash(d))
    assert_equal(loaded.set_hash().byte_length(), 64)
    print("  test_control_loads: PASS")


def test_every_declared_artifact_and_nothing_else() raises:
    var r = ExampleRelease()
    var d = _root(String("missing"))
    r.write(d)
    var text = r.declarations_text() + String(
        'artifacts {\n  name: "komira_extra"\n  build_system: "buck2"\n  args: "{out_dir}"\n}\n'
    )
    var raised = False
    try:
        _ = load_release(parse_artifact_declarations(text, String("d.textproto")), d)
    except e:
        raised = True
        assert_true(String(e).find(String("artifact 'komira_extra' is declared but the release directory holds no 'komira_extra/'")) >= 0, String(e))
    assert_true(raised)

    var d2 = _root(String("stray"))
    r.write(d2)
    makedirs(d2 + String("/komira_stray"), exist_ok=True)
    _refused(r, d2, String("'komira_stray' is in the release directory but no artifact of that name is declared"))
    print("  test_every_declared_artifact_and_nothing_else: PASS")


def test_each_member_is_verified_over_its_bytes() raises:
    var r = ExampleRelease()
    # the manifest names another artifact
    var d = _root(String("name"))
    r.write(d)
    var mpath = d + String("/komira_alpha/manifest.json")
    write_text_file(mpath, _read(mpath).replace(String('"name":"komira_alpha"'), String('"name":"komira_other"')))
    _refused(r, d, String("artifact 'komira_alpha'"))
    # the file's bytes are not the manifest's sha256 (same length)
    var d2 = _root(String("sha"))
    r.write(d2)
    write_text_file(d2 + String("/komira_beta/") + r.file_name(String("komira_beta")), String("beta conda bytez"))
    _refused(r, d2, String("artifact 'komira_beta'"))
    # metadata disagrees with the file (size)
    var r3 = ExampleRelease()
    r3.set_meta(String("komira_alpha"), String("size"), String("999"))
    r3.omit_release_json = True
    var d3 = _root(String("size"))
    r3.write(d3)
    _refused(r3, d3, String("artifact 'komira_alpha'"))
    # 0.6: `file` is not a bare name
    var d4 = _root(String("bare"))
    r.write(d4)
    var m4 = d4 + String("/komira_alpha/manifest.json")
    write_text_file(m4, _read(m4).replace(String('"file":"komira_alpha'), String('"file":"../komira_beta/komira_alpha')))
    _refused(r, d4, String("not a file name in the artifact's directory"))
    print("  test_each_member_is_verified_over_its_bytes: PASS")


def test_release_json_is_a_marker_never_an_authority() raises:
    var r = ExampleRelease()
    r.omit_release_json = True
    var d = _root(String("nojson"))
    r.write(d)
    _refused(r, d, String("holds no release.json: the BUILD step writes it last"))

    var good = ExampleRelease()
    var d2 = _root(String("stale"))
    good.write(d2)
    var other = ExampleRelease()
    other.build_number = 4
    var d3 = _root(String("other"))
    other.write(d3)
    write_text_file(d2 + String("/release.json"), _read(d3 + String("/release.json")))
    _refused(good, d2, String("release.json is not what the member directories recompute to"))
    print("  test_release_json_is_a_marker_never_an_authority: PASS")


def main() raises:
    test_control_loads()
    test_every_declared_artifact_and_nothing_else()
    test_each_member_is_verified_over_its_bytes()
    test_release_json_is_a_marker_never_an_authority()
    print("test_publish_inputs: ALL PASS")
