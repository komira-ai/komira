# =============================================================================
# partition_topn_sink -- PartitionTopNSink, the top K rows of each partition
# =============================================================================
#
# `PartitionTopNSink` runs a `PartitionTopNSinkData` (`komira_physical_plan`)
# over one batch: per partition, the rows whose ROW_NUMBER (`PF_ROW_NUMBER`)
# or RANK (`PF_RANK`) over the sort keys is at most `k`, optionally with that
# number appended as an INT64 column (`output_rank_col_name`). Order and
# ties are DuckDB's (docs/design/query_semantics.md §4, §9): NULL sort keys
# last in both directions and peers of each other, NULL partition keys one
# partition, floats with NaN above +inf (every NaN a peer of every other) and
# -0.0 a peer of +0.0. A float sort key column comes back with each -0.0 as
# 0.0 (§4.9).
#
# Two paths, the same rows:
#
#   * compact (`partition_topn_compact`): one INT32 / INT64 partition key and
#     one INT32 / INT64 / FLOAT64 sort key, neither holding a NULL in this
#     batch: a bounded heap per partition, O(rows log cap), built on the
#     engine's workers when a pool is given (`combine_pooled`);
#   * generic: any keys: the window sort (`partition_keys.sort_partition_batch`)
#     and one walk that counts rows and peers per partition.
#
# ROW_NUMBER keeps exactly min(k, rows) rows per partition; which of several
# rows tied at the k-th place is kept is not specified (§4.7). RANK keeps
# every row tied within k.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.copy_column_ref import copy_column_ref
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_async.runtime.parallel_fork_join_shared import (
    SharedForkJoinHandle,
    serial_fork_join_handle,
)
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.compiler_helpers import gather_batch
from komira_physical_plan.physical_plan import PartitionTopNSinkData
from komira_plan_expr.partition_expr import PF_RANK, PF_ROW_NUMBER

from .partition_keys import column_has_nulls, key_cells_equal, sort_partition_batch
from .partition_topn_compact import (
    _build_partition_heaps_dispatch,
    _emit_compact_rank,
    _emit_compact_row_number,
    _encode_order_keys,
    _extract_partition_keys,
)


# Compile-time rank modes of the two kernel bodies.
comptime _RM_ROW_NUMBER: UInt8 = 0
comptime _RM_RANK: UInt8 = 1


