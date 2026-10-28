# =============================================================================
# sort_stage_buffer -- SortBuffer[KB, *Payloads], the stage sort buffer, and
# its key block
# =============================================================================
#
# The keys live behind one concrete key block `KB` (`SortKeyBlock[*Keys]`) so
# the payloads can be the parameter list's one variadic pack (`*Payloads`, of
# mixed DTypes). Storage is column-wise; the sort is an index permutation, a
# stable bottom-up merge sort over a comparator that reads the key columns in
# order with each key's run-time direction (payloads never compared). Equal
# keys keep input order. `combine` appends another buffer's rows after this
# buffer's; restore puts the spilled rows (chunks in spill order) before the
# rows fed since the spill, so a drain after either is the drain of one buffer
# fed the same rows in input order.
#
# NULLs: the buffer stores values only, no validity. `feed_row` refuses a row
# with a NULL in any bound key or payload column with a named error and leaves
# the buffer unchanged; callers filter or replace nulls first. The spill image
# and the drain carry no validity either.
#
# The drain sorts through `sort_multi.sort_batch_by_keys` when every key DType
# is one that kernel takes, and through the merge sort otherwise. The buffer is
# a `BreakerStateCombinable` (`komira_operator_api`) for the SORT breaker and a
# `SpillableOp` (`komira_engine_runtime`): its spill image is the pre-sort rows
# as THSPLC chunks.
#
# No pointer in any signature, no wildcard origin; cells cross the generic body
# through the UInt64 bit channel (`sort_stage_columns`).
# =============================================================================

from std.collections import Optional
from std.builtin.swap import swap
from std.memory import bitcast
from std.os import abort
from std.sys import size_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView, scalar_arrow_type
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_arrow.column_native import ColumnNativeBatch
from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)
from komira_engine_runtime.spill.spill_storage import ChunkId, SpillStorage
from komira_engine_runtime.spill.spillable_op import SpillableOp
from komira_expr.stage_program import BREAKER_SORT
from komira_operator_api.breaker_state_trait import (
    BreakerState,
    BreakerStateCombinable,
)

from .sort_multi import sort_batch_by_keys
from .sort_stage_buffer_spill import SortSpillLedger
from .sort_stage_key_block import (
    SortKeyBlock,
    SortKeyBlock1_F64,
    SortKeyBlock1_I64,
    SortKeyBlock1_String,
    SortKeyBlockTrait,
)
from .sort_stage_columns import (
    MAX_SORT_KEYS,
    SORT_DIR_ASC_U8,
    SORT_DIR_DESC_U8,
    SortKeyColumn,
    SortKeyColumn_Typed,
    sort_bits_of,
    sort_from_bits,
)
from .sort_stage_payloads import (
    PayloadColumn,
    PayloadCol_Typed,
    payload_column_f64,
    payload_column_i64,
)
from .sort_stage_string_key import (
    SortKeyColumn_String,
    sort_key_column_f64,
    sort_key_column_i64,
)


comptime Payload_I64 = PayloadCol_Typed[DType.int64, 0]
comptime Payload_F64 = PayloadCol_Typed[DType.float64, 0]


# =============================================================================
# §7 — SortBuffer[KB, *Payloads] — the variadic full-frame sort buffer
# =============================================================================


