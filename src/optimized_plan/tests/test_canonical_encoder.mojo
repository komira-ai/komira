# =============================================================================
# test_canonical_encoder.mojo
# =============================================================================
#
# The canonical encoder (docs/design/optimized_plan.md §7.1) on messages built
# by hand, each with its exact expected bytes.
#
# What each test proves:
#   test_fields_ascend_across_a_oneof_arm: an OptimizedSegment read with
#     pin_groups (12) before the oneof arm logical (10) comes out with 10
#     before 12, and a nested message is sorted the same way.
#   test_implicit_defaults_omitted: a PinGroup whose group, lineage and
#     commit_seq are defaults encodes to no bytes, and one non-default field among defaults is the only record.
#   test_set_empty_message_written_unset_omitted: an OptimizedSegment whose
#     `needs` is set and empty gets tag 0x32 and length 0; one whose `needs`
#     is unset gets no bytes.
#   test_repeated_numeric_is_packed: PinGroup.members [1, 2, 300] is one
#     length-delimited record, not three varint records; an
#     empty list writes nothing.
#   test_repeated_string_and_message_are_one_record_each: DeclaredNeeds
#     data_scopes and runtimes are one record per element in list order,
#     including an element that is an empty message.
#   test_nan_payloads_become_one_bit_pattern: signalling, negative and
#     payload NaNs of a double field and a float field are each written as
#     one pattern (0x7FF8000000000000, 0x7FC00000); a decoded NaN is too.
#   test_negative_zero_kept_positive_zero_omitted: WireScalar.float_val -0.0
#     is written as 0x8000000000000000, +0.0 is omitted.
#   test_varints_are_minimal: the largest uint64 is a ten-byte varint, a
#     negative int64 is its ten-byte two's complement, 300 is two bytes.
#   test_every_scalar_writer_and_stable_sort: each scalar, enum and message
#     writer of the encoder, called from field 18 down to field 1, comes out
#     ascending with the tag and payload of its wire type; records of one
#     field keep the order they were written in.
#   test_every_repeated_writer_packs_or_repeats: each repeated writer: packed
#     varint, fixed and bool payloads with NaN canonicalized, an empty list
#     omitted, and strings, bytes and messages as one record per element.
#   test_map_methods_refuse_by_name: each of the four map methods raises
#     CANONICAL_MAP_UNSUPPORTED with its full text.
#   test_encoder_is_empty_after_into_buf: a second `into_buf` is empty.
#   test_canonical_round_trips: decoding canonical bytes and encoding again
#     gives the same bytes.
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_true

from proto_codec import decode_proto
from optimized_plan import (
    CANONICAL_MAP_UNSUPPORTED,
    CanonicalPbEncoder,
    encode_canonical,
)
from plan_proto.optimized_plan import (
    DeclaredNeeds,
    OptimizedSegment,
    PinGroup,
    RuntimeNeed,
)
from plan_proto.plan import UdfKind, UdfRef, WireScalar


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


def _is(got: List[UInt8], expected: String, label: String) raises:
    assert_equal(_hex(got), _hex(_unhex(expected)), label)


def _pin_group(
    group: String, commit_seq: UInt64, members: List[UInt32]
) -> PinGroup:
    return PinGroup(group, String(""), commit_seq, members.copy())


def test_fields_ascend_across_a_oneof_arm() raises:
    # segment_id 5 (3), pin_groups (12) "g", logical (10) with an empty
    # output_schema (2), written in that order.
    var seg = decode_proto[OptimizedSegment](
        _unhex("1805 6203 0a0167 5202 1200")
    )
    _is(encode_canonical(seg), "1805 5202 1200 6203 0a0167", "canonical order")


def test_implicit_defaults_omitted() raises:
    var defaults = decode_proto[PinGroup](_unhex("0a00 1200 1800"))
    _is(encode_canonical(defaults), "", "defaults omitted")
    var one = _pin_group("g", 300, List[UInt32]())
    _is(encode_canonical(one), "0a0167 18ac02", "one field set")


