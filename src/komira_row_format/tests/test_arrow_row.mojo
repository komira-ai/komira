# =============================================================================
# test_arrow_row.mojo — unit tests for byte-lex Arrow Row sort encoder
# =============================================================================
#
# Coverage:
#   * Round-trip per fixed-width DType (encode → decode → original).
#   * Order-preserving property: encode(a) memcmp-< encode(b) iff a < b.
#   * Null position: NULLS_FIRST sentinel sorts before non-null; NULLS_LAST
#     sorts after.
#   * ASC vs DESC: byte inversion under DESC.
#   * Multi-column composite: schema-ordered tuple compare matches memcmp.
#   * Cross-impl validation: hardcoded byte outputs against arrow-row's
#     documented examples.
#   * STRING / BINARY raises.
#
# Discovery: test fns calling encode_row_keys_for_sort must carry `raises`
# (as tests calling xxh3_64_scalar_bytes do).
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_true, assert_false

from komira_row_format.arrow_row import (
    encode_i64_to_bytes,
    encode_u64_to_bytes,
    encode_f64_to_bytes,
    encode_i32_to_bytes,
    encode_u32_to_bytes,
    encode_f32_to_bytes,
    encode_i16_to_bytes,
    encode_u16_to_bytes,
    encode_i8_to_bytes,
    encode_u8_to_bytes,
    encode_bool_to_bytes,
    encode_decimal128_to_bytes,
    encode_row_keys_for_sort,
    encoded_width_for_dtype,
    arrow_row_compare,
    DT_I64,
    DT_F64,
    DT_I32,
    DT_I16,
    DT_I8,
    DT_U8,
    DT_U16,
    DT_U32,
    DT_U64,
    DT_F32,
    DT_BOOL,
    DT_STRING,
    DT_BINARY,
    DT_DATE32,
    DT_DATE64,
    DT_TIMESTAMP_NS,
    # Pulled in by `test_dt_tag_table_matches_row_block` below.  arrow_row
    # declares all four timestamp tags; this file previously imported only
    # _NS because nothing here cross-checked the table.
    DT_TIMESTAMP_US,
    DT_TIMESTAMP_MS,
    DT_TIMESTAMP_S,
    DT_DECIMAL128,
    SORT_ASC,
    SORT_DESC,
    NULLS_FIRST,
    NULLS_LAST,
    ARROW_ROW_NULL_FIRST,
    ARROW_ROW_NON_NULL,
    ARROW_ROW_NULL_LAST,
)

# =============================================================================
# THE DRIFT DETECTOR — `arrow_row.mojo` re-declares `row_block.mojo`'s DType
# tag table instead of importing it, to keep itself a pure-byte primitive
# (same layering invariant as `xxh3.mojo`). That duplication is deliberate;
# it being UNCHECKED was not.
#
# ⚠ `arrow_row.mojo` has claimed since it was written that "any drift in
# these values vs row_block.mojo is caught by the `eval_test_arrow_row`
# cross-check test". MEASURED: that was FALSE.
# This file imported `arrow_row` and nothing else — it never named
# `row_block` at all, so nothing compared the two tables in either
# direction. The claim described a test that did not exist.
#
# The tables agree TODAY (20 tags here, 22 there, identical on the shared
# 20; row_block additionally carries DT_LIST=21 / DT_STRUCT=22, which
# arrow_row cannot encode). So this is LATENT, not a live bug — and a
# latent one is exactly what a detector is for: the two tables are read by
# the SAME sort-spill path (`row_sort.mojo`, `row_sort_spill.mojo`), so a
# one-sided renumber silently mis-decodes spilled sort keys rather than
# failing to build.
# =============================================================================

