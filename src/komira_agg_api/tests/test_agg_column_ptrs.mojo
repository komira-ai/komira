# =============================================================================
# agg_column_ptrs: TypedColumnPtrs (per-lane typed value pointers) and
# ValidityLanes (the per-lane NULL channel).
#
# What each part proves:
#
#   * CLASSIFICATION. `from_batch_padded` gives one lane per agg, in agg
#     order: FLOAT64 -> F64, INT32 -> I32, INT64 -> I64, no child (COUNT(*))
#     -> NONE. Each lane's typed pointer, advanced by `offset_at(lane)`,
#     reads that column's values (checked at the first and LAST row), and
#     the raw backing pointers read the same kinds, offsets and values.
#   * VALIDITY RIDES WITH THE LANE. A COUNT(*) lane placed BEFORE a nullable
#     lane still pushes a validity lane, so the nullable lane's NULL is
#     reported at its own lane index and nowhere else; a non-nullable lane
#     never reports NULL; `any_nullable` is True iff some lane has a bitmap.
#   * SLICES. A sliced nullable column's lane carries the slice start as
#     both the value offset and the bit offset: values and NULLs are those of
#     the window, not of the parent's first rows.
#     A second slice starts past the first bitmap byte (rows [11, 16) of 20),
#     so a bit offset reduced to `start & 7` or dropped reads the wrong bits.
#   * ValidityLanes on its own: a negative index is an absent lane, index 0
#     is a real column, LSB-first bit order across a byte boundary.
#   * The no-capacity constructor plus `classify_none`.
# =============================================================================

from std.collections import List, Optional
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_SUM
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import AggExprArray

from komira_agg_api.agg_column_ptrs import (
    AGG_KIND_COUNT,
    AGG_KIND_F64,
    AGG_KIND_I32,
    AGG_KIND_I64,
    LANE_KIND_NONE,
    TypedColumnPtrs,
    ValidityLanes,
)


def _prim[
    dt: DType
](n: Int, base: Int, null_row: Int) raises -> Column[HeapRegion]:
    """Column of `base + i` for i in [0, n); row `null_row` NULL (-1: no
    validity bitmap at all)."""
    var a = (
        PrimitiveArray[dt].allocate_nullable(n) if null_row >= 0 else PrimitiveArray[
            dt
        ].allocate(n)
    )
    for i in range(n):
        a.set(i, Scalar[dt](base + i))
        if i == null_row:
            a._set_null(i)
    return Column.from_primitive[dt](a^)


def _fixture(sliced: Bool) raises -> RecordBatch:
    """Columns (8 rows each, or rows [3, 8) of 11 when `sliced`):

      f  FLOAT64  100 + i  NULL at parent row 5
      n  INT32    200 + i  NULL at parent row 4 (nullable)
      l  INT64    300 + i  no bitmap
      m  INT32    400 + i  no bitmap
    """
    var rbb = RecordBatchBuilder.with_capacity(4)
    var sb = SchemaBuilder()
    var total = 11 if sliced else 8
    var f = _prim[DType.float64](total, 100, 5)
    var n = _prim[DType.int32](total, 200, 4)
    var l = _prim[DType.int64](total, 300, -1)
    var m = _prim[DType.int32](total, 400, -1)
    if sliced:
        f = f.slice(3, 5)
        n = n.slice(3, 5)
        l = l.slice(3, 5)
        m = m.slice(3, 5)
    rbb.add_column(f^)
    sb.add_field(Field(String("f"), ArrowType.FLOAT64, True))
    rbb.add_column(n^)
    sb.add_field(Field(String("n"), ArrowType.INT32, True))
    rbb.add_column(l^)
    sb.add_field(Field(String("l"), ArrowType.INT64, False))
    rbb.add_column(m^)
    sb.add_field(Field(String("m"), ArrowType.INT32, False))
    return rbb.build(sb.build())