def test_set_empty_message_written_unset_omitted() raises:
    var set_empty = decode_proto[OptimizedSegment](_unhex("3200"))
    assert_true(Bool(set_empty.needs), "needs decoded as set")
    _is(encode_canonical(set_empty), "3200", "set and empty")
    var unset = decode_proto[OptimizedSegment](List[UInt8]())
    assert_true(not Bool(unset.needs), "needs decoded as unset")
    _is(encode_canonical(unset), "", "unset")


def test_repeated_numeric_is_packed() raises:
    var members = List[UInt32]()
    members.append(1)
    members.append(2)
    members.append(300)
    var g = _pin_group("", 0, members)
    _is(encode_canonical(g), "2204 01 02 ac02", "packed")
    _is(encode_canonical(_pin_group("", 0, List[UInt32]())), "", "empty omitted")


def test_repeated_string_and_message_are_one_record_each() raises:
    var scopes = List[String]()
    scopes.append("a")
    scopes.append("bc")
    var runtimes = List[RuntimeNeed]()
    runtimes.append(RuntimeNeed("r", "x"))
    runtimes.append(RuntimeNeed("", ""))
    var needs = DeclaredNeeds(List[UdfRef](), scopes^, True, runtimes^)
    _is(
        encode_canonical(needs),
        "2a0161 2a026263 4001 4a06 0a0172 120178 4a00",
        "one record per element, in order",
    )


def test_nan_payloads_become_one_bit_pattern() raises:
    var nans = List[UInt64]()
    nans.append(0x7FF8000000000000)  # quiet
    nans.append(0x7FF0000000000001)  # signalling
    nans.append(0xFFF8000000000000)  # negative
    nans.append(0x7FFFFFFFFFFFFFFF)  # full payload
    for i in range(len(nans)):
        var enc = CanonicalPbEncoder()
        enc.write_f64_field(3, "floatVal", bitcast[DType.float64, 1](nans[i]))
        _is(enc.into_buf(), "19 000000000000f87f", "double NaN " + String(i))
    var fnans = List[UInt32]()
    fnans.append(0x7FC00000)
    fnans.append(0x7F800001)
    fnans.append(0xFFC00000)
    fnans.append(0x7FFFFFFF)
    for i in range(len(fnans)):
        var enc = CanonicalPbEncoder()
        enc.write_f32_field(1, "f", bitcast[DType.float32, 1](fnans[i]))
        _is(enc.into_buf(), "0d 0000c07f", "float NaN " + String(i))
    var decoded = decode_proto[WireScalar](_unhex("19 010000000000f07f"))
    _is(encode_canonical(decoded), "19 000000000000f87f", "decoded NaN")


def test_negative_zero_kept_positive_zero_omitted() raises:
    var neg = decode_proto[WireScalar](_unhex("19 0000000000000080"))
    _is(encode_canonical(neg), "19 0000000000000080", "-0.0 kept")
    var pos = decode_proto[WireScalar](_unhex("19 0000000000000000"))
    _is(encode_canonical(pos), "", "+0.0 omitted")


def test_varints_are_minimal() raises:
    var big = _pin_group("", UInt64(0xFFFFFFFFFFFFFFFF), List[UInt32]())
    _is(encode_canonical(big), "18 ffffffffffffffffff01", "uint64 max")
    var enc = CanonicalPbEncoder()
    enc.write_i64_field(2, "intVal", -1)
    enc.write_u64_field(3, "n", 300)
    _is(enc.into_buf(), "10 ffffffffffffffffff01 18 ac02", "int64 -1 and 300")