struct SortBuffer[KB: SortKeyBlockTrait, *Payloads: PayloadColumn](
    Movable, BreakerStateCombinable, SpillableOp
):
    """Bounded variadic-arity SortBuffer: keys behind the concrete `KB` block +
    a `*Payloads` payload pack.

    SoA storage: `keys: KB` (one `SortKeyColumn` per sort key, wrapped) +
    `payloads: Tuple[*Payloads]` (one `PayloadColumn` per payload column). Sort
    is by an index permutation `order: List[Int]`, stable-merge-sorted
    (O(n log n), `_msort_order`) by the
    lexicographic comparator over the KEY columns honoring the runtime per-key
    directions (payloads never participate in the comparator).

    `Movable`-only, NOT `Copyable` — both `KB` and `Tuple[*Payloads]` are not
    `Copyable` (Mojo does not synthesize `Copyable` for a `Tuple` over a
    trait-bounded pack).

    Per-key sort direction lives in `directions: InlineArray[UInt8,
    MAX_SORT_KEYS]` (runtime UInt8, 0=ASC / 1=DESC) — a fixed-size POD array,
    NOT a heap field.

    Stability: stable bottom-up merge sort + a strict-less comparator
    (`_less_than` is False on full ties) is STABLE — equal-key rows retain buffer
    order (the merge takes the LEFT run on ties).

    # The flat compatibility surface
    Callers that hold pre-extracted values drive the buffer via a FLAT
    by-value surface preserved across the KB wrap: `append_key[k](value)` +
    `append_payload[p](value)` per column, then `commit_row()` once per row to
    register the row in `order` + bump the spill age. Drain reads back via
    `key_at[k](row)` + `payload_at[p](row)` after `sort_in_place()` /
    `ordered_row(pos)`."""

    var keys: Self.KB
    var payloads: Tuple[*Self.Payloads]
    var order: List[Int]
    # SAFETY-NOTE: directions is a fixed-size POD InlineArray (no heap); only the
    # first key-arity entries are read.
    var directions: InlineArray[UInt8, MAX_SORT_KEYS]
    var _row_count: Int
    # --- SPILL metadata (SpillableOp conformance) ---
    var _spill: SortSpillLedger
    var _age_ticks: UInt64

    def __init__(out self):
        """The empty buffer: empty key block and payload pack, every direction
        ASC."""
        self.keys = Self.KB()
        self.payloads = Tuple[*Self.Payloads]()
        self.order = List[Int]()
        self.directions = InlineArray[UInt8, MAX_SORT_KEYS](fill=SORT_DIR_ASC_U8)
        self._row_count = 0
        self._spill = SortSpillLedger()
        self._age_ticks = UInt64(0)

    def __init__(
        out self, var keys: Self.KB, var payloads: Tuple[*Self.Payloads],
        initial_capacity: Int,
    ):
        """Construct from the (moved) key block + payload pack. Directions default
        to ASC; set per-key via `set_direction`."""
        self.keys = keys^
        self.payloads = payloads^
        self.order = List[Int](capacity=initial_capacity)
        self.directions = InlineArray[UInt8, MAX_SORT_KEYS](fill=SORT_DIR_ASC_U8)
        self._row_count = 0
        self._spill = SortSpillLedger()
        self._age_ticks = UInt64(0)

    @staticmethod
    def make_empty(capacity: Int) -> Self:
        """Construct an empty buffer with both packs reserved to `capacity`."""
        var pt = Tuple[*Self.Payloads]()

        comptime for p in range(Self.Payloads.__len__()):
            pt[p] = Self.Payloads[p].make(capacity)
        return Self(Self.KB.make_empty(capacity), pt^, capacity)

    @staticmethod
    def arity() -> Int:
        """Number of sort keys (the KB key-block arity)."""
        return Self.KB.arity()

    @staticmethod
    def payload_arity() -> Int:
        """Number of payload columns (the `*Payloads` pack length)."""
        return Self.Payloads.__len__()

    @staticmethod
    def state_tag() -> Int:
        """`BreakerState` discriminator — SortBuffer backs the SORT arm."""
        return BREAKER_SORT

    # -------------------------------------------------------------------------
    # The flat by-value append / read surface
    # -------------------------------------------------------------------------

    @always_inline
    def append_key[k: Int, kdt: DType](mut self, value: Scalar[kdt]):
        """Append one key value to key column slot `k`. The value's DType `kdt`
        is supplied by the caller (which knows the concrete shape); the value is
        bit-exactly round-tripped through the UInt64 channel into the slot's
        native column (the trait-erasure wall — the generic body cannot project
        the slot DType)."""
        self.keys.append_bits_at[k](sort_bits_of[kdt](value))

    @always_inline
    def append_payload[p: Int, pdt: DType](mut self, value: Scalar[pdt]):
        """Append one payload value to payload column slot `p`. Does NOT register
        the row — call `commit_row()` once per row after all columns appended.
        `pdt` supplied by the caller; bit-exact UInt64-channel round-trip."""
        self.payloads[p].append_bits(sort_bits_of[pdt](value))

    @always_inline
    def commit_row(mut self):
        """Register the current row in `order` + bump the spill age counter. Call
        once per row AFTER appending all key + payload values."""
        self.order.append(self._row_count)
        self._row_count += 1
        self._age_ticks += UInt64(1)

    @always_inline
    def set_direction(mut self, k: Int, dir_u8: UInt8):
        """Set the sort direction (0=ASC / 1=DESC) for key slot `k`."""
        self.directions[k] = dir_u8

    @always_inline
    def size(self) -> Int:
        """Current buffered row count."""
        return self._row_count

    @always_inline
    def ordered_row(self, pos: Int) -> Int:
        """The original row index at sorted position `pos` (valid post-sort)."""
        return self.order[pos]

    @always_inline
    def key_at[k: Int, kdt: DType](self, row: Int) -> Scalar[kdt]:
        """Read the raw key value of key slot `k` for original row index `row`,
        reconstructed at the caller-supplied DType `kdt` from the UInt64 channel
        (bit-exact inverse of `append_key[k, kdt]`)."""
        return sort_from_bits[kdt](self.keys.value_bits_slot[k](row))

    @always_inline
    def payload_at[p: Int, pdt: DType](self, row: Int) -> Scalar[pdt]:
        """Read payload slot `p`'s value for original row index `row`, at the
        caller-supplied DType `pdt` (bit-exact UInt64 channel)."""
        return sort_from_bits[pdt](self.payloads[p].value_bits_at(row))

    # -------------------------------------------------------------------------
    # BreakerState executable surface
    # -------------------------------------------------------------------------

    @always_inline
    def feed_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ) raises:
        """Accumulate one input row: read each bound key column + each payload
        column off `batch` (fan via `@parameter for`), then register the row.

        `@always_inline` fuses this body into the
        generic `Stage` SORT survivors loop, killing the per-row non-inlined
        `raises` frame (the top_n lever). Callees (`read_all`, `read_and_append`,
        `commit_row`) are already inlined on the concrete column impls.

        The buffer stores values without validity, so a row with a NULL in any
        bound key or payload column is refused (an error naming the column)
        before anything is appended; the buffer is unchanged. The error names the
        slot and its input column, e.g. "NULL in sort key k0 (input column 2)"."""
        # PERF-CRITICAL: one validity-bitmap probe per bound column and row;
        # a column without a bitmap answers from a null check, no load.
        var nk = self.keys.null_key_slot[bo](batch, row)
        if nk >= 0:
            raise Error(
                String("SortBuffer.feed_row: NULL in sort key k")
                + String(nk)
                + String(" (input column ")
                + String(self.keys.key_input_column(nk))
                + String("): the sort buffer carries no validity")
            )

        comptime for p in range(Self.Payloads.__len__()):
            if self.payloads[p].input_is_null[bo](batch, row):
                raise Error(
                    String("SortBuffer.feed_row: NULL in payload p")
                    + String(p)
                    + String(" (input column ")
                    + String(self.payloads[p].input_column())
                    + String("): the sort buffer carries no validity")
                )
        self.keys.read_all[bo](batch, row)

        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].read_and_append[bo](batch, row)
        self.commit_row()

    def feed_chunk_global[
        W: Int, bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int, valid: SIMD[DType.bool, W]) raises:
        raise Error("SortBuffer.feed_chunk_global: not a 0-key HASH_AGG state")

    def probe_batch[bo: Origin[mut=False], join_t: Int](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("SortBuffer.probe_batch: not a JOIN_PROBE state")

    def probe_asof_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("SortBuffer.probe_asof_batch: not an ASOF_JOIN state")

    def _build_schema(self) raises -> Schema:
        """The drain output schema: key fields `k0..kN-1` (native DType) ++
        payload fields `p0..pM-1`."""
        var sb = SchemaBuilder()
        self.keys.add_schema(sb)

        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].add_payload_schema_field(sb, p)
        return sb.build()

    def _emit_in_order(
        self, order: List[Int], var schema: Schema
    ) raises -> RecordBatch:
        """Build a (keys ++ payloads) RecordBatch with rows materialized in the
        given `order` permutation (native-DType per-column emit, trait-erasure
        wall). `order` == identity yields BUFFER order; `order` == sorted yields
        sorted order."""
        var rb = RecordBatchBuilder()
        self.keys.emit_all(order, rb)

        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].emit_sorted_column(order, rb)
        return rb.build(schema^)

    def drain_to_record_batch(self) raises -> Optional[RecordBatch]:
        """Emit a (k0..kN-1, payload0..payloadM-1) RecordBatch with rows in
        sorted order.

        For key DTypes the vectorized index-sort kernel accepts
        (INT64 / INT32 / FLOAT64 / STRING, `KB.all_keys_fast_sortable()` at
        COMPTIME), the columns are emitted in BUFFER order and sorted by
        `sort_multi.sort_batch_by_keys` (per-key stable radix / `sort_indices_*`
        and a gather; one lexicographic radix pass for 2+ INT / STRING keys), so
        the result is that kernel's, ties in buffer order.

        Other key DTypes (I16/U16/DATE32/...) the kernel does not accept keep the
        comparison merge sort (`sorted_order` -> sorted emit) — correctness-
        preserving fallback. BORROWS `self`; the per-column emit is delegated to
        each column's `emit_sorted_column` (trait-erasure wall)."""
        var built: RecordBatch

        comptime if Self.KB.all_keys_fast_sortable():
            # FAST PATH: emit in BUFFER order, then vectorized index-sort kernel.
            var ident = List[Int](capacity=self._row_count)
            for r in range(self._row_count):
                ident.append(r)
            var unsorted = self._emit_in_order(ident, self._build_schema())

            comptime n_keys = Self.KB.arity()
            var key_names = List[String](capacity=n_keys)
            var desc = List[Bool](capacity=n_keys)
            for k in range(n_keys):
                key_names.append(String("k") + String(k))
                desc.append(self.directions[k] == SORT_DIR_DESC_U8)
            built = sort_batch_by_keys(unsorted^, key_names, desc)
        else:
            # FALLBACK: comparison merge sort over the `order` permutation, then
            # sorted per-column emit (non-fast key DTypes).
            var order = self.sorted_order()
            built = self._emit_in_order(order, self._build_schema())

        # The sorted result is lifted into a ColumnNativeBatch (the breaker's
        # native column batch) and bridged back to a RecordBatch at the breaker
        # output. The body is a THSPLC chunk, so the round trip is the bytes of
        # a spill and restore.
        var native: ColumnNativeBatch = column_native_from_record_batch(built^)
        return Optional[RecordBatch](record_batch_from_column_native(native^))

    def sorted_order(self) -> List[Int]:
        """A COPY of the `order` index permutation, stable-merge-sorted by
        the lexicographic comparator with per-key runtime directions. Borrows
        `self` (the comparator is read-only over the columns)."""
        var local = self.order.copy()
        self._msort_order(local)
        return local^

    def _msort_order(self, mut order: List[Int]):
        """Stable bottom-up (iterative) merge sort of the `order` index
        permutation by the `_less_than` (lexicographic, per-key runtime
        direction) comparator. O(n log n) compares, O(n) scratch.

        Equal keys keep buffer order: the merge takes from the LEFT run
        unless the RIGHT is strictly less (`_less_than(right, left)`)."""
        var n = len(order)
        if n < 2:
            return
        var buf = List[Int](capacity=n)
        for _ in range(n):
            buf.append(0)
        var width = 1
        while width < n:
            var lo = 0
            while lo < n:
                var mid = lo + width
                if mid > n:
                    mid = n
                var hi = lo + 2 * width
                if hi > n:
                    hi = n
                # Merge order[lo:mid) and order[mid:hi) into buf[lo:hi).
                var i = lo
                var j = mid
                var k = lo
                while i < mid and j < hi:
                    # STABLE: take LEFT unless RIGHT is strictly less.
                    if self._less_than(order[j], order[i]):
                        buf[k] = order[j]
                        j += 1
                    else:
                        buf[k] = order[i]
                        i += 1
                    k += 1
                while i < mid:
                    buf[k] = order[i]
                    i += 1
                    k += 1
                while j < hi:
                    buf[k] = order[j]
                    j += 1
                    k += 1
                lo += 2 * width
            # Copy the merged run back into order for the next pass.
            for t in range(n):
                order[t] = buf[t]
            width *= 2

    @always_inline
    def _less_than(self, ri: Int, rj: Int) -> Bool:
        """Lexicographic `row ri < row rj` over all key slots, honoring per-key
        runtime direction. First non-equal key decides; full ties → False
        (stable: keep buffer order).

        The block's comptime-unrolled `slot_sorts_before` (native-DType
        `compare_at` per key) decides; full ties are False."""
        return self.keys.slot_sorts_before(ri, rj, self.directions)

    def sort_in_place(mut self):
        """In-place stable merge sort of the `order` index permutation
        (O(n log n); see `_msort_order`). Sorts a LOCAL copy then writes it back
        — `_msort_order` borrows `self` (the comparator is read-only over the
        columns) so it cannot run directly on `self.order` while `self` is also
        the comparator receiver."""
        var local = self.order.copy()
        self._msort_order(local)
        self.order = local^

    def combine(mut self, var other: Self) raises:
        """Cross-instance merge (S1 `BreakerStateCombinable`): append every
        buffered row of `other` (key + payload values) onto `self`'s buffer.

        Byte-identical-to-single-worker: a `SortBuffer` is an APPEND buffer — the
        sort runs at DRAIN time over the full `order` permutation, not at
        feed/combine time. So `combine` is a pure concatenation: `self`'s rows
        followed by `other`'s rows in `other`'s buffer order. The per-key
        `directions` config is comptime-identical across worker states, so
        `self`'s is kept. Appends every key column + payload column from `other`,
        then registers `other`'s rows in `order`."""
        var base = self._row_count
        var added = other._row_count
        self.keys.append_other(other.keys)

        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].append_other(other.payloads[p])
        for r in range(added):
            self.order.append(base + r)
        self._row_count = base + added
        self._age_ticks += UInt64(added)

    # =========================================================================
    # SpillableOp conformance (column breaker spills via THSPLC)
    # =========================================================================
    #
    # The SortBuffer is an APPEND buffer: keys + payloads are stored SoA as
    # native-DType `List[Scalar[dt]]` columns in INSERTION order (the sort is a
    # drain-time index permutation). Spill serializes that PRE-SORT image — a
    # `[k0..kN-1, payload0..payloadM-1]` columnar RecordBatch in buffer order —
    # through THSPLC (column grain; ZERO AoS<->SoA transpose). Restore re-feeds
    # those rows in input order (spilled rows first, then the rows fed after the
    # spill), so the subsequent stable-sorted drain is the un-spilled
    # reference's. The chunk bookkeeping and storage I/O are
    # `sort_stage_buffer_spill`.

    def _spill_schema(self) raises -> Schema:
        """The `[k0..kN-1, payload0..payloadM-1]` PRE-SORT spill schema — built
        identically to `drain_to_record_batch`'s schema."""
        var sb = SchemaBuilder()
        self.keys.add_schema(sb)

        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].add_payload_schema_field(sb, p)
        return sb.build()

    def _buffered_record_batch(self) raises -> RecordBatch:
        """Materialize the PRE-SORT (buffer-order) state as a `[k0..kN-1,
        payload0..payloadM-1]` RecordBatch over the IDENTITY permutation."""
        var n = self._row_count
        var identity = List[Int](capacity=n)
        for i in range(n):
            identity.append(i)

        var schema = self._spill_schema()
        var rb = RecordBatchBuilder()
        self.keys.emit_all(identity, rb)

        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].emit_sorted_column(identity, rb)
        return rb.build(schema^)

    def memory_usage_bytes(self) -> Int64:
        """Resident bytes attributable to this buffer (O(1)).

        Per-cell width is approximated at the UInt64-channel width (8 bytes) per
        key + per payload — the generic body cannot project the per-column DType
        to read its native `size_of` (trait-erasure wall), and 8 bytes is the
        widest GA cell (i64 / f64), so this is an upper bound. Plus the Int order
        index per row."""
        var n = self._row_count
        var n_cols = Self.KB.arity() + Self.Payloads.__len__()
        var per_row_bytes = n_cols * size_of[UInt64]() + size_of[Int]()
        return Int64(n * per_row_bytes)

    def age_ticks(self) -> UInt64:
        """Monotonic counter bumped once per buffered row (in `commit_row`)."""
        return self._age_ticks

    def can_spill(self) -> Bool:
        """True unless mid-restore."""
        return not self._spill.restoring

    def spilled_chunk_ids(self) -> List[ChunkId]:
        """The chunks this buffer has spilled and not yet restored or discarded,
        in spill order (the order their rows were fed)."""
        return self._spill.ids()

    def spill_to_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises -> Int64:
        """Serialize the buffered (pre-sort) state to `storage` via THSPLC and
        free the in-memory buffers. Returns BYTES FREED. The buffer may be fed
        again afterwards; a later restore puts the spilled rows back in front of
        the rows fed since."""
        var freed = self.memory_usage_bytes()

        self._spill.write(storage, self._buffered_record_batch())

        self.keys.clear_values()

        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].clear_values()
        self.order.clear()
        self._row_count = 0
        return freed

    def restore_from_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises:
        """Put every spilled chunk's rows back into this buffer, in input order:
        the chunks in spill order, then the rows fed since the last spill (they
        came later). A drain after the restore is the drain of one buffer fed
        all the rows in input order.

        Atomic: every chunk is read and decoded into a staging buffer first. If
        any read or decode raises (a chunk released behind the buffer's back, a
        corrupt image), the buffer, its chunk list and `can_spill` are as they
        were and the call may be retried or followed by `discard_spilled`. The
        chunks are released after the rows are in place; if releasing raises,
        the rows are restored, the chunk list is empty and the error is
        raised.

        ZERO-COPY decode: a decoded RecordBatch's column buffers are borrowed
        Arc-clone slices over the read-chunk bytes (NO memcpy); each typed
        scalar is COPIED OUT of the BatchView into the staging buffer's owning
        SoA storage, so NO borrowed byte escapes this method."""
        self._spill.restoring = True
        try:
            var schema = self._spill_schema()
            var staged = Self.make_empty(0)
            for ci in range(self._spill.count()):
                var restored = self._spill.read(storage, ci, schema)
                staged._append_from_record_batch(restored^)
            # Nothing below reads storage or raises, until the release.
            var age = self._age_ticks + UInt64(staged._row_count)
            var resident = Self.make_empty(0)
            self._swap_rows(resident)
            self.combine(staged^)
            self.combine(resident^)
            self._age_ticks = age
            self._spill.release_all(storage)
        except e:
            self._spill.restoring = False
            raise e^
        self._spill.restoring = False

    def discard_spilled[S: SpillStorage](mut self, mut storage: S) raises:
        """Release every outstanding spill chunk without restoring it. The
        spilled rows are lost; the rows resident in the buffer stay. A buffer
        that is dropped while it holds chunks leaves them to the storage's
        `cleanup`; call this first to release them.

        A partial release is not retried: every chunk is attempted, the chunk
        ledger is emptied whatever happens, and the first release error is
        raised afterwards. A chunk whose release failed is left to the
        storage's `cleanup`."""
        self._spill.release_all(storage)

    def _swap_rows(mut self, mut other: Self):
        """Exchange the row storage (keys, payloads, order) with `other`."""
        swap(self.keys, other.keys)
        swap(self.payloads, other.payloads)
        swap(self.order, other.order)
        swap(self._row_count, other._row_count)

    def _append_from_record_batch(mut self, var batch: RecordBatch) raises:
        """Re-feed every row of a decoded `[k0..kN-1, payload0..payloadM-1]`
        spill image into the buffer, in batch (buffer) order. Key `k` lives at
        spill column `k`; payload `p` at spill column `arity()+p`."""
        var n = batch.num_rows()
        var bv = BatchView(batch)
        var pay_base = Self.KB.arity()
        for row in range(n):
            self.keys.restore_all(bv, row)

            comptime for p in range(Self.Payloads.__len__()):
                self.payloads[p].restore_append(bv, pay_base + p, row)
            self.commit_row()
        _ = batch^


