# =============================================================================
# test_artifact_wire.mojo
# =============================================================================
#
# The artifacts schema (`kci.release.v1`) on the protobuf binary wire, every
# message and every field.
#
# WHAT IS ASSERTED, AND WHAT EACH ONE CATCHES:
#   1. Each message is built with EVERY field set to a value that is not its
#      default, and its whole encoding is compared to bytes written out here
#      by hand: each record's tag (field number and wire type), length and
#      payload. A renumbered field, or a field whose type changes its wire
#      type, is protoc-legal and round-trips cleanly through the same
#      generated code; only a literal statement of the bytes fails on it.
#      The binary encoder writes fields in number order and every plain
#      field it is given, so the comparison is of the whole message. Each
#      value is built by naming every field, so a field added to or removed
#      from the .proto stops this file compiling.
#   2. `Artifact` field 2 is reserved (it was `allowed_channels`): a record
#      under field 2 is skipped on read and lands in no declared field.
#   3. The fully populated `Artifacts` round-trips through the binary and the
#      proto3-JSON codecs to the same bytes.
#
# Reading, validating and rendering an artifacts file is `kci_artifact`,
# whose tests pin the fields as that library reads them; this file states
# the schema itself, so the generated package is gated by its own tests.
# =============================================================================

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from std.testing import assert_equal

from kci_artifact_proto.artifact import (
    Artifact,
    Artifacts,
    BuildSystem,
    Check,
    Command,
)


def _b(*xs: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for x in xs:
        out.append(UInt8(x))
    return out^


def _cat(*parts: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    for p in parts:
        for b in p:
            out.append(b)
    return out^


def _framed(tag: Int, payload: List[UInt8]) -> List[UInt8]:
    """A length-delimited record under a one-byte tag; every payload here is
    shorter than 128 bytes, so its length is one byte."""
    return _cat(_b(tag, len(payload)), payload)


def _expect(what: String, got: List[UInt8], want: List[UInt8]) raises:
    assert_equal(len(got), len(want), what + ": encoding length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": byte " + String(i))


def _one(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


def _command(executable: String, arg: String) -> Command:
    return Command(executable=executable, args=_one(arg))


def _build_system() -> BuildSystem:
    return BuildSystem(
        name=String("n"),
        executable=String("x"),
        args=_one(String("a")),
        affected=_command(String("p"), String("q")),
        build_targets=_command(String("r"), String("s")),
        derive_checks=_command(String("t"), String("u")),
    )


def _artifact() -> Artifact:
    return Artifact(
        name=String("n"),
        build_system=String("b"),
        args=_one(String("a")),
        targets=_one(String("t")),
    )


def _check() -> Check:
    return Check(
        name=String("n"),
        build_system=String("b"),
        targets=_one(String("t")),
    )


def _artifacts() -> Artifacts:
    var bs = List[BuildSystem]()
    bs.append(_build_system())
    var arts = List[Artifact]()
    arts.append(_artifact())
    var checks = List[Check]()
    checks.append(_check())
    return Artifacts(
        build_systems=bs^,
        artifacts=arts^,
        schema_version=Int32(7),
        checks=checks^,
    )


# The pinned encodings. 0x0A = field 1 length-delimited, 0x12 = 2, 0x1A = 3,
# 0x22 = 4, 0x2A = 5, 0x32 = 6; 0x18 = field 3 varint.
def _command_bytes(e: Int, a: Int) -> List[UInt8]:
    return _b(0x0A, 1, e, 0x12, 1, a)  # executable = 1, args = 2


def _build_system_bytes() -> List[UInt8]:
    return _cat(
        _b(0x0A, 1, ord("n")),  # name = 1
        _b(0x12, 1, ord("x")),  # executable = 2
        _b(0x1A, 1, ord("a")),  # args = 3
        _framed(0x22, _command_bytes(ord("p"), ord("q"))),  # affected = 4
        _framed(0x2A, _command_bytes(ord("r"), ord("s"))),  # build_targets = 5
        _framed(0x32, _command_bytes(ord("t"), ord("u"))),  # derive_checks = 6
    )


def _artifact_bytes() -> List[UInt8]:
    return _cat(
        _b(0x0A, 1, ord("n")),  # name = 1
        _b(0x1A, 1, ord("b")),  # build_system = 3 (2 is reserved)
        _b(0x22, 1, ord("a")),  # args = 4
        _b(0x2A, 1, ord("t")),  # targets = 5
    )


def _check_bytes() -> List[UInt8]:
    return _cat(
        _b(0x0A, 1, ord("n")),  # name = 1
        _b(0x12, 1, ord("b")),  # build_system = 2
        _b(0x1A, 1, ord("t")),  # targets = 3
    )


def test_command_bytes() raises:
    _expect(
        "Command",
        encode_proto(_command(String("p"), String("q"))),
        _command_bytes(ord("p"), ord("q")),
    )


def test_build_system_bytes() raises:
    _expect("BuildSystem", encode_proto(_build_system()), _build_system_bytes())


def test_artifact_bytes() raises:
    _expect("Artifact", encode_proto(_artifact()), _artifact_bytes())


def test_check_bytes() raises:
    _expect("Check", encode_proto(_check()), _check_bytes())


def test_artifacts_bytes() raises:
    var want = _cat(
        _framed(0x0A, _build_system_bytes()),  # build_systems = 1
        _framed(0x12, _artifact_bytes()),  # artifacts = 2
        _b(0x18, 7),  # schema_version = 3
        _framed(0x22, _check_bytes()),  # checks = 4
    )
    _expect("Artifacts", encode_proto(_artifacts()), want)


def test_artifact_field_2_is_reserved() raises:
    # name = "n", a field-2 string record "z", build_system = "b".
    var back = decode_proto[Artifact](
        _b(0x0A, 1, ord("n"), 0x12, 1, ord("z"), 0x1A, 1, ord("b"))
    )
    assert_equal(back.name, "n")
    assert_equal(back.build_system, "b")
    assert_equal(len(back.args), 0, "a field-2 record read into args")
    assert_equal(len(back.targets), 0, "a field-2 record read into targets")


def test_round_trips() raises:
    var want = encode_proto(_artifacts())
    _expect(
        "binary round trip",
        encode_proto(decode_proto[Artifacts](encode_proto(_artifacts()))),
        want,
    )
    _expect(
        "proto3-JSON round trip",
        encode_proto(decode_json[Artifacts](encode_json(_artifacts()))),
        want,
    )


def main() raises:
    print("test_command_bytes")
    test_command_bytes()
    print("test_build_system_bytes")
    test_build_system_bytes()
    print("test_artifact_bytes")
    test_artifact_bytes()
    print("test_check_bytes")
    test_check_bytes()
    print("test_artifacts_bytes")
    test_artifacts_bytes()
    print("test_artifact_field_2_is_reserved")
    test_artifact_field_2_is_reserved()
    print("test_round_trips")
    test_round_trips()
    print("test_artifact_wire: PASS")
