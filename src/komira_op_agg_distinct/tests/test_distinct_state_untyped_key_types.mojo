# =============================================================================
# test_distinct_state_untyped_key_types -- `DistinctState_Untyped` gives
# DuckDB's DISTINCT over NULL, float, DECIMAL128, BOOL and non-ASCII STRING keys
# =============================================================================
#
# Every expected answer is DuckDB's `SELECT DISTINCT k FROM t` over the same
# rows, written out by hand below each fixture (first-seen order, which is the
# order this state emits).
#
# What each test catches:
#   * `test_null_int_key_is_one_value_apart_from_zero`: a NULL key merged into
#     the group its zero data word lands in (`[0, NULL, 0, NULL]` must give two
#     rows, `0` and NULL), or one row per NULL;
#   * `test_null_string_key_is_apart_from_empty_string`: the same for STRING,
#     where a NULL cell and `''` have identical (empty) bytes;
#   * `test_null_payload_reads_back_null`: the first occurrence's NULL payload
#     read back as a 0;
#   * `test_f64_key_nan_and_signed_zero_model`: equality by IEEE `==` (every
#     NaN its own row) or hashing raw bits (NaNs of different sign or payload
#     in different buckets, `-0.0` apart from `0.0`); DuckDB answers one NaN
#     row and one zero row;
#   * `test_f32_key_nan_and_signed_zero_model`: the same on the FLOAT32 arms;
#   * `test_distinct_decimal_key_hi64_distinguishes`: a DECIMAL128 key hashed
#     or compared on its low word only (5 and (1<<64)+5 share it);
#   * the BOOL pair: a BOOL key read from the validity bitmap instead of the
#     value bits (all rows then read TRUE, or "is not NULL");
#   * `test_distinct_read_unique_string_round_trips_the_stored_bytes`: a STRING
#     reader that decodes byte by byte through `chr`, which turns every byte
#     >= 0x80 into two; `test_fixture_is_actually_non_ascii` keeps that test
#     from passing on an all-ASCII fixture.
#
# Float keys must follow the float model (IEEE `==` or raw-bit hashing would
# split NaNs and merge or split the zeros), which the float tests pin; NULL
# keys must hash and compare by validity, which the NULL-key tests pin.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true, assert_false, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import batch_view_over
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_column_format.column_format_storage import (
    ColDescriptor,
    COL_DECIMAL128,
    COL_FIXED,
    COL_VAR_STRING,
    DT_BOOL,
    DT_DECIMAL128,
    DT_I8,
    DT_I16,
    DT_I32,
    DT_U8,
    DT_U16,
    DT_U32,
    DT_U64,
    DT_F32,
    DT_F64,
    DT_I64,
    DT_STRING,
    ROLE_KEY,
    ROLE_PAYLOAD,
)
from komira_op_agg_distinct.distinct_state_untyped import DistinctState_Untyped


def _one_key(kind: UInt8, tag: UInt8, nullable: Bool) -> List[ColDescriptor]:
    var l = List[ColDescriptor]()
    l.append(ColDescriptor(0, kind, tag, ROLE_KEY, 0, 0, nullable))
    return l^


def _one_payload(tag: UInt8, nullable: Bool) -> List[ColDescriptor]:
    var l = List[ColDescriptor]()
    l.append(ColDescriptor(1, COL_FIXED, tag, ROLE_PAYLOAD, 1, 1, nullable))
    return l^


def _batch1(var col: Column[HeapRegion], at: ArrowType, nullable: Bool) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), at, nullable))
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(col^)
    return b.build(sb.build())


def _i64_nullable(vals: List[Int64], nulls: List[Bool]) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        a.set(i, vals[i])
        if nulls[i]:
            a._set_null(i)
    return Column.from_primitive[DType.int64](a^)


# -----------------------------------------------------------------------------
# NULL keys and payloads
# -----------------------------------------------------------------------------