# =============================================================================
# §8 — Factory helpers
# =============================================================================

@always_inline
def make_sort_buffer_i64_1(
    initial_capacity: Int, dir_u8: UInt8 = SORT_DIR_ASC_U8
) -> SortBuffer[SortKeyBlock1_I64, Payload_I64]:
    """Single-I64-key + single-I64-payload SortBuffer with the given direction."""
    var buf = SortBuffer[SortKeyBlock1_I64, Payload_I64](
        SortKeyBlock1_I64((sort_key_column_i64(initial_capacity),)),
        (payload_column_i64(initial_capacity),),
        initial_capacity,
    )
    buf.set_direction(0, dir_u8)
    return buf^


@always_inline
def make_sort_buffer_f64_1(
    initial_capacity: Int, dir_u8: UInt8 = SORT_DIR_ASC_U8
) -> SortBuffer[SortKeyBlock1_F64, Payload_I64]:
    """Single-F64-key + single-I64-payload SortBuffer."""
    var buf = SortBuffer[SortKeyBlock1_F64, Payload_I64](
        SortKeyBlock1_F64((sort_key_column_f64(initial_capacity),)),
        (payload_column_i64(initial_capacity),),
        initial_capacity,
    )
    buf.set_direction(0, dir_u8)
    return buf^


@always_inline
def make_sort_buffer_i64_f64_i64_1(
    initial_capacity: Int, dir_u8: UInt8 = SORT_DIR_ASC_U8
) -> SortBuffer[SortKeyBlock1_I64, Payload_F64, Payload_I64]:
    """Single-I64-key + (F64, I64) payload pair, each payload a native typed
    slot of the `*Payloads` pack."""
    var buf = SortBuffer[SortKeyBlock1_I64, Payload_F64, Payload_I64](
        SortKeyBlock1_I64((sort_key_column_i64(initial_capacity),)),
        (
            payload_column_f64(initial_capacity),
            payload_column_i64(initial_capacity),
        ),
        initial_capacity,
    )
    buf.set_direction(0, dir_u8)
    return buf^
