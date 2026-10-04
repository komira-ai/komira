# =============================================================================
# src/kci_release_set/tests/test_release_manifest.mojo
#   `release.json` (kci.release_set major 2): rendered byte-exact, parsed
#   back to the same value, the release identity checked, every refusal by
#   its message.
# =============================================================================
#
# The golden set hash below was computed outside Mojo (python3 hashlib over
# "release_set\t2\t<_REV>\tlinux-x86_64\n" then the two sorted member lines
# `<name>\t<platform>\t<version>\t<build>\t<subdir>\t<artifact_type>\t<sha256>\n`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_set import (
    ReleaseEntry,
    ReleaseIdentity,
    ReleaseManifest,
    entries_set_hash,
    parse_release_manifest,
    render_release_manifest,
)

comptime _A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
comptime _C = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
comptime _REV = "0123456789abcdef0123456789abcdef01234567"
comptime _SET = "c5e97905a05bcab80064d0b583b4f963ea55cdc03ebc73959a623dc0dfbf941c"
comptime _PFX = "release manifest 'r.json': "


def _entry(name: String, kind: String, sha: String) -> ReleaseEntry:
    var e = ReleaseEntry()
    e.artifact_type = String("CONDA")
    e.build = String("0")
    e.dir = name.copy()
    e.kind = kind.copy()
    e.name = name.copy()
    e.platform = String("linux-x86_64")
    e.sha256_hex = sha.copy()
    e.subdir = String("linux-64")
    e.version = String("0.1.7")
    return e^


def _manifest() raises -> ReleaseManifest:
    var r = ReleaseManifest()
    r.set_identity(ReleaseIdentity(String(_REV), String("linux-x86_64"), String("gh-1"), 1))
    # deliberately out of order: render sorts
    r.entries.append(_entry(String("komira_hash"), String("library"), String(_A)))
    r.entries.append(_entry(String("komira"), String("metapackage"), String(_C)))
    r.set_hash = String(_SET)
    return r^


def _row(name: String, kind: String, sha: String) -> String:
    return (
        String('{"artifact_type":"CONDA","build":"0","dir":"') + name + String('","kind":"')
        + kind + String('","name":"') + name + String('","platform":"linux-x86_64","sha256":"') + sha
        + String('","subdir":"linux-64","version":"0.1.7"}')
    )


def _doc(rows: String) -> String:
    return (
        String('{"format":"kci.release_set","members":[') + rows
        + String('],"platform":"linux-x86_64","produced_by":{"attempt":1,"run_id":"gh-1"},')
        + String('"revision":"') + String(_REV) + String('","schema_version":2,"set_hash":"')
        + String(_SET) + String('"}\n')
    )


def _golden() -> String:
    return _doc(
        _row(String("komira"), String("metapackage"), String(_C)) + String(",")
        + _row(String("komira_hash"), String("library"), String(_A))
    )


def test_render_is_byte_exact() raises:
    assert_equal(render_release_manifest(_manifest()), _golden())


def test_parse_of_render_is_the_value() raises:
    var parsed = parse_release_manifest(render_release_manifest(_manifest()), String("r.json"))
    assert_equal(parsed.revision, String(_REV))
    assert_equal(parsed.platform, String("linux-x86_64"))
    assert_equal(parsed.produced_by_run_id, String("gh-1"))
    assert_equal(parsed.produced_by_attempt, 1)
    assert_equal(len(parsed.entries), 2)
    assert_equal(parsed.entries[0].name, String("komira"))
    assert_equal(parsed.entries[0].platform, String("linux-x86_64"))
    assert_equal(parsed.entries[1].sha256_hex, String(_A))
    assert_equal(parsed.set_hash, String(_SET))
    assert_equal(len(parsed.ignored_keys), 0)
    var sorted = _manifest()
    sorted.entries = List[ReleaseEntry]()
    sorted.entries.append(_entry(String("komira"), String("metapackage"), String(_C)))
    sorted.entries.append(_entry(String("komira_hash"), String("library"), String(_A)))
    assert_true(parsed.same_as(sorted))
    var other = sorted.copy()
    other.entries[1].build = String("1")
    assert_false(parsed.same_as(other))
    var by = sorted.copy()
    by.produced_by_attempt = 2
    assert_false(parsed.same_as(by))


