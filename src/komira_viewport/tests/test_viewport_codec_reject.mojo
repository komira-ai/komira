# =============================================================================
# The Expr / scalar codec and the response envelope: exact allow-lists, depth
# bound and every refusal.
#
#   * The op-code allow-lists are swept over all 256 byte values for each of
#     the three op-bearing tags: the accepted set must be EXACTLY the v1 list
#     (a dropped or an added code both fail).
#   * The depth budget is held at its boundary through each recursive site
#     (unary, string-op, alias, binary left and right): 64 levels decode, 65
#     do not. A site that forgets to spend depth lets 65 through.
#   * Scalar literals are checked by their wire tag byte, not only by a round
#     trip, so two swapped tags cannot pass as a symmetric pair.
#   * The response envelope refuses each malformed field with its own reason,
#     and when two fields are wrong the earlier one is the reason given.
#   * The payload length is refused past the buffer end at every width,
#     including lengths of 2^63 and above that are negative as an Int.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_plan_expr.expr import Expr, UN_NOT
from komira_plan_expr.scalar_value import ScalarValue
from komira_viewport import (
    ViewportWriter,
    ViewportReader,
    encode_expr,
    decode_expr,
    encode_scalar,
    decode_scalar,
    RowCount,
    encode_grid_response,
    decode_grid_response,
    VIEWPORT_COUNT_EXACT,
    VIEWPORT_COUNT_ESTIMATED,
    VIEWPORT_PAYLOAD_ARROW_IPC,
    VIEWPORT_PAYLOAD_JSON,
)

# Wire tags (a hostile client knows these, so the tests spell them).
comptime T_COL_REF: UInt8 = 0
comptime T_LITERAL: UInt8 = 2
comptime T_BINARY: UInt8 = 3
comptime T_UNARY: UInt8 = 4
comptime T_ALIAS: UInt8 = 6
comptime T_STRING_OP: UInt8 = 7


def _text(e: Expr) -> String:
    var s = String("")
    s.write(e)
    return s^


def _leaf(mut w: ViewportWriter, name: String):
    w.write_u8(T_COL_REF)
    w.write_string(name)
    w.write_u8(UInt8(0))


def _decode_all(var bytes: List[UInt8]) raises -> Expr:
    var r = ViewportReader(bytes^)
    var e = decode_expr(r)
    r.expect_end()
    return e^


# --- op-code allow-lists, swept over every byte value --------------------------


def _binary_with_op(op: Int) -> List[UInt8]:
    var w = ViewportWriter()
    w.write_u8(T_BINARY)
    w.write_u8(UInt8(op))
    _leaf(w, String("a"))
    _leaf(w, String("b"))
    return w.take_bytes()


def _unary_with_op(op: Int) -> List[UInt8]:
    var w = ViewportWriter()
    w.write_u8(T_UNARY)
    w.write_u8(UInt8(op))
    _leaf(w, String("a"))
    return w.take_bytes()


def _strop_with_op(op: Int) -> List[UInt8]:
    var w = ViewportWriter()
    w.write_u8(T_STRING_OP)
    w.write_u8(UInt8(op))
    _leaf(w, String("a"))
    w.write_string(String("p%"))
    return w.take_bytes()


def test_binary_op_allow_list_is_exact() raises:
    var accepted = List[Int]()
    for op in range(256):
        try:
            _ = _decode_all(_binary_with_op(op))
            accepted.append(op)
        except e:
            assert_true(
                String(e).find("disallowed binary op code " + String(op)) >= 0,
                String(e),
            )
    var want: List[Int] = [0, 1, 2, 3, 4, 10, 11, 12, 13, 14, 15, 20, 21]
    assert_equal(len(accepted), len(want))
    for i in range(len(want)):
        assert_equal(accepted[i], want[i])


def test_unary_op_allow_list_is_exact() raises:
    var accepted = List[Int]()
    for op in range(256):
        try:
            _ = _decode_all(_unary_with_op(op))
            accepted.append(op)
        except e:
            assert_true(
                String(e).find("disallowed unary op code " + String(op)) >= 0,
                String(e),
            )
    var want: List[Int] = [0, 1, 2, 3]
    assert_equal(len(accepted), len(want))
    for i in range(len(want)):
        assert_equal(accepted[i], want[i])


