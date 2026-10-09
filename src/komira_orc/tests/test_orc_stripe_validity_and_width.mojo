# =============================================================================
# test_orc_stripe_validity_and_width.mojo: column_decoder.mojo across stripes
# whose PRESENT streams come and go, integer values wider than their column,
# and dictionary encodings on kinds the spec does not allow them on.
# =============================================================================
#
# 1. A stripe with no PRESENT stream after a stripe with nulls. ORC writers
#    (this package's and Apache ORC's Java `TreeWriterBase.writeStripe`) omit
#    PRESENT for a stripe without nulls, so stripes "nv", "vv" (no PRESENT),
#    "nv" are an ordinary file. Each type must read back "nvvvnv" with its
#    values on the right rows. Covered per type through `decode_stripe_column`
#    and end to end through `read_orc_bytes` and `read_orc_bytes_pruned`, the
#    two readers that feed every stripe into one accumulator.
# 2. SHORT / INT / DATE store 64-bit RLE integers; a value outside the
#    column's Arrow width is refused, not truncated. Both edges of each width
#    still decode.
# 3. DICTIONARY / DICTIONARY_V2 on a kind other than STRING / VARCHAR / CHAR
#    is refused (spec "Column Encoding"); the refusal runs before the
#    PRESENT / no-PRESENT split, so one stream layout covers it. STRING,
#    VARCHAR and CHAR still decode both dictionary encodings, with and
#    without a PRESENT stream.
# 4. The build refuses a validity list whose length is not the row count.
#
# Integer streams use the RLEv2 Direct and RLEv1 literal layouts from the
# Apache ORC v1 specification ("Run Length Encoding").
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder, Field
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.expr import Expr, BIN_AND, BIN_GE, BIN_LT
from komira_plan_expr.scalar_value import ScalarValue

from komira_orc import (
    StreamSpan,
    make_accumulator,
    decode_stripe_column,
    OrcWriterOptions,
    OrcFileTail,
    write_orc_bytes,
    read_orc_bytes,
    read_orc_bytes_pruned,
    ORC_COMPRESSION_NONE,
    ORC_STREAM_PRESENT,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_STREAM_DICTIONARY_DATA,
    ORC_ENCODING_DIRECT,
    ORC_ENCODING_DIRECT_V2,
    ORC_ENCODING_DICTIONARY,
    ORC_ENCODING_DICTIONARY_V2,
    ORC_KIND_BOOLEAN,
    ORC_KIND_BYTE,
    ORC_KIND_SHORT,
    ORC_KIND_INT,
    ORC_KIND_LONG,
    ORC_KIND_FLOAT,
    ORC_KIND_DOUBLE,
    ORC_KIND_STRING,
    ORC_KIND_VARCHAR,
    ORC_KIND_CHAR,
    ORC_KIND_BINARY,
    ORC_KIND_DATE,
)


# -----------------------------------------------------------------------------
# Encoders.
# -----------------------------------------------------------------------------