def test_produced_by_is_not_in_the_set_hash() raises:
    # a rebuild by another run of the same revision keeps its hash
    var t = _golden().replace(String('{"attempt":1,"run_id":"gh-1"}'), String('{"attempt":3,"run_id":"gh-99"}'))
    var r = parse_release_manifest(t, String("r.json"))
    assert_equal(r.set_hash, String(_SET))
    assert_equal(r.produced_by_run_id, String("gh-99"))


def test_the_revision_and_the_platform_are_in_the_set_hash() raises:
    var other_rev = String("1123456789abcdef0123456789abcdef01234567")
    var why = _refusal(_golden().replace(String(_REV), other_rev))
    assert_true(why.find(String("is not the hash of its revision, platform and members")) >= 0, why)
    var m = _manifest()
    assert_true(entries_set_hash(other_rev, String("linux-x86_64"), m.entries) != String(_SET))


def test_render_refuses_a_wrong_set_hash() raises:
    var r = _manifest()
    r.set_hash = String(_A)
    try:
        _ = render_release_manifest(r)
    except e:
        assert_true(String(e).find(String("is not the hash of its revision")) >= 0, String(e))
        return
    assert_true(False, "rendered a wrong set hash")


def test_identity_refusals() raises:
    var n = 0
    try:
        _ = ReleaseIdentity(String("0123abc"), String("linux-x86_64"), String("gh-1"), 1)
    except e:
        n += 1
    try:
        _ = ReleaseIdentity(String(_REV), String("darwin-arm64"), String("gh-1"), 1)
    except e:
        n += 1
    try:
        _ = ReleaseIdentity(String(_REV), String("linux-x86_64"), String("GH 1"), 1)
    except e:
        n += 1
    try:
        _ = ReleaseIdentity(String(_REV), String("linux-x86_64"), String("gh-1"), 0)
    except e:
        n += 1
    assert_equal(n, 4)


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


def test_major_1_is_no_longer_read() raises:
    _expect(
        String('{"members":[],"schema":"kci.release_set.v1","set_hash":"') + String(_SET) + String('"}'),
        String("this is major 1 of the release set (\"schema\"), which is no longer read (this kci reads")
        + String(" kci.release_set major 2): build the release again"),
    )


def test_refusals_of_the_document() raises:
    assert_true(_refusal(String("{")).startswith(String(_PFX) + String("not JSON: ")))
    _expect(String("[]"), String("not a JSON object"))
    _expect(
        String('{"platform":"linux-x86_64",') + String(_g()[byte = 1:]),
        String("'platform' is given twice"),
    )
    _expect(
        _g().replace(String('"schema_version":2'), String('"schema_version":3')),
        String("schema_version 3 needs a newer kci (this kci reads kci.release_set up to major 2)"),
    )
    _expect(
        _g().replace(String('"format":"kci.release_set"'), String('"format":"kci.result"')),
        String("format 'kci.result' is not 'kci.release_set'"),
    )
    _expect(
        _g().replace(String('"format":"kci.release_set",'), String("")),
        String("no 'format' (a kci.release_set document names its format)"),
    )
    _expect(
        _g().replace(String(',"produced_by":{"attempt":1,"run_id":"gh-1"}'), String("")),
        String("missing 'produced_by'"),
    )
    _expect(
        _g().replace(String('"revision":"0123'), String('"revision":"X123')),
        String("'revision' 'X123456789abcdef0123456789abcdef01234567' is not a full commit id")
        + String(" (exactly 40 lowercase hex digits; an abbreviated id is refused)"),
    )
    _expect(
        _g().replace(String('],"platform":"linux-x86_64"'), String('],"platform":"darwin-arm64"')),
        String("platform 'darwin-arm64' is not released: kci releases linux-x86_64 only for now;")
        + String(" darwin-arm64 is reserved"),
    )
    _expect(
        _g().replace(String('"run_id":"gh-1"'), String('"run_id":"GH-1"')),
        String("produced_by: --run-id 'GH-1' holds a byte outside [a-z0-9_-] (label-safe ids only)"),
    )
    _expect(
        _g().replace(String('"attempt":1'), String('"attempt":"1"')),
        String("produced_by: 'attempt' is not an integer"),
    )
    _expect(
        _g().replace(String(_SET), String("00")),
        String("'set_hash' is not 64 lowercase hex characters"),
    )
    _expect(_doc(String("")), String("'members' is EMPTY"))
    _expect(
        _g().replace(String('"members":['), String('"members":{"x":[')).replace(String('],"platform"'), String(']},"platform"')),
        String("'members' is not an array"),
    )