def test_null_int_key_is_one_value_apart_from_zero() raises:
    """k = [0, NULL, 7, NULL, 0] -> DuckDB: 0, NULL, 7."""
    var ds = DistinctState_Untyped(_one_key(COL_FIXED, DT_I64, True), 16)
    var vals: List[Int64] = [0, 0, 7, 0, 0]
    var nulls: List[Bool] = [False, True, False, True, False]
    var rb = _batch1(_i64_nullable(vals, nulls), ArrowType.INT64, True)
    ds.feed_batch(batch_view_over(rb))
    assert_equal(ds.n_unique, 3, "0, NULL and 7")
    var valid = ds.read_unique_validity(0)
    assert_true(valid[0], "first unique is 0, not NULL")
    assert_false(valid[1], "second unique is the NULL")
    assert_true(valid[2], "third unique is 7")
    var got = ds.read_unique_i64(0)
    assert_equal(got[0], Int64(0))
    assert_equal(got[2], Int64(7))


def test_null_string_key_is_apart_from_empty_string() raises:
    """s = ['', NULL, 'a', '', NULL] -> DuckDB: '', NULL, 'a'."""
    var ds = DistinctState_Untyped(
        _one_key(COL_VAR_STRING, DT_STRING, True), 16
    )
    var vals: List[String] = [String(""), String(""), String("a"), String(""), String("")]
    var valid_in: List[Bool] = [True, False, True, True, False]
    var rb = _batch1(
        Column.from_string(StringArray.from_strings_with_validity(vals, valid_in)),
        ArrowType.STRING,
        True,
    )
    ds.feed_batch(batch_view_over(rb))
    assert_equal(ds.n_unique, 3, "'', NULL and 'a'")
    var valid = ds.read_unique_validity(0)
    assert_true(valid[0], "first unique is '', not NULL")
    assert_false(valid[1], "second unique is the NULL")
    var got = ds.read_unique_string(0)
    assert_equal(got[0], String(""))
    assert_equal(got[2], String("a"))


def test_null_payload_reads_back_null() raises:
    """(k, p) = (1, NULL), (2, 5), (1, 9): the payload is each key's first
    occurrence's, so key 1 carries NULL and key 2 carries 5."""
    var ds = DistinctState_Untyped(
        _one_key(COL_FIXED, DT_I64, False), _one_payload(DT_I64, True), 16
    )
    var ks: List[Int64] = [1, 2, 1]
    var no_nulls: List[Bool] = [False, False, False]
    var ps: List[Int64] = [0, 5, 9]
    var p_nulls: List[Bool] = [True, False, False]
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("p"), ArrowType.INT64, True))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(_i64_nullable(ks, no_nulls))
    b.add_column(_i64_nullable(ps, p_nulls))
    var rb = b.build(sb.build())
    ds.feed_batch(batch_view_over(rb))
    assert_equal(ds.n_unique, 2)
    var pv = ds.read_payload_validity(0)
    assert_false(pv[0], "key 1's first payload was NULL")
    assert_true(pv[1], "key 2's payload is 5")
    assert_equal(ds.read_payload_i64(0)[1], Int64(5))
    var kv = ds.read_unique_validity(0)
    assert_true(kv[0] and kv[1], "an untracked key column is all valid")


# -----------------------------------------------------------------------------
# Float keys: every NaN is one value, -0.0 equals 0.0
# -----------------------------------------------------------------------------


