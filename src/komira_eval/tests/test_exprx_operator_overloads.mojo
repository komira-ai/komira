# =============================================================================
# test_exprx_operator_overloads.mojo — operator overloads on ExprX conformers
# =============================================================================
#
# Validates the operator-overload substrate on engine ExprX
# conformers (`komira_eval.expr_x_conformers`), so callers can write
# `col_x("a") > Int64(5)` directly against engine ExprX leaves without
# falling back to explicit `GtXI64[...]` instantiation.
#
# Exercises four canonical shapes end-to-end:
#   (1) ColXI64 __gt__  → GtXI64[ColXI64, LitXI64]
#   (2) ColXF64 __lt__  → LtXF64[ColXF64, LitXF64]
#   (3) AndX chain      → (Pred1) & (Pred2) → AndX[Pred1, Pred2]
#   (4) ColXBool __or__ → OrX[ColXBool, ColXBool]
#
# Reference for fixture / resolver shape:
#   test_expr_leaf_bind.mojo.
#
# Operator-overload contract: each leaf / binop returns its corresponding
# binop conformer. Since engine ExprX leaves don't auto-promote raw scalars
# to LitX literals (Mojo `__gt__` taking a generic `R: ExprXI64` means
# `5` doesn't coerce), tests explicitly construct `LitXI64[Int64(5)]()`
# as the RHS: the operator overloads accept ANY `ExprXI64` conformer as
# RHS, not raw scalars.
#
# Acceptance gates:
#   (a) The operator overloads compile.
#   (b) All 4 tests PASS (constructed types eval correctly per row).
#   (c) Chained `&` / `|` syntax matches AndX / OrX explicit construction.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType as PublicArrowType
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.collections.batch_view import batch_view_over

from komira_udf.column_resolver import ColumnResolver
from komira_eval.expr_x_conformers import (
    AndX,
    ColXBool,
    ColXF64,
    ColXI64,
    GtXI64,
    LtXF64,
    OrX,
    LitXBool,
    LitXF64,
    LitXI64,
)


# -----------------------------------------------------------------------------
# Fixture: 4-column batch (a: I64, b: F64, c: Bool, d: Bool).
# Same Q6-style shape as test_expr_leaf_bind, with an added bool column for
# the OR test.
# -----------------------------------------------------------------------------
def _build_test_batch(n: Int) raises -> RecordBatch:
    """4-col batch: a=I64 (i), b=F64 (i*0.5), c=Bool (i%2==0), d=Bool (i%3==0).

    Bool columns are bit-packed (BoolColView.load_bit reads bits, not bytes),
    so we use BooleanArray.allocate + set rather than PrimitiveArray.from_list.
    """
    var a: List[Scalar[DType.int64]] = []
    var b: List[Scalar[DType.float64]] = []
    for i in range(n):
        a.append(Scalar[DType.int64](Int64(i)))
        b.append(Scalar[DType.float64](Float64(i) * 0.5))
    var a_arr = PrimitiveArray[DType.int64].from_list(a^)
    var b_arr = PrimitiveArray[DType.float64].from_list(b^)
    # Bit-packed bool arrays — PrimitiveArray.from_list[DType.bool] would
    # store one byte per bool, mismatching BoolColView's bit-packed reader.
    var c_arr = BooleanArray.allocate(n)
    var d_arr = BooleanArray.allocate(n)
    for i in range(n):
        c_arr.set(i, i % 2 == 0)
        d_arr.set(i, i % 3 == 0)
    # 4-col schema via SchemaBuilder (Schema.from_fields_4 doesn't exist;
    # only 1/2/3-arity factories are provided).
    var sb = SchemaBuilder()
    sb.add_field(Field("a", DType.int64, True))
    sb.add_field(Field("b", DType.float64, True))
    sb.add_field(Field("c", DType.bool, True))
    sb.add_field(Field("d", DType.bool, True))
    var schema = sb.build()
    var c0 = Column.from_primitive[DType.int64](a_arr^)
    var c1 = Column.from_primitive[DType.float64](b_arr^)
    var c2 = Column.from_boolean(c_arr^)
    var c3 = Column.from_boolean(d_arr^)
    return RecordBatch.from_typed_columns_4(schema^, c0^, c1^, c2^, c3^)


def _test_resolver() raises -> ColumnResolver:
    """ColumnResolver mirroring the 4-col test batch."""
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    names.append(String("c"))
    names.append(String("d"))
    var indices = List[Int]()
    indices.append(0)
    indices.append(1)
    indices.append(2)
    indices.append(3)
    var dts = List[DType]()
    dts.append(DType.int64)
    dts.append(DType.float64)
    dts.append(DType.bool)
    dts.append(DType.bool)
    var ats = List[PublicArrowType]()
    ats.append(PublicArrowType.INT64)
    ats.append(PublicArrowType.FLOAT64)
    ats.append(PublicArrowType.BOOL)
    ats.append(PublicArrowType.BOOL)
    return ColumnResolver(names^, indices^, dts^, ats^)


# =============================================================================
# Test 1 — ColXI64.__gt__ returns GtXI64
# =============================================================================
def test_col_xi64_gt_returns_gtxi64() raises:
    """`col > lit` over I64 — verify operator returns GtXI64 by construction
    + evaluation matches explicit GtXI64 instantiation."""
    var col = ColXI64["a"]()
    var lit = LitXI64[Int64(5)]()
    # Operator-form result type is GtXI64[ColXI64["a"], LitXI64[5]].
    var via_op = col > lit
    # Explicit form for parity check.
    var via_explicit = GtXI64[ColXI64["a"], LitXI64[Int64(5)]]()

    var resolver = _test_resolver()
    via_op.bind(resolver)
    via_explicit.bind(resolver)

    var batch = _build_test_batch(10)
    var bv = batch_view_over(batch)
    # rows 0..5 should all eval False (a <= 5); rows 6..9 should be True.
    for i in range(10):
        var expected = (Int64(i) > Int64(5))
        assert_equal(via_op.eval_scalar_s(bv, i), expected)
        assert_equal(via_explicit.eval_scalar_s(bv, i), expected)


