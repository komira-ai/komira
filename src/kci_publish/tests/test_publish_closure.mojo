# =============================================================================
# src/kci_publish/tests/test_publish_closure.mojo -- contract 0.4: the
#   requirement closure over the set, each refusal ONE change to a good set.
# =============================================================================
#
# ROWS
#   (0) control: alpha (no set-internal requirement), beta (requires alpha),
#       the metapackage of both;
#   (1) a library: an undeclared requirement; a pin at the wrong version or
#       build; `mojo-compiler` pinned at another version; the wrong platform
#       guard; a pin on the metapackage; a requirement listed twice;
#   (2) the metapackage: an extra requirement; a library that is not a
#       member; a member whose sha256 is not the set's file; a member that
#       is not a library of the set (itself); a member row with no build (the
#       packer's older shape); a member at another version;
#   (3) the set: no metapackage; two; a subdir with no guard in the table;
#   (4) the BUILD step's name check (`undeclared_requirements`) agrees: the
#       good set is closed for it too, and an undeclared library
#       (komira_gamma) and the pin on the metapackage are open for both, each
#       named by the exact line BUILD prints;
#   (5) a system library: a library requiring `zstd >=1.5.2,<2` (and every
#       row of kci_release_set's `system_libs`) is closed for both checks;
#       `zstd >=1.0`, `zstd`, `conda-forge::zstd >=1.5.2,<2`,
#       `ZSTD >=1.5.2,<2`, a second space, a tab and `notalib >=1` are
#       refused by both, naming the library; the same row twice is refused;
#       the metapackage requiring a row is refused (only a library may).
#
# The members are loaded from a written good directory and changed in
# memory (the closure is a property of the set, which `verify_member` cannot
# see member by member).
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import assert_true

from kci_publish.release_fixture import ExampleRelease, example_loaded
from kci_publish.verify import require_closure
from kci_release_set.closure import undeclared_requirements
from kci_release_set.member import ReleaseMember
from kci_release_set.system_libs import system_libs


comptime _B: String = "h01234567_3"


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pcl_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _good() raises -> List[ReleaseMember]:
    var r = ExampleRelease()
    var d = _root(String("good"))
    r.write(d)
    return example_loaded(r, d).members.copy()


def _refused(members: List[ReleaseMember], needle: String) raises:
    var raised = False
    try:
        require_closure(members)
    except e:
        raised = True
        assert_true(String(e).find(needle) >= 0, String("'") + String(e) + String("' does not say '") + needle + String("'"))
    assert_true(raised, String("not refused; expected: ") + needle)


def test_control() raises:
    require_closure(_good())
    print("  test_control: PASS")


def test_a_library_requires_exactly_the_closure() raises:
    var m = _good()
    m[0].conda.depends.append(String("numpy ==2.0"))
    _refused(m, String("artifact 'komira_alpha': requirement 'numpy ==2.0' is not the guard"))
    m = _good()
    m[1].conda.depends[2] = String("komira_alpha ==1.0.1 ") + String(_B)
    _refused(m, String("artifact 'komira_beta': requirement 'komira_alpha ==1.0.1 h01234567_3'"))
    m = _good()
    m[1].conda.depends[2] = String("komira_alpha ==1.0.0 h01234567_2")
    _refused(m, String("requirement 'komira_alpha ==1.0.0 h01234567_2'"))
    m = _good()
    m[0].conda.depends[1] = String("mojo-compiler ==1.0.1")
    _refused(m, String("artifact 'komira_alpha': does not require exactly 'mojo-compiler ==1.0.0'"))
    m = _good()
    m[0].conda.depends[0] = String("__osx")
    _refused(m, String("artifact 'komira_alpha': does not require the platform guard '__linux'"))
    m = _good()
    m[1].conda.depends.append(String("komira ==1.0.0 ") + String(_B))
    _refused(m, String("artifact 'komira_beta': requirement 'komira ==1.0.0 h01234567_3'"))
    m = _good()
    m[1].conda.depends.append(String("komira_alpha ==1.0.0 ") + String(_B))
    _refused(m, String("artifact 'komira_beta': requirement 'komira_alpha ==1.0.0 h01234567_3' is listed twice"))
    print("  test_a_library_requires_exactly_the_closure: PASS")


def test_the_metapackage_holds_exactly_the_libraries() raises:
    var m = _good()
    m[2].conda.depends.append(String("__glibc"))
    _refused(m, String("metapackage 'komira': requirement '__glibc' is not the guard or a member pin"))
    m = _good()
    _ = m[2].conda.members.pop(1)
    _refused(m, String("library 'komira_beta' of this set is not a member"))
    m = _good()
    m[2].conda.members[0].sha256_hex = String("abababababababababababababababababababababababababababababababab")
    _refused(m, String("member 'komira_alpha' has sha256 abab"))
    m = _good()
    m[2].conda.members[1].name = String("komira")
    _refused(m, String("member 'komira' is not a library of this set"))
    m = _good()
    m[2].conda.members[0].has_build = False
    m[2].conda.members[0].build = String("")
    _refused(m, String("member 'komira_alpha' is at '1.0.0 '"))
    m = _good()
    m[2].conda.members[0].version = String("0.9.0")
    _refused(m, String("member 'komira_alpha' is at '0.9.0 h01234567_3'"))
    print("  test_the_metapackage_holds_exactly_the_libraries: PASS")