def test_f64_key_nan_and_signed_zero_model() raises:
    """k = [NaN, 0.0, -NaN, -0.0, 1.5, NaN(payload 1), 1.5]
    -> DuckDB: NaN, 0.0, 1.5 (three rows; the first-seen spelling is kept)."""
    var vals = List[Float64]()
    vals.append(bitcast[DType.float64](UInt64(0x7FF8000000000000)))
    vals.append(0.0)
    vals.append(bitcast[DType.float64](UInt64(0xFFF8000000000000)))
    vals.append(-0.0)
    vals.append(1.5)
    vals.append(bitcast[DType.float64](UInt64(0x7FF0000000000001)))
    vals.append(1.5)
    var a = PrimitiveArray[DType.float64].allocate(len(vals))
    for i in range(len(vals)):
        a.set(i, vals[i])
    var rb = _batch1(Column.from_primitive[DType.float64](a^), ArrowType.FLOAT64, False)
    var ds = DistinctState_Untyped(_one_key(COL_FIXED, DT_F64, False), 4)
    ds.feed_batch(batch_view_over(rb))
    assert_equal(ds.n_unique, 3, "NaN, 0.0, 1.5")
    var got = ds.read_unique_f64(0)
    assert_true(got[0] != got[0], "first unique is the NaN")
    assert_equal(
        bitcast[DType.uint64](got[1]), UInt64(0), "second unique is +0.0, first seen"
    )
    assert_equal(got[2], 1.5)


def test_f32_key_nan_and_signed_zero_model() raises:
    """k = [-0.0, NaN, 0.0, -NaN, 2.0] -> DuckDB: -0.0 (first seen), NaN, 2.0."""
    var vals = List[Float32]()
    vals.append(-0.0)
    vals.append(bitcast[DType.float32](UInt32(0x7FC00000)))
    vals.append(0.0)
    vals.append(bitcast[DType.float32](UInt32(0xFFC00001)))
    vals.append(2.0)
    var a = PrimitiveArray[DType.float32].allocate(len(vals))
    for i in range(len(vals)):
        a.set(i, vals[i])
    var rb = _batch1(Column.from_primitive[DType.float32](a^), ArrowType.FLOAT32, False)
    var ds = DistinctState_Untyped(_one_key(COL_FIXED, DT_F32, False), 4)
    ds.feed_batch(batch_view_over(rb))
    assert_equal(ds.n_unique, 3, "-0.0, NaN, 2.0")
    var got = ds.read_unique_f32(0)
    assert_equal(
        bitcast[DType.uint32](got[0]), UInt32(0x80000000), "first seen is -0.0"
    )
    assert_true(got[1] != got[1], "second unique is the NaN")
    assert_equal(got[2], Float32(2.0))


# -----------------------------------------------------------------------------
# DECIMAL128 keys: both words
# -----------------------------------------------------------------------------


def _i128(hi: UInt64, lo: UInt64) -> SIMD[DType.int128, 1]:
    """The signed int128 with high word `hi` and low word `lo`."""
    return (
        (hi.cast[DType.uint128]() << UInt128(64)) | lo.cast[DType.uint128]()
    ).cast[DType.int128]()


def test_distinct_decimal_key_hi64_distinguishes() raises:
    """d = [5, (1<<64)+5, 5, (1<<64)+5] -> DuckDB: 5, (1<<64)+5."""
    var vals: List[SIMD[DType.int128, 1]] = [
        _i128(0, 5), _i128(1, 5), _i128(0, 5), _i128(1, 5)
    ]
    var arr = Decimal128Array.allocate(len(vals), 38, 0)
    for i in range(len(vals)):
        arr.set_i128(i, vals[i])
    var sb = SchemaBuilder()
    var f = Field(String("d0"), ArrowType.DECIMAL128, False)
    f.decimal_precision = 38
    f.decimal_scale = 0
    sb.add_field(f)
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_decimal128(arr^))
    var rb = b.build(sb.build())
    var ds = DistinctState_Untyped(_one_key(COL_DECIMAL128, DT_DECIMAL128, False), 16)
    ds.feed_batch(batch_view_over(rb))
    assert_equal(ds.n_unique, 2, "two distinct 128-bit decimals")
    var uniq = ds.read_unique_i128(0)
    assert_true(uniq[0] == _i128(0, 5), "first unique = 5")
    assert_true(uniq[1] == _i128(1, 5), "second unique = (1<<64)+5")


# -----------------------------------------------------------------------------
# BOOL keys: the value bits, not the validity bitmap
# -----------------------------------------------------------------------------


