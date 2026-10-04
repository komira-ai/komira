# =============================================================================
# src/kci_artifact/tests/test_artifact_parse.mojo
#   Read an artifacts file, round-trip it on the wire, pin every field
#   number as bytes, refuse what the parser refuses.
# =============================================================================
#
# A control case parses a file and reads every field back, so each refusal
# below is caused by its one change. The wire round trip encodes the parsed
# value and decodes it: every field must survive. A round trip cannot see a
# renumbered field (encoder and decoder move together), so every field
# number of all three messages is also pinned as bytes.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_proto_codec import decode_proto, encode_proto

from kci_artifact_proto.artifact import (
    Artifact,
    Artifacts,
    BuildSystem,
)
from kci_artifact import parse_artifacts


def _file() -> String:
    # Line numbers are load-bearing: the refusals below name them.
    return (
        String("build_systems {\n")  # 1
        + String("  name: \"buck2\"\n")  # 2
        + String("  executable: \"buck2\"\n")  # 3
        + String("  args: \"build\"\n")  # 4
        + String("}\n")  # 5
        + String("artifacts {\n")  # 6
        + String("  name: \"a\"\n")  # 7
        + String("  build_system: \"buck2\"\n")  # 8
        + String("  args: \"//pkg:a[release]\"\n")  # 9
        + String("  args: \"--out\"\n")  # 10
        + String("  args: \"{out_dir}\"\n")  # 11
        + String("}\n")  # 12
        + String("# a second artifact, with the optional ':' before '{'\n")  # 13
        + String("artifacts: {\n  name: \"b\"\n  build_system: \"buck2\"\n")
        + String("  args: \"//pkg:b[release]\"\n  args: \"--out={out_dir}\"\n}\n")
    )


def _refusal(text: String) -> String:
    try:
        _ = parse_artifacts(text, String("artifacts.textproto"))
    except e:
        return String(e)
    return String("<parsed>")


def test_control_file_parses_every_field() raises:
    var d = parse_artifacts(_file(), String("artifacts.textproto"))
    assert_equal(len(d.build_systems), 1)
    ref b = d.build_systems[0]
    assert_equal(b.name, String("buck2"))
    assert_equal(b.executable, String("buck2"))
    assert_equal(len(b.args), 1)
    assert_equal(b.args[0], String("build"))
    assert_equal(len(d.artifacts), 2)
    ref a = d.artifacts[0]
    assert_equal(a.name, String("a"))
    assert_equal(a.build_system, String("buck2"))
    assert_equal(len(a.args), 3)
    assert_equal(a.args[0], String("//pkg:a[release]"))
    assert_equal(a.args[1], String("--out"))
    assert_equal(a.args[2], String("{out_dir}"))
    assert_equal(d.artifacts[1].name, String("b"))
    assert_equal(len(d.artifacts[1].args), 2)
    assert_equal(d.artifacts[1].args[1], String("--out={out_dir}"))


def test_parsed_value_round_trips_on_the_wire() raises:
    var d = parse_artifacts(_file(), String("artifacts.textproto"))
    var back = decode_proto[Artifacts](encode_proto[Artifacts](d))
    assert_equal(len(back.build_systems), len(d.build_systems))
    for i in range(len(d.build_systems)):
        assert_equal(back.build_systems[i].name, d.build_systems[i].name)
        assert_equal(back.build_systems[i].executable, d.build_systems[i].executable)
        assert_equal(len(back.build_systems[i].args), len(d.build_systems[i].args))
        for k in range(len(d.build_systems[i].args)):
            assert_equal(back.build_systems[i].args[k], d.build_systems[i].args[k])
    assert_equal(len(back.artifacts), len(d.artifacts))
    for i in range(len(d.artifacts)):
        ref x = back.artifacts[i]
        ref y = d.artifacts[i]
        assert_equal(x.name, y.name)
        assert_equal(x.build_system, y.build_system)
        assert_equal(len(x.args), len(y.args))
        for k in range(len(y.args)):
            assert_equal(x.args[k], y.args[k])


