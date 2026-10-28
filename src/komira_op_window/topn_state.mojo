# =============================================================================
# topn_state -- TopNState, the BreakerState of the typed stage's TOPN arm
# =============================================================================
#
# `TopNState[N, key_col, payload_col, sort_dir]` keeps the top N rows of an
# INT64 key column (at `key_col`) with an INT64 payload (at `payload_col`):
# the N smallest keys for `TOPN_DIR_ASC`, the N largest for `TOPN_DIR_DESC`,
# NULL keys LAST in both directions (docs/design/query_semantics.md §4.1).
#
#   * Non-NULL keys go to a `BoundedHeapInt64Payload[N]` that keeps the N
#     smallest STORED keys; DESC stores `~key`, which reverses the order of
#     every Int64 (negation would overflow on `Int64.MIN`).
#   * A NULL key is worse than every value, so its row survives only when
#     fewer than N rows have a value: the NULL-key rows are kept apart, in a
#     second bounded heap under one constant key, so the N smallest payload
#     ids survive (equal keys order by payload id, as above), and they fill
#     the result after the heap's rows. The NULL rows kept do not depend on
#     feed or merge order either.
#   * NULLs are placed LAST in both directions: this state has no
#     NULLS FIRST setting (the stage planner emits only the default
#     placement). `TopNSink` is the kernel's: it does not read `nulls_first`
#     and orders a numeric NULL slot by its stored value.
#
# `drain_to_record_batch` emits (key, payload), best first, NULL keys last.
# Rows with equal keys order by payload, smaller first (the heap's tie-break,
# `bounded_heap`), so a payload that is the input row index gives the stable
# sort's rows and order. `combine` merges another worker's state; the heap
# rows of the merge (NULL-key rows included) equal one worker fed every row,
# whatever the feed or merge order.
# `spill_to_storage` / `restore_from_storage` write the kept rows as one
# THSPLC chunk (stored keys verbatim, a NULL key as NULL) and read them back.
# =============================================================================

from std.collections import Optional
from std.sys import size_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.column_native import ColumnNativeBatch
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)
from komira_engine_runtime.spill.spill_storage import ChunkId, SpillStorage
from komira_engine_runtime.spill.spillable_op import SpillableOp
from komira_engine_runtime.spill.thsplc import THSPLCDecoder, THSPLCEncoder
from komira_expr.stage_program import BREAKER_TOPN
from komira_operator_api.breaker_state_trait import BreakerState, BreakerStateCombinable

from .bounded_heap import BoundedHeapInt64Payload, HeapSlot


comptime TOPN_DIR_ASC: Int = 0
"""ASC: the N smallest keys."""

comptime TOPN_DIR_DESC: Int = 1
"""DESC: the N largest keys (stored as `~key`)."""


def _key_payload_batch(
    keys: List[Int64], key_valid: List[Bool], pays: List[Int64]
) raises -> RecordBatch:
    """A 2-column (key, payload) INT64 batch; `key_valid[i]` False is a NULL
    key."""
    var n = len(keys)
    var any_null = False
    for i in range(n):
        if not key_valid[i]:
            any_null = True
            break
    var karr: PrimitiveArray[DType.int64]
    if any_null:
        karr = PrimitiveArray[DType.int64].allocate_nullable(n)
    else:
        karr = PrimitiveArray[DType.int64].allocate(n)
    var parr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        karr.store[1](i, keys[i])
        if not key_valid[i]:
            karr._set_null(i)
        parr.store[1](i, pays[i])
    var sb = SchemaBuilder()
    sb.add_field(Field(String("key"), ArrowType.INT64, True))
    sb.add_field(Field(String("payload"), ArrowType.INT64, True))
    return RecordBatch.from_typed_columns_2(
        sb.build(),
        Column.from_primitive[DType.int64](karr^),
        Column.from_primitive[DType.int64](parr^),
    )


