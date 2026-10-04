# =============================================================================
# test_lower_untyped_expr_in_list_e2e -- engine-side EXPR_IN_LIST projection arm
# =============================================================================
#
# Without this arm, TPC-H Q19 ERRed with `PipelineCompiler: unsupported projection expression
# tag: 9`. The runtime substrate (`compiler_eval_in_list._eval_in_list` + the
# 5 typed kernels at `_eval_in_list_{int64,int32,float64,string,bool,dictionary}`)
# was already shipped end-to-end as the EXPR_IN_LIST predicate-context arm in
# `compiler_eval_predicate._eval_predicate`.
#
# This slot adds the corresponding **projection-context** arm at
# `compiler_eval_column._eval_column_expr`: an EXPR_IN_LIST hoisted into a
# `with_column` / projection (or reached via `_eval_short_circuit_*` while
# materializing an OR-tree branch through `_eval_column_expr`) now lowers to
# the same typed kernel and is boxed as a Bool Column.
#
# 5 test cases covering Q19's exact predicate shapes:
#   (a) StringView IN-list K=1 (degenerate; Q19's outer `p_brand IN ('Brand#12')`)
#   (b) StringView IN-list K=4 (Q19's `p_container IN ('SM CASE','SM BOX',...)`)
#   (c) StringView IN-list K=8 (composite shipmode + container shape)
#   (d) I64 IN-list K=4 (cross-dtype coverage; `p_size IN (1,2,3,4)`)
#   (e) Empty IN-list -- all rows fail (defends future construction routes
#       that don't fold through the SDK factory)
#
# Each test hand-builds a small RecordBatch, constructs the EXPR_IN_LIST node
# via the canonical `Expr.in_list_node` factory, and calls `_eval_column_expr`
# directly -- this is the exact dispatch site PipelineCompiler hits when
# projecting an EXPR_IN_LIST branch.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import PrimitiveArray
from komira_core.arrow.column import Column
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import (
    SchemaBuilder,
    Field,
    RecordBatch,
    RecordBatchBuilder,
)
from komira_core.plan.expr import Expr
from komira_core.plan.scalar_value import ScalarValue
from komira_compiler.compiler_eval_column import _eval_column_expr


# =============================================================================
# Helpers -- hand-built single-column batches
# =============================================================================


def _str_batch(vals: List[String], name: String = "s") raises -> RecordBatch:
    """One-column STRING RecordBatch (non-nullable)."""
    var arr = StringArray.from_strings(vals)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.STRING, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_string(arr^))
    return rbb.build(sb.build())


def _i64_batch(vals: List[Int64], name: String = "v") raises -> RecordBatch:
    """One-column INT64 RecordBatch (non-nullable)."""
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.set(i, Scalar[DType.int64](vals[i]))
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    return rbb.build(sb.build())


# =============================================================================
# Test cases
# =============================================================================


def test_in_list_string_k1_degenerate() raises:
    """K=1 string IN-list (Q19's outer brand-eq shape after canonicalization).

    Predicate: s IN ('Brand#12')
    Batch:     ['Brand#12', 'Brand#23', 'Brand#34', 'Brand#12']
    Expected:  [T,           F,           F,           T]
    """
    var batch = _str_batch([
        String("Brand#12"),
        String("Brand#23"),
        String("Brand#34"),
        String("Brand#12"),
    ])
    var values: List[ScalarValue] = [ScalarValue.from_string(String("Brand#12"))]
    var expr = Expr.in_list_node(Expr.col_ref("s"), values^)
    var col = _eval_column_expr(expr, batch)
    assert_equal(col.arrow_type, ArrowType.BOOL)
    var ba = col.as_boolean()
    assert_equal(ba.length, 4)
    assert_true(ba.get(0))
    assert_false(ba.get(1))
    assert_false(ba.get(2))
    assert_true(ba.get(3))


