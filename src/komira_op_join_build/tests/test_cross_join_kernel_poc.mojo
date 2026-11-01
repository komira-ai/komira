# =============================================================================
# test_cross_join_kernel_poc -- `cross_join_cartesian` over two small resident
# batches: the M x N product in row-major order, every column type carried by
# `assemble_join_result`, and the empty-side cases.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.schema import (
    SchemaBuilder, Field, Schema, RecordBatch, RecordBatchBuilder,
)
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType

from komira_op_join_build.cross_join_kernel import cross_join_cartesian


def _build_i64_1col(name: String, vals: List[Int]) raises -> RecordBatch:
    """Build a 1-col INT64 in-memory RecordBatch."""
    var n = len(vals)
    var a = PrimitiveArray[DType.int64].allocate(n)
    var p = a._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, Scalar[DType.int64](vals[i]))
    var b = RecordBatchBuilder.with_capacity(1)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, False))
    b.add_column(Column.from_primitive[DType.int64](a^))
    return b.build(sb.build())


def _build_i64_2col(
    c0: String, vals0: List[Int], c1: String, vals1: List[Int],
) raises -> RecordBatch:
    """Build a 2-col INT64 in-memory RecordBatch."""
    var n = len(vals0)
    var a0 = PrimitiveArray[DType.int64].allocate(n)
    var a1 = PrimitiveArray[DType.int64].allocate(n)
    var p0 = a0._typed_ptr_mut()
    var p1 = a1._typed_ptr_mut()
    for i in range(n):
        p0.store[width=1](i, Scalar[DType.int64](vals0[i]))
        p1.store[width=1](i, Scalar[DType.int64](vals1[i]))
    var b = RecordBatchBuilder.with_capacity(2)
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.INT64, False))
    sb.add_field(Field(c1, ArrowType.INT64, False))
    b.add_column(Column.from_primitive[DType.int64](a0^))
    b.add_column(Column.from_primitive[DType.int64](a1^))
    return b.build(sb.build())


def _join_out_schema(
    ref left: RecordBatch, ref right: RecordBatch,
) raises -> Schema:
    """Mirror `LogicalPlan.join` non-SEMI/ANTI output schema: left cols verbatim +
    right cols (`_right`-suffix on collision), source nullability preserved."""
    var sb = SchemaBuilder()
    for i in range(left.schema.num_columns()):
        sb.add_field(left.schema.field_at_unchecked(i))
    for i in range(right.schema.num_columns()):
        var rname = right.schema.field_name(i)
        var collision = False
        for j in range(left.schema.num_columns()):
            if left.schema.field_name(j) == rname:
                collision = True
                break
        var rf = right.schema.field_at_unchecked(i)
        if collision:
            rf.name = rname + "_right"
        sb.add_field(rf^)
    return sb.build()


def _find_col(rb: RecordBatch, name: String) -> Int:
    for i in range(rb.num_columns()):
        if String(rb.schema.field_at_unchecked(i).name) == name:
            return i
    return -1


def _get_i64(rb: RecordBatch, col: Int, row: Int) raises -> Int:
    var c = rb.column_at(col).as_primitive[DType.int64]()
    return Int(c.get(row))


# =============================================================================
# Test 1 — 3×2 Cartesian product (the canonical small-both-sides CROSS).
# =============================================================================
# LEFT  l = [10, 20, 30]
# RIGHT r = [1, 2]
# CROSS: (10,1)(10,2)(20,1)(20,2)(30,1)(30,2) — 6 rows, row-major.
def test_cross_3x2() raises:
    var left = _build_i64_1col("l", [10, 20, 30])
    var right = _build_i64_1col("r", [1, 2])
    var out_schema = _join_out_schema(left, right)
    var rb = cross_join_cartesian(left, right, out_schema^)

    assert_equal(rb.num_rows(), 6, "3x2 cross: 6 output rows")
    var ci_l = _find_col(rb, "l")
    var ci_r = _find_col(rb, "r")
    assert_true(ci_l >= 0, "l col present")
    assert_true(ci_r >= 0, "r col present")

    # Row-major: left repeated, right re-scanned.
    var exp_l = List[Int]()
    exp_l.append(10); exp_l.append(10); exp_l.append(20)
    exp_l.append(20); exp_l.append(30); exp_l.append(30)
    var exp_r = List[Int]()
    exp_r.append(1); exp_r.append(2); exp_r.append(1)
    exp_r.append(2); exp_r.append(1); exp_r.append(2)
    for k in range(6):
        assert_equal(_get_i64(rb, ci_l, k), exp_l[k], "l row " + String(k))
        assert_equal(_get_i64(rb, ci_r, k), exp_r[k], "r row " + String(k))
    _ = left^
    _ = right^
    _ = rb^