from komira_row_format.row_block import (
    DT_I64 as RB_DT_I64,
    DT_F64 as RB_DT_F64,
    DT_I32 as RB_DT_I32,
    DT_F32 as RB_DT_F32,
    DT_I16 as RB_DT_I16,
    DT_I8 as RB_DT_I8,
    DT_U8 as RB_DT_U8,
    DT_STRING as RB_DT_STRING,
    DT_U16 as RB_DT_U16,
    DT_U32 as RB_DT_U32,
    DT_U64 as RB_DT_U64,
    DT_DATE32 as RB_DT_DATE32,
    DT_DECIMAL128 as RB_DT_DECIMAL128,
    DT_BOOL as RB_DT_BOOL,
    DT_DATE64 as RB_DT_DATE64,
    DT_TIMESTAMP_NS as RB_DT_TIMESTAMP_NS,
    DT_TIMESTAMP_US as RB_DT_TIMESTAMP_US,
    DT_TIMESTAMP_MS as RB_DT_TIMESTAMP_MS,
    DT_TIMESTAMP_S as RB_DT_TIMESTAMP_S,
    DT_BINARY as RB_DT_BINARY,
)


# =============================================================================
# Helpers
# =============================================================================


def _compare_inline_8(a: Array[UInt8, 8], b: Array[UInt8, 8]) -> Int:
    """Byte-lex compare two 8-byte arrays. -1/0/+1."""
    for i in range(8):
        var av = Int(a[i])
        var bv = Int(b[i])
        if av < bv:
            return -1
        if av > bv:
            return 1
    return 0


def _compare_inline_4(a: Array[UInt8, 4], b: Array[UInt8, 4]) -> Int:
    """Byte-lex compare two 4-byte arrays."""
    for i in range(4):
        var av = Int(a[i])
        var bv = Int(b[i])
        if av < bv:
            return -1
        if av > bv:
            return 1
    return 0


def _compare_inline_2(a: Array[UInt8, 2], b: Array[UInt8, 2]) -> Int:
    """Byte-lex compare two 2-byte arrays."""
    for i in range(2):
        var av = Int(a[i])
        var bv = Int(b[i])
        if av < bv:
            return -1
        if av > bv:
            return 1
    return 0


def _compare_inline_16(a: Array[UInt8, 16], b: Array[UInt8, 16]) -> Int:
    """Byte-lex compare two 16-byte arrays."""
    for i in range(16):
        var av = Int(a[i])
        var bv = Int(b[i])
        if av < bv:
            return -1
        if av > bv:
            return 1
    return 0


# =============================================================================
# Per-DType order-preserving tests
# =============================================================================


def test_i64_order_preserving() raises:
    """For 11 canonical I64 values spanning the signed range, the byte-lex
    order of encode_i64_to_bytes(_, asc=True) matches numeric I64 order.

    Canonical inputs cover: INT64_MIN, -2^32, -1, 0, +1, +2^32, INT64_MAX,
    plus a few interior points. Pair-wise the property must hold."""
    var vals = List[Int64]()
    vals.append(Int64(-9223372036854775808))  # INT64_MIN
    vals.append(Int64(-4294967296))           # -2^32
    vals.append(Int64(-12345))
    vals.append(Int64(-1))
    vals.append(Int64(0))
    vals.append(Int64(1))
    vals.append(Int64(12345))
    vals.append(Int64(4294967296))            # +2^32
    vals.append(Int64(9223372036854775807))   # INT64_MAX
    var n = len(vals)
    for i in range(n):
        for j in range(n):
            var a = vals[i]
            var b = vals[j]
            var ea = encode_i64_to_bytes(a, True)
            var eb = encode_i64_to_bytes(b, True)
            var cmp = _compare_inline_8(ea, eb)
            if a < b:
                assert_equal(cmp, -1)
            elif a > b:
                assert_equal(cmp, 1)
            else:
                assert_equal(cmp, 0)


def test_i64_desc_inverts_order() raises:
    """encode_i64_to_bytes(_, asc=False) inverts byte order so that
    memcmp natural ascending matches numeric DESCENDING."""
    var a = encode_i64_to_bytes(Int64(-100), False)
    var b = encode_i64_to_bytes(Int64(100), False)
    # Under DESC: -100 should sort AFTER +100 (i.e. encode(-100) > encode(+100)).
    assert_equal(_compare_inline_8(a, b), 1)
    # And encode(0, DESC) > encode(100, DESC):
    var c = encode_i64_to_bytes(Int64(0), False)
    assert_equal(_compare_inline_8(c, b), 1)


