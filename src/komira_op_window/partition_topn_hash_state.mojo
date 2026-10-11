# =============================================================================
# partition_topn_hash_state -- top N full rows per partition, hashed
# =============================================================================
#
# `PartitionTopNHashState[KB, order_col, order_dt, N, sort_dir, ties,
# *Payloads]` is the BreakerState of the typed stage's PARTITION_TOPN arm: for
# each partition (a composite, mixed-type key, `part_key_block`) it keeps the
# top N rows by one order key, and emits the FULL rows (partition keys, order
# key, payload columns), with memory bounded by the rows kept, not the input.
#
#   * Partitions: `ptn_dense_directory` maps a key to a dense index; the key
#     block hashes and compares (NULL equals NULL, floats canonical).
#   * Per partition, a bounded heap of capacity N over the order key
#     (`bounded_heap`): numeric keys as an order-preserving Int64, STRING keys
#     byte-wise. The rows themselves live in one recycled-slot buffer
#     (`order_vals`, `payloads`); a slot leaving a heap is reused.
#   * Order (docs/design/query_semantics.md §4): floats in DuckDB's order (NaN
#     above +inf, -0.0 equal to +0.0); DESC stores the bitwise NOT of the
#     ASC key; NULL order keys sort last in both directions.
#   * `PTN_TIES_ROW` (ROW_NUMBER): exactly the first N rows per partition.
#     `PTN_TIES_RANK` (RANK <= N): every row whose rank is at most N, which is
#     every row tied with the N-th: the heap keeps N rows and a per-partition
#     list keeps the rows tied with its root (the N-th key); when a better row
#     pushes the root out and the new root is a different key, the tied rows
#     are dropped with it. NULL-order rows are peers of each other with rank
#     (non-NULL rows) + 1, so they are kept while the partition has fewer than
#     N non-NULL rows.
#
# A partition's key comes back as the first value seen for it. Partitions are
# emitted in first-seen order, each partition best first.
# =============================================================================

from std.collections import Optional
from std.memory import bitcast

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.column_native import ColumnNativeBatch
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)
from komira_expr.stage_program import BREAKER_PARTITION_TOPN
from komira_op_sort.sort_stage_columns import _sort_arrow_type, sort_bits_of, sort_from_bits
from komira_op_sort.sort_stage_payloads import PayloadColumn
from komira_operator_api.breaker_state_trait import BreakerState, BreakerStateCombinable
from komira_udf.float_quotient_order import canonical_bits_f32, canonical_bits_f64

from .bounded_heap import BoundedHeapInt64Payload, BoundedHeapStringPayload, HeapSlotStr
from .part_key_block import PartKeyBlock, PartKeyBlockTrait
from .ptn_dense_directory import PTNDenseDirectory


comptime PTN_DIR_ASC: Int = 0
"""ASC: the N smallest order keys per partition."""

comptime PTN_DIR_DESC: Int = 1
"""DESC: the N largest order keys per partition."""

comptime PTN_TIES_ROW: Int = 0
"""ROW_NUMBER: exactly N rows per partition."""

comptime PTN_TIES_RANK: Int = 1
"""RANK: every row whose rank is at most N."""

comptime PTN_ORDER_STRING_SENTINEL: DType = DType.uint8
"""The `order_dt` that selects a STRING order key (byte-wise heap). `uint8`
is never a numeric order key here, so it is unambiguous."""


@always_inline
def _ptn_order_is_string[order_dt: DType]() -> Bool:
    return order_dt == PTN_ORDER_STRING_SENTINEL


@always_inline
def _read_order[dt: DType, bo: Origin[mut=False]](batch: BatchView[bo], col: Int, row: Int) -> Scalar[dt]:
    comptime if dt == DType.int64:
        return rebind[Scalar[dt]](batch.col_i64(col).load[1](row)[0])
    elif dt == DType.int32:
        return rebind[Scalar[dt]](batch.col_i32(col).load[1](row)[0])
    elif dt == DType.float64:
        return rebind[Scalar[dt]](batch.col_f64(col).load[1](row)[0])
    elif dt == DType.float32:
        return rebind[Scalar[dt]](batch.col_f32(col).load[1](row)[0])
    else:
        return rebind[Scalar[dt]](batch.col_i64(col).load[1](row)[0])


