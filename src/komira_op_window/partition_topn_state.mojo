# =============================================================================
# partition_topn_state -- PartitionTopNState, top N rows per partition
# =============================================================================
#
# `PartitionTopNState[part_key_col, key_col, payload_col, N, sort_dir]` is a
# BreakerState of the typed stage's PARTITION_TOPN arm for one INT64 partition
# key, one INT64 order key and one INT64 payload: for each partition it keeps
# the N rows with the smallest (`PTOPN_DIR_ASC`) or largest (`PTOPN_DIR_DESC`)
# order key, as `topn_state.TopNState` does for the whole input.
#
#   * A NULL partition key is one partition (§9.9), distinct from every value.
#   * A NULL order key sorts last in both directions (§4.1): per partition the
#     NULL-order rows are kept apart, in a second bounded heap under one
#     constant key (the N smallest payload ids survive), and fill the
#     partition's result after the rows with a value. The kept rows do not
#     depend on feed or merge order.
#   * NULLs are placed LAST in both directions: this state has no
#     NULLS FIRST setting (the stage planner emits only the default
#     placement). `TopNSink` is the kernel's: it does not read `nulls_first`
#     and orders a numeric NULL slot by its stored value.
#   * DESC stores `~key` (negation overflows on `Int64.MIN`).
#
# The partition directory is a linear scan (small partition counts);
# `partition_topn_hash_state` is the hashed, multi-key, full-row version.
# `drain_to_record_batch` emits (part_key, key, payload) per partition, in the
# order partitions were first seen, each partition best first.
# =============================================================================

from std.collections import Optional

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.column_native import ColumnNativeBatch
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)
from komira_expr.stage_program import BREAKER_PARTITION_TOPN
from komira_operator_api.breaker_state_trait import BreakerState, BreakerStateCombinable

from .bounded_heap import BoundedHeapInt64Payload, HeapSlot


comptime PTOPN_DIR_ASC: Int = 0
"""ASC: the N smallest order keys per partition."""

comptime PTOPN_DIR_DESC: Int = 1
"""DESC: the N largest order keys per partition (stored as `~key`)."""


def _nullable_i64(vals: List[Int64], valid: List[Bool]) -> Column[HeapRegion]:
    var n = len(vals)
    var any_null = False
    for i in range(n):
        if not valid[i]:
            any_null = True
            break
    var arr: PrimitiveArray[DType.int64]
    if any_null:
        arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    else:
        arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.store[1](i, vals[i])
        if not valid[i]:
            arr._set_null(i)
    return Column.from_primitive[DType.int64](arr^)