def test_string_op_allow_list_is_exact() raises:
    var accepted = List[Int]()
    for op in range(256):
        try:
            _ = _decode_all(_strop_with_op(op))
            accepted.append(op)
        except e:
            assert_true(
                String(e).find("disallowed string op code " + String(op)) >= 0,
                String(e),
            )
    var want: List[Int] = [0, 1, 2, 3]
    assert_equal(len(accepted), len(want))
    for i in range(len(want)):
        assert_equal(accepted[i], want[i])


def test_string_op_pattern_is_read_after_the_child() raises:
    var e = _decode_all(_strop_with_op(3))
    var want = Expr.string_op(UInt8(3), Expr.col_ref(String("a")), String("p%"))
    assert_equal(_text(e), _text(want))


# --- col-ref side qualifier ----------------------------------------------------


def _col_with_side(side: Int) -> List[UInt8]:
    var w = ViewportWriter()
    w.write_u8(T_COL_REF)
    w.write_string(String("x"))
    w.write_u8(UInt8(side))
    return w.take_bytes()


def test_col_ref_sides() raises:
    assert_equal(_text(_decode_all(_col_with_side(0))), _text(Expr.col_ref(String("x"))))
    assert_equal(_text(_decode_all(_col_with_side(1))), _text(Expr.left(String("x"))))
    assert_equal(_text(_decode_all(_col_with_side(2))), _text(Expr.right(String("x"))))
    with assert_raises(contains="illegal col-ref side qualifier 3"):
        _ = _decode_all(_col_with_side(3))
    with assert_raises(contains="illegal col-ref side qualifier 255"):
        _ = _decode_all(_col_with_side(255))


# --- depth budget at its boundary, through every recursive site ----------------


def _unary_chain(wrappers: Int) -> List[UInt8]:
    var w = ViewportWriter()
    for _ in range(wrappers):
        w.write_u8(T_UNARY)
        w.write_u8(UN_NOT)
    _leaf(w, String("x"))
    return w.take_bytes()


def _alias_chain(wrappers: Int) -> List[UInt8]:
    var w = ViewportWriter()
    for _ in range(wrappers):
        w.write_u8(T_ALIAS)
        w.write_string(String("n"))
    _leaf(w, String("x"))
    return w.take_bytes()


def _strop_chain(wrappers: Int) -> List[UInt8]:
    var w = ViewportWriter()
    for _ in range(wrappers):
        w.write_u8(T_STRING_OP)
        w.write_u8(UInt8(0))
    _leaf(w, String("x"))
    for _ in range(wrappers):
        w.write_string(String("p"))
    return w.take_bytes()


def _binary_left_chain(wrappers: Int) -> List[UInt8]:
    var w = ViewportWriter()
    for _ in range(wrappers):
        w.write_u8(T_BINARY)
        w.write_u8(UInt8(20))  # AND
    _leaf(w, String("x"))
    for _ in range(wrappers):
        _leaf(w, String("y"))
    return w.take_bytes()


def _binary_right_chain(wrappers: Int) -> List[UInt8]:
    var w = ViewportWriter()
    for _ in range(wrappers):
        w.write_u8(T_BINARY)
        w.write_u8(UInt8(21))  # OR
        _leaf(w, String("y"))
    _leaf(w, String("x"))
    return w.take_bytes()


def test_depth_boundary_unary() raises:
    _ = _decode_all(_unary_chain(63))  # 64 levels: the cap, admitted
    with assert_raises(contains="exceeds max depth 64"):
        _ = _decode_all(_unary_chain(64))


def test_depth_boundary_alias() raises:
    _ = _decode_all(_alias_chain(63))
    with assert_raises(contains="exceeds max depth 64"):
        _ = _decode_all(_alias_chain(64))


def test_depth_boundary_string_op() raises:
    _ = _decode_all(_strop_chain(63))
    with assert_raises(contains="exceeds max depth 64"):
        _ = _decode_all(_strop_chain(64))


def test_depth_boundary_binary_both_sides() raises:
    _ = _decode_all(_binary_left_chain(63))
    with assert_raises(contains="exceeds max depth 64"):
        _ = _decode_all(_binary_left_chain(64))
    _ = _decode_all(_binary_right_chain(63))
    with assert_raises(contains="exceeds max depth 64"):
        _ = _decode_all(_binary_right_chain(64))


# --- encoder allow-list --------------------------------------------------------


def test_encode_refuses_tags_outside_the_allow_list() raises:
    var w = ViewportWriter()
    with assert_raises(contains="Expr tag 1 is not in the viewport protocol v1 allow-list"):
        encode_expr(w, Expr.col_idx(3))
    var w2 = ViewportWriter()
    with assert_raises(contains="Expr tag 5 is not in the viewport protocol v1 allow-list"):
        encode_expr(w2, Expr.cast(Expr.col_ref(String("a")), DType.int64))