struct PartitionTopNSink(Movable):
    """The per-partition top-K of one batch.

    `ingest_prebuilt` (or `consume`) stashes the batch, `combine` /
    `combine_pooled` computes the result, `take_output` moves it out.
    """

    var _spec: PartitionTopNSinkData
    # The compact path fits the schema (one INT32 / INT64 partition key, one
    # INT32 / INT64 / FLOAT64 sort key); `combine` also needs the columns to
    # hold no NULL.
    var _compact: Bool
    var _part_col_idx: Int
    var _order_col_idx: Int
    var _order_descending: Bool
    var _prebuilt: Optional[RecordBatch]
    var _output: Optional[RecordBatch]

    def __init__(out self, var spec: PartitionTopNSinkData):
        var compact = False
        var part_col_idx = -1
        var order_col_idx = -1
        var order_desc = False
        if len(spec.partition_keys) == 1 and len(spec.sort_keys) == 1:
            var pk_type = ArrowType.NULL
            var ok_type = ArrowType.NULL
            for i in range(spec.output_schema.num_columns()):
                var name = spec.output_schema.field_name(i)
                if name == spec.partition_keys[0]:
                    pk_type = spec.output_schema.field_arrow_type(i)
                    part_col_idx = i
                if name == spec.sort_keys[0]:
                    ok_type = spec.output_schema.field_arrow_type(i)
                    order_col_idx = i
            if part_col_idx >= 0 and order_col_idx >= 0:
                var pk_ok = pk_type == ArrowType.INT32 or pk_type == ArrowType.INT64
                var ok_ok = (
                    ok_type == ArrowType.INT32
                    or ok_type == ArrowType.INT64
                    or ok_type == ArrowType.FLOAT64
                )
                if pk_ok and ok_ok:
                    compact = True
                    order_desc = spec.descending[0]
        self._spec = spec^
        self._compact = compact
        self._part_col_idx = part_col_idx
        self._order_col_idx = order_col_idx
        self._order_descending = order_desc
        self._prebuilt = None
        self._output = None

    @staticmethod
    def new(var spec: PartitionTopNSinkData) -> PartitionTopNSink:
        return PartitionTopNSink(spec^)

    def free(mut self) -> None:
        """Release the batch and the result. Idempotent."""
        self._prebuilt = None
        self._output = None

    def ingest_prebuilt(mut self, var batch: RecordBatch) -> None:
        """Stash the batch `combine` will process."""
        self._prebuilt = batch^

    def consume(mut self, var batch: RecordBatch) raises:
        """Stash the batch `combine` will process (replaces any earlier one)."""
        self._prebuilt = batch^

    def combine(mut self) raises -> None:
        """`combine_pooled` without a pool: every chunk runs inline."""
        self.combine_pooled(serial_fork_join_handle())

    def combine_pooled[
        has_pool: Bool, disp_o: Origin[mut=True]
    ](mut self, pool: SharedForkJoinHandle[has_pool, disp_o]) raises -> None:
        """Compute the per-partition top-K of the stashed batch."""
        if not self._prebuilt:
            self._output = RecordBatch()
            return
        var batch = self._prebuilt.take()
        if batch.num_rows() == 0:
            self._output = RecordBatch()
            return
        var rank_col_name: Optional[String] = None
        if self._spec.output_rank_col_name:
            rank_col_name = String(self._spec.output_rank_col_name.value())
        var compact = self._compact
        if compact:
            # A NULL key has no place in the compact path's encoding.
            compact = not (
                column_has_nulls(batch.column_at(self._part_col_idx))
                or column_has_nulls(batch.column_at(self._order_col_idx))
            )
        var out: RecordBatch
        if self._spec.func == PF_RANK:
            if compact:
                out = self._combine_compact[_RM_RANK, has_pool, disp_o](batch^, rank_col_name^, pool)
            else:
                out = self._combine_generic[_RM_RANK](batch^, rank_col_name^)
        else:
            if compact:
                out = self._combine_compact[_RM_ROW_NUMBER, has_pool, disp_o](batch^, rank_col_name^, pool)
            else:
                out = self._combine_generic[_RM_ROW_NUMBER](batch^, rank_col_name^)
        self._output = _canonical_zero_sort_keys(out^, self._spec.sort_keys)

    def take_output(mut self) raises -> RecordBatch:
        """Move the result out (once, after `combine`)."""
        if not self._output:
            return RecordBatch()
        return self._output.take()

    def materialize(mut self) raises -> RecordBatch:
        """`take_output`."""
        return self.take_output()

    def _combine_compact[
        rank_mode: UInt8, has_pool: Bool, disp_o: Origin[mut=True]
    ](
        mut self, var batch: RecordBatch, var rank_col_name: Optional[String],
        pool: SharedForkJoinHandle[has_pool, disp_o],
    ) raises -> RecordBatch:
        """The heap path (see `partition_topn_compact`). PERF-CRITICAL: no
        allocation per row; one UInt64 compare per heap step."""
        var num_rows = batch.num_rows()
        var k = self._spec.k
        if k <= 0:
            return RecordBatch()
        var cap = k
        comptime if rank_mode == _RM_RANK:
            cap = max(self._spec.over_fetch_k, k)
        var order_keys = _encode_order_keys(
            batch, self._order_col_idx, num_rows, self._order_descending
        )
        var part_keys = _extract_partition_keys(batch, self._part_col_idx, num_rows)
        var heaps = _build_partition_heaps_dispatch[has_pool, disp_o](
            part_keys, order_keys, num_rows, cap, pool,
        )
        var winner_indices = List[Int]()
        var winner_ranks = List[Int]()
        comptime if rank_mode == _RM_RANK:
            _emit_compact_rank(heaps, part_keys, order_keys, k, cap, winner_indices, winner_ranks)
        else:
            _emit_compact_row_number(heaps, Bool(rank_col_name), winner_indices, winner_ranks)
        if len(winner_indices) == 0:
            return RecordBatch()
        var gathered = gather_batch(batch, winner_indices)
        if rank_col_name:
            return _attach_rank_column(gathered^, rank_col_name.take(), winner_ranks^)
        return gathered^

    def _combine_generic[rank_mode: UInt8](
        mut self, var batch: RecordBatch, var rank_col_name: Optional[String],
    ) raises -> RecordBatch:
        """Any keys: sort by (partition keys ++ sort keys), then walk the rows
        numbering them (ROW_NUMBER) or ranking them by peer group (RANK) per
        partition, keeping those within k. O(rows log rows)."""
        var k = self._spec.k
        if k <= 0:
            return RecordBatch()
        var sorted_batch = sort_partition_batch(
            batch^, self._spec.partition_keys, self._spec.sort_keys, self._spec.descending
        )
        var n = sorted_batch.num_rows()
        if n == 0:
            return RecordBatch()
        var pk_cols = List[Int]()
        for name in self._spec.partition_keys:
            pk_cols.append(sorted_batch.schema.column_index(name))
        var ok_cols = List[Int]()
        for name in self._spec.sort_keys:
            ok_cols.append(sorted_batch.schema.column_index(name))

        var winner_indices = List[Int]()
        var winner_ranks = List[Int]()
        var partition_start = 0
        var rank = 1
        for row in range(n):
            if row > 0:
                var new_part = False
                for c in pk_cols:
                    if not key_cells_equal(sorted_batch.column_at(c), row, row - 1):
                        new_part = True
                        break
                if new_part:
                    partition_start = row
                    rank = 1
                else:
                    comptime if rank_mode == _RM_RANK:
                        var tie = True
                        for c in ok_cols:
                            if not key_cells_equal(sorted_batch.column_at(c), row, row - 1):
                                tie = False
                                break
                        if not tie:
                            rank = row - partition_start + 1
                    else:
                        rank = row - partition_start + 1
            if rank <= k:
                winner_indices.append(row)
                winner_ranks.append(rank)
        if len(winner_indices) == 0:
            return RecordBatch()
        var gathered = gather_batch(sorted_batch, winner_indices)
        if rank_col_name:
            return _attach_rank_column(gathered^, rank_col_name.take(), winner_ranks^)
        return gathered^