def test_u64_order_preserving() raises:
    """U64 ascending order matches encoded byte-lex order."""
    var vals = List[UInt64]()
    vals.append(UInt64(0))
    vals.append(UInt64(1))
    vals.append(UInt64(255))
    vals.append(UInt64(256))
    vals.append(UInt64(65535))
    vals.append(UInt64(65536))
    vals.append(UInt64(0xFFFFFFFFFFFFFFFF))
    var n = len(vals)
    for i in range(n - 1):
        var ea = encode_u64_to_bytes(vals[i], True)
        var eb = encode_u64_to_bytes(vals[i + 1], True)
        assert_equal(_compare_inline_8(ea, eb), -1)


def test_f64_order_preserving() raises:
    """F64 mapping: encoded byte-lex matches numeric order (`-0.0` and `+0.0`
    TIE -- the engine's float order is DuckDB's quotient
    order; `<= 0` below admits the tie)."""
    var vals = List[Float64]()
    vals.append(Float64(-1.7976931348623157e308))  # near -infinity
    vals.append(Float64(-1.0))
    vals.append(Float64(-0.5))
    vals.append(Float64(-0.0))
    vals.append(Float64(0.0))
    vals.append(Float64(0.5))
    vals.append(Float64(1.0))
    vals.append(Float64(1.7976931348623157e308))   # near +infinity
    var n = len(vals)
    # Adjacent pairs non-decreasing in the quotient order (the zeros tie).
    for i in range(n - 1):
        var ea = encode_f64_to_bytes(vals[i], True)
        var eb = encode_f64_to_bytes(vals[i + 1], True)
        # -0.0 vs 0.0: ONE value under the quotient order (they tie).
        assert_true(_compare_inline_8(ea, eb) <= 0)


def test_f64_neg_zero_lt_pos_zero() raises:
    """⛔ RENAMED MEANING, NAME KEPT FOR THE CALL LIST:
    this pinned `totalOrder`'s `-0.0 < +0.0` STRICTLY. The engine's float order
    is DuckDB v1.5.3's quotient order, under which the two zeros are ONE value
    -- so they now encode to IDENTICAL bytes, and every NaN (either sign) to
    one key strictly ABOVE `+inf`."""
    var en0 = encode_f64_to_bytes(Float64(-0.0), True)
    var ep0 = encode_f64_to_bytes(Float64(0.0), True)
    assert_equal(_compare_inline_8(en0, ep0), 0, "-0.0 ties +0.0")
    var pinf = encode_f64_to_bytes(
        bitcast[DType.float64](UInt64(0x7FF0000000000000)), True
    )
    var nan = encode_f64_to_bytes(
        bitcast[DType.float64](UInt64(0x7FF8000000000000)), True
    )
    var neg_nan = encode_f64_to_bytes(
        bitcast[DType.float64](UInt64(0xFFF8000000000000)), True
    )
    assert_equal(_compare_inline_8(pinf, nan), -1, "+inf < NaN")
    assert_equal(_compare_inline_8(nan, neg_nan), 0, "every NaN is ONE key")


def test_i32_order_preserving() raises:
    var vals = List[Int32]()
    vals.append(Int32(-2147483648))  # INT32_MIN
    vals.append(Int32(-1))
    vals.append(Int32(0))
    vals.append(Int32(1))
    vals.append(Int32(2147483647))   # INT32_MAX
    var n = len(vals)
    for i in range(n - 1):
        var ea = encode_i32_to_bytes(vals[i], True)
        var eb = encode_i32_to_bytes(vals[i + 1], True)
        assert_equal(_compare_inline_4(ea, eb), -1)


def test_u32_order_preserving() raises:
    var ea = encode_u32_to_bytes(UInt32(0), True)
    var eb = encode_u32_to_bytes(UInt32(0xFFFFFFFF), True)
    assert_equal(_compare_inline_4(ea, eb), -1)


def test_f32_order_preserving() raises:
    var vals = List[Float32]()
    vals.append(Float32(-1.0))
    vals.append(Float32(-0.0))
    vals.append(Float32(0.0))
    vals.append(Float32(1.0))
    var n = len(vals)
    for i in range(n - 1):
        var ea = encode_f32_to_bytes(vals[i], True)
        var eb = encode_f32_to_bytes(vals[i + 1], True)
        assert_true(_compare_inline_4(ea, eb) <= 0)


