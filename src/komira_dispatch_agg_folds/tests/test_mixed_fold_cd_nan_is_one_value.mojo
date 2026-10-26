# =============================================================================
# `agg_mixed_cd_fold`: COUNT(DISTINCT) over a float column counts every NaN as
# ONE value, whatever its sign or payload, as DuckDB does.
#
# The fixture, grouped by `k`:
#
#   k | x (FLOAT64)                 | y (FLOAT32)
#   --+-----------------------------+---------------------------
#   1 | NaN 0x7FF8000000000000      | NaN 0x7FC00000
#   1 | NaN 0xFFF8000000000000 (-)  | NaN 0xFFC00000 (-)
#   1 | NaN 0x7FF8000000000123      | NaN 0x7FC00123
#   1 | NaN 0xFFF8000000000456 (-)  | NaN 0xFFC00456 (-)
#   1 | 1.0                         | 1.0
#   2 | 0.0                         | 0.0
#   2 | -0.0                        | -0.0
#   2 | NaN 0x7FF8000000000789      | NaN 0x7FC00789
#
# DuckDB: `SELECT k, count(DISTINCT x), count(DISTINCT y), count(*) FROM t
# GROUP BY k` answers (1, 2, 2, 5) and (2, 2, 2, 3): group 1 is {NaN, 1.0},
# group 2 is {0.0, NaN}.
#
# What it proves: both float channels of the fold's distinct key fold every
# NaN onto one key. The defect it catches: the key taking a NaN's literal bit
# pattern (group 1 then counts 5 on both columns). Mutant seen red: the NaN
# canonicalisation removed from `cd_f64_distinct_key`.
# =============================================================================

from std.collections import List, Optional
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_collections.slab import Slab
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_COUNT_DISTINCT
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    AggExprArray, ExprArray, LogicalPlan, SOURCE_PARQUET,
)
from komira_plan_ir.logical_plan_variants import AggregateData

from komira_dispatch_agg_folds.agg_mixed_cd_fold import (
    fold_mixed_count_distinct_over_batch,
    fold_mixed_count_distinct_over_batches,
)


def _nan64(bits: UInt64) -> Float64:
    return bitcast[DType.float64](bits)


def _nan32(bits: UInt32) -> Float32:
    return bitcast[DType.float32](bits)


def _batch(lo: Int, hi: Int) raises -> RecordBatch:
    """Rows [lo, hi) of the fixture above."""
    var k: List[Int64] = [1, 1, 1, 1, 1, 2, 2, 2]
    var x: List[Float64] = [
        _nan64(0x7FF8000000000000),
        _nan64(0xFFF8000000000000),
        _nan64(0x7FF8000000000123),
        _nan64(0xFFF8000000000456),
        1.0,
        0.0,
        -0.0,
        _nan64(0x7FF8000000000789),
    ]
    var y: List[Float32] = [
        _nan32(0x7FC00000),
        _nan32(0xFFC00000),
        _nan32(0x7FC00123),
        _nan32(0xFFC00456),
        1.0,
        0.0,
        -0.0,
        _nan32(0x7FC00789),
    ]
    var n = hi - lo
    var pk = PrimitiveArray[DType.int64].allocate(n)
    var px = PrimitiveArray[DType.float64].allocate(n)
    var py = PrimitiveArray[DType.float32].allocate(n)
    for r in range(lo, hi):
        pk.set(r - lo, k[r])
        px.set(r - lo, x[r])
        py.set(r - lo, y[r])
    var rbb = RecordBatchBuilder.with_capacity(3)
    var sb = SchemaBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](pk^))
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    rbb.add_column(Column.from_primitive[DType.float64](px^))
    sb.add_field(Field(String("x"), ArrowType.FLOAT64, False))
    rbb.add_column(Column.from_primitive[DType.float32](py^))
    sb.add_field(Field(String("y"), ArrowType.FLOAT32, False))
    return rbb.build(sb.build())


def _a(func: UInt8, col: String) raises -> AggExpr:
    return AggExpr(func, Optional[Expr](Expr.col_ref(col)), Optional[String](None))


def _node() raises -> AggregateData:
    """GROUP BY k: CD(x), CD(y), COUNT(*)."""
    var keys = ExprArray()
    keys.append(Expr.col_ref(String("k")))
    var aggs = AggExprArray()
    aggs.append(_a(AGG_COUNT_DISTINCT, String("x")))
    aggs.append(_a(AGG_COUNT_DISTINCT, String("y")))
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](None), Optional[String](None)))
    var child = LogicalPlan.scan(
        String("t.parquet"), SOURCE_PARQUET, _batch(0, 0).schema.copy()
    )
    return AggregateData(keys^, aggs^, child^)


def _i(imm b: RecordBatch, c: Int, r: Int) raises -> Int:
    return Int(b.column_as_primitive_int64(c).get(r))


def _check(imm out: RecordBatch) raises:
    """Output columns: 0 k, 1 CD(x), 2 CD(y), 3 COUNT(*)."""
    assert_equal(out.num_rows(), 2)
    for r in range(2):
        var k = _i(out, 0, r)
        assert_true(k == 1 or k == 2, "unexpected group key " + String(k))
        var want_rows = 5 if k == 1 else 3
        assert_equal(_i(out, 1, r), 2, "CD(x) of group " + String(k))
        assert_equal(_i(out, 2, r), 2, "CD(y) of group " + String(k))
        assert_equal(_i(out, 3, r), want_rows, "COUNT(*) of group " + String(k))


def test_one_batch_counts_every_nan_once() raises:
    var o = fold_mixed_count_distinct_over_batch(_node(), _batch(0, 8))
    assert_true(o.__bool__(), "the mixed fold declined a shape it serves")
    _check(o.value())


def test_a_batch_list_counts_every_nan_once() raises:
    """The NaNs of group 1 split across two batches: still one value."""
    var bs = Slab[RecordBatch]()
    bs.append(_batch(0, 2))
    bs.append(_batch(2, 8))
    var o = fold_mixed_count_distinct_over_batches(_node(), bs)
    assert_true(o.__bool__(), "the mixed fold declined a list it serves")
    _check(o.value())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
