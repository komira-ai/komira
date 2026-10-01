# =============================================================================
# lower_filter_predicate unit test
# =============================================================================
#
# Proves the
# SDK filter-expression -> ExprPool lowering preserves evaluation semantics:
# a predicate lowered through `lower_filter_predicate` and then resolved
# out of the pool must evaluate identically to feeding the raw SDK Expr
# through `_eval_predicate` directly.
#
# This is the same Expr object materially (ExprPool stores Exprs); the
# test guards against future lowering refactors (e.g. col_ref -> col_idx
# rewrites) that would silently break the ExprId round trip.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_compiler.expr_pool import ExprPool
from komira_core.plan.col_expr import col
from komira_compiler.compiler_eval_predicate import _eval_predicate, lower_filter_predicate
from komira_core.plan.expr import Expr


def _make_batch() raises -> RecordBatch:
    """Tiny 6-row FLOAT64 batch: val = [0.1, 0.5, 0.95, 0.99, 0.995, 1.0]."""
    var sb = SchemaBuilder()
    sb.add_field(Field("val", ArrowType.FLOAT64, False))
    var schema = sb.build()

    var buf = OwnedAlignedBuffer(6 * 8)
    var p = buf.view_typed_ro[DType.float64]()
    p[0] = 0.1
    p[1] = 0.5
    p[2] = 0.95
    p[3] = 0.99
    p[4] = 0.995
    p[5] = 1.0
    var arr = PrimitiveArray[DType.float64](buf^, 6, None, 0)
    var c0 = Column.from_primitive[DType.float64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, c0^)


def test_lower_roundtrip_eq_direct_eval() raises:
    """Register predicate via lowering; resolve; eval. Must match direct eval."""
    var pred_direct = col("val") > 0.99
    var pred_lowered = col("val") > 0.99

    var pool = ExprPool()
    var id = lower_filter_predicate(pool, pred_lowered^)
    assert_equal(Int(id.id), 0, "first ExprId should be 0")
    assert_equal(len(pool), 1, "pool length should be 1 after one lower")

    var batch_a = _make_batch()
    var batch_b = _make_batch()

    var mask_direct = _eval_predicate(pred_direct, batch_a)
    ref resolved = pool.resolve(id)
    var mask_pool = _eval_predicate(resolved, batch_b)

    assert_equal(
        mask_direct.true_count(),
        mask_pool.true_count(),
        "true_count must match between direct and pool-resolved eval",
    )
    # val > 0.99 -> {0.995, 1.0} -> 2 survivors.
    assert_equal(mask_direct.true_count(), 2, "expected 2 survivors for val>0.99")

    for i in range(6):
        assert_equal(
            mask_direct.get(i),
            mask_pool.get(i),
            "bit mismatch at index",
        )
    _ = batch_a^
    _ = batch_b^


def test_lower_two_predicates_distinct_ids() raises:
    """Registering two distinct predicates yields two distinct ExprIds."""
    var pool = ExprPool()
    var id0 = lower_filter_predicate(pool, col("val") > 0.99)
    var id1 = lower_filter_predicate(pool, col("val") < 0.5)
    assert_equal(Int(id0.id), 0, "first id")
    assert_equal(Int(id1.id), 1, "second id")
    assert_equal(len(pool), 2, "pool holds both predicates")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
