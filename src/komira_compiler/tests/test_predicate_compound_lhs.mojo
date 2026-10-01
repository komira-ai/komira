"""Regression tests for the computed-LHS predicate-compiler fix.

Bug class: a filter whose comparison LHS is a compound expression
(e.g. `a * b > 100`) EXEC_FAILs at runtime with

    PipelineCompiler: cannot resolve column index from expression tag: 3

`_eval_predicate`'s comparison arm resolved the LEFT operand directly to a
column index (`resolve_col_index(binary_left_ref)`), assuming the LHS is a
bare column. Gap C generalized the *RHS* to accept an arbitrary
`EXPR_BINARY_OP` (tag 3) but left the LHS un-generalized, so any `<expr> OP …`
predicate — including the shared `a * b` subtree the `sdk_cse_demo` corpus
query produces across three conjuncts (`a*b > 100 AND a*b < 1000 AND
a*b != 500`) — hit the raise.

FAILS ON CURRENT CODE (pre-fix): every `test_*` below raises the
`cannot resolve column index from expression tag: 3` Error inside
`_eval_predicate` / `evaluate_filter_narrowed`, so the assertions are never
reached. Post-fix: the LHS is materialized through `_eval_column_expr` and
compared via the type-promoting col-vs-col kernel (symmetric to Gap C's RHS).

Self-contained: builds tiny in-memory RecordBatches; does NOT depend on the
bench corpus fixtures.
"""

from std.testing import assert_true, assert_equal
from komira_core.plan.col_expr import col
from komira_core.plan.expr import Expr
from komira_compiler.compiler_eval_predicate import _eval_predicate
from komira_compiler.conjunction import evaluate_filter_narrowed
from komira_core.arrow.schema import (
    Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder,
)
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.arrow_types import ArrowType


# =============================================================================
# Helpers — build small named FLOAT64 / INT64 RecordBatches.
# =============================================================================


def _build_float64_batch(
    names: List[String], cols: List[List[Float64]]
) raises -> RecordBatch:
    var ncols = len(names)
    if len(cols) != ncols:
        raise Error("names / cols length mismatch")
    var n = len(cols[0])
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    for c in range(ncols):
        if len(cols[c]) != n:
            raise Error("ragged columns")
        var arr = PrimitiveArray[DType.float64].allocate(n)
        var p = arr._typed_ptr_mut()
        for i in range(n):
            (p + i)[] = Scalar[DType.float64](cols[c][i])
        sb.add_field(Field(names[c], ArrowType.FLOAT64, False))
        rbb.add_column(Column.from_primitive[DType.float64](arr^))
    return rbb.build(sb.build())


def _build_int64_batch(
    names: List[String], cols: List[List[Int64]]
) raises -> RecordBatch:
    var ncols = len(names)
    if len(cols) != ncols:
        raise Error("names / cols length mismatch")
    var n = len(cols[0])
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    for c in range(ncols):
        if len(cols[c]) != n:
            raise Error("ragged columns")
        var arr = PrimitiveArray[DType.int64].allocate(n)
        var p = arr._typed_ptr_mut()
        for i in range(n):
            (p + i)[] = Scalar[DType.int64](cols[c][i])
        sb.add_field(Field(names[c], ArrowType.INT64, False))
        rbb.add_column(Column.from_primitive[DType.int64](arr^))
    return rbb.build(sb.build())


def _ab_batch_float() raises -> RecordBatch:
    """a * b spans across the sdk_cse_demo thresholds:
    a  = [ 5, 20, 25, 30, 50, 15]
    b  = [10, 10, 20, 30, 30, 20]
    ab = [50,200,500,900,1500,300]
    """
    var a: List[Float64] = [5.0, 20.0, 25.0, 30.0, 50.0, 15.0]
    var b: List[Float64] = [10.0, 10.0, 20.0, 30.0, 30.0, 20.0]
    var names: List[String] = [String("a"), String("b")]
    var cols: List[List[Float64]] = [a^, b^]
    return _build_float64_batch(names, cols)


# =============================================================================
# Headline repro — the exact sdk_cse_demo 3-conjunct shared-subtree shape.
# =============================================================================


def test_compound_lhs_three_conjunct_shared_subtree_eval_predicate() raises:
    """`a*b > 100 AND a*b < 1000 AND a*b != 500` — the sdk_cse_demo shape.

    ab   = [50, 200, 500, 900, 1500, 300]
    >100 = [ F,   T,   T,   T,    T,   T]
    <1000= [ T,   T,   T,   T,    F,   T]
    !=500= [ T,   T,   F,   T,    T,   T]
    AND  = [ F,   T,   F,   T,    F,   T]  -> 3 survivors (200, 900, 300)
    """
    var batch = _ab_batch_float()
    var pred = (
        ((col("a") * col("b")) > 100.0)
        & ((col("a") * col("b")) < 1000.0)
        & ((col("a") * col("b")) != 500.0)
    )
    var mask = _eval_predicate(pred, batch)
    assert_equal(mask.true_count(), 3, "3-conjunct a*b filter: expected 3 true")
    print("PASS: _eval_predicate a*b>100 AND a*b<1000 AND a*b!=500")