def test_unknown_keys_are_ignored_and_listed() raises:
    var t = _g().replace(String('"schema_version":2,'), String('"schema_version":2,"later":true,'))
    t = t.replace(String('"dir":"komira",'), String('"dir":"komira","extra":1,'))
    var r = parse_release_manifest(t, String("r.json"))
    assert_equal(len(r.ignored_keys), 2)
    assert_equal(r.ignored_keys[0], String("later"))
    assert_equal(r.ignored_keys[1], String("members[0].extra"))
    assert_equal(render_release_manifest(r), _g())


def test_refusals_of_a_member_row() raises:
    _expect(
        _g().replace(String('"dir":"komira",'), String("")),
        String("members[0]: missing 'dir'"),
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


def test_member_platform_rules() raises:
    # a member of another (released or reserved) platform is refused
    var other = _g().replace(
        String('"name":"komira","platform":"linux-x86_64"'), String('"name":"komira","platform":"linux-arm64"')
    )
    var why = _refusal(other)
    assert_true(why.startswith(String(_PFX) + String("members[0]: platform 'linux-arm64' is not released")), why)
    # a CONDA member's subdir must be its platform's conda subdir
    var sub = _g().replace(
        String('"sha256":"') + String(_C) + String('","subdir":"linux-64"'),
        String('"sha256":"') + String(_C) + String('","subdir":"osx-arm64"'),
    )
    _expect(sub, String("members[0]: 'subdir' 'osx-arm64' is not platform linux-x86_64's conda subdir 'linux-64'"))
    # a noarch member with the noarch subdir parses (and changes the hash)
    var noarch = _g().replace(
        String('"name":"komira","platform":"linux-x86_64","sha256":"') + String(_C) + String('","subdir":"linux-64"'),
        String('"name":"komira","platform":"noarch","sha256":"') + String(_C) + String('","subdir":"noarch"'),
    )
    why = _refusal(noarch)
    assert_true(why.find(String("is not the hash of its revision, platform and members")) >= 0, why)


def test_refuses_a_python_row_with_conda_fields() raises:
    _expect(
        _g().replace(String('"artifact_type":"CONDA","build":"0","dir":"komira_hash"'),
                     String('"artifact_type":"PYTHON","build":"0","dir":"komira_hash"')),
        String("members[1]: 'build' is set on a PYTHON member; only CONDA members have one"),
    )


def test_refuses_unsorted_or_repeated_members() raises:
    var swapped = _doc(
        _row(String("komira_hash"), String("library"), String(_A)) + String(",")
        + _row(String("komira"), String("metapackage"), String(_C))
    )
    _expect(swapped, String("members are not sorted by name: 'komira' comes after 'komira_hash'"))
    var twice = _doc(
        _row(String("komira"), String("metapackage"), String(_C)) + String(",")
        + _row(String("komira"), String("metapackage"), String(_C))
    )
    _expect(twice, String("member 'komira' is given twice"))


def test_refuses_a_set_hash_that_is_not_its_members() raises:
    var t = _g().replace(String('"version":"0.1.7"}]'), String('"version":"0.1.8"}]'))
    var why = _refusal(t)
    assert_true(
        why.startswith(String(_PFX) + String("'set_hash' ") + String(_SET)
                       + String(" is not the hash of its revision, platform and members (")),
        why,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