def test_distinct_bool_keeps_true_and_false_apart() raises:
    """b = [T, F, T, F] (no validity bitmap) -> DuckDB: TRUE, FALSE."""
    var keys: List[Bool] = [True, False, True, False]
    var arr = BooleanArray.allocate(len(keys))
    for i in range(len(keys)):
        arr.set(i, keys[i])
    var rb = _batch1(Column.from_boolean(arr^), ArrowType.BOOL, False)
    var ds = DistinctState_Untyped(_one_key(COL_FIXED, DT_BOOL, False), 16)
    ds.feed_batch(batch_view_over(rb))
    assert_equal(ds.n_unique, 2, "TRUE and FALSE are two distinct values")
    var uniq = ds.read_unique_u8(0)
    assert_equal(Int(uniq[0]), 1, "first unique = TRUE")
    assert_equal(Int(uniq[1]), 0, "second unique = FALSE")


def test_distinct_nullable_bool_is_three_uniques() raises:
    """b = [T, NULL, F, NULL] -> DuckDB: TRUE, NULL, FALSE. The NULL rows carry
    different value bits (T, F), so only the validity bit can group them."""
    var keys: List[Bool] = [True, True, False, False]
    var nulls: List[Bool] = [False, True, False, True]
    var arr = BooleanArray.allocate_nullable(len(keys))
    for i in range(len(keys)):
        arr.set(i, keys[i])
    for i in range(len(nulls)):
        if nulls[i]:
            arr._set_null(i)
    var rb = _batch1(Column.from_boolean(arr^), ArrowType.BOOL, True)
    var ds = DistinctState_Untyped(_one_key(COL_FIXED, DT_BOOL, True), 16)
    ds.feed_batch(batch_view_over(rb))
    assert_equal(ds.n_unique, 3, "TRUE, NULL and FALSE are three uniques")
    var valid = ds.read_unique_validity(0)
    assert_true(valid[0], "first unique (TRUE) is not NULL")
    assert_false(valid[1], "second unique is the NULL")
    assert_true(valid[2], "third unique (FALSE) is not NULL")
    var uniq = ds.read_unique_u8(0)
    assert_equal(Int(uniq[0]), 1, "first unique = TRUE")
    assert_equal(Int(uniq[2]), 0, "third unique = FALSE")


# -----------------------------------------------------------------------------
# Non-ASCII STRING keys: read back byte for byte
# -----------------------------------------------------------------------------


def _keys() -> List[String]:
    return [String("ok"), String("aé"), String("Ω"), String("日本"), String("𐍈")]


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def test_fixture_is_actually_non_ascii() raises:
    """A `chr`-per-byte decode is the identity on ASCII, so the round-trip test
    below proves nothing unless the fixture has 2-, 3- and 4-byte UTF-8
    sequences. Their lead bytes are C0-DF, E0-EF and F0-F7; the fixture is
    17 bytes in all."""
    var ks = _keys()
    var total = 0
    var has2 = False
    var has3 = False
    var has4 = False
    for i in range(len(ks)):
        var b = _bytes_of(ks[i])
        total += len(b)
        for j in range(len(b)):
            var v = Int(b[j])
            if v >= 0xC0 and v <= 0xDF:
                has2 = True
            elif v >= 0xE0 and v <= 0xEF:
                has3 = True
            elif v >= 0xF0 and v <= 0xF7:
                has4 = True
    assert_true(has2 and has3 and has4, "2-, 3- and 4-byte sequences present")
    assert_equal(total, 17, "fixture byte total")