@always_inline
def _order_heap_key[dt: DType](value: Scalar[dt]) -> Int64:
    """An order-preserving Int64 for an order key, ascending.

    Integers map to themselves. A float maps through its canonical form
    (every NaN to one positive NaN, -0.0 to +0.0) to the signed integer whose
    order is the float's: a non-negative float's bits are already ordered;
    a negative float's bits order in reverse, which XOR with the 63 low bits
    undoes. The canonical NaN maps above +inf, and -0.0 and +0.0 map to one
    key, which is DuckDB's order (§4.3, §4.4)."""
    comptime if dt == DType.int64:
        return rebind[Int64](value)
    elif dt == DType.int32:
        return Int64(rebind[Int32](value))
    elif dt == DType.float64:
        var s = bitcast[DType.int64, 1](
            SIMD[DType.uint64, 1](canonical_bits_f64(rebind[Float64](value)))
        )[0]
        if s < 0:
            return s ^ Int64(0x7FFFFFFFFFFFFFFF)
        return s
    elif dt == DType.float32:
        var s32 = Int64(
            bitcast[DType.int32, 1](
                SIMD[DType.uint32, 1](canonical_bits_f32(rebind[Float32](value)))
            )[0]
        )
        if s32 < 0:
            return s32 ^ Int64(0x7FFFFFFF)
        return s32
    else:
        return rebind[Int64](value)


@always_inline
def _stored_key[sort_dir: Int](hk: Int64) -> Int64:
    """The heap key: `hk` for ASC, `~hk` for DESC (order-reversing without
    the overflow of negation)."""
    comptime if sort_dir == PTN_DIR_DESC:
        return ~hk
    else:
        return hk


