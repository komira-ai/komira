# =============================================================================
# agg_column.mojo — the aggregate half of the stage hash aggregation
# =============================================================================
#
# `AggColumn` is one aggregate of `HashAggTable[KB, *Aggs]`: an aggregator plus
# one state per group, indexed by the key block's dense group index. The table
# fans over its aggregate pack with `comptime for`, calling only `AggColumn`
# methods. Conformers: `AggSlot[A]` over a `komira_agg.Aggregator` (here) and
# `AggFnSlot[F, col]` over a user-defined `AggFn` (`agg_fn_slot`).
#
# SQL semantics, as DuckDB answers them:
#   * NULL inputs. `AggSlot` asks `A.input_is_null` before every fold; a NULL
#     row goes to `A.update_null` (a no-op except for FIRST / LAST, which pick
#     the NULL) and does not count as a value of its group.
#   * Empty groups. A group that folded no non-NULL value answers NULL when
#     `A.EMPTY_IS_NULL` (SUM, MIN, MAX, AVG, ...), else `finalize(init())`
#     (COUNT and COUNT(DISTINCT) answer 0). `A.result_is_null` adds the groups
#     whose picked value was NULL (FIRST / LAST).
#   * Integer SUM. The exact 128-bit total is narrowed to the INT64 column at
#     emission; a total outside INT64 raises `int_sum_overflow_message`
#     (`refuse_unrepresentable`, which every drain calls before it emits).
#   * MIN / MAX over floats order NaN above +inf; that is the aggregator's fold
#     (`komira_udf.float_quotient_order`), not this file's.
# =============================================================================

from std.collections import Optional, List
from std.memory import Pointer
from std.os import abort
from std.sys import size_of

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from komira_arrow.band_view import BandView
from komira_arrow.batch_view import BatchView, scalar_arrow_type
from komira_arrow.column import Column
from komira_arrow.morsel_view import MorselView
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import ArrowType, Field, RecordBatchBuilder

from komira_agg.aggregator import Aggregator
from komira_operator_api.emit_at_offset_target import (
    _EmitColDesc,
    _EmitColTarget,
    EMIT_KIND_FIXED,
    EMIT_KIND_INELIGIBLE,
)
from komira_op_agg_distinct.cd_radix_grouped import (
    radix_distinct_count_grouped,
)
from komira_op_agg_distinct.median_parallel_drain import (
    parallel_group_finalize_column,
)
from komira_op_agg_state.int_sum_overflow import int_sum_overflow_message


comptime AGG_INITIAL_CAPACITY: Int = 16
"""The first reserve of each per-group state list; it grows past this."""


@always_inline
def _agg_arrow_type[D: DType]() -> ArrowType:
    """The Arrow type of an aggregate output DType (an unhandled DType is a
    compile error, never a silent fallback)."""
    return scalar_arrow_type[D]()