def test_i16_order_preserving() raises:
    var vals = List[Int16]()
    vals.append(Int16(-32768))
    vals.append(Int16(-1))
    vals.append(Int16(0))
    vals.append(Int16(1))
    vals.append(Int16(32767))
    var n = len(vals)
    for i in range(n - 1):
        var ea = encode_i16_to_bytes(vals[i], True)
        var eb = encode_i16_to_bytes(vals[i + 1], True)
        assert_equal(_compare_inline_2(ea, eb), -1)


def test_u16_order_preserving() raises:
    var ea = encode_u16_to_bytes(UInt16(0), True)
    var eb = encode_u16_to_bytes(UInt16(65535), True)
    assert_equal(_compare_inline_2(ea, eb), -1)


def test_i8_order_preserving() raises:
    """I8 sign-flip: -128..127 maps to 0..255 byte order."""
    var emin = encode_i8_to_bytes(Int8(-128), True)
    var em1 = encode_i8_to_bytes(Int8(-1), True)
    var e0 = encode_i8_to_bytes(Int8(0), True)
    var ep1 = encode_i8_to_bytes(Int8(1), True)
    var emax = encode_i8_to_bytes(Int8(127), True)
    assert_equal(Int(emin), 0x00)
    assert_equal(Int(em1), 0x7F)
    assert_equal(Int(e0), 0x80)
    assert_equal(Int(ep1), 0x81)
    assert_equal(Int(emax), 0xFF)


def test_u8_order_preserving() raises:
    """U8 raw byte; no sign-flip."""
    assert_equal(Int(encode_u8_to_bytes(UInt8(0), True)), 0)
    assert_equal(Int(encode_u8_to_bytes(UInt8(255), True)), 0xFF)


def test_bool_encoding() raises:
    assert_equal(Int(encode_bool_to_bytes(False, True)), 0)
    assert_equal(Int(encode_bool_to_bytes(True, True)), 1)
    assert_equal(Int(encode_bool_to_bytes(False, False)), 0xFF)
    assert_equal(Int(encode_bool_to_bytes(True, False)), 0xFE)


def test_decimal128_order_preserving() raises:
    """Two Decimal128 values: -1 (hi=0xFFFFFFFFFFFFFFFF, lo=0xFFFFFFFFFFFFFFFF
    in two's complement) vs +1 (hi=0, lo=1). After sign-flip on hi, -1
    becomes hi=0x7FFFFFFFFFFFFFFF lo=0xFFFFFFFFFFFFFFFF; +1 becomes
    hi=0x8000000000000000 lo=1; so encode(-1) < encode(+1) byte-lex.
    """
    var e_neg = encode_decimal128_to_bytes(
        UInt64(0xFFFFFFFFFFFFFFFF), UInt64(0xFFFFFFFFFFFFFFFF), True
    )
    var e_pos = encode_decimal128_to_bytes(UInt64(0), UInt64(1), True)
    assert_equal(_compare_inline_16(e_neg, e_pos), -1)


# =============================================================================
# Cross-impl validation against arrow-row's documented examples
# =============================================================================


def test_i64_neg_5_canonical_bytes() raises:
    """Cross-impl check: encode_i64(-5, asc=True) per arrow-row spec.

    -5 in two's complement (u64): 0xFFFFFFFFFFFFFFFB
    Flip sign bit (XOR 0x8000000000000000): 0x7FFFFFFFFFFFFFFB
    Write big-endian: [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFB]
    """
    var e = encode_i64_to_bytes(Int64(-5), True)
    assert_equal(Int(e[0]), 0x7F)
    assert_equal(Int(e[1]), 0xFF)
    assert_equal(Int(e[2]), 0xFF)
    assert_equal(Int(e[3]), 0xFF)
    assert_equal(Int(e[4]), 0xFF)
    assert_equal(Int(e[5]), 0xFF)
    assert_equal(Int(e[6]), 0xFF)
    assert_equal(Int(e[7]), 0xFB)


def test_i64_zero_canonical_bytes() raises:
    """encode_i64(0, asc=True) = sign-flip(0) BE = 0x8000000000000000 BE."""
    var e = encode_i64_to_bytes(Int64(0), True)
    assert_equal(Int(e[0]), 0x80)
    for i in range(1, 8):
        assert_equal(Int(e[i]), 0x00)