struct PartitionTopNHashState[
    KB: PartKeyBlockTrait,
    order_col: Int,
    order_dt: DType,
    N: Int,
    sort_dir: Int,
    ties: Int,
    *Payloads: PayloadColumn,
](Movable, BreakerStateCombinable):
    """Top N full rows per partition. See the module header.

    Parameters:
        KB: the partition-key block, `PartKeyBlock[*PartKeys]`.
        order_col: the input column of the order key.
        order_dt: the order key's DType, or `PTN_ORDER_STRING_SENTINEL`.
        N: the per-partition limit.
        sort_dir: `PTN_DIR_ASC` / `PTN_DIR_DESC`.
        ties: `PTN_TIES_ROW` / `PTN_TIES_RANK`.
        Payloads: the carried columns (`PayloadCol_Typed[dt, col]` ...).
    """

    var dir: PTNDenseDirectory
    var keys: Self.KB
    var rep_row: List[Int]
    var heaps: List[BoundedHeapInt64Payload[Self.N]]
    var str_heaps: List[BoundedHeapStringPayload[Self.N, Self.sort_dir]]
    # RANK: per partition, the slots of rows tied with the heap's root and
    # not in the heap.
    var tie_slots: List[List[Int]]
    # Per partition, the slots of rows whose order key is NULL.
    var null_slots: List[List[Int]]
    # Per partition, the non-NULL order keys seen (RANK's NULL rank).
    var nonnull_seen: List[Int]
    # The row buffer: per slot, the order key's bits and stored heap key
    # (numeric channel) and every payload column.
    var order_vals: List[UInt64]
    var stored_keys: List[Int64]
    var payloads: Tuple[*Self.Payloads]
    var _free_slots: List[Int]
    var _slot_high: Int

    def __init__(out self, var keys: Self.KB):
        self.dir = PTNDenseDirectory.new()
        self.keys = keys^
        self.rep_row = List[Int]()
        self.heaps = List[BoundedHeapInt64Payload[Self.N]]()
        self.str_heaps = List[BoundedHeapStringPayload[Self.N, Self.sort_dir]]()
        self.tie_slots = List[List[Int]]()
        self.null_slots = List[List[Int]]()
        self.nonnull_seen = List[Int]()
        self.order_vals = List[UInt64]()
        self.stored_keys = List[Int64]()
        self.payloads = Tuple[*Self.Payloads]()
        self._free_slots = List[Int]()
        self._slot_high = 0

    @staticmethod
    def state_tag() -> Int:
        return BREAKER_PARTITION_TOPN

    @always_inline
    def n_partitions(self) -> Int:
        return self.dir.size()

    # =========================================================================
    # Partitions and slots
    # =========================================================================

    def _append_partition(mut self):
        comptime if _ptn_order_is_string[Self.order_dt]():
            self.str_heaps.append(BoundedHeapStringPayload[Self.N, Self.sort_dir]())
        else:
            self.heaps.append(BoundedHeapInt64Payload[Self.N]())
        self.tie_slots.append(List[Int]())
        self.null_slots.append(List[Int]())
        self.nonnull_seen.append(0)

    def _find_or_create(mut self, fed_token: Int) -> Int:
        """The dense index of the partition of fed row `fed_token` (its keys
        already in `self.keys`), inserted if new. Used by `combine`."""
        var h = self.keys.hash_row(fed_token)
        var cur = self.dir.probe_start(h)
        while True:
            if self.dir.slot_is_empty(cur):
                var idx = self.dir.insert_new(h)
                self.rep_row.append(fed_token)
                self._append_partition()
                return idx
            if self.dir.slot_salt_matches(cur):
                var idx = self.dir.slot_dense_idx(cur)
                if self.keys.equals_rows(self.rep_row[idx], fed_token):
                    return idx
            cur = self.dir.advance(cur)

    @always_inline
    def _find_or_create_batch[bo: Origin[mut=False]](mut self, batch: BatchView[bo], row: Int) raises -> Int:
        """The dense index of `batch[row]`'s partition, probed before the key
        is stored: a row of a known partition stores nothing; a new
        partition stores its key once, as the representative."""
        var h = self.keys.hash_batch_row[bo](batch, row)
        var cur = self.dir.probe_start(h)
        while True:
            if self.dir.slot_is_empty(cur):
                var rep_token = self.keys.feed_row[bo](batch, row)
                var idx = self.dir.insert_new(h)
                self.rep_row.append(rep_token)
                self._append_partition()
                return idx
            if self.dir.slot_salt_matches(cur):
                var idx = self.dir.slot_dense_idx(cur)
                if self.keys.equals_batch_row_to_rep[bo](batch, row, self.rep_row[idx]):
                    return idx
            cur = self.dir.advance(cur)

    @always_inline
    def _alloc_slot(mut self) -> Int:
        if len(self._free_slots) > 0:
            return self._free_slots.pop()
        var s = self._slot_high
        self._slot_high += 1
        self.order_vals.append(UInt64(0))
        self.stored_keys.append(Int64(0))
        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].ensure_len(self._slot_high)
        return s

    @always_inline
    def _free_ties(mut self, p: Int):
        for i in range(len(self.tie_slots[p])):
            self._free_slots.append(self.tie_slots[p][i])
        self.tie_slots[p].clear()

    @always_inline
    def _free_nulls(mut self, p: Int):
        for i in range(len(self.null_slots[p])):
            self._free_slots.append(self.null_slots[p][i])
        self.null_slots[p].clear()

    @always_inline
    def _store_payloads_at[bo: Origin[mut=False]](mut self, slot: Int, batch: BatchView[bo], row: Int) raises:
        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].read_into_slot[bo](slot, batch, row)

    def _copy_slot_from(mut self, dst: Int, other: Self, src: Int):
        self.order_vals[dst] = other.order_vals[src]
        self.stored_keys[dst] = other.stored_keys[src]
        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].copy_slot(dst, other.payloads[p], src)

    # =========================================================================
    # Placement (the slot is allocated and stored by the caller)
    # =========================================================================

    def _place_numeric(mut self, p: Int, stored: Int64, slot: Int):
        """Put a row with a non-NULL order key into partition `p`, freeing
        whatever leaves (the row itself, or rows it pushes out)."""
        self.nonnull_seen[p] += 1
        if self.heaps[p].size() < Self.N:
            _ = self.heaps[p].push_returning_evicted(stored, Int64(slot))
            self._drop_nulls_if_ranked_out(p)
            return
        var root = self.heaps[p].peek_root().key
        if stored > root:
            self._free_slots.append(slot)
        elif stored == root:
            comptime if Self.ties == PTN_TIES_RANK:
                self.tie_slots[p].append(slot)
            else:
                self._free_slots.append(slot)
        else:
            var evicted = Int(self.heaps[p].push_returning_evicted(stored, Int64(slot)))
            comptime if Self.ties == PTN_TIES_RANK:
                if self.heaps[p].peek_root().key == root:
                    # The evicted row still ties with the N-th key.
                    self.tie_slots[p].append(evicted)
                else:
                    self._free_ties(p)
                    self._free_slots.append(evicted)
            else:
                self._free_slots.append(evicted)
        self._drop_nulls_if_ranked_out(p)

    def _place_string[bo: Origin[mut=False]](mut self, p: Int, key: Span[UInt8, bo], slot: Int):
        """`_place_numeric` for a STRING order key."""
        self.nonnull_seen[p] += 1
        if self.str_heaps[p].size() < Self.N:
            _ = self.str_heaps[p].push_returning_evicted(key, Int64(slot))
            self._drop_nulls_if_ranked_out(p)
            return
        var c = self.str_heaps[p].compare_to_root(key)
        if c > 0:
            self._free_slots.append(slot)
        elif c == 0:
            comptime if Self.ties == PTN_TIES_RANK:
                self.tie_slots[p].append(slot)
            else:
                self._free_slots.append(slot)
        else:
            var old_root = self.str_heaps[p].root_key_bytes()
            var evicted = Int(self.str_heaps[p].push_returning_evicted(key, Int64(slot)))
            comptime if Self.ties == PTN_TIES_RANK:
                if self.str_heaps[p].compare_to_root(Span(old_root)) == 0:
                    self.tie_slots[p].append(evicted)
                else:
                    self._free_ties(p)
                    self._free_slots.append(evicted)
            else:
                self._free_slots.append(evicted)
        self._drop_nulls_if_ranked_out(p)

    @always_inline
    def _drop_nulls_if_ranked_out(mut self, p: Int):
        """RANK: NULL-order rows rank (non-NULL rows) + 1, so once N non-NULL
        rows are seen they are out."""
        comptime if Self.ties == PTN_TIES_RANK:
            if self.nonnull_seen[p] >= Self.N and len(self.null_slots[p]) > 0:
                self._free_nulls(p)

    def _place_null(mut self, p: Int, slot: Int):
        """Keep a NULL-order row while it can still be in the result."""
        comptime if Self.ties == PTN_TIES_RANK:
            if self.nonnull_seen[p] < Self.N:
                self.null_slots[p].append(slot)
            else:
                self._free_slots.append(slot)
        else:
            if len(self.null_slots[p]) < Self.N:
                self.null_slots[p].append(slot)
            else:
                self._free_slots.append(slot)

    # =========================================================================
    # Feed
    # =========================================================================

    @always_inline
    def feed_row[bo: Origin[mut=False]](mut self, batch: BatchView[bo], row: Int) raises:
        """Take one input row into its partition.

        PERF-CRITICAL: a row whose order key cannot enter a full heap (worse
        than the root, or tied with it under ROW_NUMBER) is dropped after one
        compare, before any slot is allocated or written; the partition is
        found by probing with the row's key, without storing it."""
        var p = self._find_or_create_batch[bo](batch, row)
        if batch.col_is_null(Self.order_col, row):
            var nslot = self._alloc_slot()
            self._store_payloads_at[bo](nslot, batch, row)
            self._place_null(p, nslot)
            return
        comptime if _ptn_order_is_string[Self.order_dt]():
            var sv = batch.col_str(Self.order_col).get(row)
            var key = List[UInt8](capacity=sv.length())
            for i in range(sv.length()):
                key.append(sv.byte_at(i))
            if self.str_heaps[p].size() >= Self.N:
                var c = self.str_heaps[p].compare_to_root(Span(key))
                var keep = c < 0
                comptime if Self.ties == PTN_TIES_RANK:
                    keep = c <= 0
                if not keep:
                    self.nonnull_seen[p] += 1
                    self._drop_nulls_if_ranked_out(p)
                    return
            var slot = self._alloc_slot()
            self._store_payloads_at[bo](slot, batch, row)
            self._place_string(p, Span(key), slot)
        else:
            var okey = _read_order[Self.order_dt, bo](batch, Self.order_col, row)
            var stored = _stored_key[Self.sort_dir](_order_heap_key[Self.order_dt](okey))
            if self.heaps[p].size() >= Self.N:
                var root = self.heaps[p].peek_root().key
                var keep = stored < root
                comptime if Self.ties == PTN_TIES_RANK:
                    keep = stored <= root
                if not keep:
                    self.nonnull_seen[p] += 1
                    self._drop_nulls_if_ranked_out(p)
                    return
            var slot = self._alloc_slot()
            self.order_vals[slot] = sort_bits_of[Self.order_dt](okey)
            self.stored_keys[slot] = stored
            self._store_payloads_at[bo](slot, batch, row)
            self._place_numeric(p, stored, slot)

    def probe_batch[bo: Origin[mut=False], join_t: Int](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("PartitionTopNHashState.probe_batch: not a JOIN_PROBE state")

    def probe_asof_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("PartitionTopNHashState.probe_asof_batch: not an ASOF_JOIN state")

    def feed_chunk_global[
        W: Int, bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int, valid: SIMD[DType.bool, W]) raises:
        raise Error("PartitionTopNHashState.feed_chunk_global: not a 0-key HASH_AGG state")

    # =========================================================================
    # Combine
    # =========================================================================

    def combine(mut self, var other: Self) raises:
        """Merge another worker's state. Its partition representatives are
        appended to this key block and matched or inserted; each of its kept
        rows is copied into a fresh slot and placed as if fed here, and its
        non-NULL counts are added. The result equals one worker fed every
        row (up to which of several tied rows ROW_NUMBER keeps)."""
        var base = self.keys.n_rows_count()
        var other_reps = other.rep_row.copy()
        self.keys.append_other(other.keys)
        for op in range(other.dir.size()):
            var sp = self._find_or_create(base + other_reps[op])
            var seen_before = self.nonnull_seen[sp]
            comptime if _ptn_order_is_string[Self.order_dt]():
                var oh = other.str_heaps[op].copy()
                var root_bytes = List[UInt8]()
                if oh.size() > 0:
                    root_bytes = oh.root_key_bytes()
                var slots = oh.extract_sorted()
                for i in range(len(slots)):
                    var ns = self._alloc_slot()
                    self._copy_slot_from(ns, other, Int(slots[i].payload_row_id))
                    self._place_string(sp, oh.key_span_of_slot(slots[i]), ns)
                for i in range(len(other.tie_slots[op])):
                    var ns2 = self._alloc_slot()
                    self._copy_slot_from(ns2, other, other.tie_slots[op][i])
                    self._place_string(sp, Span(root_bytes), ns2)
            else:
                var oh2 = other.heaps[op].copy()
                var slots2 = oh2.extract_sorted()
                for i in range(len(slots2)):
                    var ns3 = self._alloc_slot()
                    self._copy_slot_from(ns3, other, Int(slots2[i].payload_row_id))
                    self._place_numeric(sp, slots2[i].key, ns3)
                for i in range(len(other.tie_slots[op])):
                    var src = other.tie_slots[op][i]
                    var ns4 = self._alloc_slot()
                    self._copy_slot_from(ns4, other, src)
                    self._place_numeric(sp, other.stored_keys[src], ns4)
            self.nonnull_seen[sp] = seen_before + other.nonnull_seen[op]
            for i in range(len(other.null_slots[op])):
                var ns5 = self._alloc_slot()
                self._copy_slot_from(ns5, other, other.null_slots[op][i])
                self._place_null(sp, ns5)
            self._drop_nulls_if_ranked_out(sp)

    # =========================================================================
    # Drain
    # =========================================================================

    def _null_room(self, p: Int, kept: Int) -> Int:
        """How many NULL-order rows partition `p` emits after `kept` rows."""
        comptime if Self.ties == PTN_TIES_RANK:
            if self.nonnull_seen[p] < Self.N:
                return len(self.null_slots[p])
            return 0
        else:
            return min(Self.N - kept, len(self.null_slots[p]))

    def drain_to_record_batch(self) raises -> Optional[RecordBatch]:
        """Every partition's kept rows as `[pk0.., order_key, payload0..]`,
        best first, NULL order keys last."""
        comptime if _ptn_order_is_string[Self.order_dt]():
            return self._drain_string()
        var out_tokens = List[Int]()
        var out_slots = List[Int]()
        var key_valid = List[Bool]()
        for p in range(self.dir.size()):
            var local = self.heaps[p].copy()
            var slots = local.extract_sorted()
            for i in range(len(slots)):
                out_tokens.append(self.rep_row[p])
                out_slots.append(Int(slots[i].payload_row_id))
                key_valid.append(True)
            for i in range(len(self.tie_slots[p])):
                out_tokens.append(self.rep_row[p])
                out_slots.append(self.tie_slots[p][i])
                key_valid.append(True)
            for i in range(self._null_room(p, len(slots))):
                out_tokens.append(self.rep_row[p])
                out_slots.append(self.null_slots[p][i])
                key_valid.append(False)

        var sb = SchemaBuilder()
        self.keys.add_schema(sb)
        sb.add_field(Field(String("order_key"), _sort_arrow_type[Self.order_dt](), True))
        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].add_payload_schema_field(sb, p)

        var rb = RecordBatchBuilder()
        self.keys.emit_at_tokens(out_tokens, rb)
        var n = len(out_slots)
        var any_null = False
        for i in range(n):
            if not key_valid[i]:
                any_null = True
                break
        var oarr: PrimitiveArray[Self.order_dt]
        if any_null:
            oarr = PrimitiveArray[Self.order_dt].allocate_nullable(n)
        else:
            oarr = PrimitiveArray[Self.order_dt].allocate(n)
        for i in range(n):
            oarr.store[1](i, sort_from_bits[Self.order_dt](self.order_vals[out_slots[i]]))
            if not key_valid[i]:
                oarr._set_null(i)
        rb.add_column(Column.from_primitive[Self.order_dt](oarr^))
        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].emit_at_slots(out_slots, rb)
        var built = rb.build(sb.build())
        var native: ColumnNativeBatch = column_native_from_record_batch(built^)
        return Optional[RecordBatch](record_batch_from_column_native(native^))

    def _drain_string(self) raises -> Optional[RecordBatch]:
        """`drain_to_record_batch` for a STRING order key: the key strings
        come from each heap's arena (a tied row's key is its heap's root)."""
        var out_tokens = List[Int]()
        var out_slots = List[Int]()
        var out_okeys = List[String]()
        var key_valid = List[Bool]()
        for p in range(self.dir.size()):
            var local = self.str_heaps[p].copy()
            var root = String("")
            if local.size() > 0:
                var rb0 = local.root_key_bytes()
                root = String(StringSlice(unsafe_from_utf8=Span(rb0)))
            var slots = local.extract_sorted()
            for i in range(len(slots)):
                out_tokens.append(self.rep_row[p])
                out_slots.append(Int(slots[i].payload_row_id))
                var kb = local.key_bytes_of_slot(slots[i])
                out_okeys.append(String(StringSlice(unsafe_from_utf8=Span(kb))))
                key_valid.append(True)
            for i in range(len(self.tie_slots[p])):
                out_tokens.append(self.rep_row[p])
                out_slots.append(self.tie_slots[p][i])
                out_okeys.append(root)
                key_valid.append(True)
            for i in range(self._null_room(p, len(slots))):
                out_tokens.append(self.rep_row[p])
                out_slots.append(self.null_slots[p][i])
                out_okeys.append(String(""))
                key_valid.append(False)

        var sb = SchemaBuilder()
        self.keys.add_schema(sb)
        sb.add_field(Field(String("order_key"), ArrowType.STRING, True))
        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].add_payload_schema_field(sb, p)
        var rb = RecordBatchBuilder()
        self.keys.emit_at_tokens(out_tokens, rb)
        rb.add_column(Column.from_string(StringArray.from_strings_with_validity(out_okeys, key_valid)))
        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].emit_at_slots(out_slots, rb)
        var built = rb.build(sb.build())
        var native: ColumnNativeBatch = column_native_from_record_batch(built^)
        return Optional[RecordBatch](record_batch_from_column_native(native^))