def test_distinct_read_unique_string_round_trips_the_stored_bytes() raises:
    """Each key twice, interleaved -> DuckDB: the five keys in first-seen
    order, each byte-identical to its input."""
    var vals = List[String]()
    var ks = _keys()
    for _rep in range(2):
        for i in range(len(ks)):
            vals.append(ks[i])
    var rb = _batch1(
        Column.from_string(StringArray.from_strings(vals)), ArrowType.STRING, False
    )
    var ds = DistinctState_Untyped(_one_key(COL_VAR_STRING, DT_STRING, False), 64)
    ds.feed_batch(batch_view_over(rb))
    var got = ds.read_unique_string(0)
    assert_equal(len(got), len(ks), "five uniques")
    for i in range(len(ks)):
        var gb = _bytes_of(got[i])
        var eb = _bytes_of(ks[i])
        assert_equal(len(gb), len(eb), "byte length of unique " + String(i))
        for j in range(len(eb)):
            assert_equal(gb[j], eb[j], "byte " + String(j) + " of unique " + String(i))


# -----------------------------------------------------------------------------
# Every typed reader, as a key and as a payload
# -----------------------------------------------------------------------------


def _prim[dt: DType](vals: List[Int]) -> Column[HeapRegion]:
    var l = List[Scalar[dt]]()
    for i in range(len(vals)):
        l.append(Scalar[dt](vals[i]))
    return Column.from_primitive[dt](PrimitiveArray[dt].from_list(l))


def _typed_batch() raises -> RecordBatch:
    """Columns i32, i16, u16, i8, u8, u32, u64, f32, f64, s over rows
    (A, B, A): the third row repeats the first in every column."""
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder.with_capacity(10)
    sb.add_field(Field(String("c0"), ArrowType.INT32, False))
    b.add_column(_prim[DType.int32]([-5, 6, -5]))
    sb.add_field(Field(String("c1"), ArrowType.INT16, False))
    b.add_column(_prim[DType.int16]([-300, 301, -300]))
    sb.add_field(Field(String("c2"), ArrowType.UINT16, False))
    b.add_column(_prim[DType.uint16]([60000, 2, 60000]))
    sb.add_field(Field(String("c3"), ArrowType.INT8, False))
    b.add_column(_prim[DType.int8]([-7, 8, -7]))
    sb.add_field(Field(String("c4"), ArrowType.UINT8, False))
    b.add_column(_prim[DType.uint8]([250, 9, 250]))
    sb.add_field(Field(String("c5"), ArrowType.UINT32, False))
    b.add_column(_prim[DType.uint32]([4000000000, 10, 4000000000]))
    sb.add_field(Field(String("c6"), ArrowType.UINT64, False))
    b.add_column(_prim[DType.uint64]([11, 12, 11]))
    sb.add_field(Field(String("c7"), ArrowType.FLOAT32, False))
    b.add_column(_prim[DType.float32]([1, 2, 1]))
    sb.add_field(Field(String("c8"), ArrowType.FLOAT64, False))
    b.add_column(_prim[DType.float64]([3, 4, 3]))
    sb.add_field(Field(String("c9"), ArrowType.STRING, False))
    var sv: List[String] = [String("x"), String("y"), String("x")]
    b.add_column(Column.from_string(StringArray.from_strings(sv)))
    return b.build(sb.build())


def _typed_descs(
    first_col: Int, n: Int, role: UInt8, storage_base: Int
) -> List[ColDescriptor]:
    var tags: List[UInt8] = [
        DT_I32, DT_I16, DT_U16, DT_I8, DT_U8, DT_U32, DT_U64, DT_F32, DT_F64,
        DT_STRING,
    ]
    var l = List[ColDescriptor]()
    for c in range(first_col, first_col + n):
        var kind = COL_VAR_STRING if c == 9 else COL_FIXED
        l.append(
            ColDescriptor(c, kind, tags[c], role, c, storage_base + c - first_col, False)
        )
    return l^


def _check_two(got_a: Int, got_b: Int, a: Int, b: Int, what: String) raises:
    assert_equal(got_a, a, what + " row 0")
    assert_equal(got_b, b, what + " row 1")