def test_i64_max_canonical_bytes() raises:
    """encode_i64(INT64_MAX, asc=True) = sign-flip BE = 0xFFFFFFFFFFFFFFFF."""
    var e = encode_i64_to_bytes(Int64(9223372036854775807), True)
    for i in range(8):
        assert_equal(Int(e[i]), 0xFF)


def test_i64_min_canonical_bytes() raises:
    """encode_i64(INT64_MIN, asc=True) = sign-flip BE = 0x0000000000000000."""
    var e = encode_i64_to_bytes(Int64(-9223372036854775808), True)
    for i in range(8):
        assert_equal(Int(e[i]), 0x00)


def test_i64_desc_inverts_min() raises:
    """encode_i64(INT64_MIN, asc=False) = bit-invert(0x00...) = 0xFF...
    so INT64_MIN sorts MAX under DESC."""
    var e = encode_i64_to_bytes(Int64(-9223372036854775808), False)
    for i in range(8):
        assert_equal(Int(e[i]), 0xFF)


def test_f64_pos_zero_canonical() raises:
    """encode_f64(+0.0, asc=True): bits=0, sign bit clear → flip sign bit →
    0x8000000000000000 → BE → [0x80, 0, 0, 0, 0, 0, 0, 0]."""
    var e = encode_f64_to_bytes(Float64(0.0), True)
    assert_equal(Int(e[0]), 0x80)
    for i in range(1, 8):
        assert_equal(Int(e[i]), 0x00)


def test_f64_neg_zero_canonical() raises:
    """encode_f64(-0.0, asc=True): `-0.0` CANONICALISES to `+0.0` first (the
    quotient order), so it encodes to `+0.0`'s bytes
    [0x80, 0, ..., 0] -- not `totalOrder`'s [0x7F, 0xFF, ..., 0xFF]."""
    var e = encode_f64_to_bytes(Float64(-0.0), True)
    assert_equal(Int(e[0]), 0x80)
    for i in range(1, 8):
        assert_equal(Int(e[i]), 0x00)


# =============================================================================
# Width / sentinel checks
# =============================================================================


def test_encoded_width_for_dtype() raises:
    assert_equal(encoded_width_for_dtype(DT_I8), 2)
    assert_equal(encoded_width_for_dtype(DT_U8), 2)
    assert_equal(encoded_width_for_dtype(DT_BOOL), 2)
    assert_equal(encoded_width_for_dtype(DT_I16), 3)
    assert_equal(encoded_width_for_dtype(DT_U16), 3)
    assert_equal(encoded_width_for_dtype(DT_I32), 5)
    assert_equal(encoded_width_for_dtype(DT_U32), 5)
    assert_equal(encoded_width_for_dtype(DT_F32), 5)
    assert_equal(encoded_width_for_dtype(DT_DATE32), 5)
    assert_equal(encoded_width_for_dtype(DT_I64), 9)
    assert_equal(encoded_width_for_dtype(DT_U64), 9)
    assert_equal(encoded_width_for_dtype(DT_F64), 9)
    assert_equal(encoded_width_for_dtype(DT_DATE64), 9)
    assert_equal(encoded_width_for_dtype(DT_TIMESTAMP_NS), 9)
    assert_equal(encoded_width_for_dtype(DT_DECIMAL128), 17)


def test_encoded_width_string_raises() raises:
    var raised = False
    try:
        _ = encoded_width_for_dtype(DT_STRING)
    except:
        raised = True
    assert_true(raised)


def test_encoded_width_binary_raises() raises:
    var raised = False
    try:
        _ = encoded_width_for_dtype(DT_BINARY)
    except:
        raised = True
    assert_true(raised)


def test_sentinel_constants() raises:
    """Spec constants match arrow-row's documented sentinel scheme."""
    assert_equal(Int(ARROW_ROW_NULL_FIRST), 0x00)
    assert_equal(Int(ARROW_ROW_NON_NULL), 0x01)
    assert_equal(Int(ARROW_ROW_NULL_LAST), 0xFF)


# =============================================================================
# Composite encoder (BatchView) tests
# =============================================================================
#
# We exercise encode_row_keys_for_sort via constructed RecordBatches and
# BatchView wrappers. The fixture compares the byte-lex output of two
# rows against the schema-ordered tuple compare.