trait AggColumn(Defaultable, Movable, Copyable, Deinitable):
    """One aggregate of a `HashAggTable`: an aggregator and one state per
    group. `Defaultable` lets `Tuple[*Aggs]()` build a whole pack."""

    @staticmethod
    def make() -> Self:
        """An empty column (no groups)."""
        ...

    def push_identity_group(mut self):
        """Append one identity state, for the group the key block just
        inserted."""
        ...

    def update_row[
        bo: Origin[mut=False]
    ](mut self, slot: Int, batch: BatchView[bo], row_idx: Int):
        """Fold row `row_idx` into group `slot`."""
        ...

    def update_row_band[
        o: Origin[mut=False]
    ](mut self, slot: Int, band: BandView[o], row: Int):
        """Fold a band row into group `slot`. DEFAULT: abort (only `AggSlot`
        folds bands)."""
        abort(
            "AggColumn.update_row_band: this aggregate column does not fold"
            " band views; only AggSlot does."
        )

    def update_chunk_at[
        W: Int, bo: Origin[mut=False]
    ](
        mut self,
        slot: Int,
        batch: BatchView[bo],
        i: Int,
        valid: SIMD[DType.bool, W],
    ):
        """Fold the `valid` lanes of rows `i .. i+W` (those inside the batch)
        into group `slot`, in row order. DEFAULT: one `update_row` per lane."""
        var n = batch.n_rows()
        comptime for lane in range(W):
            if i + lane < n and valid[lane]:
                self.update_row[bo](slot, batch, i + lane)

    def update_row_mv[
        V: MorselView
    ](mut self, slot: Int, view: V, row_idx: Int):
        """`update_row` over any `MorselView`. DEFAULT: abort."""
        abort(
            "AggColumn.update_row_mv: this aggregate column does not fold"
            " MorselViews; AggSlot and AggFnSlot do."
        )

    def update_chunk_at_mv[
        W: Int, V: MorselView
    ](
        mut self,
        slot: Int,
        view: V,
        i: Int,
        valid: SIMD[DType.bool, W],
    ):
        """`update_chunk_at` over any `MorselView`. DEFAULT: one
        `update_row_mv` per lane."""
        var n = view.n_rows()
        comptime for lane in range(W):
            if i + lane < n and valid[lane]:
                self.update_row_mv[V](slot, view, i + lane)

    def combine_into(mut self, into_slot: Int, var partial: Self):
        """Merge `partial`'s group `into_slot` into the same group here."""
        ...

    def combine_at(mut self, into_slot: Int, other_slot: Int, other: Self):
        """Merge `other`'s group `other_slot` into group `into_slot` here (the
        key block mapped one to the other by key value)."""
        ...

    def combine_at_move(
        mut self, into_slot: Int, other_slot: Int, mut other: Self
    ):
        """`combine_at`, allowed to move `other`'s state out instead of copying
        it. DEFAULT: `combine_at`. `AggSlot` over an integer COUNT(DISTINCT)
        moves the value buffer, deferring the dedup to the drain."""
        self.combine_at(into_slot, other_slot, other)

    def finalize_f64(self, slot: Int) -> Float64:
        """Group `slot`'s `finalize`, widened to Float64. For tests: it ignores
        NULL results."""
        ...

    def is_null_at(self, slot: Int) -> Bool:
        """Is group `slot`'s result NULL? DEFAULT False."""
        _ = slot
        return False

    def has_null_output(self, slots: List[Int]) -> Bool:
        """Is any of the groups `slots` NULL?"""
        for si in range(len(slots)):
            if self.is_null_at(slots[si]):
                return True
        return False

    def out_arrow_type(self) -> ArrowType:
        """The output column's Arrow type."""
        ...

    def refuse_unrepresentable(self, slots: List[Int], what: String) raises:
        """Raise when a group's result has no value in the output column (an
        exact integer SUM outside INT64). DEFAULT: nothing to refuse."""
        _ = slots
        _ = what

    def emit_column(self, slots: List[Int], mut rb: RecordBatchBuilder) raises:
        """Append the output column over the groups `slots`, NULL where
        `is_null_at`."""
        ...

    def emit_empty_row(self, mut rb: RecordBatchBuilder) raises:
        """Append a one-row column: the answer of an ungrouped aggregate over
        no rows (NULL, or COUNT's 0)."""
        ...

    def emit_column_parallel[
        disp_o: Origin[mut=True]
    ](
        self,
        slots: List[Int],
        mut rb: RecordBatchBuilder,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        imm cancel_token: CancellationToken,
    ) raises:
        """`emit_column` with the dispatcher's workers. DEFAULT: the serial
        `emit_column`; `AggSlot` over COUNT(DISTINCT) or MEDIAN overrides."""
        _ = dispatcher_ptr
        _ = cancel_token
        self.emit_column(slots, rb)

    def emit_at_offset_desc(
        self, var name: String, nullable: Bool
    ) -> _EmitColDesc:
        """The drain-at-offset plan of this column. DEFAULT: INELIGIBLE."""
        return _EmitColDesc(
            Field(name^, ArrowType.NULL, nullable), EMIT_KIND_INELIGIBLE, 0
        )

    def emit_column_at_offset(
        self,
        slots: List[Int],
        mut targets: List[_EmitColTarget],
        col_idx: Int,
        row_offset: Int,
    ) raises:
        """Write the groups `slots` into `targets[col_idx]` from `row_offset`.
        DEFAULT: raise (an INELIGIBLE plan is never written)."""
        raise Error(
            "AggColumn.emit_column_at_offset: this aggregate column is not"
            " drain-at-offset eligible"
        )

    def reset(mut self):
        """Drop every group."""
        ...