def _bytes(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
    return out^


def _i64s(*vals: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(len(vals)):
        out.append(Int64(vals[i]))
    return out^


def _zigzag(v: Int64) -> UInt64:
    return UInt64((v << 1) ^ (v >> 63))


def _rlev2_direct(values: List[Int64], bits: Int, signed: Bool) -> List[UInt8]:
    """One RLEv2 Direct run at `bits` (1..24: width code bits - 1)."""
    var out = List[UInt8]()
    var n = len(values) - 1
    out.append(UInt8((1 << 6) | ((bits - 1) << 1) | ((n >> 8) & 1)))
    out.append(UInt8(n & 0xFF))
    var cur: UInt64 = 0
    var filled = 0
    for i in range(len(values)):
        var v = _zigzag(values[i]) if signed else UInt64(values[i])
        for b in range(bits - 1, -1, -1):
            cur = (cur << 1) | ((v >> UInt64(b)) & 1)
            filled += 1
            if filled == 8:
                out.append(UInt8(cur & 0xFF))
                cur = 0
                filled = 0
    if filled > 0:
        out.append(UInt8((cur << UInt64(8 - filled)) & 0xFF))
    return out^


def _rlev1_signed(values: List[Int64]) -> List[UInt8]:
    """One RLEv1 literal run (header -n, 1 <= n <= 128), each value a zigzag
    base-128 varint, least significant group first."""
    var out = List[UInt8]()
    out.append(UInt8(256 - len(values)))
    for i in range(len(values)):
        var u = _zigzag(values[i])
        while u >= 0x80:
            out.append(UInt8((u & 0x7F) | 0x80))
            u >>= 7
        out.append(UInt8(u))
    return out^


def _present(spec: String) -> List[UInt8]:
    """A PRESENT stream for 'v'/'n' flags (n <= 8): a one-byte boolean-RLE
    literal, most significant bit first."""
    var byte = 0
    var k = 0
    for b in spec.as_bytes():
        byte |= (1 if b == UInt8(ord("v")) else 0) << (7 - k)
        k += 1
    return _bytes(0xFF, byte)


def _f32_le(*vals: Float32) -> List[UInt8]:
    from std.memory import bitcast

    var out = List[UInt8]()
    for i in range(len(vals)):
        var u = bitcast[DType.uint32, 1](vals[i])
        for k in range(4):
            out.append(UInt8((u >> UInt32(8 * k)) & 0xFF))
    return out^


def _f64_le(*vals: Float64) -> List[UInt8]:
    from std.memory import bitcast

    var out = List[UInt8]()
    for i in range(len(vals)):
        var u = bitcast[DType.uint64, 1](vals[i])
        for k in range(8):
            out.append(UInt8((u >> UInt64(8 * k)) & 0xFF))
    return out^


def _streams(
    present: String, var data: List[UInt8], var length: List[UInt8]
) -> List[StreamSpan]:
    """PRESENT (when `present` is not empty), DATA, and LENGTH (when not
    empty)."""
    var out = List[StreamSpan]()
    if present != "":
        out.append(StreamSpan(ORC_STREAM_PRESENT, _present(present)))
    out.append(StreamSpan(ORC_STREAM_DATA, data^))
    if len(length) > 0:
        out.append(StreamSpan(ORC_STREAM_LENGTH, length^))
    return out^


def _nulls(n: Int, col: Column[HeapRegion]) -> String:
    var s = String()
    for i in range(n):
        s += "n" if col.is_null_at(i) else "v"
    return s^


# =============================================================================
# 1. A no-PRESENT stripe between two null-bearing stripes.
# =============================================================================
#
# Stripe 1: PRESENT "nv", one value. Stripe 2: no PRESENT, two values.
# Stripe 3: PRESENT "nv", one value. Six rows, nulls at 0 and 4.


def _three_stripes(
    kind: Int,
    at: ArrowType,
    reserve: Int,
    var d1: List[UInt8],
    var d2: List[UInt8],
    var d3: List[UInt8],
    var l1: List[UInt8],
    var l2: List[UInt8],
    var l3: List[UInt8],
) raises -> Column[HeapRegion]:
    var acc = make_accumulator(kind, at)
    if reserve > 0:
        acc.reserve(reserve)
    var e = ORC_ENCODING_DIRECT_V2
    decode_stripe_column(acc, kind, e, 0, _streams("nv", d1^, l1^), 2)
    decode_stripe_column(acc, kind, e, 0, _streams("", d2^, l2^), 2)
    decode_stripe_column(acc, kind, e, 0, _streams("nv", d3^, l3^), 2)
    var col = acc^.build()
    assert_equal(_nulls(6, col), "nvvvnv")
    assert_equal(col.null_count(), 2)
    return col^


def _ints(
    kind: Int, at: ArrowType, reserve: Int
) raises -> Column[HeapRegion]:
    """Values 7 | 8, 9 | 10 as signed RLEv2 Direct at 5 bits."""
    return _three_stripes(
        kind, at, reserve,
        _rlev2_direct(_i64s(7), 5, True),
        _rlev2_direct(_i64s(8, 9), 5, True),
        _rlev2_direct(_i64s(10), 5, True),
        List[UInt8](), List[UInt8](), List[UInt8](),
    )


def test_int_long_short_date_no_present_after_nulls() raises:
    # The issue's probe: INT gave "nvnvvv" (stripe 3's flags on rows 2-3).
    var i = _ints(ORC_KIND_INT, ArrowType.INT32, 0).as_primitive[DType.int32]()
    assert_equal(Int(i.get(1)), 7)
    assert_equal(Int(i.get(2)), 8)
    assert_equal(Int(i.get(3)), 9)
    assert_equal(Int(i.get(5)), 10)
    var d = _ints(ORC_KIND_DATE, ArrowType.DATE32, 0)
    assert_equal(Int(d.as_primitive[DType.int32]().get(3)), 9)
    var s = _ints(ORC_KIND_SHORT, ArrowType.INT16, 0)
    assert_equal(Int(s.as_primitive[DType.int16]().get(5)), 10)
    # LONG with and without reserve(): the reserved column starts on the
    # zero-copy buffer and leaves it at stripe 1's null.
    for r in range(2):
        var l = _ints(ORC_KIND_LONG, ArrowType.INT64, 6 * r)
        var la = l.as_primitive[DType.int64]()
        assert_equal(Int(la.get(2)), 8)
        assert_equal(Int(la.get(5)), 10)


def test_boolean_no_present_after_nulls() raises:
    # Before the fix the build indexed `present` past its end (abort).
    # Boolean RLE [0xff, 0x80]: true, then false.
    var col = _three_stripes(
        ORC_KIND_BOOLEAN, ArrowType.BOOL, 0,
        _bytes(0xFF, 0x80), _bytes(0xFF, 0x80), _bytes(0xFF, 0x80),
        List[UInt8](), List[UInt8](), List[UInt8](),
    )
    var b = col.as_boolean()
    assert_true(b.get(1))
    assert_true(b.get(2))
    assert_false(b.get(3))
    assert_true(b.get(5))


def test_byte_no_present_after_nulls() raises:
    # Byte RLE literals: [0xff, 5], [0xfe, 6, 0xf9], [0xff, 8].
    var col = _three_stripes(
        ORC_KIND_BYTE, ArrowType.INT8, 0,
        _bytes(0xFF, 5), _bytes(0xFE, 6, 0xF9), _bytes(0xFF, 8),
        List[UInt8](), List[UInt8](), List[UInt8](),
    )
    var a = col.as_primitive[DType.int8]()
    assert_equal(Int(a.get(1)), 5)
    assert_equal(Int(a.get(3)), -7)
    assert_equal(Int(a.get(5)), 8)


def test_float_double_no_present_after_nulls() raises:
    var f = _three_stripes(
        ORC_KIND_FLOAT, ArrowType.FLOAT32, 0,
        _f32_le(1.5), _f32_le(2.5, -3.5), _f32_le(4.25),
        List[UInt8](), List[UInt8](), List[UInt8](),
    ).as_primitive[DType.float32]()
    assert_equal(f.get(1), Float32(1.5))
    assert_equal(f.get(3), Float32(-3.5))
    assert_equal(f.get(5), Float32(4.25))
    var d = _three_stripes(
        ORC_KIND_DOUBLE, ArrowType.FLOAT64, 0,
        _f64_le(1.5), _f64_le(2.5, -3.5), _f64_le(4.25),
        List[UInt8](), List[UInt8](), List[UInt8](),
    ).as_primitive[DType.float64]()
    assert_equal(d.get(2), Float64(2.5))
    assert_equal(d.get(5), Float64(4.25))


def test_binary_and_string_no_present_after_nulls() raises:
    # BINARY: before the fix the validity bitmap had 4 bits for 6 values.
    # STRING keeps validity in its builder; it is pinned here alongside.
    for kind in [ORC_KIND_BINARY, ORC_KIND_STRING]:
        var at = ArrowType.BINARY if kind == ORC_KIND_BINARY else ArrowType.STRING
        var col = _three_stripes(
            kind, at, 0,
            _bytes(0x61), _bytes(0x62, 0x63, 0x63), _bytes(0x64, 0x64),
            _rlev2_direct(_i64s(1), 2, False),
            _rlev2_direct(_i64s(1, 2), 2, False),
            _rlev2_direct(_i64s(2), 2, False),
        )
        if kind == ORC_KIND_BINARY:
            var b = col.as_binary()
            assert_equal(b.get_length(3), 2)
            assert_equal(b.get_length(5), 2)
            assert_equal(Int(b.get(5)[0]), 0x64)
        else:
            var s = col.as_string()
            assert_equal(s.get(1), "a")
            assert_equal(s.get(3), "cc")
            assert_equal(s.get(5), "dd")


def _nullable_batch() raises -> RecordBatch:
    """Six rows: `k` = row index (never null); `b`, `i`, `l` with nulls at
    rows 0 and 4, so with two-row stripes the middle stripe has none."""
    var n = 6
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.BOOL, True))
    sb.add_field(Field("i", ArrowType.INT32, True))
    sb.add_field(Field("l", ArrowType.INT64, True))
    var k = PrimitiveArray[DType.int64].allocate(n)
    var b = BooleanArray.allocate_nullable(n)
    var i = PrimitiveArray[DType.int32].allocate_nullable(n)
    var l = PrimitiveArray[DType.int64].allocate_nullable(n)
    for r in range(n):
        k.set(r, Int64(r))
        if r == 0 or r == 4:
            b._set_null(r)
            i._set_null(r)
            l._set_null(r)
        else:
            b.set(r, r % 2 == 1)
            i.set(r, Int32(100 + r))
            l.set(r, Int64(-1000 - r))
    i.null_count = 2
    l.null_count = 2
    var builder = RecordBatchBuilder.with_capacity(4)
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](k^, ArrowType.INT64)
    )
    builder.add_column(Column.from_boolean(b^))
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](i^, ArrowType.INT32)
    )
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](l^, ArrowType.INT64)
    )
    return builder.build(sb.build())


