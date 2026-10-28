# =============================================================================
# cross_batch_gather: rows from several batches into one, in index order
# =============================================================================
#
# Cases: one source (the single-source gather), two sources alternating,
# eight sources, no indices, an all-NULL column, a mixed schema (INT64,
# STRING, FLOAT64, BOOL), validity carried row by row, output order equal to
# index order, and each column type alone (INT32, INT64, FLOAT32, FLOAT64,
# BOOL, STRING, LARGE_STRING), the other fixed widths (1-, 2-byte, unsigned,
# DATE, TIME, TIMESTAMP, DURATION), BINARY and LARGE_STRING with NULLs, sliced
# 2- and 4-byte sources, and DECIMAL128 / DECIMAL256 / INTERVAL_MONTH_DAY_NANO
# refused as an unsupported column type.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.boolean_array import BooleanArray
from komira_column_kernels.cross_batch_gather import cross_batch_gather
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab


# =============================================================================
# Test helpers — construct RecordBatches
# =============================================================================


def _batch_i64(values: List[Int64], name: String) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].from_list(values)
    var col = Column.from_primitive(arr)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, False))
    var schema = sb.build()
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(schema^)


def _batch_i32(values: List[Int32], name: String) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int32].from_list(values)
    var col = Column.from_primitive(arr)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT32, False))
    var schema = sb.build()
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(schema^)


def _batch_f64(values: List[Float64], name: String) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.float64].from_list(values)
    var col = Column.from_primitive(arr)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.FLOAT64, False))
    var schema = sb.build()
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(schema^)


def _batch_f32(values: List[Float32], name: String) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.float32].from_list(values)
    var col = Column.from_primitive(arr)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.FLOAT32, False))
    var schema = sb.build()
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(schema^)


def _batch_str(values: List[String], name: String) raises -> RecordBatch:
    var arr = StringArray.from_strings(values)
    var col = Column.from_string(arr)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.STRING, False))
    var schema = sb.build()
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(schema^)


def _batch_bool(values: List[Bool], name: String) raises -> RecordBatch:
    var n = len(values)
    var bm = Bitmap.create(n)
    for i in range(n):
        if values[i]:
            bm.set(i)
    var barr = BooleanArray.from_bitmap(bm^)
    var col = Column.from_boolean(barr)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.BOOL, False))
    var schema = sb.build()
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(schema^)


def _mk_sources_1(var batch: RecordBatch) -> Slab[RecordBatch]:
    var out = Slab[RecordBatch]()
    out.append(batch^)
    return out^


def _mk_sources_2(
    var b0: RecordBatch, var b1: RecordBatch
) -> Slab[RecordBatch]:
    var out = Slab[RecordBatch]()
    out.append(b0^)
    out.append(b1^)
    return out^


# =============================================================================
# Tests
# =============================================================================


def test_single_source_sanity() raises:
    """Single-source gather: (0, 0), (0, 2), (0, 1) — equivalent to _gather_batch
    with indices [0, 2, 1]."""
    var vals = List[Int64]()
    vals.append(Int64(10)); vals.append(Int64(20)); vals.append(Int64(30))
    var srcs = _mk_sources_1(_batch_i64(vals, "x"))
    var idx = List[Tuple[Int, Int]]()
    idx.append((0, 0))
    idx.append((0, 2))
    idx.append((0, 1))

    var out = cross_batch_gather(srcs, idx)
    assert_equal(out.num_rows(), 3)
    assert_equal(out.num_columns(), 1)
    var arr = out.column_at(0).as_primitive[DType.int64]()
    assert_equal(arr.get(0), Int64(10))
    assert_equal(arr.get(1), Int64(30))
    assert_equal(arr.get(2), Int64(20))


