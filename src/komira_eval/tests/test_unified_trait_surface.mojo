# =============================================================================
# Unit tests for the trait surface
# =============================================================================
#
# Acceptance checks:
#   - One typed `ExprI64U` conformer compiles end-to-end and its
#     `eval_column` default-impl path takes the straight-line column-
#     write shape (shape-disasm check — verified via compile-only
#     pass; disasm verification is offline and not gated in CI).
#   - One typed `AggI64U` conformer compiles with the `mut acc:
#     I64Accumulator` parameter shape.
#
# Coverage:
#   1. `EvalI64Chunk[W]` / `EvalBoolChunk[W]` / `EvalDecimal128Chunk[W]`
#      can be constructed and field-accessed (uniform shape).
#   2. `ExprI64_ColRead` conformer compiles + eval[W] / eval_column
#      forward properly; the trait body is exercised via a
#      parametric helper `_invoke_eval_column[E: ExprI64U]`.
#   3. `ExprBool_AlwaysTrue` conformer compiles + run_filter_self
#      writes the expected 0xFF mask bytes through ByteView.
#   4. `AggI64_Sum` conformer compiles + run_agg_combine updates a
#      mutable accumulator via the `mut acc: I64Accumulator` shape.
#   5. Free-function defaults (`_default_run_filter_self_unified` +
#      `_default_eval_column_i64`) compile and forward correctly.
#
# This file is the trait-surface acceptance harness; it does NOT exercise
# the production filter kernel (filter_apply).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.collections import BatchView, ColView, batch_view_over
from komira_core.collections.byte_view import ByteView
from komira_eval import (
    EvalBoolChunk,
    EvalI64Chunk,
    EvalDecimal128Chunk,
    ExprBoolU,
    ExprI64U,
    AggI64U,
    I64Accumulator,
    _default_run_filter_self_unified,
    _default_eval_column_i64,
)


# =============================================================================
# Sample conformers
# =============================================================================


struct ExprI64_ColRead(ExprI64U):
    """Sample ExprI64U conformer — reads column 0 as Int64.

    Carries the column index as comptime state (zero-field shape here;
    planner-emitted conformers are parameterized over the
    column index). The `eval[W]` body reads W lanes from column 0;
    `eval_column` forwards to the free-function default impl.
    """

    def __init__(out self):
        pass

    def eval[W: Int](
        self,
        batch: BatchView,
        i: Int,
    ) raises -> EvalI64Chunk[W]:
        var col = batch.col_i64(0)
        return EvalI64Chunk[W](
            values=col.load[W](i),
            validity=col.validity_load[W](i),
        )

    def eval_column[
        out_origin: Origin[mut=True],
    ](
        self,
        batch: BatchView,
        col_out: ByteView[out_origin],
    ) raises:
        # Forward to the free-function default — shape-disasm
        # gate: this body collapses to a single tail call once
        # @always_inline fires.
        _default_eval_column_i64[ExprI64_ColRead, out_origin](self, batch, col_out)


struct ExprBool_AlwaysTrue(ExprBoolU):
    """Sample ExprBoolU conformer — constant TRUE.

    Returns `eval[W]` = all-True splat with all-True validity (no
    nulls — non-nullable comptime specialization). `run_filter_self`
    forwards to the free-function default which writes 0xFF bytes.
    """

    def __init__(out self):
        pass

    def eval[W: Int](
        self,
        batch: BatchView,
        i: Int,
    ) raises -> EvalBoolChunk[W]:
        return EvalBoolChunk[W](
            values=SIMD[DType.bool, W](fill=True),
            validity=SIMD[DType.bool, W](fill=True),
        )

    def run_filter_self[
        mask_origin: Origin[mut=True],
        validity_origin: Origin[mut=True],
    ](
        self,
        batch: BatchView,
        mask_out: ByteView[mask_origin],
        validity_out: Optional[ByteView[validity_origin]],
    ) raises:
        _default_run_filter_self_unified[
            ExprBool_AlwaysTrue, mask_origin, validity_origin
        ](self, batch, mask_out, validity_out)


struct AggI64_Sum(AggI64U):
    """Sample AggI64U conformer — sum-only over column 0.

    Exercises the `mut acc: I64Accumulator` parameter shape.
    Production conformers (Sum / Count / Avg / Min / Max)
    live elsewhere.
    """

    def __init__(out self):
        pass

    def run_agg_combine(
        self,
        batch: BatchView,
        mut acc: I64Accumulator,
    ) raises:
        var n = batch.n_rows()
        var col = batch.col_i64(0)
        var i = 0
        # Scalar accumulator update — this test only validates the trait shape compiles
        # and the `mut acc` parameter is updateable.
        while i < n:
            var v = col.load[1](i)
            acc.sum = acc.sum + Int64(v[0])
            acc.count = acc.count + 1
            i += 1


# =============================================================================
# Builders
# =============================================================================


def _build_int64_batch(n: Int) raises -> RecordBatch:
    """`n`-row Int64 batch with values [0, 1, ..., n-1]."""
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](Int64(i)))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var schema = Schema.from_fields_1(Field("x", DType.int64, True))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


# =============================================================================
# Tests
# =============================================================================