# =============================================================================
# Output
# =============================================================================


def _clone_column_for_rank_output(col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    """Copy one carried column (every layout `copy_column_ref` copies; a
    DICTIONARY by `dict_clone`, which resolves a numeric dictionary)."""
    if col.arrow_type == ArrowType.DICTIONARY:
        return col.dict_clone()
    return copy_column_ref(col, col.length())


def _attach_rank_column(
    var batch: RecordBatch, rank_col_name: String, var ranks: List[Int]
) raises -> RecordBatch:
    """`batch` with a non-NULL INT64 column `rank_col_name` appended."""
    var n = batch.num_rows()
    if n != len(ranks):
        raise Error(
            "_attach_rank_column: ranks length " + String(len(ranks))
            + " != batch.num_rows " + String(n)
        )
    var rank_arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        rank_arr.store[1](i, Int64(ranks[i]))
    var sb = SchemaBuilder()
    for i in range(batch.schema.num_columns()):
        sb.add_field(batch.schema.field_at(i))
    sb.add_field(Field(rank_col_name, ArrowType.INT64, False))
    var bb = RecordBatchBuilder()
    for c in range(batch.num_columns()):
        bb.add_column(_clone_column_for_rank_output(batch.column_at(c)))
    bb.add_column(Column.from_primitive[DType.int64](rank_arr^))
    return bb.build(sb.build())


def _canonical_zero_sort_keys(var batch: RecordBatch, sort_keys: List[String]) raises -> RecordBatch:
    """`batch` with each -0.0 of a FLOAT64 / FLOAT32 sort key column written
    as 0.0 (§4.9); every other column and value unchanged."""
    if batch.num_rows() == 0 or batch.num_columns() == 0:
        return batch^
    var fix = List[Bool]()
    var any_fix = False
    for i in range(batch.num_columns()):
        var is_key = False
        for name in sort_keys:
            if batch.schema.field_name(i) == name:
                is_key = True
                break
        var at = batch.column_at(i).arrow_type
        var f = is_key and (at == ArrowType.FLOAT64 or at == ArrowType.FLOAT32)
        fix.append(f)
        any_fix = any_fix or f
    if not any_fix:
        return batch^
    var sb = SchemaBuilder()
    var bb = RecordBatchBuilder()
    for i in range(batch.num_columns()):
        sb.add_field(batch.schema.field_at(i))
        ref col = batch.column_at(i)
        if not fix[i]:
            bb.add_column(_clone_column_for_rank_output(col))
        elif col.arrow_type == ArrowType.FLOAT64:
            var arr = col.as_primitive[DType.float64]()
            for r in range(arr.length):
                if arr.get(r) == 0.0:
                    arr.store[1](r, Float64(0.0))
            bb.add_column(Column.from_primitive[DType.float64](arr))
        else:
            var arr32 = col.as_primitive[DType.float32]()
            for r in range(arr32.length):
                if arr32.get(r) == 0.0:
                    arr32.store[1](r, Float32(0.0))
            bb.add_column(Column.from_primitive[DType.float32](arr32))
    return bb.build(sb.build())