def _check_nullable_batch(back: RecordBatch, label: String) raises:
    assert_equal(back.num_rows(), 6, label + ": 6 rows")
    for c in range(1, 4):
        assert_equal(_nulls(6, back.column_at(c)), "nvvvnv", label + ": col " + String(c))
    var b = back.column_as_boolean(1)
    var i = back.column_as_primitive_int32(2)
    var l = back.column_as_primitive_int64(3)
    for r in [1, 2, 3, 5]:
        assert_equal(b.get(r), r % 2 == 1, label + ": b row " + String(r))
        assert_equal(Int(i.get(r)), 100 + r, label + ": i row " + String(r))
        assert_equal(Int(l.get(r)), -1000 - r, label + ": l row " + String(r))


def test_writer_omits_present_middle_stripe_read_back() raises:
    # This package's writer emits PRESENT only for a stripe with a null
    # (stripe_emit.mojo), so a two-row stripe layout gives the issue's shape.
    var bytes = write_orc_bytes(
        _nullable_batch(), OrcWriterOptions(ORC_COMPRESSION_NONE, 2, String("UTC"))
    )
    assert_equal(OrcFileTail.parse(Span(bytes)).num_stripes(), 3)
    _check_nullable_batch(read_orc_bytes(Span(bytes)), "read_orc_bytes")
    # The stripe-pruning reader with a predicate every stripe satisfies.
    var pred = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_GE, Expr.col_ref("k"), Expr.literal(ScalarValue.from_int64(0))),
        Expr.binary(BIN_LT, Expr.col_ref("k"), Expr.literal(ScalarValue.from_int64(100))),
    )
    var res = read_orc_bytes_pruned(Span(bytes), pred, List[Int]())
    assert_equal(res.stripes_skipped, 0)
    _check_nullable_batch(res.batch, "read_orc_bytes_pruned")