def test_eval_chunk_uniform_shape() raises:
    """EvalXChunk[W] family has uniform (values, validity) field
    shape across Bool / I64 / Decimal128"""
    var bc = EvalBoolChunk[4](
        values=SIMD[DType.bool, 4](fill=True),
        validity=SIMD[DType.bool, 4](fill=True),
    )
    var ic = EvalI64Chunk[4](
        values=SIMD[DType.int64, 4](Int64(7)),
        validity=SIMD[DType.bool, 4](fill=True),
    )
    var dc = EvalDecimal128Chunk[1](
        values=SIMD[DType.int128, 1](Int64(42)),
        validity=SIMD[DType.bool, 1](fill=True),
    )
    assert_equal(Bool(bc.values[0]), True)
    assert_equal(Bool(bc.validity[0]), True)
    assert_equal(Int(ic.values[0]), 7)
    assert_equal(Int(ic.validity[0]), 1)  # True
    assert_equal(Int(dc.validity[0]), 1)


def test_expr_i64_col_read_eval_w() raises:
    """ExprI64_ColRead conformer compiles + eval[W=4] returns the
    expected column values."""
    var batch = _build_int64_batch(8)
    var bv = batch_view_over(batch)
    var expr = ExprI64_ColRead()
    var chunk = expr.eval[4](bv, 0)
    assert_equal(Int(chunk.values[0]), 0)
    assert_equal(Int(chunk.values[1]), 1)
    assert_equal(Int(chunk.values[2]), 2)
    assert_equal(Int(chunk.values[3]), 3)
    # Non-nullable column → validity all True.
    assert_equal(Bool(chunk.validity[0]), True)


def test_expr_i64_col_read_eval_column() raises:
    """ExprI64_ColRead.eval_column writes through the ByteView output
    buffer. The default impl writes zeros (placeholder); the
    test verifies the trait shape + forwarding compiles end-to-end."""
    var batch = _build_int64_batch(4)
    var bv = batch_view_over(batch)
    var expr = ExprI64_ColRead()
    var buf = OwnedAlignedBuffer(4 * 8)  # 4 elements * 8 bytes/i64
    buf.set_length(4 * 8)

    var view = buf.view_mut()
    expr.eval_column(bv, view)
    # The default writes Int64(0) per element — see
    # _default_eval_column_i64 docstring. A full implementation writes the
    # real value; this assertion exists to lock the trait-method
    # forwarding shape, NOT the per-element values.
    assert_equal(Int(view.read_i64_le_at(0)), 0)
    assert_equal(Int(view.read_i64_le_at(8)), 0)
    assert_equal(Int(view.read_i64_le_at(16)), 0)
    assert_equal(Int(view.read_i64_le_at(24)), 0)


def test_expr_bool_always_true_run_filter_self() raises:
    """ExprBool_AlwaysTrue.run_filter_self writes 0xFF bytes through
    the default impl."""
    var batch = _build_int64_batch(16)  # 16 rows → 2 mask bytes
    var bv = batch_view_over(batch)
    var expr = ExprBool_AlwaysTrue()
    var mask_buf = OwnedAlignedBuffer(2)
    mask_buf.set_length(2)

    var mask_view = mask_buf.view_mut()
    # Pre-fill 0x00 so we can verify the kernel actually wrote 0xFF.
    mask_view.write_u8_at(0, UInt8(0))
    mask_view.write_u8_at(1, UInt8(0))
    # Pass validity_out=None via an explicit Optional construction
    # on a separate (unused) buffer so the validity_origin parameter
    # is inferred independently of mask_view's origin — avoids the
    # Mojo 1.0.0b1 exclusivity check ("allows writing a memory
    # location previously writable through another aliased
    # argument").
    var dummy_buf = OwnedAlignedBuffer(1)
    dummy_buf.set_length(1)

    var dummy_view = dummy_buf.view_mut()
    var validity_none = Optional[ByteView[dummy_view.origin]](None)
    expr.run_filter_self(bv, mask_view, validity_none)
    assert_equal(Int(mask_view.read_u8_at(0)), 0xFF)
    assert_equal(Int(mask_view.read_u8_at(1)), 0xFF)
    _ = dummy_buf^


def test_agg_i64_sum_mut_acc() raises:
    """AggI64_Sum.run_agg_combine compiles with the `mut acc:
    I64Accumulator` parameter shape and accumulates correctly."""
    var batch = _build_int64_batch(5)  # 0+1+2+3+4 = 10
    var bv = batch_view_over(batch)
    var agg = AggI64_Sum()
    var acc = I64Accumulator(sum=Int64(0), count=Int64(0))
    agg.run_agg_combine(bv, acc)
    assert_equal(Int(acc.sum), 10)
    assert_equal(Int(acc.count), 5)


def test_agg_i64_sum_two_batches_compound() raises:
    """Two consecutive run_agg_combine calls compound into the same
    accumulator (the `mut acc` shape allows the kernel to thread a
    long-lived accumulator across batches)."""
    var batch1 = _build_int64_batch(3)  # 0+1+2 = 3
    var batch2 = _build_int64_batch(4)  # 0+1+2+3 = 6
    var bv1 = batch_view_over(batch1)
    var bv2 = batch_view_over(batch2)
    var agg = AggI64_Sum()
    var acc = I64Accumulator(sum=Int64(0), count=Int64(0))
    agg.run_agg_combine(bv1, acc)
    agg.run_agg_combine(bv2, acc)
    assert_equal(Int(acc.sum), 9)
    assert_equal(Int(acc.count), 7)


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