def test_two_source_interleave() raises:
    """Classic interleave doctest: values0=[A,D], values1=[B,C,E]; indices
    [(0,0),(1,0),(1,1),(0,1)] -> [A,B,C,D]."""
    var v0 = List[Int64](); v0.append(Int64(100)); v0.append(Int64(400))
    var v1 = List[Int64](); v1.append(Int64(200)); v1.append(Int64(300)); v1.append(Int64(500))
    var srcs = _mk_sources_2(_batch_i64(v0, "x"), _batch_i64(v1, "x"))
    var idx = List[Tuple[Int, Int]]()
    idx.append((0, 0))
    idx.append((1, 0))
    idx.append((1, 1))
    idx.append((0, 1))

    var out = cross_batch_gather(srcs, idx)
    assert_equal(out.num_rows(), 4)
    var arr = out.column_at(0).as_primitive[DType.int64]()
    assert_equal(arr.get(0), Int64(100))
    assert_equal(arr.get(1), Int64(200))
    assert_equal(arr.get(2), Int64(300))
    assert_equal(arr.get(3), Int64(400))


def test_n_source_stress() raises:
    """N=8 sources, each with 3 rows; pick one from each in order."""
    var srcs = Slab[RecordBatch]()
    for s in range(8):
        var v = List[Int64]()
        for r in range(3):
            v.append(Int64(s * 100 + r))
        srcs.append(_batch_i64(v, "x"))

    var idx = List[Tuple[Int, Int]]()
    for s in range(8):
        idx.append((s, 1))  # middle row of each source

    var out = cross_batch_gather(srcs, idx)
    assert_equal(out.num_rows(), 8)
    var arr = out.column_at(0).as_primitive[DType.int64]()
    for s in range(8):
        assert_equal(arr.get(s), Int64(s * 100 + 1))


def test_empty_indices() raises:
    """Empty indices -> empty batch, same schema."""
    var vals = List[Int64](); vals.append(Int64(10)); vals.append(Int64(20))
    var srcs = _mk_sources_1(_batch_i64(vals, "x"))
    var idx = List[Tuple[Int, Int]]()

    var out = cross_batch_gather(srcs, idx)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 1)
    assert_equal(out.schema.field_name(0), String("x"))
    assert_true(out.schema.field_arrow_type(0) == ArrowType.INT64)


def test_all_null_column_type() raises:
    """Column with arrow_type NULL — length-only column, all entries null."""
    # Build a batch with a single NULL-typed column of length 3 manually.
    var d = OwnedAlignedBuffer(1); d.set_length(0)
    var col = Column(
        arrow_type=ArrowType.NULL,
        data=d^,
        offsets=None,
        validity=None,
        length=3,
        null_count=3,
        offset=0,
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("n", ArrowType.NULL, True))
    var schema = sb.build()
    var b = RecordBatchBuilder()
    b.add_column(col^)
    var batch = b.build(schema^)

    var srcs = _mk_sources_1(batch^)
    var idx = List[Tuple[Int, Int]]()
    idx.append((0, 0))
    idx.append((0, 2))

    var out = cross_batch_gather(srcs, idx)
    assert_equal(out.num_rows(), 2)
    assert_true(out.schema.field_arrow_type(0) == ArrowType.NULL)