struct AggSlot[A: Aggregator](AggColumn):
    """An `Aggregator` `A` and its per-group states.

    `states[g]` is group g's state; `fed[g]` is True once group g folded a
    non-NULL value (the empty-group rule of `A.EMPTY_IS_NULL`)."""

    var agg: Self.A
    var states: List[Self.A.StateTy]
    var fed: List[Bool]

    def __init__(out self, var agg: Self.A):
        self.agg = agg^
        self.states = List[Self.A.StateTy](capacity=AGG_INITIAL_CAPACITY)
        self.fed = List[Bool](capacity=AGG_INITIAL_CAPACITY)

    def __init__(out self):
        """From `A.make()` (a field-less aggregator such as `HashAggOpAgg`)."""
        self.agg = Self.A.make()
        self.states = List[Self.A.StateTy](capacity=AGG_INITIAL_CAPACITY)
        self.fed = List[Bool](capacity=AGG_INITIAL_CAPACITY)

    @staticmethod
    def make() -> Self:
        return Self()

    @always_inline
    def push_identity_group(mut self):
        self.states.append(Self.A.init())
        self.fed.append(False)

    @always_inline
    def update_row[
        bo: Origin[mut=False]
    ](mut self, slot: Int, batch: BatchView[bo], row_idx: Int):
        if self.agg.input_is_null[BatchView[bo]](batch, row_idx):
            self.agg.update_null(self.states[slot])
            return
        self.agg.update_scalar[bo](self.states[slot], batch, row_idx)
        self.fed[slot] = True

    @always_inline
    def update_row_band[
        o: Origin[mut=False]
    ](mut self, slot: Int, band: BandView[o], row: Int):
        """A band carries no validity: every band row is a value."""
        self.agg.update_band[o](self.states[slot], band, row)
        self.fed[slot] = True

    @always_inline
    def update_chunk_at[
        W: Int, bo: Origin[mut=False]
    ](
        mut self,
        slot: Int,
        batch: BatchView[bo],
        i: Int,
        valid: SIMD[DType.bool, W],
    ):
        """`A.update_chunk` when no live lane is NULL; else one `update_row`
        per live lane, in row order (FIRST / LAST see the NULL in place)."""
        var n = batch.n_rows()
        var any_live = False
        var any_null = False
        comptime for lane in range(W):
            if i + lane < n and valid[lane]:
                any_live = True
                if self.agg.input_is_null[BatchView[bo]](batch, i + lane):
                    any_null = True
        if not any_live:
            return
        if not any_null:
            self.agg.update_chunk[W, bo](self.states[slot], batch, i, valid)
            self.fed[slot] = True
            return
        comptime for lane in range(W):
            if i + lane < n and valid[lane]:
                self.update_row[bo](slot, batch, i + lane)

    @always_inline
    def update_row_mv[
        V: MorselView
    ](mut self, slot: Int, view: V, row_idx: Int):
        if self.agg.input_is_null[V](view, row_idx):
            self.agg.update_null(self.states[slot])
            return
        self.agg.update_scalar_mv[V](self.states[slot], view, row_idx)
        self.fed[slot] = True

    @always_inline
    def update_chunk_at_mv[
        W: Int, V: MorselView
    ](
        mut self,
        slot: Int,
        view: V,
        i: Int,
        valid: SIMD[DType.bool, W],
    ):
        var n = view.n_rows()
        var any_live = False
        var any_null = False
        comptime for lane in range(W):
            if i + lane < n and valid[lane]:
                any_live = True
                if self.agg.input_is_null[V](view, i + lane):
                    any_null = True
        if not any_live:
            return
        if not any_null:
            self.agg.update_chunk_mv[W, V](self.states[slot], view, i, valid)
            self.fed[slot] = True
            return
        comptime for lane in range(W):
            if i + lane < n and valid[lane]:
                self.update_row_mv[V](slot, view, i + lane)

    @always_inline
    def combine_into(mut self, into_slot: Int, var partial: Self):
        self.agg.combine(
            self.states[into_slot], partial.states[into_slot].copy()
        )
        self.fed[into_slot] = self.fed[into_slot] or partial.fed[into_slot]

    @always_inline
    def combine_at(mut self, into_slot: Int, other_slot: Int, other: Self):
        self.agg.combine(
            self.states[into_slot], other.states[other_slot].copy()
        )
        self.fed[into_slot] = self.fed[into_slot] or other.fed[other_slot]

    @always_inline
    def combine_at_move(
        mut self, into_slot: Int, other_slot: Int, mut other: Self
    ):
        comptime if Self.A.IS_DISTINCT:
            self.agg.take_distinct_into(
                self.states[into_slot], other.states[other_slot]
            )
            self.fed[into_slot] = (
                self.fed[into_slot] or other.fed[other_slot]
            )
        else:
            self.combine_at(into_slot, other_slot, other)

    @always_inline
    def finalize_f64(self, slot: Int) -> Float64:
        return Self.A.finalize(self.states[slot]).cast[DType.float64]()

    @always_inline
    def is_null_at(self, slot: Int) -> Bool:
        comptime if Self.A.EMPTY_IS_NULL:
            if not self.fed[slot]:
                return True
        return Self.A.result_is_null(self.states[slot])

    @always_inline
    def out_arrow_type(self) -> ArrowType:
        return _agg_arrow_type[Self.A.OUT_DT]()

    def refuse_unrepresentable(self, slots: List[Int], what: String) raises:
        comptime if Self.A.EXACT_INT_SUM:
            for si in range(len(slots)):
                var s = slots[si]
                if self.is_null_at(s):
                    continue
                if not Self.A.total_fits_i64(self.states[s]):
                    raise Error(int_sum_overflow_message(what))

    def emit_column(self, slots: List[Int], mut rb: RecordBatchBuilder) raises:
        var n = len(slots)
        if not self.has_null_output(slots):
            var col = List[Scalar[Self.A.OUT_DT]](capacity=n)
            for si in range(n):
                col.append(Self.A.finalize(self.states[slots[si]]))
            var arr = PrimitiveArray[Self.A.OUT_DT].from_list(col)
            rb.add_column(Column.from_primitive[Self.A.OUT_DT](arr^))
            return
        var arr = PrimitiveArray[Self.A.OUT_DT].allocate_nullable(n)
        for si in range(n):
            if not self.is_null_at(slots[si]):
                arr.set(si, Self.A.finalize(self.states[slots[si]]))
        # Values first: `set` marks its index valid.
        for si in range(n):
            if self.is_null_at(slots[si]):
                arr._set_null(si)
        rb.add_column(Column.from_primitive[Self.A.OUT_DT](arr^))

    def emit_empty_row(self, mut rb: RecordBatchBuilder) raises:
        comptime if Self.A.EMPTY_IS_NULL:
            var arr = PrimitiveArray[Self.A.OUT_DT].allocate_nullable(1)
            arr._set_null(0)
            rb.add_column(Column.from_primitive[Self.A.OUT_DT](arr^))
        else:
            var col = List[Scalar[Self.A.OUT_DT]](capacity=1)
            col.append(Self.A.finalize(Self.A.init()))
            var arr = PrimitiveArray[Self.A.OUT_DT].from_list(col)
            rb.add_column(Column.from_primitive[Self.A.OUT_DT](arr^))

    def emit_column_parallel[
        disp_o: Origin[mut=True]
    ](
        self,
        slots: List[Int],
        mut rb: RecordBatchBuilder,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        imm cancel_token: CancellationToken,
    ) raises:
        """Integer COUNT(DISTINCT): every group's value runs are counted by
        `radix_distinct_count_grouped`, parallel across groups. MEDIAN: the
        per-group sort-finalize is fanned out by `parallel_group_finalize_column`
        when no group is NULL (that column carries no validity). Everything
        else: `emit_column`. The answer is the serial drain's either way."""
        comptime if Self.A.IS_DISTINCT:
            var groups_runs = List[List[List[Int64]]](capacity=len(slots))
            for si in range(len(slots)):
                groups_runs.append(self.agg.distinct_runs(self.states[slots[si]]))
            var counts = radix_distinct_count_grouped(
                groups_runs^, dispatcher_ptr[], cancel_token.clone()
            )
            var col = List[Scalar[Self.A.OUT_DT]](capacity=len(slots))
            for si in range(len(slots)):
                col.append(Scalar[Self.A.OUT_DT](counts[si]))
            var arr = PrimitiveArray[Self.A.OUT_DT].from_list(col)
            rb.add_column(Column.from_primitive[Self.A.OUT_DT](arr^))
        elif Self.A.PARALLEL_SORT_FINALIZE:
            if self.has_null_output(slots):
                self.emit_column(slots, rb)
            else:
                parallel_group_finalize_column[Self.A](
                    self.states, slots, rb, dispatcher_ptr[], cancel_token.clone()
                )
        else:
            _ = dispatcher_ptr
            _ = cancel_token
            self.emit_column(slots, rb)

    def emit_at_offset_desc(
        self, var name: String, nullable: Bool
    ) -> _EmitColDesc:
        """FIXED, except for COUNT(DISTINCT) (its buffers hold undeduped runs
        only `emit_column_parallel` counts), MEDIAN (kept on its parallel
        drain) and a BOOL output (bit-packed): those are INELIGIBLE."""
        comptime if (
            Self.A.IS_DISTINCT
            or Self.A.PARALLEL_SORT_FINALIZE
            or Self.A.OUT_DT == DType.bool
        ):
            return _EmitColDesc(
                Field(name^, _agg_arrow_type[Self.A.OUT_DT](), nullable),
                EMIT_KIND_INELIGIBLE,
                0,
            )
        else:
            return _EmitColDesc(
                Field(name^, _agg_arrow_type[Self.A.OUT_DT](), nullable),
                EMIT_KIND_FIXED,
                size_of[Scalar[Self.A.OUT_DT]](),
            )

    def emit_column_at_offset(
        self,
        slots: List[Int],
        mut targets: List[_EmitColTarget],
        col_idx: Int,
        row_offset: Int,
    ) raises:
        """Write each group's `finalize` at row `row_offset + si`. Raises on a
        NULL group: the targets carry no validity."""
        if self.has_null_output(slots):
            raise Error(
                "AggSlot.emit_column_at_offset: a group's result is NULL and"
                " the drain-at-offset targets carry no validity"
            )
        ref data = targets[col_idx].data
        for si in range(len(slots)):
            data.set_typed[Scalar[Self.A.OUT_DT]](
                row_offset + si, Self.A.finalize(self.states[slots[si]])
            )

    @always_inline
    def reset(mut self):
        self.states.clear()
        self.fed.clear()


@always_inline
def agg_slot[A: Aggregator](var agg: A) -> AggSlot[A]:
    """An `AggSlot[A]` over a constructed aggregator."""
    return AggSlot[A](agg^)


struct AggBlock[*Aggs: AggColumn](Movable):
    """The aggregate pack, carried into the `HashAggTable` constructor (a
    parameter list holds one variadic pack, and the table's is `*Aggs`)."""

    var _payload: Optional[Tuple[*Self.Aggs]]

    def __init__(out self, var *slots: *Self.Aggs):
        self._payload = Tuple(*slots^)

    @always_inline
    def take(mut self) -> Tuple[*Self.Aggs]:
        """Move the pack out (once)."""
        return self._payload.take()