# =============================================================================
# Test 2 — multi-col both sides (2 left cols × 2 right cols).
# =============================================================================
def test_cross_multicol() raises:
    var left = _build_i64_2col("a", [100, 200], "b", [1, 2])
    var right = _build_i64_2col("c", [7, 8, 9], "d", [70, 80, 90])
    var out_schema = _join_out_schema(left, right)
    var rb = cross_join_cartesian(left, right, out_schema^)

    assert_equal(rb.num_rows(), 6, "2x3 multicol cross: 6 rows")
    var ci_a = _find_col(rb, "a")
    var ci_b = _find_col(rb, "b")
    var ci_c = _find_col(rb, "c")
    var ci_d = _find_col(rb, "d")
    assert_true(ci_a >= 0 and ci_b >= 0 and ci_c >= 0 and ci_d >= 0, "all cols")
    # left row 0 (a=100,b=1) × right rows 0,1,2; then left row 1 (a=200,b=2).
    assert_equal(_get_i64(rb, ci_a, 0), 100, "row0 a")
    assert_equal(_get_i64(rb, ci_b, 0), 1, "row0 b")
    assert_equal(_get_i64(rb, ci_c, 0), 7, "row0 c")
    assert_equal(_get_i64(rb, ci_d, 0), 70, "row0 d")
    assert_equal(_get_i64(rb, ci_a, 3), 200, "row3 a")
    assert_equal(_get_i64(rb, ci_c, 3), 7, "row3 c")
    assert_equal(_get_i64(rb, ci_d, 5), 90, "row5 d")
    _ = left^
    _ = right^
    _ = rb^


# =============================================================================
# Test 3 — collision rename: both sides have a column named "k".
# =============================================================================
def test_cross_collision_rename() raises:
    var left = _build_i64_1col("k", [5, 6])
    var right = _build_i64_1col("k", [100])
    var out_schema = _join_out_schema(left, right)
    var rb = cross_join_cartesian(left, right, out_schema^)

    assert_equal(rb.num_rows(), 2, "collision cross: 2 rows")
    var ci_k = _find_col(rb, "k")
    var ci_kr = _find_col(rb, "k_right")
    assert_true(ci_k >= 0, "left k col present")
    assert_true(ci_kr >= 0, "right k_right col present (collision rename)")
    assert_equal(_get_i64(rb, ci_k, 0), 5, "row0 k")
    assert_equal(_get_i64(rb, ci_kr, 0), 100, "row0 k_right")
    assert_equal(_get_i64(rb, ci_k, 1), 6, "row1 k")
    assert_equal(_get_i64(rb, ci_kr, 1), 100, "row1 k_right")
    _ = left^
    _ = right^
    _ = rb^


# =============================================================================
# Test 4 — empty side: N==0 -> 0 output rows (degenerate Cartesian).
# =============================================================================
def test_cross_empty_right() raises:
    var left = _build_i64_1col("l", [10, 20, 30])
    var right = _build_i64_1col("r", List[Int]())
    var out_schema = _join_out_schema(left, right)
    var rb = cross_join_cartesian(left, right, out_schema^)
    assert_equal(rb.num_rows(), 0, "empty right cross: 0 rows")
    _ = left^
    _ = right^
    _ = rb^


def main() raises:
    var suite = TestSuite()
    suite.test[test_cross_3x2]()
    suite.test[test_cross_multicol]()
    suite.test[test_cross_collision_rename]()
    suite.test[test_cross_empty_right]()
    suite^.run()