def test_in_list_string_k4_q19_container_shape() raises:
    """K=4 string IN-list (Q19's `p_container IN ('SM CASE','SM BOX','SM PACK','SM PKG')`).

    Batch covers every value table entry + 2 misses.
    """
    var batch = _str_batch([
        String("SM CASE"),    # hit (idx 0)
        String("MED BOX"),    # miss
        String("SM BOX"),     # hit (idx 1)
        String("SM PACK"),    # hit (idx 2)
        String("LG PKG"),     # miss
        String("SM PKG"),     # hit (idx 3)
    ])
    var values: List[ScalarValue] = [
        ScalarValue.from_string(String("SM CASE")),
        ScalarValue.from_string(String("SM BOX")),
        ScalarValue.from_string(String("SM PACK")),
        ScalarValue.from_string(String("SM PKG")),
    ]
    var expr = Expr.in_list_node(Expr.col_ref("s"), values^)
    var col = _eval_column_expr(expr, batch)
    assert_equal(col.arrow_type, ArrowType.BOOL)
    var ba = col.as_boolean()
    assert_equal(ba.length, 6)
    assert_true(ba.get(0))
    assert_false(ba.get(1))
    assert_true(ba.get(2))
    assert_true(ba.get(3))
    assert_false(ba.get(4))
    assert_true(ba.get(5))


def test_in_list_string_k8_long_form() raises:
    """K=8 string IN-list -- exercises the per-row inline probe at the full
    Q19 composite size (4 container vals + 2 shipmode vals + 2 brand vals = 8).
    """
    var batch = _str_batch([
        String("AIR"),         # hit
        String("RAIL"),        # miss
        String("AIR REG"),     # hit
        String("SM CASE"),     # hit
        String("FOB"),         # miss
        String("Brand#34"),    # hit
        String("Brand#12"),    # hit
        String("MED BOX"),     # miss
    ])
    var values: List[ScalarValue] = [
        ScalarValue.from_string(String("AIR")),
        ScalarValue.from_string(String("AIR REG")),
        ScalarValue.from_string(String("SM CASE")),
        ScalarValue.from_string(String("SM BOX")),
        ScalarValue.from_string(String("LG CASE")),
        ScalarValue.from_string(String("LG PKG")),
        ScalarValue.from_string(String("Brand#34")),
        ScalarValue.from_string(String("Brand#12")),
    ]
    var expr = Expr.in_list_node(Expr.col_ref("s"), values^)
    var col = _eval_column_expr(expr, batch)
    assert_equal(col.arrow_type, ArrowType.BOOL)
    var ba = col.as_boolean()
    assert_equal(ba.length, 8)
    assert_true(ba.get(0))
    assert_false(ba.get(1))
    assert_true(ba.get(2))
    assert_true(ba.get(3))
    assert_false(ba.get(4))
    assert_true(ba.get(5))
    assert_true(ba.get(6))
    assert_false(ba.get(7))


def test_in_list_int64_k4() raises:
    """K=4 Int64 IN-list (cross-dtype coverage; Q19's `p_size IN (1,2,3,4)`).

    Batch:    [1, 2, 5, 3, 7, 4, 0]
    Expected: [T, T, F, T, F, T, F]
    """
    var batch = _i64_batch([Int64(1), Int64(2), Int64(5), Int64(3), Int64(7), Int64(4), Int64(0)])
    var values: List[ScalarValue] = [
        ScalarValue.from_int64(Int64(1)),
        ScalarValue.from_int64(Int64(2)),
        ScalarValue.from_int64(Int64(3)),
        ScalarValue.from_int64(Int64(4)),
    ]
    var expr = Expr.in_list_node(Expr.col_ref("v"), values^)
    var col = _eval_column_expr(expr, batch)
    assert_equal(col.arrow_type, ArrowType.BOOL)
    var ba = col.as_boolean()
    assert_equal(ba.length, 7)
    assert_true(ba.get(0))
    assert_true(ba.get(1))
    assert_false(ba.get(2))
    assert_true(ba.get(3))
    assert_false(ba.get(4))
    assert_true(ba.get(5))
    assert_false(ba.get(6))


def test_in_list_empty_all_false() raises:
    """K=0 IN-list returns an all-False bitmap. The SDK factory normally
    folds `IN ` to `literal(False)`, but the engine path defends against
    future construction routes that bypass the fold (per the K=0 short-
    circuit at `compiler_eval_in_list._eval_in_list:60-66`).
    """
    var batch = _i64_batch([Int64(1), Int64(2), Int64(3)])
    var values = List[ScalarValue]()
    var expr = Expr.in_list_node(Expr.col_ref("v"), values^)
    var col = _eval_column_expr(expr, batch)
    assert_equal(col.arrow_type, ArrowType.BOOL)
    var ba = col.as_boolean()
    assert_equal(ba.length, 3)
    assert_false(ba.get(0))
    assert_false(ba.get(1))
    assert_false(ba.get(2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