def test_multi_dtype_schema() raises:
    """Multi-column batch: INT64 + STRING + FLOAT64 + BOOL; gather works
    column-wise, row order preserved."""
    # Source 0: i=[1,2], s=["a","bb"], f=[1.5, 2.5], b=[True, False]
    # Source 1: i=[3,4], s=["ccc","dddd"], f=[3.5, 4.5], b=[False, True]
    # Indices: (0,1), (1,0), (0,0), (1,1) -> 4 rows
    var s0_i_l = List[Int64](); s0_i_l.append(Int64(1)); s0_i_l.append(Int64(2))
    var s0_i = PrimitiveArray[DType.int64].from_list(s0_i_l)
    var s0_ss_strs = List[String](); s0_ss_strs.append(String("a")); s0_ss_strs.append(String("bb"))
    var s0_ss = StringArray.from_strings(s0_ss_strs)
    var s0_f_l = List[Float64](); s0_f_l.append(Float64(1.5)); s0_f_l.append(Float64(2.5))
    var s0_f = PrimitiveArray[DType.float64].from_list(s0_f_l)
    var s0_bm = Bitmap.create(2); s0_bm.set(0)  # [True, False]
    var s0_b = BooleanArray.from_bitmap(s0_bm^)

    var s1_i_l = List[Int64](); s1_i_l.append(Int64(3)); s1_i_l.append(Int64(4))
    var s1_i = PrimitiveArray[DType.int64].from_list(s1_i_l)
    var s1_ss_strs = List[String](); s1_ss_strs.append(String("ccc")); s1_ss_strs.append(String("dddd"))
    var s1_ss = StringArray.from_strings(s1_ss_strs)
    var s1_f_l = List[Float64](); s1_f_l.append(Float64(3.5)); s1_f_l.append(Float64(4.5))
    var s1_f = PrimitiveArray[DType.float64].from_list(s1_f_l)
    var s1_bm = Bitmap.create(2); s1_bm.set(1)  # [False, True]
    var s1_b = BooleanArray.from_bitmap(s1_bm^)

    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    sb.add_field(Field("b", ArrowType.BOOL, False))

    var rb0b = RecordBatchBuilder()
    rb0b.add_column(Column.from_primitive(s0_i))
    rb0b.add_column(Column.from_string(s0_ss))
    rb0b.add_column(Column.from_primitive(s0_f))
    rb0b.add_column(Column.from_boolean(s0_b))
    var s0 = rb0b.build(sb.build())

    var sb2 = SchemaBuilder()
    sb2.add_field(Field("i", ArrowType.INT64, False))
    sb2.add_field(Field("s", ArrowType.STRING, False))
    sb2.add_field(Field("f", ArrowType.FLOAT64, False))
    sb2.add_field(Field("b", ArrowType.BOOL, False))
    var rb1b = RecordBatchBuilder()
    rb1b.add_column(Column.from_primitive(s1_i))
    rb1b.add_column(Column.from_string(s1_ss))
    rb1b.add_column(Column.from_primitive(s1_f))
    rb1b.add_column(Column.from_boolean(s1_b))
    var s1 = rb1b.build(sb2.build())

    var srcs = _mk_sources_2(s0^, s1^)
    var idx = List[Tuple[Int, Int]]()
    idx.append((0, 1))  # row 0 -> 2, "bb", 2.5, False
    idx.append((1, 0))  # row 1 -> 3, "ccc", 3.5, False
    idx.append((0, 0))  # row 2 -> 1, "a", 1.5, True
    idx.append((1, 1))  # row 3 -> 4, "dddd", 4.5, True

    var out = cross_batch_gather(srcs, idx)
    assert_equal(out.num_rows(), 4)
    assert_equal(out.num_columns(), 4)

    var iarr = out.column_at(0).as_primitive[DType.int64]()
    assert_equal(iarr.get(0), Int64(2))
    assert_equal(iarr.get(1), Int64(3))
    assert_equal(iarr.get(2), Int64(1))
    assert_equal(iarr.get(3), Int64(4))

    var sarr = out.column_at(1).as_string()
    assert_equal(sarr.get(0), String("bb"))
    assert_equal(sarr.get(1), String("ccc"))
    assert_equal(sarr.get(2), String("a"))
    assert_equal(sarr.get(3), String("dddd"))

    var farr = out.column_at(2).as_primitive[DType.float64]()
    assert_equal(farr.get(0), Float64(2.5))
    assert_equal(farr.get(1), Float64(3.5))
    assert_equal(farr.get(2), Float64(1.5))
    assert_equal(farr.get(3), Float64(4.5))

    var barr = out.column_at(3).as_boolean()
    assert_equal(barr.get(0), False)
    assert_equal(barr.get(1), False)
    assert_equal(barr.get(2), True)
    assert_equal(barr.get(3), True)


