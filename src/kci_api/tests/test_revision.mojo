# =============================================================================
# src/kci_api/tests/test_revision.mojo
#   Full commit ids only; an artifact reference names revision, platform and
#   name, and output names it with its revision.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import ArtifactRef, is_full_commit_id, require_full_commit_id

comptime _REV = "0123456789abcdef0123456789abcdef01234567"


def _ref(rev: String, platform: String, name: String) -> String:
    try:
        return ArtifactRef(rev, platform, name).display()
    except e:
        return String(e)


def test_full_commit_ids() raises:
    assert_true(is_full_commit_id(String(_REV)))
    assert_false(is_full_commit_id(String(String(_REV)[byte = 1 :])))
    assert_false(is_full_commit_id(String(_REV) + String("8")))
    assert_false(is_full_commit_id(String(_REV).upper()))
    assert_false(is_full_commit_id(String("g") + String(String(_REV)[byte = 1 :])))
    var msg = String("")
    try:
        require_full_commit_id(String("--revision-id"), String("abc1234"))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String("--revision-id 'abc1234' is not a full commit id (exactly 40 lowercase hex digits; an abbreviated id is refused)"),
    )


def test_artifact_ref() raises:
    assert_equal(
        _ref(String(_REV), String("linux-x86_64"), String("komira_encoding")),
        String("komira_encoding@") + String(_REV) + String("/linux-x86_64"),
    )
    assert_equal(_ref(String(_REV), String("noarch"), String("x")), String("x@") + String(_REV) + String("/noarch"))
    assert_true(_ref(String("abc"), String("linux-x86_64"), String("x")).find(String("not a full commit id")) >= 0)
    assert_true(_ref(String(_REV), String("darwin-arm64"), String("x")).find(String("is not released")) >= 0)
    assert_true(_ref(String(_REV), String("windows"), String("x")).find(String("is not one of")) >= 0)
    assert_equal(_ref(String(_REV), String("linux-x86_64"), String("")), String("an artifact reference needs a name"))
    assert_true(_ref(String(_REV), String("linux-x86_64"), String("a/b")).find(String("holds '/' or '@'")) >= 0)
    var a = ArtifactRef(String(_REV), String("linux-x86_64"), String("x"))
    var b = ArtifactRef(String(_REV), String("noarch"), String("x"))
    assert_false(a == b)
    assert_true(a == a.copy())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