struct TopNState[
    N: Int, key_col: Int, payload_col: Int, sort_dir: Int
](Movable, BreakerStateCombinable, SpillableOp):
    """The TOPN arm's state. See the module header.

    Parameters:
        N: the top-N limit.
        key_col: the input column of the INT64 key.
        payload_col: the input column of the INT64 payload.
        sort_dir: `TOPN_DIR_ASC` or `TOPN_DIR_DESC`.
    """

    var heap: BoundedHeapInt64Payload[Self.N]
    var null_heap: BoundedHeapInt64Payload[Self.N]
    var _spill_chunks: List[ChunkId]
    var _age_ticks: UInt64
    var _restoring: Bool

    def __init__(out self):
        self.heap = BoundedHeapInt64Payload[Self.N]()
        self.null_heap = BoundedHeapInt64Payload[Self.N]()
        self._spill_chunks = List[ChunkId]()
        self._age_ticks = UInt64(0)
        self._restoring = False

    @staticmethod
    def state_tag() -> Int:
        return BREAKER_TOPN

    @staticmethod
    @always_inline
    def capacity() -> Int:
        return Self.N

    @always_inline
    def _push_stored(mut self, stored: Int64, pay: Int64):
        self.heap.push(stored, pay)

    @always_inline
    def _push_null(mut self, pay: Int64):
        self.null_heap.push(Int64(0), pay)

    def feed_row[bo: Origin[mut=False]](mut self, batch: BatchView[bo], row: Int) raises:
        """Take one input row: its payload goes to the heap under its stored
        key, or to the NULL-key rows."""
        var pay = batch.col_i64(Self.payload_col).load[1](row)[0]
        self._age_ticks += UInt64(1)
        if batch.col_is_null(Self.key_col, row):
            self._push_null(pay)
            return
        var key = batch.col_i64(Self.key_col).load[1](row)[0]
        comptime if Self.sort_dir == TOPN_DIR_DESC:
            self._push_stored(~key, pay)
        else:
            self._push_stored(key, pay)

    def probe_batch[bo: Origin[mut=False], join_t: Int](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("TopNState.probe_batch: not a JOIN_PROBE state")

    def probe_asof_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("TopNState.probe_asof_batch: not an ASOF_JOIN state")

    def _rows(self, unflip: Bool) -> Tuple[List[Int64], List[Bool], List[Int64]]:
        """The kept rows, best first: the heap's (un-flipped when `unflip`),
        then NULL-key rows (smallest payload ids first) up to N in all."""
        var local = self.heap.copy()
        var slots = local.extract_sorted()
        var keys = List[Int64]()
        var valid = List[Bool]()
        var pays = List[Int64]()
        for i in range(len(slots)):
            var k = slots[i].key
            comptime if Self.sort_dir == TOPN_DIR_DESC:
                if unflip:
                    k = ~k
            keys.append(k)
            valid.append(True)
            pays.append(slots[i].payload_row_id)
        var null_local = self.null_heap.copy()
        var nulls = null_local.extract_sorted()
        var room = Self.N - len(slots)
        # A spill image needs no more NULL rows than this either: a heap only
        # grows, so after a merge the room left for NULL rows is no larger.
        for i in range(min(room, len(nulls))):
            keys.append(Int64(0))
            valid.append(False)
            pays.append(nulls[i].payload_row_id)
        return (keys^, valid^, pays^)

    def drain_to_record_batch(self) raises -> Optional[RecordBatch]:
        """The kept rows as (key, payload), best first, NULL keys last."""
        var rows = self._rows(True)
        var built = _key_payload_batch(rows[0], rows[1], rows[2])
        var native: ColumnNativeBatch = column_native_from_record_batch(built^)
        return Optional[RecordBatch](record_batch_from_column_native(native^))

    def combine(mut self, var other: Self) raises:
        """Merge another worker's state: its heap rows are pushed under their
        stored keys (both sides store the same way), its NULL-key rows join
        this side's under the same payload order."""
        var other_heap = other.heap.copy()
        var entries = other_heap.extract_sorted()
        for i in range(len(entries)):
            self.heap.push(entries[i].key, entries[i].payload_row_id)
        var other_nulls_heap = other.null_heap.copy()
        var other_nulls = other_nulls_heap.extract_sorted()
        for i in range(len(other_nulls)):
            self._push_null(other_nulls[i].payload_row_id)

    # =========================================================================
    # SpillableOp
    # =========================================================================

    def _spill_schema(self) raises -> Schema:
        var sb = SchemaBuilder()
        sb.add_field(Field(String("key"), ArrowType.INT64, True))
        sb.add_field(Field(String("payload"), ArrowType.INT64, True))
        return sb.build()

    def memory_usage_bytes(self) -> Int64:
        """Bytes of the kept rows."""
        return Int64(
            self.heap.size() * size_of[HeapSlot]()
            + self.null_heap.size() * size_of[HeapSlot]()
        )

    def age_ticks(self) -> UInt64:
        """Bumped once per fed row."""
        return self._age_ticks

    def can_spill(self) -> Bool:
        return not self._restoring

    def spill_to_storage[S: SpillStorage](mut self, mut storage: S) raises -> Int64:
        """Write the kept rows (stored keys verbatim, NULL keys as NULL) as
        one chunk and empty the state. Returns the bytes freed."""
        var freed = self.memory_usage_bytes()
        var rows = self._rows(False)
        var batch = _key_payload_batch(rows[0], rows[1], rows[2])
        self._spill_chunks.append(storage.write_chunk(THSPLCEncoder.encode(batch^)))
        self.heap = BoundedHeapInt64Payload[Self.N]()
        self.null_heap = BoundedHeapInt64Payload[Self.N]()
        return freed

    def restore_from_storage[S: SpillStorage](mut self, mut storage: S) raises:
        """Push every row of every spilled chunk back (stored keys verbatim)
        and release the chunks."""
        self._restoring = True
        var schema = self._spill_schema()
        for ci in range(len(self._spill_chunks)):
            var chunk = self._spill_chunks[ci]
            var restored = THSPLCDecoder.decode_copy(storage.read_chunk(chunk), schema.copy())
            var bv = BatchView(restored)
            for row in range(restored.num_rows()):
                var p = bv.col_i64(1).load[1](row)[0]
                if bv.col_is_null(0, row):
                    self._push_null(p)
                else:
                    self.heap.push(bv.col_i64(0).load[1](row)[0], p)
            storage.release_chunk(chunk)
        self._spill_chunks.clear()
        self._restoring = False