def test_nullable_validity_preserved() raises:
    """Nullable column: source validity bits must map correctly to the
    output position given by the index pair."""
    # Source 0: values [10, 20, 30]; validity [T, F, T]  (row 1 null)
    var n = 3
    var data_buf = OwnedAlignedBuffer(n * 8)
    var data_ptr = data_buf.view_typed_mut[DType.int64]()
    (data_ptr + 0)[] = Int64(10)
    (data_ptr + 1)[] = Int64(20)
    (data_ptr + 2)[] = Int64(30)
    data_buf.set_length(Int64(n * 8))
    var vbm = Bitmap.create(n)
    vbm.set(0); vbm.set(2)  # row 1 null
    var col = Column(
        arrow_type=ArrowType.INT64,
        data=data_buf^,
        offsets=None,
        validity=vbm^,
        length=n,
        null_count=1,
        offset=0,
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, True))
    var bb = RecordBatchBuilder()
    bb.add_column(col^)
    var b0 = bb.build(sb.build())

    var srcs = _mk_sources_1(b0^)
    var idx = List[Tuple[Int, Int]]()
    idx.append((0, 2))  # -> 30, valid
    idx.append((0, 1))  # -> null
    idx.append((0, 0))  # -> 10, valid

    var out = cross_batch_gather(srcs, idx)
    assert_equal(out.num_rows(), 3)
    assert_true(out.column_at(0)._validity.__bool__())
    ref out_v = out.column_at(0)._validity.value()
    assert_equal(out_v.test(0), True)
    assert_equal(out_v.test(1), False)
    assert_equal(out_v.test(2), True)
    assert_equal(out.column_at(0)._null_count, 1)


def test_row_order_stability() raises:
    """Output row order matches indices order even when sources alternate."""
    var v0 = List[Int64](); v0.append(Int64(1000)); v0.append(Int64(1001)); v0.append(Int64(1002))
    var v1 = List[Int64](); v1.append(Int64(2000)); v1.append(Int64(2001)); v1.append(Int64(2002))
    var srcs = _mk_sources_2(_batch_i64(v0, "x"), _batch_i64(v1, "x"))
    # Zigzag order.
    var idx = List[Tuple[Int, Int]]()
    idx.append((1, 2))  # 2002
    idx.append((0, 0))  # 1000
    idx.append((1, 1))  # 2001
    idx.append((0, 2))  # 1002
    idx.append((1, 0))  # 2000
    idx.append((0, 1))  # 1001

    var out = cross_batch_gather(srcs, idx)
    var arr = out.column_at(0).as_primitive[DType.int64]()
    assert_equal(arr.get(0), Int64(2002))
    assert_equal(arr.get(1), Int64(1000))
    assert_equal(arr.get(2), Int64(2001))
    assert_equal(arr.get(3), Int64(1002))
    assert_equal(arr.get(4), Int64(2000))
    assert_equal(arr.get(5), Int64(1001))


# ---- Per-dtype smokes ----


def test_smoke_int32() raises:
    var v0 = List[Int32](); v0.append(Int32(1)); v0.append(Int32(2))
    var v1 = List[Int32](); v1.append(Int32(3)); v1.append(Int32(4))
    var srcs = _mk_sources_2(_batch_i32(v0, "x"), _batch_i32(v1, "x"))
    var idx = List[Tuple[Int, Int]]()
    idx.append((1, 1)); idx.append((0, 0)); idx.append((1, 0))
    var out = cross_batch_gather(srcs, idx)
    var arr = out.column_at(0).as_primitive[DType.int32]()
    assert_equal(arr.get(0), Int32(4))
    assert_equal(arr.get(1), Int32(1))
    assert_equal(arr.get(2), Int32(3))


def test_smoke_float32() raises:
    var v0 = List[Float32](); v0.append(Float32(1.5)); v0.append(Float32(2.5))
    var v1 = List[Float32](); v1.append(Float32(3.5))
    var srcs = _mk_sources_2(_batch_f32(v0, "x"), _batch_f32(v1, "x"))
    var idx = List[Tuple[Int, Int]]()
    idx.append((0, 1)); idx.append((1, 0))
    var out = cross_batch_gather(srcs, idx)
    var arr = out.column_at(0).as_primitive[DType.float32]()
    assert_equal(arr.get(0), Float32(2.5))
    assert_equal(arr.get(1), Float32(3.5))


