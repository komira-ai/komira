# =============================================================================
# src/kci_publish/tests/test_publish_lockstep.mojo -- contract 0.3: one
#   version, build, build_number, source_commit, timestamp_ms and subdir
#   across every member, equal to --release-version; every member stamped.
#   And the --release-version reader.
# =============================================================================
#
# ROWS
#   (0) control: the good set is in lockstep with its release-version text;
#   (1) each of the six keys differing in ONE member (the metapackage
#       included) is refused naming the member and the key;
#   (2) each --release-version value differing (version, build,
#       build_number, commit) is refused naming the key;
#   (3) `stamped: false` is refused;
#   (4) the reader: buck_args ignored; a missing, duplicated or unknown key,
#       an EMPTY value, a line without `=`, a build_number that is not a
#       decimal and a commit that is not hex are each refused naming it.
#
# The members are loaded from a written good directory and changed in
# memory, so each row is exactly one difference that `verify_member` (which
# checks a member against itself) cannot see.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import assert_equal, assert_true

from kci_publish.release_fixture import ExampleRelease, example_loaded
from kci_publish.release_version import ReleaseVersion, parse_release_version
from kci_publish.verify import require_lockstep
from kci_release_set.member import ReleaseMember


def _root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pls_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _good() raises -> List[ReleaseMember]:
    var r = ExampleRelease()
    var d = _root(String("good"))
    r.write(d)
    return example_loaded(r, d).members.copy()


def _rv() raises -> ReleaseVersion:
    return parse_release_version(ExampleRelease().release_version_text(), String("rv.txt"))


def _refused(members: List[ReleaseMember], rv: ReleaseVersion, needle: String) raises:
    var raised = False
    try:
        require_lockstep(members, rv)
    except e:
        raised = True
        assert_true(String(e).find(needle) >= 0, String("'") + String(e) + String("' does not say '") + needle + String("'"))
    assert_true(raised, String("not refused; expected: ") + needle)


def test_control() raises:
    require_lockstep(_good(), _rv())
    print("  test_control: PASS")


def test_each_key_differing_in_one_member() raises:
    var rv = _rv()
    var m = _good()
    m[2].conda.version = String("1.0.1")
    _refused(m, rv, String("artifact 'komira': version is '1.0.1'"))
    m = _good()
    m[1].conda.build = String("h01234567_4")
    _refused(m, rv, String("artifact 'komira_beta': build is 'h01234567_4'"))
    m = _good()
    m[1].conda.build_number = 4
    _refused(m, rv, String("artifact 'komira_beta': build_number is '4'"))
    m = _good()
    m[2].conda.source_commit = String("fedcba9876543210fedcba9876543210fedcba98")
    _refused(m, rv, String("artifact 'komira': source_commit is 'fedcba98"))
    m = _good()
    m[1].conda.timestamp_ms = 1
    _refused(m, rv, String("artifact 'komira_beta': timestamp_ms is '1'"))
    m = _good()
    m[2].conda.subdir = String("osx-arm64")
    _refused(m, rv, String("artifact 'komira': subdir is 'osx-arm64'"))
    m = _good()
    m[0].conda.stamped = False
    _refused(m, rv, String("artifact 'komira_alpha' is not stamped"))
    print("  test_each_key_differing_in_one_member: PASS")


def test_each_release_version_value() raises:
    var m = _good()
    var rv = _rv()
    rv.version = String("1.0.2")
    _refused(m, rv, String("version is '1.0.0', --release-version (rv.txt) says '1.0.2'"))
    rv = _rv()
    rv.build = String("h01234567_9")
    _refused(m, rv, String("build is 'h01234567_3', --release-version (rv.txt) says 'h01234567_9'"))
    rv = _rv()
    rv.build_number = 9
    _refused(m, rv, String("build_number is '3', --release-version (rv.txt) says '9'"))
    rv = _rv()
    rv.commit = String("fedcba9876543210fedcba9876543210fedcba98")
    _refused(m, rv, String("source_commit is '0123456789abcdef0123456789abcdef01234567', --release-version"))
    print("  test_each_release_version_value: PASS")


def _rv_refused(text: String, needle: String) raises:
    var raised = False
    try:
        _ = parse_release_version(text, String("rv.txt"))
    except e:
        raised = True
        assert_true(String(e).find(needle) >= 0, String("'") + String(e) + String("' does not say '") + needle + String("'"))
        assert_true(String(e).find(String("release version 'rv.txt'")) >= 0, String(e))
    assert_true(raised, String("not refused; expected: ") + needle)


def test_the_release_version_reader() raises:
    var rv = _rv()
    assert_equal(rv.version, String("1.0.0"))
    assert_equal(rv.build_number, 3)
    assert_equal(rv.build, String("h01234567_3"))
    assert_equal(rv.commit, String("0123456789abcdef0123456789abcdef01234567"))
    var c = String("commit=0123456789abcdef0123456789abcdef01234567\n")
    _rv_refused(String("version=1\nbuild=b\n") + c, String("missing key(s): build_number"))
    _rv_refused(String("version=1\nversion=1\nbuild_number=1\nbuild=b\n") + c, String("version is given twice"))
    _rv_refused(String("version=1\nbuild_number=1\nbuild=b\nchannel=x\n") + c, String("unknown key 'channel'"))
    _rv_refused(String("version=\nbuild_number=1\nbuild=b\n") + c, String("version is EMPTY"))
    _rv_refused(String("version 1\n"), String("line 1 is not key=value"))
    _rv_refused(String("version=1\nbuild_number=01\nbuild=b\n") + c, String("build_number is not a decimal integer"))
    _rv_refused(String("version=1\nbuild_number=x\nbuild=b\n") + c, String("build_number is not a decimal integer"))
    _rv_refused(String("version=1\nbuild_number=1\nbuild=b\ncommit=0123ABCD\n"), String("commit is not 40 or 64 lowercase hex"))
    # main's script prints version= and commit= only: publish cannot pass on it
    _rv_refused(String("version=0.1.7\n") + c, String("missing key(s): build_number, build"))
    print("  test_the_release_version_reader: PASS")


def main() raises:
    test_control()
    test_each_key_differing_in_one_member()
    test_each_release_version_value()
    test_the_release_version_reader()
    print("test_publish_lockstep: ALL PASS")
