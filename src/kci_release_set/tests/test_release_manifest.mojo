# =============================================================================
# src/kci_release_set/tests/test_release_manifest.mojo
#   `release.json`: rendered byte-exact, parsed back to the same value, and
#   every refusal by its message.
# =============================================================================
#
# The golden set hash below was computed outside Mojo (python3 hashlib over
# the two sorted lines `<name>\t<version>\t<build>\t<sha256>\n`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_set import (
    ReleaseEntry,
    ReleaseManifest,
    parse_release_manifest,
    render_release_manifest,
)

comptime _A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
comptime _C = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
comptime _SET = "445764fc69d946e0f064ba064b7f8382d24e26f3fe94e5061cdf4252b72f1a2d"
comptime _PFX = "release manifest 'r.json': "


def _entry(name: String, kind: String, sha: String) -> ReleaseEntry:
    var e = ReleaseEntry()
    e.artifact_type = String("CONDA")
    e.build = String("0")
    e.dir = name.copy()
    e.kind = kind.copy()
    e.name = name.copy()
    e.sha256_hex = sha.copy()
    e.subdir = String("linux-64")
    e.version = String("0.1.7")
    return e^


def _manifest() -> ReleaseManifest:
    var r = ReleaseManifest()
    # deliberately out of order: render sorts
    r.entries.append(_entry(String("komira_hash"), String("library"), String(_A)))
    r.entries.append(_entry(String("komira"), String("metapackage"), String(_C)))
    r.set_hash = String(_SET)
    return r^


def _row(name: String, kind: String, sha: String) -> String:
    return (
        String('{"artifact_type":"CONDA","build":"0","dir":"') + name + String('","kind":"')
        + kind + String('","name":"') + name + String('","sha256":"') + sha
        + String('","subdir":"linux-64","version":"0.1.7"}')
    )


def _golden() -> String:
    return (
        String('{"members":[') + _row(String("komira"), String("metapackage"), String(_C))
        + String(",") + _row(String("komira_hash"), String("library"), String(_A))
        + String('],"schema":"kci.release_set.v1","set_hash":"') + String(_SET) + String('"}\n')
    )


def test_render_is_byte_exact() raises:
    assert_equal(render_release_manifest(_manifest()), _golden())


def test_parse_of_render_is_the_value() raises:
    var parsed = parse_release_manifest(render_release_manifest(_manifest()), String("r.json"))
    assert_equal(len(parsed.entries), 2)
    assert_equal(parsed.entries[0].name, String("komira"))
    assert_equal(parsed.entries[0].kind, String("metapackage"))
    assert_equal(parsed.entries[1].name, String("komira_hash"))
    assert_equal(parsed.entries[1].sha256_hex, String(_A))
    assert_equal(parsed.set_hash, String(_SET))
    # `same_as` compares every field; the sorted original is the parsed value
    var sorted = ReleaseManifest()
    sorted.entries.append(_entry(String("komira"), String("metapackage"), String(_C)))
    sorted.entries.append(_entry(String("komira_hash"), String("library"), String(_A)))
    sorted.set_hash = String(_SET)
    assert_true(parsed.same_as(sorted))
    var other = sorted.copy()
    other.entries[1].build = String("1")
    assert_false(parsed.same_as(other))


def test_render_refuses_a_wrong_set_hash() raises:
    var r = _manifest()
    r.set_hash = String(_A)
    try:
        _ = render_release_manifest(r)
    except e:
        assert_true(String(e).find(String("is not the hash of its members")) >= 0, String(e))
        return
    assert_true(False, "rendered a wrong set hash")


def _refusal(text: String) -> String:
    try:
        _ = parse_release_manifest(text, String("r.json"))
    except e:
        return String(e)
    return String("<parsed>")


def _expect(text: String, why: String) raises:
    assert_equal(_refusal(text), String(_PFX) + why)


def _g() -> String:
    return _golden()


