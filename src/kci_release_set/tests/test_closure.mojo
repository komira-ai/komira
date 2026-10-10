# =============================================================================
# src/kci_release_set/tests/test_closure.mojo -- `undeclared_requirements`
#   and `requirement_name`, over members built in memory.
# =============================================================================
#
# ROWS
#   (0) a closed set: beta requires the guard, the compiler pin and alpha;
#       the metapackage's own requirements are not read: EMPTY;
#   (1) the name is the text before the first space, or all of it;
#   (2) listed, one line each, naming the artifact and the requirement: a
#       library no member is; a library spelled with `-` where the member's
#       conda name has `_` (names compare exactly); the metapackage; itself;
#       a member that is not CONDA (it has no conda name);
#   (3) skipped: every `__` virtual package and the compiler at any pin;
#   (4) a non-library member's requirements are never read;
#   (5) a system library: a library requiring a conda-forge requirement of
#       system_libs.mojo byte for byte (`zstd >=1.5.2,<2`, and every row) is
#       closed; another range, no range, a channel prefix, another case, a
#       second space, a tab, a trailing space, a pattern and a package the
#       table does not hold are listed, naming the library; a row given
#       more than once is listed once.
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_artifact_manifest import ArtifactManifest
from kci_release_set import (
    KIND_LIBRARY,
    KIND_METAPACKAGE,
    CondaMetadata,
    ReleaseMember,
    requirement_name,
    system_libs,
    undeclared_requirements,
)


def _member(artifact: String, kind: String, var depends: List[String], conda: Bool = True) -> ReleaseMember:
    var m = ReleaseMember(artifact.copy(), String("/r/") + artifact, ArtifactManifest(String("t")), 1)
    if conda:
        m.has_conda = True
        m.conda = CondaMetadata(String("t"))
        m.conda.kind = kind.copy()
        m.conda.name = artifact.copy()
        m.conda.depends = depends^
    return m^