def _one(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


def _expect_bytes(got: List[UInt8], want: List[UInt8]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _bytes(*xs: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for x in xs:
        out.append(UInt8(x))
    return out^


def _bs() -> BuildSystem:
    return BuildSystem(String("b"), String("e"), _one(String("x")))


def _art() -> Artifact:
    return Artifact(String("a"), String("b"), _one(String("x")))


def test_build_system_field_numbers_are_pinned() raises:
    # name = 1 (0x0a), executable = 2 (0x12), args = 3 (0x1a); each a
    # one-byte string. Every field is set, so no empty-value encoding choice
    # can move a byte.
    _expect_bytes(
        encode_proto[BuildSystem](_bs()),
        _bytes(0x0A, 1, 0x62, 0x12, 1, 0x65, 0x1A, 1, 0x78),
    )


def test_artifact_field_numbers_are_pinned() raises:
    # name = 1 (0x0a), build_system = 3 (0x1a), args = 4 (0x22); 2 is
    # reserved, so no 0x12 byte.
    _expect_bytes(
        encode_proto[Artifact](_art()),
        _bytes(0x0A, 1, 0x61, 0x1A, 1, 0x62, 0x22, 1, 0x78),
    )


def test_file_field_numbers_are_pinned() raises:
    # build_systems = 1 (0x0a, 9 bytes), artifacts = 2 (0x12, 9 bytes).
    var systems = List[BuildSystem]()
    systems.append(_bs())
    var artifacts = List[Artifact]()
    artifacts.append(_art())
    _expect_bytes(
        encode_proto[Artifacts](Artifacts(systems^, artifacts^)),
        _bytes(
            0x0A, 9, 0x0A, 1, 0x62, 0x12, 1, 0x65, 0x1A, 1, 0x78,
            0x12, 9, 0x0A, 1, 0x61, 0x1A, 1, 0x62, 0x22, 1, 0x78,
        ),
    )


def test_parse_refusals() raises:
    var f = _file()
    assert_equal(
        _refusal(String("artifact {\n  name: \"a\"\n}\n")),
        String(
            "artifacts.textproto: line 1: unknown top-level field 'artifact'"
            " (expected build_systems, artifacts)"
        ),
    )
    assert_equal(
        _refusal(f.replace(String("  args: \"build\"\n"), String("  args: \"build\"\n  kind: \"x\"\n"))),
        String(
            "artifacts.textproto: line 5: unknown field 'kind' in build system 'buck2'"
            " (expected name, executable, args)"
        ),
    )
    assert_equal(
        _refusal(String("build_systems {\n  label: \"x\"\n}\n")),
        String(
            "artifacts.textproto: line 2: unknown field 'label' in build system #1"
            " (expected name, executable, args)"
        ),
    )
    assert_equal(
        _refusal(
            f.replace(String("  executable: \"buck2\"\n"), String("  executable: \"buck2\"\n  executable: \"b\"\n"))
        ),
        String("artifacts.textproto: line 4: field 'executable' is set twice in build system 'buck2'"),
    )
    assert_equal(
        _refusal(f.replace(String("  name: \"buck2\"\n"), String("  name: \"buck2\"\n  name: \"c\"\n"))),
        String("artifacts.textproto: line 3: field 'name' is set twice in build system 'buck2'"),
    )
    assert_equal(
        _refusal(
            f.replace(String("  build_system: \"buck2\"\n  args: \"//pkg:a"), String("  build_system: \"buck2\"\n  version: \"1\"\n  args: \"//pkg:a"))
        ),
        String(
            "artifacts.textproto: line 9: unknown field 'version' in artifact 'a'"
            " (expected name, build_system, args)"
        ),
    )
    assert_equal(
        _refusal(
            f.replace(String("  build_system: \"buck2\"\n  args: \"//pkg:a"), String("  build_system: \"buck2\"\n  build_system: \"x\"\n  args: \"//pkg:a"))
        ),
        String("artifacts.textproto: line 9: field 'build_system' is set twice in artifact 'a'"),
    )
    assert_equal(
        _refusal(f.replace(String("  name: \"a\"\n"), String("  name: \"a\"\n  name: \"z\"\n"))),
        String("artifacts.textproto: line 8: field 'name' is set twice in artifact 'a'"),
    )
    assert_equal(
        _refusal(f.replace(String("name: \"a\""), String("name: a"))),
        String("artifacts.textproto: line 7: expected a quoted string for 'name' but got word 'a'"),
    )
    assert_equal(
        _refusal(String("artifacts {\n  name: \"a\"\n")),
        String("artifacts.textproto: line 1: artifact 'a' is not closed (expected '}')"),
    )
    assert_equal(
        _refusal(String("build_systems {\n")),
        String("artifacts.textproto: line 1: build system #1 is not closed (expected '}')"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