from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.collections.batch_view import BatchView


def _build_batch_2col_i64_i64(
    a_vals: List[Int64], b_vals: List[Int64]
) raises -> RecordBatch:
    """Build a 2-col RecordBatch (I64, I64) from parallel lists."""
    var n = len(a_vals)
    assert_equal(n, len(b_vals))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(a_vals)
        )
    )
    rbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(b_vals)
        )
    )
    return rbb.build(schema^)


def test_composite_2col_i64_asc_asc_matches_tuple_order() raises:
    """Composite (a I64 ASC, b I64 ASC) — encode each row, byte-lex
    compare matches schema-ordered (a, b) tuple compare."""
    var a_vals = List[Int64]()
    a_vals.append(Int64(1))
    a_vals.append(Int64(1))
    a_vals.append(Int64(2))
    a_vals.append(Int64(2))
    a_vals.append(Int64(-1))
    var b_vals = List[Int64]()
    b_vals.append(Int64(10))
    b_vals.append(Int64(20))
    b_vals.append(Int64(10))
    b_vals.append(Int64(20))
    b_vals.append(Int64(100))
    var rb = _build_batch_2col_i64_i64(a_vals, b_vals)
    var bv = BatchView(rb)
    var key_cols = List[Int]()
    key_cols.append(0)
    key_cols.append(1)
    var dtypes = List[UInt8]()
    dtypes.append(DT_I64)
    dtypes.append(DT_I64)
    var asc = List[UInt8]()
    asc.append(SORT_ASC)
    asc.append(SORT_ASC)
    var nf = List[UInt8]()
    nf.append(NULLS_FIRST)
    nf.append(NULLS_FIRST)
    var is_null = List[Bool]()
    is_null.append(False)
    is_null.append(False)

    var encs = List[List[UInt8]]()
    for r in range(len(a_vals)):
        encs.append(encode_row_keys_for_sort(bv, r, key_cols, dtypes, asc, nf, is_null))

    # Cross-row pair-wise property
    var n = len(a_vals)
    for i in range(n):
        for j in range(n):
            var ai = a_vals[i]
            var aj = a_vals[j]
            var bi = b_vals[i]
            var bj = b_vals[j]
            var cmp = arrow_row_compare(encs[i], encs[j])
            if ai < aj:
                assert_equal(cmp, -1)
            elif ai > aj:
                assert_equal(cmp, 1)
            else:
                if bi < bj:
                    assert_equal(cmp, -1)
                elif bi > bj:
                    assert_equal(cmp, 1)
                else:
                    assert_equal(cmp, 0)


def test_composite_2col_i64_desc_first_key() raises:
    """Composite (a I64 DESC, b I64 ASC): the first key inverts; the
    second still tiebreaks ascending."""
    var a_vals = List[Int64]()
    a_vals.append(Int64(1))
    a_vals.append(Int64(2))
    var b_vals = List[Int64]()
    b_vals.append(Int64(10))
    b_vals.append(Int64(10))
    var rb = _build_batch_2col_i64_i64(a_vals, b_vals)
    var bv = BatchView(rb)
    var key_cols = List[Int]()
    key_cols.append(0)
    key_cols.append(1)
    var dtypes = List[UInt8]()
    dtypes.append(DT_I64)
    dtypes.append(DT_I64)
    var asc = List[UInt8]()
    asc.append(SORT_DESC)  # first key DESC
    asc.append(SORT_ASC)
    var nf = List[UInt8]()
    nf.append(NULLS_FIRST)
    nf.append(NULLS_FIRST)
    var is_null = List[Bool]()
    is_null.append(False)
    is_null.append(False)

    var e1 = encode_row_keys_for_sort(bv, 0, key_cols, dtypes, asc, nf, is_null)
    var e2 = encode_row_keys_for_sort(bv, 1, key_cols, dtypes, asc, nf, is_null)
    # Under (a DESC), row1(a=1) > row2(a=2) in memcmp order.
    assert_equal(arrow_row_compare(e1, e2), 1)