def test_every_scalar_writer_and_stable_sort() raises:
    var enc = CanonicalPbEncoder()
    enc.write_bool_field(18, "b", False)
    enc.write_message_field[PinGroup](17, "m", _pin_group("g", 0, List[UInt32]()))
    enc.write_enum_field[UdfKind](16, "e", UdfKind.from_number(2))
    enc.write_bool_field(15, "b", True)
    enc.write_sfixed32_field(14, "n", -1)
    enc.write_sfixed64_field(13, "n", -1)
    enc.write_fixed32_field(12, "n", 1)
    enc.write_fixed64_field(11, "n", 1)
    enc.write_sint32_field(10, "n", -2)
    enc.write_sint64_field(9, "n", -1)
    enc.write_f32_field(8, "n", 1.0)
    enc.write_f64_field(7, "n", 1.0)
    enc.write_u32_field(6, "n", 5)
    enc.write_u64_field(5, "n", 300)
    enc.write_i32_field(4, "n", -1)
    enc.write_i64_field(3, "n", -1)
    var blob = List[UInt8]()
    blob.append(1)
    blob.append(2)
    enc.write_bytes_field(2, "n", blob)
    enc.write_string_field(1, "n", "ab")
    _is(
        enc.into_buf(),
        "0a026162 12020102 18ffffffffffffffffff01 20ffffffffffffffffff01"
        " 28ac02 3005 39000000000000f03f 450000803f 4801 5003"
        " 590100000000000000 6501000000 69ffffffffffffffff 75ffffffff 7801"
        " 800102 8a0103 0a0167 900100",
        "ascending, one wire type each",
    )
    # Records of one field keep their written order around another field's.
    var same = CanonicalPbEncoder()
    same.write_string_field(5, "n", "a")
    same.write_u32_field(2, "n", 1)
    same.write_string_field(5, "n", "b")
    _is(same.into_buf(), "1001 2a0161 2a0162", "stable")


def test_every_repeated_writer_packs_or_repeats() raises:
    var enc = CanonicalPbEncoder()
    enc.begin_list_field(3, "n")
    enc.write_i64_element(3, -1)
    enc.write_i64_element(3, 2)
    enc.end_list_field()
    enc.begin_list_field(4, "n")
    enc.write_i32_element(4, -1)
    enc.write_i32_element(4, 3)
    enc.end_list_field()
    enc.begin_list_field(5, "n")
    enc.write_u64_element(5, 300)
    enc.write_u64_element(5, 1)
    enc.end_list_field()
    enc.begin_list_field(6, "n")
    enc.write_u32_element(6, 300)
    enc.end_list_field()
    enc.begin_list_field(7, "n")
    enc.write_f64_element(7, 1.0)
    enc.write_f64_element(7, bitcast[DType.float64, 1](UInt64(0x7FF0000000000001)))
    enc.end_list_field()
    enc.begin_list_field(8, "n")
    enc.write_f32_element(8, 1.0)
    enc.write_f32_element(8, bitcast[DType.float32, 1](UInt32(0xFFC00001)))
    enc.end_list_field()
    enc.begin_list_field(9, "n")
    enc.write_sint64_element(9, -1)
    enc.write_sint64_element(9, 1)
    enc.end_list_field()
    enc.begin_list_field(10, "n")
    enc.write_sint32_element(10, -2)
    enc.write_sint32_element(10, 2)
    enc.end_list_field()
    enc.begin_list_field(11, "n")
    enc.write_fixed64_element(11, 1)
    enc.end_list_field()
    enc.begin_list_field(12, "n")
    enc.write_fixed32_element(12, 1)
    enc.end_list_field()
    enc.begin_list_field(13, "n")
    enc.write_sfixed64_element(13, -1)
    enc.end_list_field()
    enc.begin_list_field(14, "n")
    enc.write_sfixed32_element(14, -1)
    enc.end_list_field()
    enc.begin_list_field(15, "n")
    enc.write_bool_element(15, True)
    enc.write_bool_element(15, False)
    enc.end_list_field()
    enc.begin_list_field(16, "n")
    enc.write_enum_element[UdfKind](16, UdfKind.from_number(1))
    enc.write_enum_element[UdfKind](16, UdfKind.from_number(2))
    enc.end_list_field()
    enc.begin_list_field(17, "n")
    enc.end_list_field()
    enc.begin_list_field(18, "n")
    enc.write_string_element(18, "x")
    enc.write_string_element(18, "y")
    enc.end_list_field()
    var blob = List[UInt8]()
    blob.append(1)
    blob.append(2)
    enc.begin_list_field(19, "n")
    enc.write_bytes_element(19, blob)
    enc.end_list_field()
    enc.begin_list_field(20, "n")
    enc.write_message_element[PinGroup](20, _pin_group("g", 0, List[UInt32]()))
    enc.write_message_element[PinGroup](20, _pin_group("", 0, List[UInt32]()))
    enc.end_list_field()
    _is(
        enc.into_buf(),
        "1a0b ffffffffffffffffff01 02"
        " 220b ffffffffffffffffff01 03"
        " 2a03 ac0201"
        " 3202 ac02"
        " 3a10 000000000000f03f 000000000000f87f"
        " 4208 0000803f 0000c07f"
        " 4a02 0102"
        " 5202 0304"
        " 5a08 0100000000000000"
        " 6204 01000000"
        " 6a08 ffffffffffffffff"
        " 7204 ffffffff"
        " 7a02 0100"
        " 8201 02 0102"
        " 9201 01 78 9201 01 79"
        " 9a01 02 0102"
        " a201 03 0a0167 a201 00",
        "packed numerics, one record per string, bytes and message",
    )