struct PartitionTopNState[
    part_key_col: Int, key_col: Int, payload_col: Int, N: Int, sort_dir: Int
](Movable, BreakerStateCombinable):
    """Top N rows per partition over INT64 columns. See the module header."""

    var part_keys: List[Int64]
    var part_is_null: List[Bool]
    var heaps: List[BoundedHeapInt64Payload[Self.N]]
    var null_order_heaps: List[BoundedHeapInt64Payload[Self.N]]

    def __init__(out self):
        self.part_keys = List[Int64]()
        self.part_is_null = List[Bool]()
        self.heaps = List[BoundedHeapInt64Payload[Self.N]]()
        self.null_order_heaps = List[BoundedHeapInt64Payload[Self.N]]()

    @staticmethod
    def state_tag() -> Int:
        return BREAKER_PARTITION_TOPN

    @staticmethod
    @always_inline
    def capacity() -> Int:
        return Self.N

    @always_inline
    def n_partitions(self) -> Int:
        return len(self.part_keys)

    def _find_or_create_partition(mut self, pk: Int64, is_null: Bool) -> Int:
        """The directory index of partition `(pk, is_null)`, appended if new.
        A NULL partition key matches only the NULL partition."""
        for i in range(len(self.part_keys)):
            if self.part_is_null[i] == is_null and (is_null or self.part_keys[i] == pk):
                return i
        self.part_keys.append(Int64(0) if is_null else pk)
        self.part_is_null.append(is_null)
        self.heaps.append(BoundedHeapInt64Payload[Self.N]())
        self.null_order_heaps.append(BoundedHeapInt64Payload[Self.N]())
        return len(self.part_keys) - 1

    @always_inline
    def _push_null_order(mut self, p: Int, pay: Int64):
        self.null_order_heaps[p].push(Int64(0), pay)

    def feed_row[bo: Origin[mut=False]](mut self, batch: BatchView[bo], row: Int) raises:
        """Take one row into its partition's heap, or its NULL-order rows."""
        var pk_null = batch.col_is_null(Self.part_key_col, row)
        var pk = batch.col_i64(Self.part_key_col).load[1](row)[0]
        var pay = batch.col_i64(Self.payload_col).load[1](row)[0]
        var p = self._find_or_create_partition(pk, pk_null)
        if batch.col_is_null(Self.key_col, row):
            self._push_null_order(p, pay)
            return
        var key = batch.col_i64(Self.key_col).load[1](row)[0]
        comptime if Self.sort_dir == PTOPN_DIR_DESC:
            self.heaps[p].push(~key, pay)
        else:
            self.heaps[p].push(key, pay)

    def probe_batch[bo: Origin[mut=False], join_t: Int](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("PartitionTopNState.probe_batch: not a JOIN_PROBE state")

    def probe_asof_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("PartitionTopNState.probe_asof_batch: not an ASOF_JOIN state")

    def drain_to_record_batch(self) raises -> Optional[RecordBatch]:
        """Every partition's kept rows as (part_key, key, payload), best
        first, NULL order keys last, partitions in first-seen order."""
        var out_part = List[Int64]()
        var part_valid = List[Bool]()
        var out_keys = List[Int64]()
        var key_valid = List[Bool]()
        var out_pay = List[Int64]()
        for p in range(len(self.part_keys)):
            var local = self.heaps[p].copy()
            var slots = local.extract_sorted()
            for i in range(len(slots)):
                var k = slots[i].key
                comptime if Self.sort_dir == PTOPN_DIR_DESC:
                    k = ~k
                out_part.append(self.part_keys[p])
                part_valid.append(not self.part_is_null[p])
                out_keys.append(k)
                key_valid.append(True)
                out_pay.append(slots[i].payload_row_id)
            var null_local = self.null_order_heaps[p].copy()
            var nulls = null_local.extract_sorted()
            var room = min(Self.N - len(slots), len(nulls))
            for i in range(room):
                out_part.append(self.part_keys[p])
                part_valid.append(not self.part_is_null[p])
                out_keys.append(Int64(0))
                key_valid.append(False)
                out_pay.append(nulls[i].payload_row_id)
        var all_valid = List[Bool](capacity=len(out_pay))
        for _ in range(len(out_pay)):
            all_valid.append(True)
        var sb = SchemaBuilder()
        sb.add_field(Field(String("part_key"), ArrowType.INT64, True))
        sb.add_field(Field(String("key"), ArrowType.INT64, True))
        sb.add_field(Field(String("payload"), ArrowType.INT64, True))
        var built = RecordBatch.from_typed_columns_3(
            sb.build(),
            _nullable_i64(out_part, part_valid),
            _nullable_i64(out_keys, key_valid),
            _nullable_i64(out_pay, all_valid),
        )
        var native: ColumnNativeBatch = column_native_from_record_batch(built^)
        return Optional[RecordBatch](record_batch_from_column_native(native^))

    def combine(mut self, var other: Self) raises:
        """Merge another worker's state partition by partition: its heap rows
        under their stored keys, its NULL-order rows under the same payload order."""
        for op in range(len(other.part_keys)):
            var p = self._find_or_create_partition(other.part_keys[op], other.part_is_null[op])
            var oh = other.heaps[op].copy()
            var entries = oh.extract_sorted()
            for i in range(len(entries)):
                self.heaps[p].push(entries[i].key, entries[i].payload_row_id)
            var onh = other.null_order_heaps[op].copy()
            var other_nulls = onh.extract_sorted()
            for i in range(len(other_nulls)):
                self._push_null_order(p, other_nulls[i].payload_row_id)
