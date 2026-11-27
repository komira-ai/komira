# =============================================================================
# test_canonical_wire_plan.mojo
# =============================================================================
#
# The canonical encoder on `WirePlan` messages read from hand-written bytes in
# the order a producer may write them (oneof arm before the fields beside it,
# fields out of order), each with its hand-computed canonical bytes (protoc's
# ordinary serializer form, ascending field numbers).
#
# What each test proves:
#   test_nested_oneof_arms_sort_beside_fields: a Limit plan holding a Filter
#     plan holding an empty plan, with a double literal, comes out with
#     output_schema (2) before the node arm (10 / 5) at every level, and the
#     set-but-empty child plan written as tag and length 0.
#   test_project_exprs_repeat_and_literals_canonicalize: a Project plan with
#     three literal expressions keeps them one record each in order, writes
#     -0.0 as 0x8000000000000000, rewrites a non-canonical NaN as
#     0x7FF8000000000000, and moves `is_cse_introduced` and `child` after
#     `exprs`.
#
# Each case also decodes the canonical bytes and encodes again: the same
# bytes (idempotence).
# =============================================================================

from std.testing import assert_equal

from proto_codec import decode_proto
from optimized_plan import encode_canonical
from plan_proto.plan import WirePlan


def _nibble(c: Int) raises -> Int:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    raise Error("not a lower-case hex digit: " + chr(c))


def _unhex(s: String) raises -> List[UInt8]:
    """Two digits a byte, spaces ignored."""
    var out = List[UInt8]()
    var high = -1
    for b in s.as_bytes():
        var c = Int(b)
        if c == 32:
            continue
        if high < 0:
            high = _nibble(c)
        else:
            out.append(UInt8(high * 16 + _nibble(c)))
            high = -1
    return out^


def _hex(b: List[UInt8]) -> String:
    comptime digits = "0123456789abcdef"
    var out = String("")
    for i in range(len(b)):
        var v = Int(b[i])
        out += String(digits[byte = v >> 4]) + String(digits[byte = v & 15])
    return out


def _canonical(written: String, expected: String) raises:
    var plan = decode_proto[WirePlan](_unhex(written))
    var got = encode_canonical(plan)
    assert_equal(_hex(got), _hex(_unhex(expected)), "canonical bytes")
    var again = encode_canonical(decode_proto[WirePlan](got.copy()))
    assert_equal(_hex(again), _hex(got), "idempotence")


def test_nested_oneof_arms_sort_beside_fields() raises:
    # limit (10) { n 5, child (3) { filter (5) { predicate literal 2.5,
    # child (2) { empty } } } }, then output_schema (2) with one field
    # named "a", written after the arm.
    _canonical(
        "5217 0805 1a13 2a11 0a0b 2209 19 0000000000000440 1202 1200"
        " 1205 0a03 0a0161",
        "1205 0a03 0a0161"
        " 5217 0805 1a13 2a11 0a0b 2209 19 0000000000000440 1202 1200",
    )


def test_project_exprs_repeat_and_literals_canonicalize() raises:
    _canonical(
        "3225 1801 1200"
        " 0a05 2203 2201 78"
        " 0a0b 2209 19 0000000000000080"
        " 0a0b 2209 19 010000000000f07f",
        "3225 0a05 2203 2201 78"
        " 0a0b 2209 19 0000000000000080"
        " 0a0b 2209 19 000000000000f87f"
        " 1200 1801",
    )


def main() raises:
    test_nested_oneof_arms_sort_beside_fields()
    test_project_exprs_repeat_and_literals_canonicalize()
    print("the canonical encoder sorts and canonicalizes hand-built wire plans")