# =============================================================================
# 2. Integer values wider than the column.
# =============================================================================


def _decode_ints(
    kind: Int, at: ArrowType, values: List[Int64], present: String
) raises -> Column[HeapRegion]:
    """RLEv1 (DIRECT) values, with a PRESENT stream when `present` is set."""
    var acc = make_accumulator(kind, at)
    var n = present.byte_length() if present != "" else len(values)
    decode_stripe_column(
        acc, kind, ORC_ENCODING_DIRECT, 0,
        _streams(present, _rlev1_signed(values), List[UInt8]()), n,
    )
    return acc^.build()


def test_width_edges_decode() raises:
    var s = _decode_ints(
        ORC_KIND_SHORT, ArrowType.INT16, _i64s(32767, -32768), ""
    ).as_primitive[DType.int16]()
    assert_equal(Int(s.get(0)), 32767)
    assert_equal(Int(s.get(1)), -32768)
    for kind in [ORC_KIND_INT, ORC_KIND_DATE]:
        var at = ArrowType.INT32 if kind == ORC_KIND_INT else ArrowType.DATE32
        var i = _decode_ints(
            kind, at, _i64s(2147483647, -2147483648), ""
        ).as_primitive[DType.int32]()
        assert_equal(Int(i.get(0)), 2147483647)
        assert_equal(Int(i.get(1)), -2147483648)