def test_refusals_of_the_document() raises:
    assert_true(_refusal(String("{")).startswith(String(_PFX) + String("not JSON: ")))
    _expect(String("[]"), String("not a JSON object"))
    _expect(String('{"zzz":1,') + String(_g()[byte = 1:]), String("unknown key 'zzz'"))
    _expect(
        String('{"schema":"kci.release_set.v1",') + String(_g()[byte = 1:]),
        String("'schema' is given twice"),
    )
    _expect(
        String('{"members":[],"schema":"kci.release_set.v1"}'), String("missing 'set_hash'")
    )
    _expect(
        _g().replace(String('"kci.release_set.v1"'), String('"kci.release_set.v2"')),
        String("schema 'kci.release_set.v2' is not 'kci.release_set.v1'"),
    )
    _expect(
        _g().replace(String('"kci.release_set.v1"'), String("1")), String("'schema' is not a string")
    )
    _expect(
        _g().replace(String(_SET), String("00")),
        String("'set_hash' is not 64 lowercase hex characters"),
    )
    _expect(
        String('{"members":[],"schema":"kci.release_set.v1","set_hash":"') + String(_SET)
        + String('"}'),
        String("'members' is EMPTY"),
    )
    _expect(
        String('{"members":{},"schema":"kci.release_set.v1","set_hash":"') + String(_SET)
        + String('"}'),
        String("'members' is not an array"),
    )


def test_refusals_of_a_member_row() raises:
    _expect(
        _g().replace(String('"dir":"komira",'), String("")),
        String("members[0]: missing 'dir'"),
    )
    _expect(
        _g().replace(String('"dir":"komira",'), String('"dir":"komira","x":"y",')),
        String("members[0]: unknown key 'x'"),
    )
    _expect(
        _g().replace(String('"dir":"komira",'), String('"dir":"other",')),
        String("members[0]: 'dir' 'other' is not the member's name 'komira'"),
    )
    _expect(
        _g().replace(String('"kind":"library"'), String('"kind":""')),
        String("members[1]: 'kind' is EMPTY on a CONDA member"),
    )
    _expect(
        _g().replace(String('"version":"0.1.7"}]'), String('"version":7}]')),
        String("members[1]: 'version' is not a string"),
    )
    _expect(
        _g().replace(String(_A), String(_A).upper()),
        String("members[1]: 'sha256' is not 64 lowercase hex characters"),
    )


def test_refuses_a_python_row_with_conda_fields() raises:
    _expect(
        _g().replace(String('"artifact_type":"CONDA","build":"0","dir":"komira_hash"'),
                     String('"artifact_type":"PYTHON","build":"0","dir":"komira_hash"')),
        String("members[1]: 'build' is set on a PYTHON member; only CONDA members have one"),
    )


def test_refuses_unsorted_or_repeated_members() raises:
    var swapped = (
        String('{"members":[') + _row(String("komira_hash"), String("library"), String(_A))
        + String(",") + _row(String("komira"), String("metapackage"), String(_C))
        + String('],"schema":"kci.release_set.v1","set_hash":"') + String(_SET) + String('"}\n')
    )
    _expect(swapped, String("members are not sorted by name: 'komira' comes after 'komira_hash'"))
    var twice = (
        String('{"members":[') + _row(String("komira"), String("metapackage"), String(_C))
        + String(",") + _row(String("komira"), String("metapackage"), String(_C))
        + String('],"schema":"kci.release_set.v1","set_hash":"') + String(_SET) + String('"}\n')
    )
    _expect(twice, String("member 'komira' is given twice"))


def test_refuses_a_set_hash_that_is_not_its_members() raises:
    var t = _g().replace(String('"version":"0.1.7"}]'), String('"version":"0.1.8"}]'))
    var why = _refusal(t)
    assert_true(
        why.startswith(String(_PFX) + String("'set_hash' ") + String(_SET)
                       + String(" is not the hash of its members (")),
        why,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
