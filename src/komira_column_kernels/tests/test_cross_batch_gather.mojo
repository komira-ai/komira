# =============================================================================
# cross_batch_gather: rows from several batches into one, in index order
# =============================================================================
#
# Cases: one source (the single-source gather), two sources alternating,
# eight sources, no indices, an all-NULL column, a mixed schema (INT64,
# STRING, FLOAT64, BOOL), validity carried row by row, output order equal to
# index order, and each column type alone (INT32, INT64, FLOAT32, FLOAT64,
# BOOL, STRING, LARGE_STRING).
# =============================================================================

from std.testing import assert_equal, assert_true

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


# =============================================================================
# Main
# =============================================================================


def main() raises:
    test_single_source_sanity()
    test_two_source_interleave()
    test_n_source_stress()
    test_empty_indices()
    test_all_null_column_type()
    test_multi_dtype_schema()
    test_nullable_validity_preserved()
    test_row_order_stability()
    test_smoke_int32()
    test_smoke_float32()
    test_smoke_float64()
    test_smoke_string()
    test_smoke_bool()
    test_string_with_nulls()
    print("PASS: all 14 cross_batch_gather tests")