def _l(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _closed() -> List[ReleaseMember]:
    var s = List[ReleaseMember]()
    s.append(_member(String("komira_alpha"), String(KIND_LIBRARY), _l("__linux", "mojo-compiler ==1.0.0")))
    s.append(
        _member(
            String("komira_beta"),
            String(KIND_LIBRARY),
            _l("__linux", "mojo-compiler ==1.0.0", "komira_alpha ==1.0.0 h0_1"),
        )
    )
    s.append(
        _member(
            String("komira"),
            String(KIND_METAPACKAGE),
            _l("__linux", "komira_alpha ==1.0.0 h0_1", "komira_beta ==1.0.0 h0_1", "undeclared ==1"),
        )
    )
    return s^


def _line(artifact: String, req: String, name: String) -> String:
    return (
        String("artifact '") + artifact + String("' requires '") + req + String("', and '") + name
        + String("' is not another library of this release set")
        + String(" (nor a system library requirement of tools/build/package/system_libs.bzl)")
    )


def _one(var s: List[ReleaseMember], want: String) raises:
    var got = undeclared_requirements(s)
    assert_equal(len(got), 1, want)
    assert_equal(got[0], want)


def test_a_closed_set_is_empty() raises:
    assert_equal(len(undeclared_requirements(_closed())), 0)
    print("  test_a_closed_set_is_empty: PASS")


def test_requirement_name() raises:
    assert_equal(requirement_name(String("komira_alpha ==1.0.0 h0_1")), String("komira_alpha"))
    assert_equal(requirement_name(String("komira_alpha >=1")), String("komira_alpha"))
    assert_equal(requirement_name(String("komira_alpha")), String("komira_alpha"))
    assert_equal(requirement_name(String("komira_alpha==1")), String("komira_alpha==1"))
    print("  test_requirement_name: PASS")


def test_open_requirements_are_listed() raises:
    var s = _closed()
    s[0].conda.depends.append(String("komira_gamma ==1.0.0 h0_1"))
    _one(s^, _line(String("komira_alpha"), String("komira_gamma ==1.0.0 h0_1"), String("komira_gamma")))
    s = _closed()
    s[1].conda.depends[2] = String("komira-alpha ==1.0.0 h0_1")
    _one(s^, _line(String("komira_beta"), String("komira-alpha ==1.0.0 h0_1"), String("komira-alpha")))
    s = _closed()
    s[1].conda.depends.append(String("komira ==1.0.0 h0_1"))
    _one(s^, _line(String("komira_beta"), String("komira ==1.0.0 h0_1"), String("komira")))
    s = _closed()
    s[0].conda.depends.append(String("komira_alpha ==1.0.0 h0_1"))
    _one(s^, _line(String("komira_alpha"), String("komira_alpha ==1.0.0 h0_1"), String("komira_alpha")))
    s = _closed()
    s[0] = _member(String("komira_alpha"), String(""), List[String](), conda=False)
    _one(s^, _line(String("komira_beta"), String("komira_alpha ==1.0.0 h0_1"), String("komira_alpha")))
    # two at once, in member order
    s = _closed()
    s[1].conda.depends.append(String("b2"))
    s[0].conda.depends.append(String("a1"))
    var got = undeclared_requirements(s)
    assert_equal(len(got), 2)
    assert_equal(got[0], _line(String("komira_alpha"), String("a1"), String("a1")))
    assert_equal(got[1], _line(String("komira_beta"), String("b2"), String("b2")))
    print("  test_open_requirements_are_listed: PASS")


def test_the_guard_and_the_compiler_are_skipped() raises:
    var s = _closed()
    s[0].conda.depends.append(String("__osx"))
    s[0].conda.depends.append(String("__glibc >=2.17"))
    s[0].conda.depends.append(String("mojo-compiler ==9.9.9"))
    s[0].conda.depends.append(String("mojo-compiler"))
    assert_equal(len(undeclared_requirements(s)), 0)
    # a name that merely starts like the compiler is not skipped
    s[0].conda.depends.append(String("mojo-compiler-extra ==1"))
    assert_equal(len(undeclared_requirements(s)), 1)
    print("  test_the_guard_and_the_compiler_are_skipped: PASS")


def test_a_metapackage_is_not_read() raises:
    var s = _closed()
    s[2].conda.depends.append(String("anything ==1"))
    s[2].conda.kind = String(KIND_METAPACKAGE)
    assert_equal(len(undeclared_requirements(s)), 0)
    s[2].conda.kind = String(KIND_LIBRARY)
    assert_equal(len(undeclared_requirements(s)), 2, "read as a library, 'undeclared' and 'anything' are open")
    print("  test_a_metapackage_is_not_read: PASS")


def test_a_library_may_require_a_system_library_exactly() raises:
    var s = _closed()
    s[0].conda.depends.append(String("zstd >=1.5.2,<2"))
    assert_equal(len(undeclared_requirements(s)), 0, "zstd >=1.5.2,<2 is the table's requirement")
    var rows = system_libs()
    assert_true(len(rows) > 0, "the table is empty")
    s = _closed()
    for i in range(len(rows)):
        s[1].conda.depends.append(rows[i].requirement.copy())
    assert_equal(len(undeclared_requirements(s)), 0, "every row of the table is closed")
    var refused = _l(
        "zstd >=1.0",
        "zstd",
        "conda-forge::zstd >=1.5.2,<2",
        "ZSTD >=1.5.2,<2",
        "zstd  >=1.5.2,<2",
        "zstd\t>=1.5.2,<2",
        "zstd >=1.5.2,<2 ",
        "zstd >=1.5.2,<3",
        "zst* >=1.5.2,<2",
        "notalib >=1",
    )
    for i in range(len(refused)):
        s = _closed()
        s[0].conda.depends.append(refused[i].copy())
        _one(s^, _line(String("komira_alpha"), refused[i], requirement_name(refused[i])))
    # given twice (or three times): one line, as PUBLISH refuses it
    s = _closed()
    s[0].conda.depends.append(String("zstd >=1.5.2,<2"))
    s[0].conda.depends.append(String("zstd >=1.5.2,<2"))
    _one(s^, String("artifact 'komira_alpha' requires 'zstd >=1.5.2,<2' more than once"))
    s = _closed()
    for _ in range(3):
        s[0].conda.depends.append(String("zstd >=1.5.2,<2"))
    _one(s^, String("artifact 'komira_alpha' requires 'zstd >=1.5.2,<2' more than once"))
    print("  test_a_library_may_require_a_system_library_exactly: PASS")


def main() raises:
    test_a_closed_set_is_empty()
    test_requirement_name()
    test_open_requirements_are_listed()
    test_the_guard_and_the_compiler_are_skipped()
    test_a_metapackage_is_not_read()
    test_a_library_may_require_a_system_library_exactly()
    print("test_closure: ALL PASS")