def test_compound_lhs_three_conjunct_shared_subtree_filter_narrowed() raises:
    """Same predicate through the OP_FILTER entry `evaluate_filter_narrowed`
    (flatten_and_conjuncts -> per-conjunct narrowing). This is the path the
    morsel executor actually drives, so it pins the end-to-end filter.
    """
    var batch = _ab_batch_float()
    var pred = (
        ((col("a") * col("b")) > 100.0)
        & ((col("a") * col("b")) < 1000.0)
        & ((col("a") * col("b")) != 500.0)
    )
    var sel = evaluate_filter_narrowed(batch, pred)
    assert_equal(sel.length(), 3, "narrowed a*b filter: expected 3 survivors")
    print("PASS: evaluate_filter_narrowed 3-conjunct shared a*b subtree")


# =============================================================================
# Minimal single-conjunct repro + generality (N != 3, RHS variants).
# =============================================================================


def test_compound_lhs_single_conjunct_vs_literal() raises:
    """`a*b > 100` alone — the minimal LHS-compound-vs-literal repro.

    ab = [50,200,500,900,1500,300]; >100 => [F,T,T,T,T,T] = 5.
    """
    var batch = _ab_batch_float()
    var pred = (col("a") * col("b")) > 100.0
    var mask = _eval_predicate(pred, batch)
    assert_equal(mask.true_count(), 5, "a*b > 100: expected 5 true")
    print("PASS: _eval_predicate a*b > 100 (single compound-LHS conjunct)")


def test_compound_lhs_vs_column() raises:
    """`a*b > c` — compound LHS, bare-column RHS.

    ab = [50,200,500,900,1500,300]; c = [60,150,500,1000,1400,300]
    a*b > c => [F, T, F, F, T, F] = 2.
    """
    var a: List[Float64] = [5.0, 20.0, 25.0, 30.0, 50.0, 15.0]
    var b: List[Float64] = [10.0, 10.0, 20.0, 30.0, 30.0, 20.0]
    var c: List[Float64] = [60.0, 150.0, 500.0, 1000.0, 1400.0, 300.0]
    var names: List[String] = [String("a"), String("b"), String("c")]
    var cols: List[List[Float64]] = [a^, b^, c^]
    var batch = _build_float64_batch(names, cols)
    var pred = (col("a") * col("b")) > col("c")
    var mask = _eval_predicate(pred, batch)
    assert_equal(mask.true_count(), 2, "a*b > c: expected 2 true")
    print("PASS: _eval_predicate a*b > c (compound LHS vs column)")


def test_compound_lhs_vs_compound_rhs() raises:
    """`a*b > c+d` — compound on BOTH sides.

    ab  = [50,200,500,900,1500,300]
    cd  = [60,199,900,800,2000,299]  (c+d)
    a*b > c+d => [F, T, F, T, F, T] = 3.
    """
    var a: List[Float64] = [5.0, 20.0, 25.0, 30.0, 50.0, 15.0]
    var b: List[Float64] = [10.0, 10.0, 20.0, 30.0, 30.0, 20.0]
    var c: List[Float64] = [30.0, 99.0, 400.0, 400.0, 1000.0, 149.0]
    var d: List[Float64] = [30.0, 100.0, 500.0, 400.0, 1000.0, 150.0]
    var names: List[String] = [
        String("a"), String("b"), String("c"), String("d")
    ]
    var cols: List[List[Float64]] = [a^, b^, c^, d^]
    var batch = _build_float64_batch(names, cols)
    var pred = (col("a") * col("b")) > (col("c") + col("d"))
    var mask = _eval_predicate(pred, batch)
    assert_equal(mask.true_count(), 3, "a*b > c+d: expected 3 true")
    print("PASS: _eval_predicate a*b > c+d (compound LHS vs compound RHS)")


def test_compound_lhs_int_with_numeric_promotion() raises:
    """`a*b > 250.5` with INT64 a,b and a FLOAT64 literal — exercises the
    computed-LHS path AND SQL numeric promotion (INT64 computed col vs FLOAT64
    broadcast).

    ab = [50,200,500,900,1500,300]; > 250.5 => [F,F,T,T,T,T] = 4.
    """
    var a: List[Int64] = [Int64(5), Int64(20), Int64(25), Int64(30), Int64(50), Int64(15)]
    var b: List[Int64] = [Int64(10), Int64(10), Int64(20), Int64(30), Int64(30), Int64(20)]
    var names: List[String] = [String("a"), String("b")]
    var cols: List[List[Int64]] = [a^, b^]
    var batch = _build_int64_batch(names, cols)
    var pred = (col("a") * col("b")) > 250.5
    var mask = _eval_predicate(pred, batch)
    assert_equal(mask.true_count(), 4, "INT a*b > 250.5: expected 4 true")
    print("PASS: _eval_predicate INT a*b > 250.5 (compound LHS + promotion)")


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    print("=== COMPUTED-LHS predicate fix ===")
    test_compound_lhs_three_conjunct_shared_subtree_eval_predicate()
    test_compound_lhs_three_conjunct_shared_subtree_filter_narrowed()
    test_compound_lhs_single_conjunct_vs_literal()
    test_compound_lhs_vs_column()
    test_compound_lhs_vs_compound_rhs()
    test_compound_lhs_int_with_numeric_promotion()
    print()
    print("All computed-LHS predicate tests PASS")