def test_typed_key_readers_round_trip() raises:
    """Every fixed-width column a key: two distinct rows, read back by each
    typed key reader at its own width and sign."""
    var rb = _typed_batch()
    var ds = DistinctState_Untyped(_typed_descs(0, 10, ROLE_KEY, 0), 4)
    ds.feed_batch(batch_view_over(rb))
    assert_equal(ds.n_unique, 2)
    var i32 = ds.read_unique_i32(0)
    _check_two(Int(i32[0]), Int(i32[1]), -5, 6, "i32")
    var i16 = ds.read_unique_i16(1)
    _check_two(Int(i16[0]), Int(i16[1]), -300, 301, "i16")
    var u16 = ds.read_unique_u16(2)
    _check_two(Int(u16[0]), Int(u16[1]), 60000, 2, "u16")
    var i8 = ds.read_unique_i8(3)
    _check_two(Int(i8[0]), Int(i8[1]), -7, 8, "i8")
    var u8 = ds.read_unique_u8(4)
    _check_two(Int(u8[0]), Int(u8[1]), 250, 9, "u8")
    var u32 = ds.read_unique_u32(5)
    _check_two(Int(u32[0]), Int(u32[1]), 4000000000, 10, "u32")
    var u64 = ds.read_unique_u64(6)
    _check_two(Int(u64[0]), Int(u64[1]), 11, 12, "u64")
    var f32 = ds.read_unique_f32(7)
    _check_two(Int(f32[0]), Int(f32[1]), 1, 2, "f32")
    var f64 = ds.read_unique_f64(8)
    _check_two(Int(f64[0]), Int(f64[1]), 3, 4, "f64")
    var s = ds.read_unique_string(9)
    assert_equal(s[0], String("x"))
    assert_equal(s[1], String("y"))
    with assert_raises(contains="is not Int64"):
        _ = ds.read_unique_i64(0)
    with assert_raises(contains="out of range"):
        _ = ds.read_unique_i32(10)
    with assert_raises(contains="not VAR_STRING"):
        _ = ds.read_unique_string(0)
    with assert_raises(contains="not DECIMAL128"):
        _ = ds.read_unique_i128(0)


def test_typed_payload_readers_round_trip() raises:
    """Key c0 only; every other column a payload, read back by each typed
    payload reader (the first occurrence of each key)."""
    var rb = _typed_batch()
    var ds = DistinctState_Untyped(
        _typed_descs(0, 1, ROLE_KEY, 0), _typed_descs(1, 9, ROLE_PAYLOAD, 1), 4
    )
    # Payload storage columns follow the key: payload p sits at 1 + p.
    ds.feed_batch(batch_view_over(rb))
    assert_equal(ds.n_payload(), 9)
    var i16 = ds.read_payload_i16(0)
    _check_two(Int(i16[0]), Int(i16[1]), -300, 301, "i16")
    var u16 = ds.read_payload_u16(1)
    _check_two(Int(u16[0]), Int(u16[1]), 60000, 2, "u16")
    var i8 = ds.read_payload_i8(2)
    _check_two(Int(i8[0]), Int(i8[1]), -7, 8, "i8")
    var u8 = ds.read_payload_u8(3)
    _check_two(Int(u8[0]), Int(u8[1]), 250, 9, "u8")
    var u32 = ds.read_payload_u32(4)
    _check_two(Int(u32[0]), Int(u32[1]), 4000000000, 10, "u32")
    var u64 = ds.read_payload_u64(5)
    _check_two(Int(u64[0]), Int(u64[1]), 11, 12, "u64")
    var f32 = ds.read_payload_f32(6)
    _check_two(Int(f32[0]), Int(f32[1]), 1, 2, "f32")
    var f64 = ds.read_payload_f64(7)
    _check_two(Int(f64[0]), Int(f64[1]), 3, 4, "f64")
    var s = ds.read_payload_string(8)
    assert_equal(s[0], String("x"))
    assert_equal(s[1], String("y"))
    with assert_raises(contains="out of range"):
        _ = ds.read_payload_i64(9)
    with assert_raises(contains="is not Int32"):
        _ = ds.read_payload_i32(0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