def test_smoke_float64() raises:
    var v0 = List[Float64](); v0.append(Float64(0.25))
    var v1 = List[Float64](); v1.append(Float64(1.25)); v1.append(Float64(2.25))
    var srcs = _mk_sources_2(_batch_f64(v0, "x"), _batch_f64(v1, "x"))
    var idx = List[Tuple[Int, Int]]()
    idx.append((1, 1)); idx.append((0, 0)); idx.append((1, 0))
    var out = cross_batch_gather(srcs, idx)
    var arr = out.column_at(0).as_primitive[DType.float64]()
    assert_equal(arr.get(0), Float64(2.25))
    assert_equal(arr.get(1), Float64(0.25))
    assert_equal(arr.get(2), Float64(1.25))


def test_smoke_string() raises:
    var v0 = List[String](); v0.append(String("alpha")); v0.append(String("beta"))
    var v1 = List[String](); v1.append(String("gamma"))
    var srcs = _mk_sources_2(_batch_str(v0, "s"), _batch_str(v1, "s"))
    var idx = List[Tuple[Int, Int]]()
    idx.append((1, 0)); idx.append((0, 1)); idx.append((0, 0))
    var out = cross_batch_gather(srcs, idx)
    var arr = out.column_at(0).as_string()
    assert_equal(arr.get(0), String("gamma"))
    assert_equal(arr.get(1), String("beta"))
    assert_equal(arr.get(2), String("alpha"))


def test_smoke_bool() raises:
    var v0 = List[Bool](); v0.append(True); v0.append(False); v0.append(True)
    var v1 = List[Bool](); v1.append(False); v1.append(True)
    var srcs = _mk_sources_2(_batch_bool(v0, "b"), _batch_bool(v1, "b"))
    var idx = List[Tuple[Int, Int]]()
    idx.append((0, 0)); idx.append((1, 0)); idx.append((0, 1)); idx.append((1, 1)); idx.append((0, 2))
    var out = cross_batch_gather(srcs, idx)
    var arr = out.column_at(0).as_boolean()
    assert_equal(arr.get(0), True)
    assert_equal(arr.get(1), False)
    assert_equal(arr.get(2), False)
    assert_equal(arr.get(3), True)
    assert_equal(arr.get(4), True)


def test_string_with_nulls() raises:
    """STRING with a nullable validity — validity mapped through gather."""
    # Build a string column manually with validity.
    comptime off_size = 4
    var strs = List[String]()
    strs.append(String("x"))
    strs.append(String(""))   # logical null
    strs.append(String("zzz"))
    var sa = StringArray.from_strings(strs)
    var col = Column.from_string(sa)
    # Attach a validity bitmap with row 1 null.
    var vbm = Bitmap.create(3); vbm.set(0); vbm.set(2)
    col._validity = vbm^
    col._null_count = 1

    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(col^)
    var b0 = rbb.build(sb.build())

    var srcs = _mk_sources_1(b0^)
    var idx = List[Tuple[Int, Int]]()
    idx.append((0, 0))  # "x", valid
    idx.append((0, 1))  # "", null
    idx.append((0, 2))  # "zzz", valid

    var out = cross_batch_gather(srcs, idx)
    assert_equal(out.num_rows(), 3)
    assert_true(out.column_at(0)._validity.__bool__())
    ref out_v = out.column_at(0)._validity.value()
    assert_equal(out_v.test(0), True)
    assert_equal(out_v.test(1), False)
    assert_equal(out_v.test(2), True)
    var arr = out.column_at(0).as_string()
    assert_equal(arr.get(0), String("x"))
    assert_equal(arr.get(2), String("zzz"))