def test_decode_refuses_tags_outside_the_allow_list() raises:
    # Every tag byte that is not one of the six; the reason names the tag.
    for tag in range(256):
        var t = UInt8(tag)
        if (
            t == T_COL_REF or t == T_LITERAL or t == T_BINARY
            or t == T_UNARY or t == T_ALIAS or t == T_STRING_OP
        ):
            continue
        var w = ViewportWriter()
        w.write_u8(t)
        _leaf(w, String("x"))
        with assert_raises(contains="Expr tag " + String(tag) + " is not in the viewport protocol v1 allow-list"):
            _ = _decode_all(w.take_bytes())


# --- scalar literals by their wire tag ----------------------------------------


def _scalar_bytes(sv: ScalarValue) raises -> List[UInt8]:
    var w = ViewportWriter()
    encode_scalar(w, sv)
    return w.take_bytes()


def _scalar_back(var bytes: List[UInt8]) raises -> ScalarValue:
    var r = ViewportReader(bytes^)
    var sv = decode_scalar(r)
    r.expect_end()
    return sv^


def test_scalar_wire_tags() raises:
    var b = _scalar_bytes(ScalarValue())
    assert_equal(len(b), 1)
    assert_equal(b[0], UInt8(0))
    assert_true(_scalar_back(b^).is_null())

    b = _scalar_bytes(ScalarValue.from_bool(True))
    assert_equal(len(b), 2)
    assert_equal(b[0], UInt8(1))
    assert_equal(b[1], UInt8(1))
    assert_true(_scalar_back(b^).bool_val)

    b = _scalar_bytes(ScalarValue.from_int64(Int64(-3)))
    assert_equal(len(b), 2)
    assert_equal(b[0], UInt8(2))
    assert_equal(b[1], UInt8(5))  # zigzag(-3)
    var i64 = _scalar_back(b^)
    assert_true(i64.dtype == DType.int64)
    assert_equal(i64.int_val, Int64(-3))

    b = _scalar_bytes(ScalarValue.from_int32(Int32(-3)))
    assert_equal(b[0], UInt8(3))
    var i32 = _scalar_back(b^)
    assert_true(i32.dtype == DType.int32)
    assert_equal(i32.int_val, Int64(-3))

    b = _scalar_bytes(ScalarValue.from_float(Float64(0.25)))
    assert_equal(len(b), 9)
    assert_equal(b[0], UInt8(4))
    var f64 = _scalar_back(b^)
    assert_true(f64.dtype == DType.float64)
    assert_equal(f64.float_val, Float64(0.25))

    b = _scalar_bytes(ScalarValue.from_float32(Float32(0.25)))
    assert_equal(len(b), 5)
    assert_equal(b[0], UInt8(5))
    var f32 = _scalar_back(b^)
    assert_true(f32.dtype == DType.float32)
    assert_equal(f32.float_val, Float64(0.25))

    b = _scalar_bytes(ScalarValue.from_string(String("hé")))
    assert_equal(b[0], UInt8(6))
    assert_equal(b[1], UInt8(3))  # byte length, not character count
    var s = _scalar_back(b^)
    assert_true(s.is_string())
    assert_equal(s.string_val, String("hé"))


def test_scalar_kinds_outside_v1_refused() raises:
    var w = ViewportWriter()
    with assert_raises(contains="literal scalar kind not supported"):
        encode_scalar(w, ScalarValue.from_int8(Int8(1)))
    var w2 = ViewportWriter()
    with assert_raises(contains="literal scalar kind not supported"):
        encode_scalar(w2, ScalarValue.from_uint64(UInt64(1)))
    var w3 = ViewportWriter()
    with assert_raises(contains="literal scalar kind not supported"):
        encode_scalar(w3, ScalarValue.from_binary(String("ab")))


def test_unknown_scalar_tags_refused() raises:
    for tag in range(7, 256):
        var one = List[UInt8]()
        one.append(UInt8(tag))
        var r = ViewportReader(one^)
        with assert_raises(contains="unknown scalar tag " + String(tag)):
            _ = decode_scalar(r)


def test_literal_inside_expr_roundtrips() raises:
    var e = Expr.literal(ScalarValue.from_float32(Float32(1.5)))
    var w = ViewportWriter()
    encode_expr(w, e)
    var bytes = w.take_bytes()
    assert_equal(bytes[0], T_LITERAL)
    assert_equal(bytes[1], UInt8(5))
    assert_equal(_text(_decode_all(bytes^)), _text(e))