def test_map_methods_refuse_by_name() raises:
    var text = (
        CANONICAL_MAP_UNSUPPORTED
        + ": a map field has no canonical encoding (protoc leaves the order"
        " of its entries open)"
    )
    var enc = CanonicalPbEncoder()
    var seen = 0
    try:
        enc.begin_map_field(1, "m")
    except e:
        assert_equal(String(e), text)
        seen += 1
    try:
        enc.begin_map_entry()
    except e:
        assert_equal(String(e), text)
        seen += 1
    try:
        enc.end_map_entry()
    except e:
        assert_equal(String(e), text)
        seen += 1
    try:
        enc.end_map_field()
    except e:
        assert_equal(String(e), text)
        seen += 1
    assert_equal(seen, 4, "every map method refused")


def test_encoder_is_empty_after_into_buf() raises:
    var enc = CanonicalPbEncoder()
    enc.write_u32_field(2, "n", 1)
    enc.write_u32_field(1, "n", 1)
    _is(enc.into_buf(), "0801 1001", "first")
    _is(enc.into_buf(), "", "second")


def test_canonical_round_trips() raises:
    var seg = decode_proto[OptimizedSegment](
        _unhex("1805 6203 0a0167 5202 1200 3200")
    )
    var once = encode_canonical(seg)
    var twice = encode_canonical(decode_proto[OptimizedSegment](once.copy()))
    _is(once, "1805 3200 5202 1200 6203 0a0167", "once")
    assert_equal(_hex(twice), _hex(once), "twice")


def main() raises:
    test_fields_ascend_across_a_oneof_arm()
    test_implicit_defaults_omitted()
    test_set_empty_message_written_unset_omitted()
    test_repeated_numeric_is_packed()
    test_repeated_string_and_message_are_one_record_each()
    test_nan_payloads_become_one_bit_pattern()
    test_negative_zero_kept_positive_zero_omitted()
    test_varints_are_minimal()
    test_every_scalar_writer_and_stable_sort()
    test_every_repeated_writer_packs_or_repeats()
    test_map_methods_refuse_by_name()
    test_encoder_is_empty_after_into_buf()
    test_canonical_round_trips()
    print("the canonical encoder writes ascending, packed, minimal, NaN-canonical bytes")