def test_sliced_source_with_validity() raises:
    """A zero-copy slice (`_offset > 0`) of a nullable source is read from its
    window, values and validity both, across a batch boundary."""
    var vals: List[Int64] = [10, 11, 12, 13]
    var full = Column.from_primitive(PrimitiveArray[DType.int64].from_list(vals))
    var vbm = Bitmap.create(4)
    vbm.set(0)
    vbm.set(1)
    vbm.set(3)
    full._validity = vbm^
    full._null_count = 1
    var sliced = full.slice(1, 3)  # logical rows: 11, null, 13
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    var rb0 = RecordBatchBuilder()
    rb0.add_column(sliced^)
    var b0 = rb0.build(sb.build())
    var b1 = _batch_i64([Int64(20), Int64(21)], "k")

    var srcs = Slab[RecordBatch]()
    srcs.append(b0^)
    srcs.append(b1^)
    var idx = List[Tuple[Int, Int]]()
    idx.append((0, 0))
    idx.append((1, 1))
    idx.append((0, 2))
    idx.append((0, 1))
    idx.append((1, 0))
    var out = cross_batch_gather(srcs, idx)
    assert_equal(out.num_rows(), 5)
    var arr = out.column_at(0).as_primitive[DType.int64]()
    assert_equal(arr.get(0), Int64(11))
    assert_equal(arr.get(1), Int64(21))
    assert_equal(arr.get(2), Int64(13))
    assert_equal(arr.get(4), Int64(20))
    ref v = out.column_at(0)._validity.value()
    assert_equal(v.test(0), True)
    assert_equal(v.test(1), True)
    assert_equal(v.test(2), True)
    assert_equal(v.test(3), False)
    assert_equal(v.test(4), True)
    assert_equal(out.column_at(0)._null_count, 1)


def _fixed(at: ArrowType, elem: Int, base: Int, rows: Int) raises -> RecordBatch:
    var d = OwnedAlignedBuffer(rows * elem)
    for i in range(rows * elem):
        d.write_u8_at(i, UInt8((base + i) & 0xFF))
    d.set_length(Int64(rows * elem))
    var c = Column[HeapRegion](arrow_type=at, data=d^, offsets=None, validity=None, length=rows, null_count=0, offset=0)
    var sb = SchemaBuilder()
    sb.add_field(Field("c", at, False))
    var b = RecordBatchBuilder()
    b.add_column(c^)
    return b.build(sb.build())


def _probe(at: ArrowType, elem: Int, name: String) raises -> String:
    """Returns "" if ok else a message."""
    try:
        var b0 = _fixed(at, elem, 10, 4)
        var b1 = _fixed(at, elem, 100, 4)
        var srcs = Slab[RecordBatch]()
        srcs.append(b0^)
        srcs.append(b1^)
        var idx = List[Tuple[Int, Int]]()
        idx.append((1, 2))
        idx.append((0, 3))
        idx.append((0, 0))
        idx.append((1, 1))
        var out = cross_batch_gather(srcs, idx)
        var want = List[Tuple[Int, Int]]()
        want.append((100, 2))
        want.append((10, 3))
        want.append((10, 0))
        want.append((100, 1))
        for i in range(4):
            for j in range(elem):
                var e = (want[i][0] + want[i][1] * elem + j) & 0xFF
                var g = Int(out.column_at(0)._data.read_u8_at(i * elem + j))
                if g != e:
                    return name + ": wrong byte"
        if out.column_at(0).arrow_type != at:
            return name + ": type changed"
        return ""
    except e:
        return name + ": raised " + String(e)


def test_narrow_and_unsigned_widths() raises:
    var bad = List[String]()
    var at = List[ArrowType]()
    var el = List[Int]()
    var nm = List[String]()
    at.append(ArrowType.INT8); el.append(1); nm.append("INT8")
    at.append(ArrowType.UINT8); el.append(1); nm.append("UINT8")
    at.append(ArrowType.INT16); el.append(2); nm.append("INT16")
    at.append(ArrowType.UINT16); el.append(2); nm.append("UINT16")
    at.append(ArrowType.FLOAT16); el.append(2); nm.append("FLOAT16")
    at.append(ArrowType.UINT32); el.append(4); nm.append("UINT32")
    at.append(ArrowType.UINT64); el.append(8); nm.append("UINT64")
    for i in range(len(at)):
        var m = _probe(at[i], el[i], nm[i])
        if m.byte_length() > 0:
            bad.append(m)
    assert_equal(len(bad), 0, "failed: " + (bad[0] if len(bad) > 0 else String("")))