# --- the response envelope -----------------------------------------------------


def _response(
    magic_bad_at: Int = -1,
    version: UInt64 = UInt64(1),
    facet: UInt8 = UInt8(0),
    count_kind: UInt8 = UInt8(1),
    payload_kind: UInt8 = UInt8(1),
    declared_len: UInt64 = UInt64(2),
    actual_len: Int = 2,
    trailing: Int = 0,
) -> List[UInt8]:
    var magic: List[UInt8] = [UInt8(0x49), UInt8(0x56), UInt8(0x50), UInt8(0x31)]
    if magic_bad_at >= 0:
        magic[magic_bad_at] = magic[magic_bad_at] ^ UInt8(0x20)
    var w = ViewportWriter()
    for i in range(4):
        w.write_u8(magic[i])
    w.write_uvarint(version)
    w.write_u8(facet)
    w.write_uvarint(UInt64(7))  # view_version
    w.write_u8(count_kind)
    w.write_uvarint(UInt64(100))
    w.write_uvarint(UInt64(3))
    w.write_string(String("tok"))
    w.write_u8(payload_kind)
    w.write_uvarint(declared_len)
    for i in range(actual_len):
        w.write_u8(UInt8(0xA0 + i))
    for _ in range(trailing):
        w.write_u8(UInt8(0))
    return w.take_bytes()


def test_response_base_decodes() raises:
    var b = _response()
    var resp = decode_grid_response(Span(b))
    assert_equal(resp.view_version, UInt64(7))
    assert_equal(resp.rowcount.kind, VIEWPORT_COUNT_ESTIMATED)
    assert_equal(resp.rowcount.value, UInt64(100))
    assert_equal(resp.rowcount.error_bound, UInt64(3))
    assert_equal(resp.rowcount.refine_token, String("tok"))
    assert_equal(resp.payload_kind, VIEWPORT_PAYLOAD_JSON)
    assert_equal(len(resp.payload), 2)
    assert_equal(resp.payload[0], UInt8(0xA0))
    assert_equal(resp.payload[1], UInt8(0xA1))


def test_response_encode_bytes() raises:
    var payload: List[UInt8] = [UInt8(0xA0), UInt8(0xA1)]
    var enc = encode_grid_response(
        UInt64(7), RowCount.estimated(UInt64(100), UInt64(3), String("tok")),
        VIEWPORT_PAYLOAD_JSON, Span(payload),
    )
    var want = _response()
    assert_equal(len(enc), len(want))
    for i in range(len(want)):
        assert_equal(enc[i], want[i])


def test_response_bad_magic_at_each_byte() raises:
    for pos in range(4):
        var b = _response(magic_bad_at=pos)
        with assert_raises(contains="bad magic"):
            _ = decode_grid_response(Span(b))


def test_response_field_refusals() raises:
    var b = _response(version=UInt64(2))
    with assert_raises(contains="unsupported response version 2"):
        _ = decode_grid_response(Span(b))
    b = _response(facet=UInt8(1))
    with assert_raises(contains="response facet 1 is not grid"):
        _ = decode_grid_response(Span(b))
    b = _response(count_kind=UInt8(2))
    with assert_raises(contains="unknown RowCount kind 2"):
        _ = decode_grid_response(Span(b))
    b = _response(payload_kind=UInt8(2))
    with assert_raises(contains="unknown payload kind 2"):
        _ = decode_grid_response(Span(b))
    b = _response(declared_len=UInt64(3))
    with assert_raises(contains="payload length runs past buffer end"):
        _ = decode_grid_response(Span(b))
    b = _response(trailing=1)
    with assert_raises(contains="1 trailing bytes"):
        _ = decode_grid_response(Span(b))


def test_response_accepted_kinds() raises:
    var b = _response(count_kind=VIEWPORT_COUNT_EXACT, payload_kind=VIEWPORT_PAYLOAD_ARROW_IPC)
    var resp = decode_grid_response(Span(b))
    assert_equal(resp.rowcount.kind, VIEWPORT_COUNT_EXACT)
    assert_equal(resp.payload_kind, VIEWPORT_PAYLOAD_ARROW_IPC)
    # A payload that ends the buffer exactly is admitted, an empty one too.
    var e = _response(declared_len=UInt64(0), actual_len=0)
    assert_equal(len(decode_grid_response(Span(e)).payload), 0)


