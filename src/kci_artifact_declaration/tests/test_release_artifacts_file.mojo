# =============================================================================
# src/kci_artifact_declaration/tests/test_release_artifacts_file.mojo
#   The repository's own release declarations, release/artifacts.textproto,
#   read through the real reader: it parses and validates, the libraries
#   build stamped, and the metapackage is last with every library a member.
# =============================================================================
#
# The file is staged as test data at `artifacts.textproto` (BUCK). A typo
# in it, a forgotten stamp, a library left out of the metapackage, or the
# metapackage moved off the end fails this test, and with it
# `./buck2 build //...`: the release workflow cannot be the first to find it.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_artifact_declaration import (
    ReleaseStamp,
    read_artifact_declarations,
    render_build_argv,
)

comptime _FILE = "artifacts.textproto"
comptime _REV = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _SRC = "f0e1d2c3b4a5968778695a4b3c2d1e0f12345678"
comptime _REL = "/work/rel"


def _stamp() raises -> ReleaseStamp:
    return ReleaseStamp(String(_REV), String(_SRC), 154, 1790994309000)


def _count(argv: List[String], want: String) -> Int:
    var n = 0
    for i in range(len(argv)):
        if argv[i] == want:
            n += 1
    return n


def _flag_values(argv: List[String], flag: String) -> List[String]:
    var out = List[String]()
    for i in range(len(argv) - 1):
        if argv[i] == flag:
            out.append(argv[i + 1])
    return out^


def test_the_first_release_is_komira_encoding_then_komira_all() raises:
    assert_equal(read_artifact_declarations(String(_FILE)).schema_version, Int32(1))
    var d = read_artifact_declarations(String(_FILE))
    assert_equal(len(d.artifacts), 2)
    assert_equal(d.artifacts[0].name, String("komira_encoding"))
    assert_equal(d.artifacts[1].name, String("komira_all"))


def test_every_library_builds_stamped_into_its_own_directory() raises:
    var d = read_artifact_declarations(String(_FILE))
    for i in range(len(d.artifacts) - 1):
        var name = d.artifacts[i].name.copy()
        var argv = render_build_argv(d, name, String(_REL), String("linux-x86_64"), _stamp())
        assert_equal(argv[0], String("buck2"))
        assert_equal(argv[1], String("build"))
        assert_equal(_count(argv, String("komira.package_stamp=154")), 1)
        assert_equal(_count(argv, String("komira.package_commit=") + String(_SRC)), 1)
        assert_equal(_count(argv, String("komira.package_timestamp_ms=1790994309000")), 1)
        assert_equal(
            _count(argv, String("//src/") + name + String(":") + name + String("_conda[release]")),
            1,
        )
        var outs = _flag_values(argv, String("--out"))
        assert_equal(len(outs), 1)
        assert_equal(outs[0], String(_REL) + String("/") + name)


def test_the_metapackage_is_last_and_holds_every_library() raises:
    var d = read_artifact_declarations(String(_FILE))
    var last = len(d.artifacts) - 1
    var meta = d.artifacts[last].name.copy()
    var argv = render_build_argv(d, meta, String(_REL), String("linux-x86_64"), _stamp())
    assert_equal(_count(argv, String("conda-meta")), 1)
    var names = _flag_values(argv, String("--name"))
    assert_equal(len(names), 1)
    assert_equal(names[0], meta)
    var members = _flag_values(argv, String("--member-manifest"))
    assert_equal(len(members), last)
    for i in range(last):
        assert_equal(
            members[i],
            String(_REL) + String("/") + d.artifacts[i].name + String("/manifest.json"),
        )
    var outs = _flag_values(argv, String("--out-dir"))
    assert_equal(len(outs), 1)
    assert_equal(outs[0], String(_REL) + String("/") + meta)
    var labels = _flag_values(argv, String("--label"))
    assert_equal(len(labels), 1)
    assert_true(labels[0].endswith(String(_REV)))
    # The label names the one verb for stages, `kci run`.
    assert_equal(labels[0], String("kci run ") + String(_REV))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