def test_temporal_widths() raises:
    """DATE, TIME and DURATION and TIMESTAMP columns gather by their width."""
    var bad = List[String]()
    var at = List[ArrowType]()
    var el = List[Int]()
    var nm = List[String]()
    at.append(ArrowType.DATE32); el.append(4); nm.append("DATE32")
    at.append(ArrowType.TIME32_S); el.append(4); nm.append("TIME32_S")
    at.append(ArrowType.TIME32_MS); el.append(4); nm.append("TIME32_MS")
    at.append(ArrowType.DATE64); el.append(8); nm.append("DATE64")
    at.append(ArrowType.TIMESTAMP); el.append(8); nm.append("TIMESTAMP")
    at.append(ArrowType.TIMESTAMP_S); el.append(8); nm.append("TIMESTAMP_S")
    at.append(ArrowType.TIMESTAMP_MS); el.append(8); nm.append("TIMESTAMP_MS")
    at.append(ArrowType.TIMESTAMP_US); el.append(8); nm.append("TIMESTAMP_US")
    at.append(ArrowType.TIMESTAMP_NS); el.append(8); nm.append("TIMESTAMP_NS")
    at.append(ArrowType.TIME64_US); el.append(8); nm.append("TIME64_US")
    at.append(ArrowType.TIME64_NS); el.append(8); nm.append("TIME64_NS")
    at.append(ArrowType.DURATION_S); el.append(8); nm.append("DURATION_S")
    at.append(ArrowType.DURATION_MS); el.append(8); nm.append("DURATION_MS")
    at.append(ArrowType.DURATION_US); el.append(8); nm.append("DURATION_US")
    at.append(ArrowType.DURATION_NS); el.append(8); nm.append("DURATION_NS")
    for i in range(len(at)):
        var m = _probe(at[i], el[i], nm[i])
        if m.byte_length() > 0:
            bad.append(m)
    assert_equal(len(bad), 0, "failed: " + String(len(bad)) + " first: " + (bad[0] if len(bad) > 0 else String("")))


def _refused(at: ArrowType, elem: Int) raises -> Bool:
    var srcs = Slab[RecordBatch]()
    srcs.append(_fixed(at, elem, 10, 4))
    var idx = List[Tuple[Int, Int]]()
    idx.append((0, 1))
    try:
        _ = cross_batch_gather(srcs, idx)
    except e:
        return "unsupported column type" in String(e)
    return False


def test_decimal_and_interval_are_refused() raises:
    """The 16- and 32-byte types are not gathered: the call raises, naming
    "unsupported column type"."""
    assert_true(_refused(ArrowType.DECIMAL128, 16))
    assert_true(_refused(ArrowType.DECIMAL256, 32))
    assert_true(_refused(ArrowType.INTERVAL_MONTH_DAY_NANO, 16))


