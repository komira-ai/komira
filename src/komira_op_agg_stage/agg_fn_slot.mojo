# =============================================================================
# agg_fn_slot.mojo — AggFnSlot[F, col], a user-defined AggFn as an AggColumn
# =============================================================================
#
# `AggSlot[A]` calls the aggregator's STATIC `init` / `finalize`. A user-defined
# `AggFn` has instance methods instead (its captures live on the instance), so
# `AggSlot[AggFnAgg[F, col]]` cannot be built: `AggFnAgg.init` and `.finalize`
# are compile-time refusals. `AggFnSlot[F, col]` holds the `F` instance and
# calls `self.udf.init()` / `.update_scalar` / `.merge` / `.finalize` itself.
#
# One input column (`col`, of `F.InputSchema.cols[0].dtype`). A NULL in it is
# skipped, and a group with no non-NULL input answers `finalize(init())`, as
# the engine's `komira_op_agg_state.AggFnAcc` route does.
# =============================================================================

from std.collections import List

from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.morsel_view import MorselView
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import ArrowType, RecordBatchBuilder

from komira_udf.agg_fn import AggFn
from komira_udf.schema_descriptor import dtag_to_dtype

from komira_op_agg_stage.agg_column import (
    AGG_INITIAL_CAPACITY,
    AggColumn,
    _agg_arrow_type,
)


struct AggFnSlot[F: AggFn, col: Int](AggColumn):
    """`AggColumn` over a user-defined `AggFn` `F` reading input column
    `col`: the `F` instance and one `F.State` per group."""

    var udf: Self.F
    var states: List[Self.F.State]

    def __init__(out self, var udf: Self.F):
        self.states = List[Self.F.State](capacity=AGG_INITIAL_CAPACITY)
        self.udf = udf^

    def __init__(out self):
        """A compile-time refusal: an `F` cannot be built without its
        captures, so a field-less aggregate factory cannot carry it."""
        comptime assert False, (
            "AggFnSlot needs its AggFn instance; build it with"
            " agg_fn_slot[F, col](F(...))."
        )

    @staticmethod
    def make() -> Self:
        """A compile-time refusal (see the no-argument `__init__`)."""
        comptime assert False, (
            "AggFnSlot needs its AggFn instance; build it with"
            " agg_fn_slot[F, col](F(...))."
        )

    @always_inline
    def push_identity_group(mut self):
        self.states.append(self.udf.init())

    @always_inline
    def update_row[
        bo: Origin[mut=False]
    ](mut self, slot: Int, batch: BatchView[bo], row_idx: Int):
        if batch.col_is_null(Self.col, row_idx):
            return
        comptime dt0 = dtag_to_dtype(Self.F.InputSchema.cols[0].dtype)
        var v = batch.col_scalar_nonraising[dt0](Self.col, row_idx)
        self.udf.update_scalar(self.states[slot], v)

    @always_inline
    def update_row_mv[
        V: MorselView
    ](mut self, slot: Int, view: V, row_idx: Int):
        if view.col_is_null(Self.col, row_idx):
            return
        comptime dt0 = dtag_to_dtype(Self.F.InputSchema.cols[0].dtype)
        var v = view.col_scalar_nonraising[dt0](Self.col, row_idx)
        self.udf.update_scalar(self.states[slot], v)

    @always_inline
    def combine_into(mut self, into_slot: Int, var partial: Self):
        var merged = self.udf.merge(
            self.states[into_slot], partial.states[into_slot].copy()
        )
        self.states[into_slot] = merged^

    @always_inline
    def combine_at(mut self, into_slot: Int, other_slot: Int, other: Self):
        var merged = self.udf.merge(
            self.states[into_slot], other.states[other_slot].copy()
        )
        self.states[into_slot] = merged^

    @always_inline
    def finalize_f64(self, slot: Int) -> Float64:
        return self.udf.finalize(self.states[slot]).cast[DType.float64]()

    @always_inline
    def out_arrow_type(self) -> ArrowType:
        return _agg_arrow_type[Self.F.OutType]()

    def emit_column(self, slots: List[Int], mut rb: RecordBatchBuilder) raises:
        var out_vals = List[Scalar[Self.F.OutType]](capacity=len(slots))
        for si in range(len(slots)):
            out_vals.append(self.udf.finalize(self.states[slots[si]]))
        var arr = PrimitiveArray[Self.F.OutType].from_list(out_vals)
        rb.add_column(Column.from_primitive[Self.F.OutType](arr^))

    def emit_empty_row(self, mut rb: RecordBatchBuilder) raises:
        var out_vals = List[Scalar[Self.F.OutType]](capacity=1)
        out_vals.append(self.udf.finalize(self.udf.init()))
        var arr = PrimitiveArray[Self.F.OutType].from_list(out_vals)
        rb.add_column(Column.from_primitive[Self.F.OutType](arr^))

    @always_inline
    def reset(mut self):
        self.states.clear()


@always_inline
def agg_fn_slot[F: AggFn, col: Int](var udf: F) -> AggFnSlot[F, col]:
    """An `AggFnSlot[F, col]` over a constructed `F`."""
    return AggFnSlot[F, col](udf^)