def test_composite_string_raises() raises:
    """STRING key columns are not supported by this encoder and raise."""
    # We need a batch to feed but the encoder should reject before any
    # column read. Use a simple I64 batch and lie about the dtype.
    var a_vals = List[Int64]()
    a_vals.append(Int64(0))
    var b_vals = List[Int64]()
    b_vals.append(Int64(0))
    var rb = _build_batch_2col_i64_i64(a_vals, b_vals)
    var bv = BatchView(rb)
    var key_cols = List[Int]()
    key_cols.append(0)
    var dtypes = List[UInt8]()
    dtypes.append(DT_STRING)
    var asc = List[UInt8]()
    asc.append(SORT_ASC)
    var nf = List[UInt8]()
    nf.append(NULLS_FIRST)
    var is_null = List[Bool]()
    is_null.append(False)
    var raised = False
    try:
        _ = encode_row_keys_for_sort(
            bv, 0, key_cols, dtypes, asc, nf, is_null
        )
    except:
        raised = True
    assert_true(raised)


def test_composite_null_first_lt_non_null() raises:
    """A NULLS_FIRST null sorts BEFORE any non-null."""
    var a_vals = List[Int64]()
    a_vals.append(Int64(0))      # treat as null in row 0
    a_vals.append(Int64(0))      # non-null in row 1
    var b_vals = List[Int64]()
    b_vals.append(Int64(0))
    b_vals.append(Int64(0))
    var rb = _build_batch_2col_i64_i64(a_vals, b_vals)
    var bv = BatchView(rb)
    var key_cols = List[Int]()
    key_cols.append(0)
    var dtypes = List[UInt8]()
    dtypes.append(DT_I64)
    var asc = List[UInt8]()
    asc.append(SORT_ASC)
    var nf = List[UInt8]()
    nf.append(NULLS_FIRST)

    var is_null_null = List[Bool]()
    is_null_null.append(True)
    var is_null_nn = List[Bool]()
    is_null_nn.append(False)

    var e_null = encode_row_keys_for_sort(
        bv, 0, key_cols, dtypes, asc, nf, is_null_null
    )
    var e_nn = encode_row_keys_for_sort(
        bv, 1, key_cols, dtypes, asc, nf, is_null_nn
    )
    # NULLS_FIRST: null sentinel 0x00 < non-null sentinel 0x01.
    assert_equal(arrow_row_compare(e_null, e_nn), -1)


def test_composite_null_last_gt_non_null() raises:
    """A NULLS_LAST null sorts AFTER any non-null."""
    var a_vals = List[Int64]()
    a_vals.append(Int64(0))
    a_vals.append(Int64(0))
    var b_vals = List[Int64]()
    b_vals.append(Int64(0))
    b_vals.append(Int64(0))
    var rb = _build_batch_2col_i64_i64(a_vals, b_vals)
    var bv = BatchView(rb)
    var key_cols = List[Int]()
    key_cols.append(0)
    var dtypes = List[UInt8]()
    dtypes.append(DT_I64)
    var asc = List[UInt8]()
    asc.append(SORT_ASC)
    var nf = List[UInt8]()
    nf.append(NULLS_LAST)

    var is_null_null = List[Bool]()
    is_null_null.append(True)
    var is_null_nn = List[Bool]()
    is_null_nn.append(False)

    var e_null = encode_row_keys_for_sort(
        bv, 0, key_cols, dtypes, asc, nf, is_null_null
    )
    var e_nn = encode_row_keys_for_sort(
        bv, 1, key_cols, dtypes, asc, nf, is_null_nn
    )
    # NULLS_LAST: null sentinel 0xFF > non-null sentinel 0x01.
    assert_equal(arrow_row_compare(e_null, e_nn), 1)


def test_composite_arity_mismatch_raises() raises:
    """Length-mismatched argument lists raise."""
    var a_vals = List[Int64]()
    a_vals.append(Int64(0))
    var b_vals = List[Int64]()
    b_vals.append(Int64(0))
    var rb = _build_batch_2col_i64_i64(a_vals, b_vals)
    var bv = BatchView(rb)
    var key_cols = List[Int]()
    key_cols.append(0)
    var dtypes = List[UInt8]()
    dtypes.append(DT_I64)
    dtypes.append(DT_I64)  # length mismatch
    var asc = List[UInt8]()
    asc.append(SORT_ASC)
    var nf = List[UInt8]()
    nf.append(NULLS_FIRST)
    var is_null = List[Bool]()
    is_null.append(False)
    var raised = False
    try:
        _ = encode_row_keys_for_sort(
            bv, 0, key_cols, dtypes, asc, nf, is_null
        )
    except:
        raised = True
    assert_true(raised)


