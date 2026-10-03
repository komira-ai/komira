# =============================================================================
# test_expr_leaf_bind.mojo — bind acceptance harness
# =============================================================================
#
# Validates the end-to-end bind chain:
#   1. Leaf single-bind happy path (name → idx populates via resolver).
#   2. Composite binop recursive bind (5-deep AND chain Q6 shape).
#   3. Bind miss: resolver doesn't carry the leaf's name → raise.
#   4. ArrowType mismatch: resolver has wrong ArrowType for leaf's expected
#      DType → raise (defensive validation).
#   5. Generic-context bind: drive `fn helper[E: ExprXBool](mut e, resolver)`
#      through a parametric helper (which sidesteps the parametric
#      trait-member-alias compiler-bug family).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType as PublicArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema
from komira_core.collections.batch_view import batch_view_over

from komira_udf.column_resolver import ColumnResolver
from komira_expr.expr_x import ExprXBool
from komira_eval.expr_x_conformers import (
    AndX,
    ColXBool,
    ColXF64,
    ColXI64,
    GtXF64,
    GtXI64,
    LeXF64,
    LeXI64,
    LitXBool,
    LitXF64,
    LitXI64,
)


# -----------------------------------------------------------------------------
# Fixture: 3-column batch matching Q6 shape (l_shipdate I64, l_discount F64,
# l_quantity F64).
# -----------------------------------------------------------------------------
def _build_q6_batch(n: Int) raises -> RecordBatch:
    """Q6-shape batch: l_shipdate (I64, days), l_discount (F64), l_quantity (F64)."""
    var sd: List[Scalar[DType.int64]] = []
    var dc: List[Scalar[DType.float64]] = []
    var qy: List[Scalar[DType.float64]] = []
    for i in range(n):
        sd.append(Scalar[DType.int64](Int64(i)))
        dc.append(Scalar[DType.float64](Float64(0.05 + Float64(i) * 0.01)))
        qy.append(Scalar[DType.float64](Float64(20.0 + Float64(i))))
    var sd_arr = PrimitiveArray[DType.int64].from_list(sd^)
    var dc_arr = PrimitiveArray[DType.float64].from_list(dc^)
    var qy_arr = PrimitiveArray[DType.float64].from_list(qy^)
    var schema = Schema.from_fields_3(
        Field("l_shipdate", DType.int64, True),
        Field("l_discount", DType.float64, True),
        Field("l_quantity", DType.float64, True),
    )
    var c0 = Column.from_primitive[DType.int64](sd_arr^)
    var c1 = Column.from_primitive[DType.float64](dc_arr^)
    var c2 = Column.from_primitive[DType.float64](qy_arr^)
    return RecordBatch.from_typed_columns_3(schema^, c0^, c1^, c2^)


def _q6_resolver() raises -> ColumnResolver:
    """ColumnResolver for the Q6-shape batch (l_shipdate I64, l_discount F64,
    l_quantity F64)."""
    var names = List[String]()
    names.append(String("l_shipdate"))
    names.append(String("l_discount"))
    names.append(String("l_quantity"))
    var indices = List[Int]()
    indices.append(0)
    indices.append(1)
    indices.append(2)
    var dts = List[DType]()
    dts.append(DType.int64)
    dts.append(DType.float64)
    dts.append(DType.float64)
    var ats = List[PublicArrowType]()
    ats.append(PublicArrowType.INT64)
    ats.append(PublicArrowType.FLOAT64)
    ats.append(PublicArrowType.FLOAT64)
    return ColumnResolver(names^, indices^, dts^, ats^)


# =============================================================================
# Test 1 — Single-leaf bind happy path
# =============================================================================
def test_single_leaf_bind_i64_happy() raises:
    """ColXI64["l_shipdate"] binds to idx 0 + reads correctly."""
    var resolver = _q6_resolver()
    var leaf = ColXI64["l_shipdate"]()
    leaf.bind(resolver)

    var batch = _build_q6_batch(5)
    var bv = batch_view_over(batch)
    # row 3 → 3
    assert_equal(leaf.eval_scalar_s(bv, 3), Int64(3))


def test_single_leaf_bind_f64_happy() raises:
    """ColXF64["l_discount"] binds to idx 1 + reads correctly."""
    var resolver = _q6_resolver()
    var leaf = ColXF64["l_discount"]()
    leaf.bind(resolver)

    var batch = _build_q6_batch(5)
    var bv = batch_view_over(batch)
    # row 0 → 0.05
    var got = leaf.eval_scalar_s(bv, 0)
    assert_true(got > 0.049 and got < 0.051)


# =============================================================================
# Test 2 — Composite recursive bind (5-deep AndX Q6 shape)
# =============================================================================
def test_composite_recursive_bind_q6_5deep() raises:
    """Q6 5-deep AndX: 5 binary preds AND'd together. Verifies recursive
    bind walks every leaf in the tree."""
    # Q6 pred shape:
    #   (l_shipdate >= 0) AND (l_shipdate < 365) AND
    #   (l_discount >= 0.05) AND (l_discount <= 0.07) AND (l_quantity < 24)
    comptime Pred = AndX[
        AndX[
            AndX[
                AndX[
                    GtXI64[ColXI64["l_shipdate"], LitXI64[Int64(-1)]],
                    LeXI64[ColXI64["l_shipdate"], LitXI64[Int64(364)]],
                ],
                GtXF64[ColXF64["l_discount"], LitXF64[Float64(0.049)]],
            ],
            LeXF64[ColXF64["l_discount"], LitXF64[Float64(0.071)]],
        ],
        LeXF64[ColXF64["l_quantity"], LitXF64[Float64(24.0)]],
    ]

    var resolver = _q6_resolver()
    var pred = Pred()
    pred.bind(resolver)

    var batch = _build_q6_batch(10)
    var bv = batch_view_over(batch)
    # row 0: l_shipdate=0 (>-1 T, <=364 T), l_discount=0.05 (>0.049 T, <=0.071 T),
    #        l_quantity=20 (<=24 T) → PASS
    assert_true(pred.eval_scalar_s(bv, 0))
    # row 5: l_shipdate=5, l_discount=0.10 (>0.071 F) → FAIL
    assert_false(pred.eval_scalar_s(bv, 5))


