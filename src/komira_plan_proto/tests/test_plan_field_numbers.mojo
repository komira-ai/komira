# =============================================================================
# test_plan_field_numbers.mojo
# =============================================================================
#
# A FIELD-NUMBER CENSUS of the parts of `komira.plan.v1` every reader meets
# first, stated as WIRE BYTES: the envelope, two leaf expression messages and
# two vocabulary spaces. The whole plan wire (every node and expression arm)
# is exercised by `komira_plan_wire`'s round trips; this file pins the
# numbers themselves, which a round trip through one generated codec cannot
# see (it agrees with itself whatever the numbers are).
#
# A message is pinned as in the other proto censuses: a byte stream written
# by hand with the number and wire type the proto declares, decoded and read
# back BY NAME, then re-encoded to the same bytes. Every implicit-presence
# field written here holds a non-zero value, so the comparison does not
# depend on whether an encoder writes zero values.
#
# Pinned: WirePlanEnvelope 1 format_version (2 plan and 3 write_target absent
# decode unset); WireColRef 1 name, 2 side; WireColIdx 1 index (int64, a
# negative is a 10-byte varint); ColSide 0..3 and PlanTag 0..4 by number and
# by name, with wire 0 the UNSPECIFIED value of each space (the vocabulary's
# "wire number = engine value + 1" rule).
# =============================================================================

from std.testing import assert_equal, assert_false

from komira_proto_codec import decode_proto, encode_proto
from komira_plan_proto.plan import WireColIdx, WireColRef, WirePlanEnvelope
from komira_plan_proto.plan_vocabulary import ColSide, PlanTag


def _varint(mut b: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _uint(mut b: List[UInt8], field: Int, v: UInt64):
    """A varint record: tag (wire type 0), then the value."""
    _varint(b, UInt64(field << 3))
    _varint(b, v)


def _str(mut b: List[UInt8], field: Int, s: String):
    """A length-delimited record (wire type 2) holding `s`."""
    _varint(b, UInt64((field << 3) | 2))
    _varint(b, UInt64(s.byte_length()))
    for c in s.as_bytes():
        b.append(c)


def _hex(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += hex(Int(b[i])) + " "
    return out


def _same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(_hex(got), _hex(want), what + ": re-encode differs from the hand-written bytes")


def test_envelope() raises:
    """WirePlanEnvelope: 1 format_version; 2 plan and 3 write_target are
    messages, absent here, and decode unset."""
    var b = List[UInt8]()
    _uint(b, 1, 3)
    assert_equal(b[0], UInt8(0x08), "field 1, varint: tag byte 0x08")
    var e = decode_proto[WirePlanEnvelope](b.copy())
    assert_equal(e.format_version, UInt32(3))
    assert_false(Bool(e.plan))
    assert_false(Bool(e.write_target))
    _same(encode_proto(e), b, "WirePlanEnvelope")


def test_col_ref() raises:
    """WireColRef: 1 name, 2 side (ColSide)."""
    var b = List[UInt8]()
    _str(b, 1, "amount")
    _uint(b, 2, 3)  # COL_SIDE_RIGHT
    var c = decode_proto[WireColRef](b.copy())
    assert_equal(c.name, "amount")
    assert_equal(c.side.value, ColSide.COL_SIDE_RIGHT)
    _same(encode_proto(c), b, "WireColRef")


def test_col_idx() raises:
    """WireColIdx: 1 index (int64)."""
    var b = List[UInt8]()
    _uint(b, 1, 41)
    var c = decode_proto[WireColIdx](b.copy())
    assert_equal(c.index, Int64(41))
    _same(encode_proto(c), b, "WireColIdx")

    var neg = List[UInt8]()
    _uint(neg, 1, UInt64(Int64(-2)))
    assert_equal(len(neg), 1 + 10, "a negative int64 is a 10-byte varint")
    var n = decode_proto[WireColIdx](neg.copy())
    assert_equal(n.index, Int64(-2))
    _same(encode_proto(n), neg, "WireColIdx negative")


def test_vocabulary_numbers() raises:
    """ColSide 0..3 and the first PlanTag values, by number AND by name."""
    var sides = List[String]()
    sides.append("COL_SIDE_WIRE_UNSPECIFIED")
    sides.append("COL_SIDE_NONE")
    sides.append("COL_SIDE_LEFT")
    sides.append("COL_SIDE_RIGHT")
    for n in range(len(sides)):
        assert_equal(ColSide(n).json_name(), sides[n], "ColSide " + String(n))
        assert_equal(ColSide.from_json_name(sides[n]).value, n, sides[n])

    var tags = List[String]()
    tags.append("PLAN_WIRE_UNSPECIFIED")
    tags.append("PLAN_SCAN")
    tags.append("PLAN_FILTER")
    tags.append("PLAN_PROJECT")
    tags.append("PLAN_AGGREGATE")
    for n in range(len(tags)):
        assert_equal(PlanTag(n).json_name(), tags[n], "PlanTag " + String(n))
        assert_equal(PlanTag.from_json_name(tags[n]).value, n, tags[n])


def main() raises:
    print("test_plan_field_numbers: the komira.plan.v1 envelope and leaf census")
    test_envelope()
    test_col_ref()
    test_col_idx()
    test_vocabulary_numbers()
    print("ALL komira.plan.v1 FIELD-NUMBER TESTS PASSED")
