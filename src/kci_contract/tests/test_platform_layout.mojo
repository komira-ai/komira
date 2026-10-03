# =============================================================================
# src/kci_contract/tests/test_platform_layout.mojo
#   The platform table pinned by value, the release/member rules, and the
#   release directory layout.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_contract import (
    ARTIFACT_MANIFEST_NAME,
    RELEASE_MANIFEST_NAME,
    conda_subdir_of,
    member_dir,
    platform_of_conda_subdir,
    platform_table,
    release_manifest_path,
    release_platform_dir,
    require_member_platform,
    require_release_platform,
)


def _release(p: String) -> String:
    try:
        require_release_platform(p)
    except e:
        return String(e)
    return String("<ok>")


def _member(r: String, m: String) -> String:
    try:
        require_member_platform(r, m)
    except e:
        return String(e)
    return String("<ok>")


def test_golden_table() raises:
    var t = platform_table()
    assert_equal(len(t), 4)
    var want = List[String]()
    want.append(String("linux-x86_64 linux-64 True"))
    want.append(String("darwin-arm64 osx-arm64 False"))
    want.append(String("linux-arm64 linux-aarch64 False"))
    want.append(String("noarch noarch True"))
    for i in range(len(t)):
        assert_equal(t[i].name + String(" ") + t[i].conda_subdir + String(" ") + String(t[i].released), want[i])
        assert_equal(t[i].reason.byte_length() > 0, not t[i].released)


def test_release_platform() raises:
    assert_equal(_release(String("linux-x86_64")), String("<ok>"))
    assert_equal(
        _release(String("darwin-arm64")),
        String("platform 'darwin-arm64' is not released: kci releases linux-x86_64 only for now; darwin-arm64 is reserved"),
    )
    assert_true(_release(String("noarch")).find(String("never a release's")) >= 0)
    assert_equal(
        _release(String("linux-64")),
        String("platform 'linux-64' is not one of: linux-x86_64 darwin-arm64 linux-arm64 noarch"),
    )


def test_member_platform() raises:
    assert_equal(_member(String("linux-x86_64"), String("linux-x86_64")), String("<ok>"))
    assert_equal(_member(String("linux-x86_64"), String("noarch")), String("<ok>"))
    assert_true(_member(String("linux-x86_64"), String("linux-arm64")).find(String("is not released")) >= 0)
    assert_true(_member(String("linux-x86_64"), String("bogus")).find(String("is not one of")) >= 0)


def test_conda_subdirs() raises:
    assert_equal(conda_subdir_of(String("linux-x86_64")), String("linux-64"))
    assert_equal(conda_subdir_of(String("noarch")), String("noarch"))
    assert_equal(platform_of_conda_subdir(String("linux-64")), String("linux-x86_64"))
    assert_equal(platform_of_conda_subdir(String("osx-arm64")), String("darwin-arm64"))
    var refused = False
    try:
        _ = platform_of_conda_subdir(String("win-64"))
    except e:
        refused = String(e) == String("conda subdir 'win-64' is not a kci platform's subdir")
    assert_true(refused)


def test_layout() raises:
    assert_equal(String(ARTIFACT_MANIFEST_NAME), String("manifest.json"))
    assert_equal(String(RELEASE_MANIFEST_NAME), String("release.json"))
    assert_equal(release_platform_dir(String("/r"), String("linux-x86_64")), String("/r/linux-x86_64"))
    assert_equal(release_platform_dir(String("/r/"), String("linux-x86_64")), String("/r/linux-x86_64"))
    assert_equal(member_dir(String("/r"), String("linux-x86_64"), String("komira")), String("/r/linux-x86_64/komira"))
    assert_equal(release_manifest_path(String("/r"), String("linux-x86_64")), String("/r/linux-x86_64/release.json"))
    var refused = 0
    try:
        _ = member_dir(String("/r"), String("linux-x86_64"), String(".."))
    except e:
        refused += 1
    try:
        _ = release_platform_dir(String(""), String("linux-x86_64"))
    except e:
        refused += 1
    try:
        _ = release_platform_dir(String("/r"), String("a/b"))
    except e:
        refused += 1
    assert_equal(refused, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
