# parquet_source_options and parquet_source_emit, as pure functions:
#   - the adaptive stride: 1 below 8 row groups per worker, then
#     ceil(n / 2w) capped at 32;
#   - the selection-pipeline deferral: off, all pass, at and below half;
#   - partition ids and their inverse;
#   - the numeric-dictionary count shape: each comparison with an integer
#     literal, and the shapes refused;
#   - lowered hooks to capabilities;
#   - split_and_stash_first: sub-morsel ids, partition ids and origin hints,
#     the rest parked in reverse, popped in order; emit_outcome cuts a batch
#     but never a count-only one.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_atomic_alias import AtomicI64
from komira_collections.slab import Slab
from komira_morsel.morsel import Morsel
from komira_morsel.source_hooks import LoweredSourceHooks
from komira_parquet_scan.parquet_source_emit import ClaimOutcome, emit_outcome, split_and_stash_first
from komira_parquet_scan.parquet_source_options import (
    SUB_SLOT_STRIDE,
    adaptive_stride,
    dict_count_comparison_op,
    lowered_hooks_to_source_caps,
    rg_index_of_partition_id,
    rg_partition_id,
    sel_pipe_should_defer,
)
from komira_plan_expr.expr import BIN_ADD, BIN_AND, BIN_EQ, BIN_GE, BIN_LT, Expr
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.scalar_value import ScalarValue


def test_the_adaptive_stride() raises:
    assert_equal(Int(adaptive_stride(79, 10)), 1)
    assert_equal(Int(adaptive_stride(80, 10)), 4)
    assert_equal(Int(adaptive_stride(101, 10)), 6)
    assert_equal(Int(adaptive_stride(100_000, 10)), 32)
    assert_equal(Int(adaptive_stride(0, 1)), 1)


def test_the_selection_pipeline_deferral() raises:
    assert_false(sel_pipe_should_defer(False, 90, 100))
    assert_false(sel_pipe_should_defer(True, 100, 100))
    assert_true(sel_pipe_should_defer(True, 50, 100))
    assert_false(sel_pipe_should_defer(True, 49, 100))


def test_partition_ids() raises:
    assert_equal(rg_partition_id(3), 3 * SUB_SLOT_STRIDE)
    assert_equal(rg_index_of_partition_id(rg_partition_id(7) + 5), 7)


def _cmp(op: UInt8, var rhs: Expr) -> Expr:
    return Expr.binary(op, Expr.col_ref("x"), rhs^)


def test_the_dictionary_count_shape() raises:
    assert_equal(Int(dict_count_comparison_op(_cmp(BIN_LT, Expr.literal(ScalarValue.from_int(3))))), Int(BIN_LT))
    assert_equal(Int(dict_count_comparison_op(_cmp(BIN_GE, Expr.literal(ScalarValue.from_int(3))))), Int(BIN_GE))
    assert_equal(Int(dict_count_comparison_op(_cmp(BIN_EQ, Expr.literal(ScalarValue.from_string("a"))))), 0xFF)
    assert_equal(Int(dict_count_comparison_op(_cmp(BIN_EQ, Expr.col_ref("y")))), 0xFF)
    assert_equal(Int(dict_count_comparison_op(_cmp(BIN_ADD, Expr.literal(ScalarValue.from_int(3))))), 0xFF)
    var lit_left = Expr.binary(BIN_LT, Expr.literal(ScalarValue.from_int(3)), Expr.col_ref("x"))
    assert_equal(Int(dict_count_comparison_op(lit_left)), 0xFF)
    var conj = Expr.binary(BIN_AND, _cmp(BIN_LT, Expr.literal(ScalarValue.from_int(3))), Expr.col_ref("b"))
    assert_equal(Int(dict_count_comparison_op(conj)), 0xFF)
    assert_equal(Int(dict_count_comparison_op(Expr.col_ref("x"))), 0xFF)


def test_hooks_to_capabilities() raises:
    var hooks = LoweredSourceHooks()
    var empty = lowered_hooks_to_source_caps(hooks)
    assert_false(empty.decode_filter_stages.__bool__())
    assert_false(empty.bypass_set.__bool__())
    hooks.decode_filter.append(ExprId(UInt32(3)))
    hooks.bypass_columns.append(2)
    hooks.count_only = True
    hooks.morsel_rows = 1024
    hooks.dynamic_filter_key_name = "k"
    var caps = lowered_hooks_to_source_caps(hooks)
    assert_equal(len(caps.decode_filter_stages.value()), 1)
    assert_true(caps.bypass_set.__bool__())
    assert_true(caps.count_only)
    assert_equal(caps.morsel_rows, 1024)
    assert_equal(caps.dynamic_filter_key_name, "k")
    assert_true(caps.fused_eval_enabled)
    assert_false(caps.row_window_active)


def _batch(n: Int) raises -> RecordBatch:
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](i))
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, False))
    return RecordBatch.from_typed_columns_1(
        sb.build(), Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals^))
    )


def test_split_and_stash_first() raises:
    var counter = AtomicI64(10)
    var pending = Slab[Morsel]()
    var first = split_and_stash_first(_batch(10), 4, 2, counter, pending, 6)
    assert_equal(first.batch.num_rows(), 4)
    assert_equal(first.partition_id, 2 * SUB_SLOT_STRIDE + 6)
    assert_equal(first.origin_hint, 6)
    assert_equal(len(pending), 2)
    var popped = pending.pop()
    var second = popped.take()
    assert_equal(second.origin_hint, 7)
    assert_equal(Int(second.batch.column_at(0).as_primitive[DType.int64]().get(0)), 4)
    var popped3 = pending.pop()
    var third = popped3.take()
    assert_equal(third.origin_hint, 8)
    assert_equal(third.batch.num_rows(), 2)
    assert_equal(Int(counter.load()), 13)


def test_emit_outcome_cuts_batches_not_counts() raises:
    var counter = AtomicI64(0)
    var pending = Slab[Morsel]()
    var m = emit_outcome(ClaimOutcome.emit(_batch(9)), 4, 1, counter, pending)
    assert_equal(m.batch.num_rows(), 4)
    assert_equal(len(pending), 2)
    var pending2 = Slab[Morsel]()
    var c = emit_outcome(ClaimOutcome.emit_count(9), 4, 1, counter, pending2)
    assert_equal(c.batch.num_rows(), 9)
    assert_equal(len(pending2), 0)
    assert_equal(c.partition_id, SUB_SLOT_STRIDE)
    var whole = emit_outcome(ClaimOutcome.emit(_batch(3)), 0, 2, counter, pending2)
    assert_equal(whole.batch.num_rows(), 3)
    assert_equal(whole.origin_hint, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