def test_short_out_of_width_refused_in_chunk_and_tail() raises:
    # Nine values: rows 0..7 fill whole SIMD chunks at every width this runs
    # on (2, 4 or 8 lanes of int64) and row 8 is in the scalar tail.
    for bad_row in [0, 5, 8]:
        var vals = List[Int64]()
        for r in range(9):
            vals.append(Int64(r))
        vals[bad_row] = Int64(32768)
        if bad_row == 5:
            vals[6] = Int64(-32769)  # two in one chunk: the first is named
        with assert_raises(
            contains="VALUE_OUT_OF_RANGE: row " + String(bad_row) + " holds 32768"
        ):
            _ = _decode_ints(ORC_KIND_SHORT, ArrowType.INT16, vals, "")


def test_int_and_date_out_of_width_refused_both_paths() raises:
    # Without the check the int32 cast kept the low 32 bits (2^31 -> -2^31).
    for kind in [ORC_KIND_INT, ORC_KIND_DATE]:
        var at = ArrowType.INT32 if kind == ORC_KIND_INT else ArrowType.DATE32
        with assert_raises(contains="row 1 holds 2147483648, which does not fit"):
            _ = _decode_ints(kind, at, _i64s(1, 2147483648), "")
        # PRESENT "nvv": the null takes row 0, so the value is on row 2.
        with assert_raises(contains="row 2 holds -2147483649"):
            _ = _decode_ints(kind, at, _i64s(1, -2147483649), "nvv")


# =============================================================================
# 3. Dictionary encodings on kinds that cannot carry one.
# =============================================================================


def test_dictionary_encoding_refused_on_non_string_kinds() raises:
    # BINARY with DICTIONARY used to be read as DIRECT.
    var kinds: List[Int] = [
        ORC_KIND_BOOLEAN, ORC_KIND_BYTE, ORC_KIND_SHORT, ORC_KIND_INT,
        ORC_KIND_LONG, ORC_KIND_DATE, ORC_KIND_FLOAT, ORC_KIND_DOUBLE,
        ORC_KIND_BINARY,
    ]
    for ki in range(len(kinds)):
        for enc in [ORC_ENCODING_DICTIONARY, ORC_ENCODING_DICTIONARY_V2]:
            var acc = make_accumulator(kinds[ki], ArrowType.INT64)
            with assert_raises(contains="BAD_ENCODING: ORC Type.Kind"):
                decode_stripe_column(
                    acc, kinds[ki], enc, 1,
                    _streams("", _bytes(0xFF, 0x01), _bytes(0x00, 0x00, 0x01)),
                    1,
                )
    var acc = make_accumulator(ORC_KIND_BINARY, ArrowType.BINARY)
    with assert_raises(contains="binary has a DICTIONARY encoding (1)"):
        decode_stripe_column(
            acc, ORC_KIND_BINARY, ORC_ENCODING_DICTIONARY, 1,
            _streams("", _bytes(0x61), _rlev2_direct(_i64s(1), 1, False)), 1,
        )