def _var(at: ArrowType, w: Int, strs: List[String], valid: List[Bool]) raises -> RecordBatch:
    var total = 0
    for i in range(len(strs)):
        total += strs[i].byte_length()
    var d = OwnedAlignedBuffer(max(total, 1))
    var o = OwnedAlignedBuffer((len(strs) + 1) * w)
    var pos = 0
    if w == 4:
        o.set_typed[Int32](0, Int32(0))
    else:
        o.set_typed[Int64](0, Int64(0))
    for i in range(len(strs)):
        var bs = strs[i].as_bytes()
        for j in range(len(bs)):
            d.write_u8_at(pos + j, bs[j])
        pos += len(bs)
        if w == 4:
            o.set_typed[Int32](i + 1, Int32(pos))
        else:
            o.set_typed[Int64](i + 1, Int64(pos))
    d.set_length(Int64(total))
    o.set_length(Int64((len(strs) + 1) * w))
    var vb = Optional[Bitmap[HeapRegion]](None)
    var nc = 0
    if len(valid) > 0:
        var bm = Bitmap.create_all_valid(len(strs))
        for i in range(len(strs)):
            if not valid[i]:
                bm.clear(i)
                nc += 1
        vb = bm^
    var c = Column[HeapRegion](arrow_type=at, data=d^, offsets=o^, validity=vb^, length=len(strs), null_count=nc, offset=0)
    var sb = SchemaBuilder()
    sb.add_field(Field("c", at, len(valid) > 0))
    var b = RecordBatchBuilder()
    b.add_column(c^)
    return b.build(sb.build())


def _str_at(col: Column[HeapRegion], w: Int, i: Int) -> String:
    var s = 0
    var e = 0
    if w == 4:
        s = Int(col._offsets.value().get_typed[Int32](i))
        e = Int(col._offsets.value().get_typed[Int32](i + 1))
    else:
        s = Int(col._offsets.value().get_typed[Int64](i))
        e = Int(col._offsets.value().get_typed[Int64](i + 1))
    var out = String("")
    for j in range(s, e):
        out += chr(Int(col._data.read_u8_at(j)))
    return out^


def _var_case(at: ArrowType, w: Int) raises:
    var a: List[String] = ["", "bb", "ccc", "dddd"]
    var bl: List[String] = ["x", "", "yyyyy"]
    var va: List[Bool] = [True, False, True, True]
    var srcs = Slab[RecordBatch]()
    srcs.append(_var(at, w, a, va))
    srcs.append(_var(at, w, bl, List[Bool]()))
    var idx = List[Tuple[Int, Int]]()
    idx.append((1, 2)); idx.append((0, 3)); idx.append((0, 0)); idx.append((0, 1)); idx.append((1, 1)); idx.append((0, 2)); idx.append((1,0))
    var out = cross_batch_gather(srcs, idx)
    ref c = out.column_at(0)
    var want: List[String] = ["yyyyy", "dddd", "", "bb", "", "ccc", "x"]
    for i in range(7):
        assert_equal(_str_at(c, w, i), want[i])
    assert_equal(c._null_count, 1)
    assert_true(c._validity.value().test(2))
    assert_true(not c._validity.value().test(3))
    assert_true(c._validity.value().test(4))
    assert_true(c._validity.value().test(6))


def test_binary_with_nulls() raises:
    _var_case(ArrowType.BINARY, 4)


def test_large_string_with_nulls() raises:
    _var_case(ArrowType.LARGE_STRING, 8)


def test_sliced_two_and_four_byte_sources() raises:
    for w in range(2):
        var at = ArrowType.INT16 if w == 0 else ArrowType.INT32
        var el = 2 if w == 0 else 4
        var b0 = _fixed(at, el, 10, 4)
        var full = b0.column_at(0).slice(1, 2)  # rows 1,2 of base 10
        var sb = SchemaBuilder()
        sb.add_field(Field("c", at, False))
        var rb = RecordBatchBuilder()
        rb.add_column(full^)
        var sl = rb.build(sb.build())
        var srcs = Slab[RecordBatch]()
        srcs.append(sl^)
        srcs.append(_fixed(at, el, 100, 3))
        var idx = List[Tuple[Int, Int]]()
        idx.append((0, 1)); idx.append((1, 2)); idx.append((0, 0))
        var out = cross_batch_gather(srcs, idx)
        var wants = List[Int]()
        wants.append(10 + 2 * el); wants.append(100 + 2 * el); wants.append(10 + 1 * el)
        for i in range(3):
            for j in range(el):
                assert_equal(Int(out.column_at(0)._data.read_u8_at(i * el + j)), (wants[i] + j) & 0xFF)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