# =============================================================================
# Test 3 — Bind miss raises (helpful diagnostic)
# =============================================================================
def test_bind_miss_raises() raises:
    """ColXI64 binding to a resolver that doesn't carry the name should raise."""
    var resolver = _q6_resolver()
    var leaf = ColXI64["nonexistent_column"]()
    var raised = False
    try:
        leaf.bind(resolver)
    except:
        raised = True
    assert_true(raised, "bind to nonexistent column must raise")


# =============================================================================
# Test 4 — ArrowType mismatch raises (defensive validation)
# =============================================================================
def test_arrow_type_mismatch_raises() raises:
    """ColXF64["l_shipdate"] should raise — l_shipdate is INT64 in resolver
    but the leaf expects FLOAT64."""
    var resolver = _q6_resolver()
    var leaf = ColXF64["l_shipdate"]()  # expects FLOAT64
    var raised = False
    try:
        leaf.bind(resolver)  # resolver says l_shipdate is INT64
    except:
        raised = True
    assert_true(
        raised,
        "ColXF64 binding to INT64 column must raise (ArrowType mismatch)",
    )


# =============================================================================
# Test 5 — Generic-context bind (parametric helper)
# =============================================================================
def _generic_bind_helper[E: ExprXBool](mut e: E, resolver: ColumnResolver) raises:
    """Generic-context bind: parametric over any ExprXBool conformer.

    This is the load-bearing shape `materialize_typed` will use (Path B
    Step 5): the SDK builds a typed Stage[Pred, ...] and threads
    Pred through generic functions to bind. If this compiles + runs,
    the parametric trait-member-alias compiler-bug family is sidestepped
    at production scale.
    """
    e.bind(resolver)


def test_generic_context_bind_compiles_and_runs() raises:
    """Drive bind through a generic helper parametric on ExprXBool.

    Exercises 4 distinct ExprXBool conformer shapes through the same
    generic helper:
      - Leaf: ColXBool["c_bool"]
      - Binop on I64: GtXI64[ColXI64["l_shipdate"], LitXI64[100]]
      - Binop on F64: LeXF64[ColXF64["l_quantity"], LitXF64[24.0]]
      - Deep composite: AndX[GtXI64[...], LeXF64[...]]
    """
    # Make a resolver that includes a bool column too.
    var names = List[String]()
    names.append(String("l_shipdate"))
    names.append(String("l_discount"))
    names.append(String("l_quantity"))
    names.append(String("c_bool"))
    var indices = List[Int]()
    indices.append(0)
    indices.append(1)
    indices.append(2)
    indices.append(3)
    var dts = List[DType]()
    dts.append(DType.int64)
    dts.append(DType.float64)
    dts.append(DType.float64)
    dts.append(DType.bool)
    var ats = List[PublicArrowType]()
    ats.append(PublicArrowType.INT64)
    ats.append(PublicArrowType.FLOAT64)
    ats.append(PublicArrowType.FLOAT64)
    ats.append(PublicArrowType.BOOL)
    var resolver = ColumnResolver(names^, indices^, dts^, ats^)

    var leaf_bool = ColXBool["c_bool"]()
    _generic_bind_helper(leaf_bool, resolver)

    var pred_i64 = GtXI64[ColXI64["l_shipdate"], LitXI64[Int64(100)]]()
    _generic_bind_helper(pred_i64, resolver)

    var pred_f64 = LeXF64[ColXF64["l_quantity"], LitXF64[Float64(24.0)]]()
    _generic_bind_helper(pred_f64, resolver)

    var deep = AndX[
        GtXI64[ColXI64["l_shipdate"], LitXI64[Int64(50)]],
        LeXF64[ColXF64["l_quantity"], LitXF64[Float64(30.0)]],
    ]()
    _generic_bind_helper(deep, resolver)

    # Drive one through eval to verify bind populated leaves correctly.
    var batch = _build_q6_batch(10)
    var bv = batch_view_over(batch)
    # row 7: l_shipdate=7 > 50 = False
    assert_false(pred_i64.eval_scalar_s(bv, 7))


def main() raises:
    test_single_leaf_bind_i64_happy()
    print("test_single_leaf_bind_i64_happy PASSED")

    test_single_leaf_bind_f64_happy()
    print("test_single_leaf_bind_f64_happy PASSED")

    test_composite_recursive_bind_q6_5deep()
    print("test_composite_recursive_bind_q6_5deep PASSED")

    test_bind_miss_raises()
    print("test_bind_miss_raises PASSED")

    test_arrow_type_mismatch_raises()
    print("test_arrow_type_mismatch_raises PASSED")

    test_generic_context_bind_compiles_and_runs()
    print("test_generic_context_bind_compiles_and_runs PASSED")

    print("ALL 6 TESTS PASSED — bind acceptance harness")