# =============================================================================
# Test 2 — ColXF64.__lt__ returns LtXF64
# =============================================================================
def test_col_xf64_lt_returns_ltxf64() raises:
    """`col < lit` over F64 — verify operator returns LtXF64."""
    var col = ColXF64["b"]()
    var lit = LitXF64[Float64(2.0)]()
    var via_op = col < lit
    var via_explicit = LtXF64[ColXF64["b"], LitXF64[Float64(2.0)]]()

    var resolver = _test_resolver()
    via_op.bind(resolver)
    via_explicit.bind(resolver)

    var batch = _build_test_batch(10)
    var bv = batch_view_over(batch)
    # b[i] = i*0.5 — should be < 2.0 for i in [0,1,2,3] (b=0,0.5,1.0,1.5),
    # but b[4]=2.0 is NOT < 2.0.
    for i in range(10):
        var expected = (Float64(i) * 0.5 < 2.0)
        assert_equal(via_op.eval_scalar_s(bv, i), expected)
        assert_equal(via_explicit.eval_scalar_s(bv, i), expected)


# =============================================================================
# Test 3 — Chained AND: `(a > 5) & (b < 2.0)`
# =============================================================================
def test_chained_and_overload() raises:
    """Chained AND via `&` operator — exercises AndX overload on a binop
    output type."""
    var pred_i = ColXI64["a"]() > LitXI64[Int64(5)]()
    var pred_f = ColXF64["b"]() < LitXF64[Float64(2.0)]()
    var via_op = pred_i & pred_f
    var via_explicit = AndX[
        GtXI64[ColXI64["a"], LitXI64[Int64(5)]],
        LtXF64[ColXF64["b"], LitXF64[Float64(2.0)]],
    ]()

    var resolver = _test_resolver()
    via_op.bind(resolver)
    via_explicit.bind(resolver)

    var batch = _build_test_batch(10)
    var bv = batch_view_over(batch)
    # row i: (a=i > 5) AND (b=i*0.5 < 2.0).
    # i=0..3: a<=5 FAIL    → False
    # i=4:    a=4 <=5 FAIL → False
    # i=5:    a=5, not >5  → False
    # i=6:    a=6 > 5 TRUE, b=3.0 < 2.0 FALSE → False
    # No row satisfies both — all should be False.
    for i in range(10):
        var i64_pass = (Int64(i) > Int64(5))
        var f64_pass = (Float64(i) * 0.5 < 2.0)
        var expected = i64_pass and f64_pass
        assert_equal(via_op.eval_scalar_s(bv, i), expected)
        assert_equal(via_explicit.eval_scalar_s(bv, i), expected)


# =============================================================================
# Test 4 — Bool OR: `col_c | col_d`
# =============================================================================
def test_col_xbool_or_overload() raises:
    """`col_bool | col_bool` — exercises OrX overload on a ColXBool."""
    var lhs = ColXBool["c"]()
    var rhs = ColXBool["d"]()
    var via_op = lhs | rhs
    var via_explicit = OrX[ColXBool["c"], ColXBool["d"]]()

    var resolver = _test_resolver()
    via_op.bind(resolver)
    via_explicit.bind(resolver)

    var batch = _build_test_batch(10)
    var bv = batch_view_over(batch)
    # c[i] = (i%2==0), d[i] = (i%3==0).
    for i in range(10):
        var expected = (i % 2 == 0) or (i % 3 == 0)
        assert_equal(via_op.eval_scalar_s(bv, i), expected)
        assert_equal(via_explicit.eval_scalar_s(bv, i), expected)


# =============================================================================
# Test 5 — Triple-chain AND: `(a > 0) & (a < 8) & (b < 2.5)`
# =============================================================================
def test_triple_chain_and_overload() raises:
    """3-way AND `(a > 0) & (a < 8) & (b < 2.5)` exercises chaining AndX
    over an existing AndX (verifies AndX itself has __and__ overload)."""
    var p1 = ColXI64["a"]() > LitXI64[Int64(0)]()
    var p2 = ColXI64["a"]() < LitXI64[Int64(8)]()
    var p3 = ColXF64["b"]() < LitXF64[Float64(2.5)]()
    # (p1 & p2) & p3 — second `&` is on AndX itself.
    var chained = (p1 & p2) & p3

    var resolver = _test_resolver()
    chained.bind(resolver)

    var batch = _build_test_batch(10)
    var bv = batch_view_over(batch)
    for i in range(10):
        var c1 = (Int64(i) > Int64(0))
        var c2 = (Int64(i) < Int64(8))
        var c3 = (Float64(i) * 0.5 < 2.5)
        var expected = c1 and c2 and c3
        assert_equal(chained.eval_scalar_s(bv, i), expected)


def main() raises:
    test_col_xi64_gt_returns_gtxi64()
    print("test_col_xi64_gt_returns_gtxi64 PASSED")

    test_col_xf64_lt_returns_ltxf64()
    print("test_col_xf64_lt_returns_ltxf64 PASSED")

    test_chained_and_overload()
    print("test_chained_and_overload PASSED")

    test_col_xbool_or_overload()
    print("test_col_xbool_or_overload PASSED")

    test_triple_chain_and_overload()
    print("test_triple_chain_and_overload PASSED")

    print(
        "ALL 5 TESTS PASSED — ExprX operator overloads"
    )