def test_the_set_has_exactly_one_metapackage_and_a_guard() raises:
    var m = _good()
    _ = m.pop(2)
    _refused(m, String("the release set holds 0 metapackages"))
    m = _good()
    m.append(m[2].copy())
    _refused(m, String("the release set holds 2 metapackages"))
    m = _good()
    for i in range(len(m)):
        m[i].conda.subdir = String("osx-arm64")
    _refused(m, String("subdir 'osx-arm64' has no platform guard"))
    print("  test_the_set_has_exactly_one_metapackage_and_a_guard: PASS")


def test_the_build_steps_name_check_agrees() raises:
    assert_true(len(undeclared_requirements(_good())) == 0, "the good set is closed by name")
    var m = _good()
    m[0].conda.depends.append(String("komira_gamma ==1.0.0 ") + String(_B))
    var open_a = undeclared_requirements(m)
    assert_true(len(open_a) == 1)
    assert_true(
        open_a[0]
        == String("artifact 'komira_alpha' requires 'komira_gamma ==1.0.0 h01234567_3', and 'komira_gamma'")
        + String(" is not another library of this release set")
        + String(" (nor a system library requirement of tools/build/package/system_libs.bzl)"),
        open_a[0],
    )
    _refused(m, String("artifact 'komira_alpha': requirement 'komira_gamma ==1.0.0 h01234567_3'"))
    m = _good()
    m[1].conda.depends.append(String("komira ==1.0.0 ") + String(_B))
    var open_b = undeclared_requirements(m)
    assert_true(len(open_b) == 1)
    assert_true(
        open_b[0]
        == String("artifact 'komira_beta' requires 'komira ==1.0.0 h01234567_3', and 'komira'")
        + String(" is not another library of this release set")
        + String(" (nor a system library requirement of tools/build/package/system_libs.bzl)"),
        open_b[0],
    )
    _refused(m, String("artifact 'komira_beta': requirement 'komira ==1.0.0 h01234567_3'"))
    print("  test_the_build_steps_name_check_agrees: PASS")


def test_a_library_may_require_a_system_library_exactly() raises:
    var m = _good()
    m[0].conda.depends.append(String("zstd >=1.5.2,<2"))
    require_closure(m)
    assert_true(len(undeclared_requirements(m)) == 0, "BUILD: zstd >=1.5.2,<2 is closed")
    var rows = system_libs()
    m = _good()
    for i in range(len(rows)):
        m[1].conda.depends.append(rows[i].requirement.copy())
    require_closure(m)
    assert_true(len(undeclared_requirements(m)) == 0, "BUILD: every row is closed")
    for bad in [
        String("zstd >=1.0"),
        String("zstd"),
        String("conda-forge::zstd >=1.5.2,<2"),
        String("ZSTD >=1.5.2,<2"),
        String("zstd  >=1.5.2,<2"),
        String("zstd\t>=1.5.2,<2"),
        String("notalib >=1"),
    ]:
        m = _good()
        m[0].conda.depends.append(bad.copy())
        _refused(m, String("artifact 'komira_alpha': requirement '") + bad + String("' is not the guard"))
        var open_reqs = undeclared_requirements(m)
        assert_true(len(open_reqs) == 1, String("BUILD did not list '") + bad + String("'"))
        assert_true(
            open_reqs[0].startswith(String("artifact 'komira_alpha' requires '") + bad + String("'")), open_reqs[0]
        )
    m = _good()
    m[0].conda.depends.append(String("zstd >=1.5.2,<2"))
    m[0].conda.depends.append(String("zstd >=1.5.2,<2"))
    _refused(m, String("artifact 'komira_alpha': requirement 'zstd >=1.5.2,<2' is listed twice"))
    m = _good()
    m[2].conda.depends.append(String("zstd >=1.5.2,<2"))
    _refused(m, String("metapackage 'komira': requirement 'zstd >=1.5.2,<2' is not the guard or a member pin"))
    print("  test_a_library_may_require_a_system_library_exactly: PASS")


def main() raises:
    test_control()
    test_the_build_steps_name_check_agrees()
    test_a_library_requires_exactly_the_closure()
    test_the_metapackage_holds_exactly_the_libraries()
    test_the_set_has_exactly_one_metapackage_and_a_guard()
    test_a_library_may_require_a_system_library_exactly()
    print("test_publish_closure: ALL PASS")
