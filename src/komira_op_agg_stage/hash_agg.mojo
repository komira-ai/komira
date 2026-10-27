# =============================================================================
# hash_agg.mojo — HashAggTable[KB, *Aggs], the stage HASH_AGG breaker state
# =============================================================================
#
# One variadic struct covers every key arity, key type and aggregate pack: the
# key axis is a `KeyTuple` block (`key_block`), the aggregate axis the
# comptime pack `*Aggs` of `AggColumn` conformers (`agg_column`), stored as one
# `Tuple[*Aggs]`. (A parameter list carries one `*` pack, so the key axis is a
# single type parameter whose type is itself variadic.)
#
# Feeding: `feed_row` looks up or inserts the row's group in the key block, and
# a NEW group grows every aggregate's state list by one identity state; then
# each aggregate folds the row. `feed_chunk_global` / `fold_scalar_view` are the
# ungrouped (0-key) masked folds; `consume_band` folds a decoded band without a
# RecordBatch.
#
# Merging: `combine` re-keys each of the other table's groups BY KEY VALUE
# (the two tables number groups independently) and folds every aggregate at
# the mapped group. `combine_partition_from` is the same fold restricted to
# the groups whose key hash routes to one partition, so partitions combine in
# parallel; `n_combine_partitions` sizes that fan from the group count.
#
# Draining: one row per group, keys then aggregates. An ungrouped aggregate
# drains exactly one row, also over no input (DuckDB: COUNT 0, others NULL).
# Every drain calls `refuse_unrepresentable` on each aggregate first (an exact
# integer SUM outside INT64 raises). The result is lifted into a
# `ColumnNativeBatch` and bridged back to a `RecordBatch` (`column_native_shims`);
# the round trip is byte-identical.
# =============================================================================

from std.collections import Optional, List
from std.memory import Pointer

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from komira_arrow.band_view import BandView
from komira_arrow.batch_view import BatchView
from komira_arrow.column_native import ColumnNativeBatch
from komira_arrow.morsel_view import MorselView
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)
from komira_expr.stage_program import BREAKER_HASH_AGG
from komira_operator_api.breaker_state_trait import (
    BreakerState,
    BreakerStateCombinable,
)
from komira_operator_api.emit_at_offset_target import (
    _EmitColDesc,
    _EmitColTarget,
    EMIT_KIND_INELIGIBLE,
)

from komira_op_agg_stage.agg_column import AggBlock, AggColumn
from komira_op_agg_stage.key_block import KeyTuple


comptime TYPED_AGG_RADIX_PARTITIONS: Int = 64
"""The most partitions the parallel combine fans out to."""

comptime TYPED_AGG_RADIX_MIN_GROUPS: Int = 4096
"""Below this many groups in the peeked worker table the combine is serial."""

comptime TYPED_AGG_RADIX_GROUPS_PER_PARTITION: Int = 1024
"""The target group count per combine partition: the fan is about
`groups / 1024`, rounded down to a power of 2 and clamped to [2, 64]. Each
partition task scans every source group to route it, so a fan too wide for the
group count repeats that scan for nothing."""