def _dict_streams(present: String, is_v2: Bool) -> List[StreamSpan]:
    """Dictionary ["blue", "red"]: DICTIONARY_DATA "bluered", LENGTH [4, 3],
    DATA indices [1, 0, 1] (one per present row), RLEv2 Direct for
    DICTIONARY_V2 and an RLEv1 literal for DICTIONARY."""
    var out = List[StreamSpan]()
    if present != "":
        out.append(StreamSpan(ORC_STREAM_PRESENT, _present(present)))
    out.append(
        StreamSpan(
            ORC_STREAM_DICTIONARY_DATA,
            _bytes(0x62, 0x6C, 0x75, 0x65, 0x72, 0x65, 0x64),
        )
    )
    if is_v2:
        out.append(StreamSpan(ORC_STREAM_LENGTH, _rlev2_direct(_i64s(4, 3), 4, False)))
        out.append(StreamSpan(ORC_STREAM_DATA, _rlev2_direct(_i64s(1, 0, 1), 1, False)))
    else:
        out.append(StreamSpan(ORC_STREAM_LENGTH, _bytes(0xFE, 4, 3)))
        out.append(StreamSpan(ORC_STREAM_DATA, _bytes(0xFD, 1, 0, 1)))
    return out^


def test_dictionary_encoding_decodes_on_string_kinds() raises:
    # The allow-list's other side: Apache ORC writers dictionary-encode
    # STRING, VARCHAR and CHAR, so each must still decode, on the PRESENT
    # path ("vnvv") and the no-PRESENT path.
    for kind in [ORC_KIND_STRING, ORC_KIND_VARCHAR, ORC_KIND_CHAR]:
        for enc in [ORC_ENCODING_DICTIONARY, ORC_ENCODING_DICTIONARY_V2]:
            var is_v2 = enc == ORC_ENCODING_DICTIONARY_V2
            var label = String("kind ") + String(kind) + " enc " + String(enc)
            var acc = make_accumulator(kind, ArrowType.STRING)
            decode_stripe_column(acc, kind, enc, 2, _dict_streams("", is_v2), 3)
            decode_stripe_column(acc, kind, enc, 2, _dict_streams("vnvv", is_v2), 4)
            var col = acc^.build()
            assert_equal(_nulls(7, col), "vvvvnvv", label)
            var s = col.as_string()
            assert_equal(s.get(0), "red", label)
            assert_equal(s.get(1), "blue", label)
            assert_equal(s.get(2), "red", label)
            assert_equal(s.get(3), "red", label)
            assert_equal(s.get(5), "blue", label)
            assert_equal(s.get(6), "red", label)


# =============================================================================
# 4. The build's validity-length check.
# =============================================================================


def test_build_refuses_validity_shorter_than_rows() raises:
    var acc = make_accumulator(ORC_KIND_INT, ArrowType.INT32)
    acc.i64s.append(Int64(1))
    acc.i64s.append(Int64(2))
    acc.n_rows = 2
    acc.has_any_nulls = True
    acc.present.append(False)
    with assert_raises(contains="INTERNAL: the column has 2 rows but 1 validity flags"):
        _ = acc^.build()


def main() raises:
    test_int_long_short_date_no_present_after_nulls()
    test_byte_no_present_after_nulls()
    test_float_double_no_present_after_nulls()
    test_binary_and_string_no_present_after_nulls()
    test_writer_omits_present_middle_stripe_read_back()
    test_boolean_no_present_after_nulls()
    test_width_edges_decode()
    test_short_out_of_width_refused_in_chunk_and_tail()
    test_int_and_date_out_of_width_refused_both_paths()
    test_dictionary_encoding_refused_on_non_string_kinds()
    test_dictionary_encoding_decodes_on_string_kinds()
    test_build_refuses_validity_shorter_than_rows()
    print("test_orc_stripe_validity_and_width: ALL PASS")