def _aggs() raises -> AggExprArray:
    """Lanes: 0 COUNT(*), 1 SUM(f), 2 SUM(n), 3 SUM(l)."""
    var a = AggExprArray()
    a.append(AggExpr(AGG_COUNT, Optional[Expr](None), Optional[String](None)))
    a.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("f")), Optional[String](None)))
    a.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("n")), Optional[String](None)))
    a.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("l")), Optional[String](None)))
    return a^


def _check_lanes(sliced: Bool) raises:
    var batch = _fixture(sliced)
    var aggs = _aggs()
    var p = TypedColumnPtrs[origin_of(batch)].from_batch_padded(batch, aggs, 4)
    var start = 3 if sliced else 0
    var rows = batch.num_rows()
    assert_equal(len(p), 4)
    assert_equal(p.kind_at(0), AGG_KIND_COUNT)
    assert_equal(p.kind_at(1), AGG_KIND_F64)
    assert_equal(p.kind_at(2), AGG_KIND_I32)
    assert_equal(p.kind_at(3), AGG_KIND_I64)
    assert_equal(p.offset_at(0), 0)
    for lane in range(1, 4):
        assert_equal(p.offset_at(lane), start, "offset lane " + String(lane))
    assert_true(p.any_nullable())

    # Values at the first and last row of the batch.
    var last = rows - 1
    assert_equal((p._f64_ptr(1) + p.offset_at(1))[], Float64(100 + start))
    assert_equal((p._f64_ptr(1) + p.offset_at(1) + last)[], Float64(100 + start + last))
    assert_equal((p._i32_ptr(2) + p.offset_at(2))[], Int32(200 + start))
    assert_equal((p._i32_ptr(2) + p.offset_at(2) + last)[], Int32(200 + start + last))
    assert_equal((p._i64_ptr(3) + p.offset_at(3))[], Int64(300 + start))
    assert_equal((p._i64_ptr(3) + p.offset_at(3) + last)[], Int64(300 + start + last))

    # The raw backing pointers read the same thing.
    var kp = p._unsafe_kind_ptr()
    var op = p._unsafe_offset_ptr()
    assert_equal((kp + 2)[], AGG_KIND_I32)
    assert_equal((op + 3)[], start)
    assert_equal(((p._unsafe_f64_ptr() + 1)[] + start + last)[], Float64(100 + start + last))
    assert_equal(((p._unsafe_i32_ptr() + 2)[] + start)[], Int32(200 + start))
    assert_equal(((p._unsafe_i64_ptr() + 3)[] + start + 1)[], Int64(301 + start))

    # NULLs: f at parent row 5, n at parent row 4; l has no bitmap; the
    # COUNT(*) lane has none either.
    for r in range(rows):
        var parent = r + start
        assert_false(p.is_null_at(0, r), "count lane row " + String(r))
        assert_equal(p.is_null_at(1, r), parent == 5, "f row " + String(r))
        assert_equal(p.is_null_at(2, r), parent == 4, "n row " + String(r))
        assert_false(p.is_null_at(3, r), "l row " + String(r))
    _ = aggs^
    _ = batch^


def test_from_batch_padded_classifies_reads_and_gates_nulls() raises:
    _check_lanes(False)


def test_from_batch_padded_on_sliced_columns() raises:
    _check_lanes(True)


def test_no_nullable_lane_reports_none() raises:
    var batch = _fixture(False)
    var a = AggExprArray()
    a.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("l")), Optional[String](None)))
    a.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("m")), Optional[String](None)))
    var p = TypedColumnPtrs[origin_of(batch)].from_batch_padded(batch, a, 2)
    assert_equal(len(p), 2)
    assert_equal(p.kind_at(1), AGG_KIND_I32)
    assert_false(p.any_nullable())
    _ = a^
    _ = batch^