struct HashAggTable[KB: KeyTuple, *Aggs: AggColumn](
    Movable, BreakerStateCombinable
):
    """GROUP BY over the key block `KB` with the aggregate pack `*Aggs`.

    Fields: `keys` (the key block), `aggs` (one `AggColumn` per aggregate),
    `n_used` (the group count), the optional output names and nullability of
    the aggregate columns, and `_radix_min_groups` (the parallel combine's
    group threshold, `TYPED_AGG_RADIX_MIN_GROUPS` unless set)."""

    var keys: Self.KB
    var aggs: Tuple[*Self.Aggs]
    var n_used: Int
    var _out_names: Optional[List[String]]
    """The aggregate column names; `agg0`, `agg1`, ... when None."""
    var _out_nullable: Bool
    """The aggregate fields' nullability (True unless `with_output_names` says
    otherwise). A column that holds a NULL is emitted nullable regardless."""
    var _radix_min_groups: Int

    comptime SUPPORTS_RADIX_COMBINE: Bool = True

    def __init__(out self, var agg_block: AggBlock[*Self.Aggs]):
        self.keys = Self.KB.make()
        self.aggs = agg_block.take()
        self.n_used = 0
        self._out_names = None
        self._out_nullable = True
        self._radix_min_groups = TYPED_AGG_RADIX_MIN_GROUPS

    def __init__(out self):
        """Every aggregate default-constructed (`Tuple[*Aggs]()`)."""
        self.keys = Self.KB.make()
        self.aggs = Tuple[*Self.Aggs]()
        self.n_used = 0
        self._out_names = None
        self._out_nullable = True
        self._radix_min_groups = TYPED_AGG_RADIX_MIN_GROUPS

    def with_output_names(
        mut self, var names: List[String], nullable: Bool = False
    ):
        """Name the aggregate columns (one name per aggregate; a drain raises
        on a length mismatch) and set their nullability."""
        self._out_names = names^
        self._out_nullable = nullable

    def with_radix_min_groups(mut self, min_groups: Int):
        """Set the group count from which `n_combine_partitions` fans out (a
        test sets 2 to exercise the parallel combine on a small input)."""
        self._radix_min_groups = min_groups

    @staticmethod
    @always_inline
    def key_arity() -> Int:
        return Self.KB.ARITY

    @staticmethod
    @always_inline
    def agg_arity() -> Int:
        return Self.Aggs.__len__()

    @staticmethod
    def state_tag() -> Int:
        return BREAKER_HASH_AGG

    @always_inline
    def capacity(self) -> Int:
        """The group count (the table grows; there is no fixed capacity)."""
        return self.n_used

    @always_inline
    def size(self) -> Int:
        return self.n_used

    @always_inline
    def _push_new_group(mut self):
        comptime for a in range(Self.Aggs.__len__()):
            self.aggs[a].push_identity_group()

    @always_inline
    def reset(mut self):
        self.keys.reset()
        comptime for a in range(Self.Aggs.__len__()):
            self.aggs[a].reset()
        self.n_used = 0

    @always_inline
    def agg_finalize_f64[a: Int](self, slot: Int) -> Float64:
        """Aggregate `a`'s `finalize` of group `slot` as Float64 (tests)."""
        return self.aggs[a].finalize_f64(slot)

    @always_inline
    def agg_is_null[a: Int](self, slot: Int) -> Bool:
        """Is aggregate `a`'s result of group `slot` NULL?"""
        return self.aggs[a].is_null_at(slot)

    # --- feeding ---------------------------------------------------------

    @always_inline
    def feed_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ) raises:
        """Fold one row: find or insert its group, fold every aggregate."""
        var before = self.n_used
        var slot = self.keys.feed_lookup[bo](self.n_used, batch, row)
        if self.n_used != before:
            self._push_new_group()
        comptime for a in range(Self.Aggs.__len__()):
            self.aggs[a].update_row[bo](slot, batch, row)

    def consume_band[o: Origin[mut=False]](mut self, band: BandView[o]) raises:
        """Fold every live row of a decoded band (`band.selection_live`) into
        the same key block and states `feed_row` uses, without building a
        RecordBatch."""
        for row in range(band.n_rows()):
            if not band.selection_live(row):
                continue
            var before = self.n_used
            var slot = self.keys.feed_lookup_band[o](self.n_used, band, row)
            if self.n_used != before:
                self._push_new_group()
            comptime for a in range(Self.Aggs.__len__()):
                self.aggs[a].update_row_band[o](slot, band, row)

    @always_inline
    def feed_chunk_global[
        W: Int, bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int, valid: SIMD[DType.bool, W]):
        """Ungrouped (`KB.ARITY == 0`) masked fold of rows `i .. i+W` into the
        one group. The group is created by the first chunk with a live lane;
        a fully masked chunk folds nothing. The caller gates this to 0 keys."""
        if not valid.reduce_or():
            return
        if self.n_used == 0:
            self.n_used = 1
            self._push_new_group()
        comptime for a in range(Self.Aggs.__len__()):
            self.aggs[a].update_chunk_at[W, bo](0, batch, i, valid)

    @always_inline
    def feed_chunk_global_mv[
        W: Int, V: MorselView
    ](mut self, view: V, i: Int, valid: SIMD[DType.bool, W]):
        """`feed_chunk_global` over any `MorselView`."""
        if not valid.reduce_or():
            return
        if self.n_used == 0:
            self.n_used = 1
            self._push_new_group()
        comptime for a in range(Self.Aggs.__len__()):
            self.aggs[a].update_chunk_at_mv[W, V](0, view, i, valid)

    def fold_scalar_view[V: MorselView](mut self, view: V) raises:
        """Ungrouped fold of a whole morsel: 4-wide masked chunks honoring the
        view's selection mask, then the tail row by row. Raises for a keyed
        table."""
        comptime if Self.KB.ARITY != 0:
            raise Error(
                "HashAggTable.fold_scalar_view: ungrouped (0-key) tables only"
            )
        var n = view.n_rows()
        comptime W = 4
        var i = 0
        if not view.has_selection_mask():
            while i + W <= n:
                self.feed_chunk_global_mv[W, V](
                    view, i, SIMD[DType.bool, W](fill=True)
                )
                i = i + W
            while i < n:
                self.feed_chunk_global_mv[1, V](
                    view, i, SIMD[DType.bool, 1](True)
                )
                i = i + 1
        else:
            while i + W <= n:
                var m = SIMD[DType.bool, W](fill=False)
                comptime for j in range(W):
                    m[j] = view.selection_mask_get(i + j)
                self.feed_chunk_global_mv[W, V](view, i, m)
                i = i + W
            while i < n:
                self.feed_chunk_global_mv[1, V](
                    view, i, SIMD[DType.bool, 1](view.selection_mask_get(i))
                )
                i = i + 1

    def probe_batch[bo: Origin[mut=False], join_t: Int](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("HashAggTable.probe_batch: not a JOIN_PROBE state")

    def probe_asof_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("HashAggTable.probe_asof_batch: not an ASOF_JOIN state")

    # --- draining ----------------------------------------------------------

    def _agg_name(self, a: Int) -> String:
        if self._out_names:
            return self._out_names.value()[a]
        return String("agg") + String(a)

    def _check_names(self, who: String) raises:
        if self._out_names and len(self._out_names.value()) != Self.Aggs.__len__():
            raise Error(
                who
                + ": _out_names length "
                + String(len(self._out_names.value()))
                + " != agg arity "
                + String(Self.Aggs.__len__())
            )

    def _group_slots(self) -> List[Int]:
        """The groups a drain emits: every group, in dense (first-seen)
        order."""
        var slots = List[Int](capacity=self.n_used)
        for s in range(self.n_used):
            slots.append(s)
        return slots^

    def _drain_schema(self, slots: List[Int], who: String) raises -> Schema:
        self._check_names(who)
        var sb = SchemaBuilder()
        self.keys.add_key_schema_fields(sb)
        comptime for a in range(Self.Aggs.__len__()):
            var nullable = self._out_nullable
            if self.n_used == 0 or self.aggs[a].has_null_output(slots):
                nullable = True
            sb.add_field(
                Field(self._agg_name(a), self.aggs[a].out_arrow_type(), nullable)
            )
        return sb.build()

    def _refuse_unrepresentable(self, slots: List[Int]) raises:
        comptime for a in range(Self.Aggs.__len__()):
            self.aggs[a].refuse_unrepresentable(slots, self._agg_name(a))

    @staticmethod
    def _bridge(var built: RecordBatch) raises -> Optional[RecordBatch]:
        var native: ColumnNativeBatch = column_native_from_record_batch(built^)
        return Optional[RecordBatch](record_batch_from_column_native(native^))

    def drain_to_record_batch(self) raises -> Optional[RecordBatch]:
        """One row per group: the key columns, then each aggregate's column."""
        var slots = self._group_slots()
        var schema = self._drain_schema(slots, "HashAggTable.drain")
        self._refuse_unrepresentable(slots)
        var rb = RecordBatchBuilder()
        comptime if Self.KB.ARITY == 0:
            if self.n_used == 0:
                comptime for a in range(Self.Aggs.__len__()):
                    self.aggs[a].emit_empty_row(rb)
                return Self._bridge(rb.build(schema^))
        self.keys.emit_key_columns(slots, rb)
        comptime for a in range(Self.Aggs.__len__()):
            self.aggs[a].emit_column(slots, rb)
        return Self._bridge(rb.build(schema^))

    def drain_to_record_batch_parallel[
        disp_o: Origin[mut=True]
    ](
        self,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        cancel_token: CancellationToken,
    ) raises -> Optional[RecordBatch]:
        """`drain_to_record_batch` with each aggregate emitted by
        `emit_column_parallel`; the same batch."""
        var slots = self._group_slots()
        var schema = self._drain_schema(slots, "HashAggTable.drain_parallel")
        self._refuse_unrepresentable(slots)
        var rb = RecordBatchBuilder()
        comptime if Self.KB.ARITY == 0:
            if self.n_used == 0:
                comptime for a in range(Self.Aggs.__len__()):
                    self.aggs[a].emit_empty_row(rb)
                return Self._bridge(rb.build(schema^))
        self.keys.emit_key_columns(slots, rb)
        comptime for a in range(Self.Aggs.__len__()):
            self.aggs[a].emit_column_parallel(
                slots, rb, dispatcher_ptr, cancel_token
            )
        return Self._bridge(rb.build(schema^))

    # --- merging -----------------------------------------------------------

    def combine(mut self, var other: Self) raises:
        """Fold every group of `other` into this table, mapped by key value."""
        comptime if Self.KB.ARITY == 0:
            if other.n_used > 0:
                var before = self.n_used
                var slot = self.keys.reinsert_from(self.n_used, other.keys, 0)
                if self.n_used != before:
                    self._push_new_group()
                comptime for a in range(Self.Aggs.__len__()):
                    self.aggs[a].combine_at(slot, 0, other.aggs[a])
        else:
            for other_slot in range(other.n_used):
                var before = self.n_used
                var self_slot = self.keys.reinsert_from(
                    self.n_used, other.keys, other_slot
                )
                if self.n_used != before:
                    self._push_new_group()
                comptime for a in range(Self.Aggs.__len__()):
                    self.aggs[a].combine_at(
                        self_slot, other_slot, other.aggs[a]
                    )

    def combine_move_distinct(mut self, var other: Self) raises:
        """`combine`, folding with `combine_at_move`: an integer
        COUNT(DISTINCT) moves each group's value buffer instead of copying it
        (the drain dedups the runs together); every other aggregate folds as in
        `combine`. Same result. Consumes `other`."""
        comptime if Self.KB.ARITY == 0:
            if other.n_used > 0:
                var before = self.n_used
                var slot = self.keys.reinsert_from(self.n_used, other.keys, 0)
                if self.n_used != before:
                    self._push_new_group()
                comptime for a in range(Self.Aggs.__len__()):
                    self.aggs[a].combine_at_move(slot, 0, other.aggs[a])
        else:
            for other_slot in range(other.n_used):
                var before = self.n_used
                var self_slot = self.keys.reinsert_from(
                    self.n_used, other.keys, other_slot
                )
                if self.n_used != before:
                    self._push_new_group()
                comptime for a in range(Self.Aggs.__len__()):
                    self.aggs[a].combine_at_move(
                        self_slot, other_slot, other.aggs[a]
                    )
        _ = other^

    @always_inline
    def n_combine_partitions(self) -> Int:
        """1 for an ungrouped table or one below `_radix_min_groups` groups;
        else about `n_used / TYPED_AGG_RADIX_GROUPS_PER_PARTITION`, a power of 2
        in [2, TYPED_AGG_RADIX_PARTITIONS]."""
        comptime if Self.KB.ARITY == 0:
            return 1
        if self.n_used < self._radix_min_groups:
            return 1
        var want = self.n_used // TYPED_AGG_RADIX_GROUPS_PER_PARTITION
        var parts = 2
        while parts * 2 <= want and parts < TYPED_AGG_RADIX_PARTITIONS:
            parts = parts * 2
        return parts

    def combine_partition_from[o: Origin[mut=False]](
        mut self, ref [o] src: Self, partition: Int, n_partitions: Int
    ) raises:
        """Fold the groups of `src` whose key hash routes to `partition` (of
        `n_partitions`: `(hash >> 24)` masked, or modulo for a count that is not
        a power of 2) into this table, mapped by key value. The same key hashes
        the same on every worker, so a group's partials all land in one
        partition, and partitions never share a group."""
        comptime if Self.KB.ARITY == 0:
            return
        else:
            var use_mask = (n_partitions & (n_partitions - 1)) == 0
            var pmask = UInt64(n_partitions - 1)
            var np_u = UInt64(n_partitions)
            for src_slot in range(src.n_used):
                var hi = src.keys.cached_hash_at(src_slot) >> UInt64(24)
                var p = Int(hi & pmask) if use_mask else Int(hi % np_u)
                if p != partition:
                    continue
                var before = self.n_used
                var self_slot = self.keys.reinsert_from(
                    self.n_used, src.keys, src_slot
                )
                if self.n_used != before:
                    self._push_new_group()
                comptime for a in range(Self.Aggs.__len__()):
                    self.aggs[a].combine_at(self_slot, src_slot, src.aggs[a])

    # --- the drain-at-offset surface ----------------------------------------
    #
    # An orchestrator drains each combine partition straight into the final
    # output columns at prefix-sum offsets, instead of draining each partition
    # and concatenating. These describe the columns, size the string buffers
    # and write one partition's groups, in the serial drain's column order.
    # The targets carry no validity, so a column holding a NULL is INELIGIBLE
    # in this partition's plan, and a write that meets a NULL raises: an
    # orchestrator that plans from one partition only must fall back to the
    # serial drain on that error, never emit the data under the NULL.

    @always_inline
    def n_drain_rows(self) -> Int:
        return self.n_used

    def emit_at_offset_plan(self, mut descs: List[_EmitColDesc]) raises:
        self._check_names("HashAggTable.emit_at_offset_plan")
        self.keys.plan_key_cols(descs)
        var slots = self._group_slots()
        comptime for a in range(Self.Aggs.__len__()):
            var d = self.aggs[a].emit_at_offset_desc(
                self._agg_name(a), self._out_nullable
            )
            if self.aggs[a].has_null_output(slots):
                d.kind = EMIT_KIND_INELIGIBLE
            descs.append(d^)

    def emit_at_offset_data_bytes(self, mut out: List[Int]):
        self.keys.key_data_bytes(out)
        comptime for a in range(Self.Aggs.__len__()):
            out.append(0)

    def emit_at_offset_write[do: Origin[mut=False]](
        self,
        mut targets: List[_EmitColTarget],
        row_offset: Int,
        ref [do] data_offsets: List[Int],
        data_base: Int,
    ) raises:
        var slots = self._group_slots()
        self._refuse_unrepresentable(slots)
        self.keys.emit_keys_at_offset[do](
            slots, targets, 0, row_offset, data_offsets, data_base
        )
        var ka = Self.KB.ARITY
        comptime for a in range(Self.Aggs.__len__()):
            self.aggs[a].emit_column_at_offset(
                slots, targets, ka + a, row_offset
            )