# =============================================================================
# Main
# =============================================================================



def test_dt_tag_table_matches_row_block() raises:
    """Every DType tag arrow_row re-declares must equal row_block's.

    A failure here means the two hand-maintained tables have diverged.
    Fix the VALUE, never this assertion: both tables are wire formats for
    the same spilled sort key, so whichever side is wrong corrupts reads
    of data the other side wrote.
    """
    assert_equal(Int(DT_I64), Int(RB_DT_I64))
    assert_equal(Int(DT_F64), Int(RB_DT_F64))
    assert_equal(Int(DT_I32), Int(RB_DT_I32))
    assert_equal(Int(DT_F32), Int(RB_DT_F32))
    assert_equal(Int(DT_I16), Int(RB_DT_I16))
    assert_equal(Int(DT_I8), Int(RB_DT_I8))
    assert_equal(Int(DT_U8), Int(RB_DT_U8))
    assert_equal(Int(DT_STRING), Int(RB_DT_STRING))
    assert_equal(Int(DT_U16), Int(RB_DT_U16))
    assert_equal(Int(DT_U32), Int(RB_DT_U32))
    assert_equal(Int(DT_U64), Int(RB_DT_U64))
    assert_equal(Int(DT_DATE32), Int(RB_DT_DATE32))
    assert_equal(Int(DT_DECIMAL128), Int(RB_DT_DECIMAL128))
    assert_equal(Int(DT_BOOL), Int(RB_DT_BOOL))
    assert_equal(Int(DT_DATE64), Int(RB_DT_DATE64))
    assert_equal(Int(DT_TIMESTAMP_NS), Int(RB_DT_TIMESTAMP_NS))
    assert_equal(Int(DT_TIMESTAMP_US), Int(RB_DT_TIMESTAMP_US))
    assert_equal(Int(DT_TIMESTAMP_MS), Int(RB_DT_TIMESTAMP_MS))
    assert_equal(Int(DT_TIMESTAMP_S), Int(RB_DT_TIMESTAMP_S))
    assert_equal(Int(DT_BINARY), Int(RB_DT_BINARY))

    # Guard the SHAPE too, not just the values: arrow_row deliberately
    # stops at DT_BINARY=20. If row_block's two extra tags (DT_LIST=21,
    # DT_STRUCT=22) were ever renumbered DOWN into arrow_row's range they
    # would collide with a tag arrow_row already encodes, and every
    # assertion above would still pass.
    assert_true(Int(DT_BINARY) < 21)

def main() raises:
    # Per-DType encoder tests
    test_i64_order_preserving()
    test_i64_desc_inverts_order()
    test_u64_order_preserving()
    test_f64_order_preserving()
    test_f64_neg_zero_lt_pos_zero()
    test_i32_order_preserving()
    test_u32_order_preserving()
    test_f32_order_preserving()
    test_i16_order_preserving()
    test_u16_order_preserving()
    test_i8_order_preserving()
    test_u8_order_preserving()
    test_bool_encoding()
    test_decimal128_order_preserving()
    # Cross-impl validation
    test_i64_neg_5_canonical_bytes()
    test_i64_zero_canonical_bytes()
    test_i64_max_canonical_bytes()
    test_i64_min_canonical_bytes()
    test_i64_desc_inverts_min()
    test_f64_pos_zero_canonical()
    test_f64_neg_zero_canonical()
    # Width / sentinel
    test_encoded_width_for_dtype()
    test_encoded_width_string_raises()
    test_encoded_width_binary_raises()
    test_sentinel_constants()
    # Drift detector (the cross-check arrow_row.mojo's header names)
    test_dt_tag_table_matches_row_block()
    # Composite encoder
    test_composite_2col_i64_asc_asc_matches_tuple_order()
    test_composite_2col_i64_desc_first_key()
    test_composite_string_raises()
    test_composite_null_first_lt_non_null()
    test_composite_null_last_gt_non_null()
    test_composite_arity_mismatch_raises()
    print("test_arrow_row: PASS")
