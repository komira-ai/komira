# =============================================================================
# test_avro_nullable_union_decode.mojo — nullable-union decode.
# =============================================================================
#
# Acceptance:
#   test_nullable_union_decode — both `[null, T]` (NullFirst) and `[T, null]`
#   (NullSecond) union orderings.
#
# Avro encodes nullability ONLY via a 2-branch union. The wire is a zigzag
# `long` tag (0 selects branch 0, 1 selects branch 1) followed by the value
# if the selected branch is non-null. NullFirst: tag 0 == null. NullSecond:
# tag 1 == null. Getting the ordering wrong corrupts every nullable field —
# this is the load-bearing decoder invariant.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import read_avro_bytes, OCF_SYNC_LEN


def _enc_long(n: Int64, mut out: List[UInt8]):
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _str_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _enc_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _enc_bytes(b: List[UInt8], mut out: List[UInt8]):
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _sync() -> List[UInt8]:
    var s = List[UInt8]()
    for i in range(OCF_SYNC_LEN):
        s.append(UInt8(0xA0 + i))
    return s^


def _make_header(schema: String, mut out: List[UInt8]):
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)
    _enc_long(Int64(2), out)
    _enc_str(String("avro.schema"), out)
    _enc_bytes(_str_bytes(schema), out)
    _enc_str(String("avro.codec"), out)
    _enc_bytes(_str_bytes(String("null")), out)
    _enc_long(Int64(0), out)
    var s = _sync()
    for i in range(len(s)):
        out.append(s[i])


def _append_block(mut out: List[UInt8], object_count: Int64, payload: List[UInt8]):
    _enc_long(object_count, out)
    _enc_long(Int64(len(payload)), out)
    for i in range(len(payload)):
        out.append(payload[i])
    var s = _sync()
    for i in range(len(s)):
        out.append(s[i])


# -----------------------------------------------------------------------------
# Tests.
# -----------------------------------------------------------------------------


# nf: union[null, long]  (NullFirst — tag 0 == null, tag 1 == long)
# ns: union[string, null] (NullSecond — tag 0 == string, tag 1 == null)
comptime _SCHEMA_NULLABLE = String(
    '{"type":"record","name":"Nullable","fields":['
    '{"name":"nf","type":["null","long"]},'
    '{"name":"ns","type":["string","null"]}]}'
)


def test_nullable_union() raises:
    """NullFirst + NullSecond unions decode with correct per-row validity."""
    var buf = List[UInt8]()
    _make_header(_SCHEMA_NULLABLE, buf)

    var p = List[UInt8]()
    # Row 0: nf = 100 (tag 1, then long), ns = "a" (tag 0, then string)
    _enc_long(Int64(1), p)  # NullFirst: tag 1 selects the `long` branch
    _enc_long(Int64(100), p)
    _enc_long(Int64(0), p)  # NullSecond: tag 0 selects the `string` branch
    _enc_str(String("a"), p)
    # Row 1: nf = null (tag 0), ns = null (tag 1)
    _enc_long(Int64(0), p)  # NullFirst: tag 0 == null (no value follows)
    _enc_long(Int64(1), p)  # NullSecond: tag 1 == null (no value follows)
    # Row 2: nf = -5 (tag 1), ns = "bc" (tag 0)
    _enc_long(Int64(1), p)
    _enc_long(Int64(-5), p)
    _enc_long(Int64(0), p)
    _enc_str(String("bc"), p)

    _append_block(buf, Int64(3), p)

    var rb = read_avro_bytes(Span(buf))
    assert_equal(rb.num_rows(), 3, "3 rows")
    assert_equal(rb.num_columns(), 2, "2 cols")

    # NullFirst long column
    ref nfcol = rb.column_at(0)
    var nfa = nfcol.as_primitive[DType.int64]()
    assert_true(not nfa.is_null(0), "nf[0] valid")
    assert_equal(Int(nfa.get(0)), 100, "nf[0]")
    assert_true(nfa.is_null(1), "nf[1] null")
    assert_true(not nfa.is_null(2), "nf[2] valid")
    assert_equal(Int(nfa.get(2)), -5, "nf[2]")
    assert_equal(nfcol.null_count(), 1, "nf null_count == 1")

    # NullSecond string column
    ref nscol = rb.column_at(1)
    var nsa = nscol.as_string()
    assert_true(not nsa.is_null(0), "ns[0] valid")
    assert_equal(nsa.get(0), String("a"), "ns[0]")
    assert_true(nsa.is_null(1), "ns[1] null")
    assert_true(not nsa.is_null(2), "ns[2] valid")
    assert_equal(nsa.get(2), String("bc"), "ns[2]")


def main() raises:
    test_nullable_union()
    print("test_avro_nullable_union_decode: ALL PASS")