def test_response_payload_length_at_and_past_the_buffer() raises:
    # The declared payload length is a UInt64; the decoder must compare it
    # with the bytes left before narrowing it to Int. Two bytes follow the
    # length in every case here.
    var ok = _response(declared_len=UInt64(2))
    assert_equal(len(decode_grid_response(Span(ok)).payload), 2)
    var past: List[UInt64] = [
        UInt64(3),                     # one past the end
        UInt64(0x7FFFFFFFFFFFFFFF),    # Int64.max, the largest non-negative Int
        UInt64(0x8000000000000000),    # 2^63, Int(x) is Int64.min
        UInt64(0x8000000000000001),    # 2^63 + 1
        UInt64(0xFFFFFFFFFFFFFFFE),    # Int(x) is -2
        UInt64(0xFFFFFFFFFFFFFFFF),    # UInt64.max, Int(x) is -1
    ]
    for i in range(len(past)):
        var b = _response(declared_len=past[i])
        with assert_raises(contains="payload length runs past buffer end"):
            _ = decode_grid_response(Span(b))
    # No payload bytes at all: the 2^63 and UInt64.max lengths still refuse.
    var e = _response(declared_len=UInt64(0xFFFFFFFFFFFFFFFF), actual_len=0)
    with assert_raises(contains="payload length runs past buffer end"):
        _ = decode_grid_response(Span(e))
    e = _response(declared_len=UInt64(0x8000000000000000), actual_len=0)
    with assert_raises(contains="payload length runs past buffer end"):
        _ = decode_grid_response(Span(e))


def test_response_first_fault_is_reported() raises:
    # Two faults at once: the field read first names the refusal.
    var b = _response(magic_bad_at=3, version=UInt64(9))
    with assert_raises(contains="bad magic"):
        _ = decode_grid_response(Span(b))
    b = _response(version=UInt64(9), facet=UInt8(1))
    with assert_raises(contains="unsupported response version 9"):
        _ = decode_grid_response(Span(b))
    b = _response(facet=UInt8(1), count_kind=UInt8(9))
    with assert_raises(contains="response facet 1"):
        _ = decode_grid_response(Span(b))
    b = _response(count_kind=UInt8(9), payload_kind=UInt8(9))
    with assert_raises(contains="unknown RowCount kind 9"):
        _ = decode_grid_response(Span(b))
    b = _response(payload_kind=UInt8(9), declared_len=UInt64(50))
    with assert_raises(contains="unknown payload kind 9"):
        _ = decode_grid_response(Span(b))


def test_rowcount_copy_is_independent() raises:
    var rc = RowCount.estimated(UInt64(10), UInt64(2), String("t1"))
    var c = rc.copy()
    rc.refine_token = String("changed")
    rc.value = UInt64(0)
    assert_equal(c.kind, VIEWPORT_COUNT_ESTIMATED)
    assert_equal(c.value, UInt64(10))
    assert_equal(c.error_bound, UInt64(2))
    assert_equal(c.refine_token, String("t1"))


def main() raises:
    var suite = TestSuite()
    suite.test[test_binary_op_allow_list_is_exact]()
    suite.test[test_unary_op_allow_list_is_exact]()
    suite.test[test_string_op_allow_list_is_exact]()
    suite.test[test_string_op_pattern_is_read_after_the_child]()
    suite.test[test_col_ref_sides]()
    suite.test[test_depth_boundary_unary]()
    suite.test[test_depth_boundary_alias]()
    suite.test[test_depth_boundary_string_op]()
    suite.test[test_depth_boundary_binary_both_sides]()
    suite.test[test_encode_refuses_tags_outside_the_allow_list]()
    suite.test[test_decode_refuses_tags_outside_the_allow_list]()
    suite.test[test_scalar_wire_tags]()
    suite.test[test_scalar_kinds_outside_v1_refused]()
    suite.test[test_unknown_scalar_tags_refused]()
    suite.test[test_literal_inside_expr_roundtrips]()
    suite.test[test_response_base_decodes]()
    suite.test[test_response_encode_bytes]()
    suite.test[test_response_bad_magic_at_each_byte]()
    suite.test[test_response_field_refusals]()
    suite.test[test_response_accepted_kinds]()
    suite.test[test_response_payload_length_at_and_past_the_buffer]()
    suite.test[test_response_first_fault_is_reported]()
    suite.test[test_rowcount_copy_is_independent]()
    suite^.run()