def test_validity_lanes_from_batch_columns() raises:
    var batch = _fixture(False)
    var idx: List[Int] = [-1, 0, 2, 1]
    var v = ValidityLanes[origin_of(batch)].from_batch_columns(batch, idx)
    assert_equal(v.__len__(), 4)
    assert_true(v.any_nullable())
    assert_false(v.lane_is_nullable(0))
    assert_true(v.lane_is_nullable(1))
    assert_false(v.lane_is_nullable(2))
    assert_true(v.lane_is_nullable(3))
    for r in range(8):
        assert_false(v.is_null_at(0, r))
        assert_equal(v.is_null_at(1, r), r == 5, "lane 1 row " + String(r))
        assert_false(v.is_null_at(2, r))
        assert_equal(v.is_null_at(3, r), r == 4, "lane 3 row " + String(r))
    _ = batch^


def test_validity_lanes_bit_order_across_bytes() raises:
    # 20 rows, NULL at row 9 only: byte 1, bit 1. A reversed (MSB-first) bit
    # order or a missing byte step reads the wrong row.
    var rbb = RecordBatchBuilder.with_capacity(1)
    var sb = SchemaBuilder()
    rbb.add_column(_prim[DType.int64](20, 0, 9))
    sb.add_field(Field(String("x"), ArrowType.INT64, True))
    var batch = rbb.build(sb.build())
    var idx: List[Int] = [0]
    var v = ValidityLanes[origin_of(batch)].from_batch_columns(batch, idx)
    for r in range(20):
        assert_equal(v.is_null_at(0, r), r == 9, "row " + String(r))
    var none: List[Int] = [-3]
    var w = ValidityLanes[origin_of(batch)].from_batch_columns(batch, none)
    assert_false(w.any_nullable())
    assert_false(w.lane_is_nullable(0))
    _ = batch^


def test_validity_bit_offset_past_first_byte() raises:
    # Rows [11, 16) of a 20-row parent; the slice start crosses a whole byte
    # of the bitmap. NULLs at parent rows 3 (outside the window, in byte 0),
    # 13 (window row 2) and 16 (just past the window's end). A bit offset that
    # keeps only `start & 7` (3) reads parent rows 3..7 and reports window row
    # 0 NULL and row 2 non-NULL; one that drops the offset reads rows 0..4.
    # Checked through ValidityLanes directly and through the TypedColumnPtrs
    # lane that rides on it.
    var a = PrimitiveArray[DType.int64].allocate_nullable(20)
    for i in range(20):
        a.set(i, Int64(500 + i))
        if i == 3 or i == 13 or i == 16:
            a._set_null(i)
    var col = Column.from_primitive[DType.int64](a^).slice(11, 5)
    var rbb = RecordBatchBuilder.with_capacity(1)
    var sb = SchemaBuilder()
    rbb.add_column(col^)
    sb.add_field(Field(String("x"), ArrowType.INT64, True))
    var batch = rbb.build(sb.build())
    assert_equal(batch.num_rows(), 5)

    var idx: List[Int] = [0]
    var v = ValidityLanes[origin_of(batch)].from_batch_columns(batch, idx)
    for r in range(5):
        assert_equal(v.is_null_at(0, r), r == 2, "lanes row " + String(r))

    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("x")), Optional[String](None)))
    var p = TypedColumnPtrs[origin_of(batch)].from_batch_padded(batch, aggs, 1)
    assert_equal(p.offset_at(0), 11)
    assert_equal((p._i64_ptr(0) + p.offset_at(0) + 2)[], Int64(513))
    for r in range(5):
        assert_equal(p.is_null_at(0, r), r == 2, "ptrs row " + String(r))
    _ = aggs^
    _ = batch^


def test_default_constructor_and_classify_none() raises:
    var batch = _fixture(False)
    var p = TypedColumnPtrs[origin_of(batch)]()
    assert_equal(len(p), 0)
    p.classify_none()
    p.classify_none()
    assert_equal(len(p), 2)
    assert_equal(p.kind_at(1), LANE_KIND_NONE)
    assert_equal(p.offset_at(1), 0)
    assert_false(p.any_nullable())
    assert_false(p.is_null_at(1, 0))
    _ = batch^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
