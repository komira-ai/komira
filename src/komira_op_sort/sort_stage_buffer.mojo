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
# keys keep buffer order, and both `combine` (append another buffer's rows)
# and spill / restore keep buffer order, so a drain after either is the drain
# of one buffer fed the same rows.
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
from komira_engine_runtime.spill.thsplc import THSPLCDecoder, THSPLCEncoder
from komira_expr.stage_program import BREAKER_SORT
from komira_operator_api.breaker_state_trait import (
    BreakerState,
    BreakerStateCombinable,
)

from .sort_multi import sort_batch_by_keys
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


# =============================================================================
# §5 — SortKeyBlockTrait + SortKeyBlock[*Keys] — the wrapped key pack (KB)
# =============================================================================
#
# `SortKeyBlock[*Keys]` wraps the `*Keys` pack and exposes the NON-variadic
# methods the generic `SortBuffer` body needs. `SortBuffer` bounds `KB` on
# `SortKeyBlockTrait`, so the generic body reaches the key surface WITHOUT naming
# the variadic — the single `*` then lands on `*Payloads`.
#
# The per-slot methods `append_bits_at[k]` / `value_bits_slot[k]` carry a
# COMPTIME slot index, so a caller can append and read cells by value
# (`SortBuffer.append_key[k]` / `key_at[k]`).

trait SortKeyBlockTrait(Defaultable, Movable, Deinitable):
    """The NON-variadic key-block surface the generic `SortBuffer` body needs.

    Every per-slot typed cell crosses the UInt64 bit channel (`append_bits_at` /
    `value_bits_slot`) so the generic body never projects the per-column DType
    behind the wrap (the trait-erasure wall). The
    `slot_dir`-aware comparator (`compare_rows`) + schema + emit stay on the
    block (where the concrete `@parameter for k` over the pack lives)."""

    @staticmethod
    def make_empty(capacity: Int) -> Self:
        ...

    @staticmethod
    def arity() -> Int:
        ...

    @staticmethod
    def key0_is_varlen() -> Bool:
        """True iff key slot 0 is a variable-length (STRING) key. The bounded
        global TOP-N reads this at COMPTIME to elide the single-key SIMD reject
        fast path for a STRING order key (a varlen key cannot be loaded into a
        fixed-width SIMD vector — the STRING arity-1 case takes the scalar
        `feed_row` path instead)."""
        ...

    @staticmethod
    def all_keys_fast_sortable() -> Bool:
        """True iff EVERY key column's DType is one the vectorized index-sort
        kernel (`sort_batch_by_keys`) accepts — INT64 / INT32 / FLOAT64, or a
        STRING key (dict-rank encoded by the kernel). Read at COMPTIME by the
        drain to route the sorted-batch build through the fast radix/index-sort
        kernel (the multi-key sort kernel) instead of the O(n log n)
        comparison merge sort when eligible."""
        ...

    def read_all[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ):
        """Read every key column off `batch` at `row` and append (one row)."""
        ...

    def restore_all[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ):
        """SPILL restore — read each key at its OUTPUT slot index `k`."""
        ...

    def append_bits_at[k: Int](mut self, bits: UInt64):
        """Append one value (UInt64 bit pattern) to key slot `k`."""
        ...

    def value_bits_slot[k: Int](self, row: Int) -> UInt64:
        """Read key slot `k`'s value at buffered row `row` as UInt64 bits."""
        ...

    def compare_rows(self, i: Int, j: Int) -> Int:
        """Lexicographic ASC compare over all key slots; first non-equal decides."""
        ...

    def compare_slot(self, k: Int, i: Int, j: Int) -> Int:
        """3-way ASC compare of key slot `k` for rows i vs j (runtime `k`)."""
        ...

    def slot_sorts_before(
        self, i: Int, j: Int, directions: InlineArray[UInt8, MAX_SORT_KEYS]
    ) -> Bool:
        """True iff buffered row `i` sorts STRICTLY BEFORE buffered row `j` under
        the per-key (ASC/DESC) direction comparator (first non-equal key decides;
        full ties -> False, the STABLE contract). Comptime-unrolled over the
        `*Keys` pack (native-DType `compare_at` per key, NO runtime-k trait loop)
        — the merge-sort hot-loop comparator (the slot-vs-slot twin of
        `batch_row_sorts_before_slot`)."""
        ...

    def batch_row_sorts_before_slot[bo: Origin[mut=False]](
        self,
        batch: BatchView[bo],
        row: Int,
        slot: Int,
        directions: InlineArray[UInt8, MAX_SORT_KEYS],
    ) -> Bool:
        """True if a CANDIDATE row read DIRECTLY off `batch` at `row` sorts BEFORE
        the buffered `slot`'s row under the per-key (ASC/DESC) direction
        comparator (first non-equal key decides; full ties -> False). The TOP-N
        reject-path fast path — comptime-unrolled over the `*Keys` pack, native
        DType direct compare, NO per-row slot store, NO runtime-k trait loop."""
        ...

    def simd_reject_winner_mask_k0[W: Int, bo: Origin[mut=False]](
        self, batch: BatchView[bo], i: Int, slot: Int, dir0_u8: UInt8
    ) -> SIMD[DType.bool, W]:
        """TOP-N SIMD reject-path (single-key). W-wide mask of candidate keys
        (read off column 0 starting at row `i`) that sort STRICTLY BEFORE the
        buffered `slot`'s key under `dir0_u8`. Caller gates to `arity() == 1`."""
        ...

    def ensure_len_all(mut self, n: Int):
        """Grow every key column to at least `n` slots (zero-filled) — enables
        random-access overwrite for the bounded recycled-slot global TOP-N
        buffer."""
        ...

    def read_into_slot_all[bo: Origin[mut=False]](
        mut self, slot: Int, batch: BatchView[bo], row: Int
    ):
        """Read every key column off `batch` at `row` into random-access `slot`
        (the recycled-slot global TOP-N buffer). Caller has `ensure_len_all(
        slot + 1)`'d."""
        ...

    def copy_slot_from(mut self, dst: Int, other: Self, src: Int):
        """Copy every key column's value at `other`'s slot `src` into `self`'s
        random-access slot `dst` (cross-worker combine into the recycled-slot
        buffer). BORROWS `other`."""
        ...

    def emit_at_slots(self, slots: List[Int], mut rb: RecordBatchBuilder):
        """Append every key column materialized over the per-output-row `slots`
        (global-buffer slot ids) — the full-frame global TOP-N drain."""
        ...

    def append_other(mut self, other: Self):
        ...

    def clear_values(mut self):
        ...

    def add_schema(self, mut sb: SchemaBuilder):
        ...

    def emit_all(self, order: List[Int], mut rb: RecordBatchBuilder):
        ...


struct SortKeyBlock[*Keys: SortKeyColumn](SortKeyBlockTrait):
    """The variadic key block — wraps the `*Keys` pack so `SortBuffer` can carry
    a single concrete `KB` type-param and reserve its `*` for `*Payloads`.

    `Movable`-only (`Tuple[*Keys]` is not `Copyable`). `Defaultable` (empty key
    columns) for the field-less factory recipe."""

    var cols: Tuple[*Self.Keys]

    def __init__(out self):
        # Defaultable identity: empty key columns (pack-aware ctor).
        self.cols = Tuple[*Self.Keys]()

    def __init__(out self, var cols: Tuple[*Self.Keys]):
        self.cols = cols^

    @staticmethod
    def make_empty(capacity: Int) -> Self:
        var t = Tuple[*Self.Keys]()

        comptime for k in range(Self.Keys.__len__()):
            t[k] = Self.Keys[k].make(capacity)
        return Self(t^)

    @staticmethod
    def arity() -> Int:
        return Self.Keys.__len__()

    @staticmethod
    def key0_is_varlen() -> Bool:
        return Self.Keys[0].IS_VARLEN

    @staticmethod
    def all_keys_fast_sortable() -> Bool:
        # A key column is fast-sortable when the vectorized `sort_batch_by_keys`
        # kernel accepts it: a STRING key (IS_VARLEN — dict-rank encoded by the
        # kernel) or a fixed-width INT64 / INT32 / FLOAT64 key. Other fixed-width
        # DTypes (I16/U16/DATE32/...) the kernel does not accept fall back to the
        # comparison merge sort.
        var ok = True

        comptime for k in range(Self.Keys.__len__()):

            comptime if Self.Keys[k].IS_VARLEN:
                pass  # STRING — dict-rank encoded; supported.
            elif (
                Self.Keys[k].DT == DType.int64
                or Self.Keys[k].DT == DType.int32
                or Self.Keys[k].DT == DType.float64
            ):
                pass  # fixed-width fast DType — supported.
            else:
                ok = False
        return ok

    def read_all[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ):
        comptime for k in range(Self.Keys.__len__()):
            self.cols[k].read_and_append[bo](batch, row)

    def restore_all[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ):
        comptime for k in range(Self.Keys.__len__()):
            self.cols[k].restore_append[bo](batch, k, row)

    @always_inline
    def append_bits_at[k: Int](mut self, bits: UInt64):
        self.cols[k].append_bits(bits)

    @always_inline
    def value_bits_slot[k: Int](self, row: Int) -> UInt64:
        return self.cols[k].value_bits_at(row)

    def compare_rows(self, i: Int, j: Int) -> Int:
        comptime for k in range(Self.Keys.__len__()):
            var c = self.cols[k].compare_at(i, j)
            if c != 0:
                return c
        return 0

    def compare_slot(self, k: Int, i: Int, j: Int) -> Int:
        comptime for kk in range(Self.Keys.__len__()):
            if kk == k:
                return self.cols[kk].compare_at(i, j)
        return 0

    @always_inline
    def slot_sorts_before(
        self, i: Int, j: Int, directions: InlineArray[UInt8, MAX_SORT_KEYS]
    ) -> Bool:
        # Comptime-unrolled lexicographic slot-vs-slot compare: each key read off
        # its native-DType column List via `compare_at` (the comptime `for k`
        # folds to straight-line typed compares — NO runtime-k `compare_slot`
        # ladder, NO indirect call per comparison). Per-key direction applied;
        # first non-equal key decides; full ties -> False (STABLE). This is the
        # buffered-slot twin of `batch_row_sorts_before_slot` (the TOP-N reject
        # path) and the merge-sort hot-loop comparator: restoring the native-DType
        # per-comparison edge the typed full-frame SORT lost when `_less_than`
        # routed each key through the runtime-k `compare_slot` trait loop.
        comptime for k in range(Self.Keys.__len__()):
            var c = self.cols[k].compare_at(i, j)
            if c != 0:
                if directions[k] == SORT_DIR_DESC_U8:
                    return c > 0
                return c < 0
        return False

    @always_inline
    def batch_row_sorts_before_slot[bo: Origin[mut=False]](
        self,
        batch: BatchView[bo],
        row: Int,
        slot: Int,
        directions: InlineArray[UInt8, MAX_SORT_KEYS],
    ) -> Bool:
        # Comptime-unrolled lexicographic compare: candidate read off the batch
        # (native DType, direct typed load per key — no slot store, no bit
        # channel), per-key direction applied, first non-equal decides.
        comptime for k in range(Self.Keys.__len__()):
            var c = self.cols[k].compare_batch_row_to_slot[bo](batch, row, slot)
            if c != 0:
                if directions[k] == SORT_DIR_DESC_U8:
                    return c > 0
                return c < 0
        return False

    @always_inline
    def simd_reject_winner_mask_k0[W: Int, bo: Origin[mut=False]](
        self, batch: BatchView[bo], i: Int, slot: Int, dir0_u8: UInt8
    ) -> SIMD[DType.bool, W]:
        """TOP-N SIMD reject-path for the SINGLE-key case. Read W contiguous candidate keys off key column 0 starting at
        row `i` and return the lane mask where each candidate sorts STRICTLY
        BEFORE the buffered `slot`'s key 0 under direction `dir0_u8`. The root
        broadcast value is read off column 0's `slot`. Caller MUST gate to
        `arity() == 1` (only the lone key column participates) and `i + W <=
        n_rows`. All-false (the steady-state common case) means no winner in the
        chunk — the caller skips it whole."""
        var root = self.cols[0].value_at(slot)
        return self.cols[0].simd_reject_winner_mask[W, bo](
            batch, i, root, dir0_u8
        )

    def ensure_len_all(mut self, n: Int):
        comptime for k in range(Self.Keys.__len__()):
            self.cols[k].ensure_len(n)

    def read_into_slot_all[bo: Origin[mut=False]](
        mut self, slot: Int, batch: BatchView[bo], row: Int
    ):
        comptime for k in range(Self.Keys.__len__()):
            self.cols[k].read_into_slot[bo](slot, batch, row)

    def copy_slot_from(mut self, dst: Int, other: Self, src: Int):
        # CHANNEL-NATIVE slot-to-slot copy: fixed-width keys route the
        # value through the bit channel; the STRING key copies its byte slice
        # directly. (Was `set_bits_at(dst, value_bits_at(src))` — a UInt64 round
        # trip that a variable-length STRING cannot survive.)
        comptime for k in range(Self.Keys.__len__()):
            self.cols[k].copy_slot(dst, other.cols[k], src)

    def emit_at_slots(self, slots: List[Int], mut rb: RecordBatchBuilder):
        # `emit_sorted_column` materializes the column's values over an explicit
        # index list — reused here over the per-output-row global-buffer slot ids.
        comptime for k in range(Self.Keys.__len__()):
            self.cols[k].emit_sorted_column(slots, rb)

    def append_other(mut self, other: Self):
        comptime for k in range(Self.Keys.__len__()):
            self.cols[k].append_other(other.cols[k])

    def clear_values(mut self):
        comptime for k in range(Self.Keys.__len__()):
            self.cols[k].clear_values()

    def add_schema(self, mut sb: SchemaBuilder):
        comptime for k in range(Self.Keys.__len__()):
            self.cols[k].add_sort_key_schema_field(sb, k)

    def emit_all(self, order: List[Int], mut rb: RecordBatchBuilder):
        comptime for k in range(Self.Keys.__len__()):
            self.cols[k].emit_sorted_column(order, rb)


# =============================================================================
# §6 — Key-block and payload aliases (one DType each)
# =============================================================================

comptime SortKeyBlock1_I64 = SortKeyBlock[SortKeyColumn_Typed[DType.int64, 0]]
comptime SortKeyBlock1_F64 = SortKeyBlock[SortKeyColumn_Typed[DType.float64, 0]]
# STRING single-key block. `0` is a sentinel input column: a caller that feeds
# from a batch names its own `col`.
comptime SortKeyBlock1_String = SortKeyBlock[SortKeyColumn_String[0]]

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
    var _spill_chunks: List[ChunkId]
    var _age_ticks: UInt64
    var _restoring: Bool

    def __init__(out self):
        """The empty buffer: empty key block and payload pack, every direction
        ASC."""
        self.keys = Self.KB()
        self.payloads = Tuple[*Self.Payloads]()
        self.order = List[Int]()
        self.directions = InlineArray[UInt8, MAX_SORT_KEYS](fill=SORT_DIR_ASC_U8)
        self._row_count = 0
        self._spill_chunks = List[ChunkId]()
        self._age_ticks = UInt64(0)
        self._restoring = False

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
        self._spill_chunks = List[ChunkId]()
        self._age_ticks = UInt64(0)
        self._restoring = False

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
        `commit_row`) are already inlined on the concrete column impls."""
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
    # those rows in the SAME buffer order, so the subsequent stable-sorted drain
    # is byte-identical to the un-spilled reference.

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
        return not self._restoring

    def spill_to_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises -> Int64:
        """Serialize the buffered (pre-sort) state to `storage` via THSPLC and
        free the in-memory buffers. Returns BYTES FREED."""
        var freed = self.memory_usage_bytes()

        var batch = self._buffered_record_batch()
        var bytes = THSPLCEncoder.encode(batch^)
        var chunk = storage.write_chunk(bytes^)
        self._spill_chunks.append(chunk)

        self.keys.clear_values()

        comptime for p in range(Self.Payloads.__len__()):
            self.payloads[p].clear_values()
        self.order.clear()
        self._row_count = 0
        return freed

    def restore_from_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises:
        """Rebuild the buffered state from every stashed spill chunk via
        `THSPLCDecoder.decode_zerocopy`, re-feeding each row in decoded
        (buffer-order) sequence. After restore, the buffer holds the same
        multiset of rows in the same pre-sort order, so a subsequent
        stable-sorted drain is byte-identical to the un-spilled reference.

        ZERO-COPY restore: the decoded RecordBatch's column buffers are borrowed
        Arc-clone slices over the read-chunk bytes (NO memcpy). The restore
        path COPIES each typed scalar OUT of the BatchView into the operator's
        owning SoA storage, so NO borrowed byte escapes this method."""
        self._restoring = True
        var schema = self._spill_schema()
        for ci in range(len(self._spill_chunks)):
            var chunk = self._spill_chunks[ci]
            var bytes = storage.read_chunk(chunk)
            var restored = THSPLCDecoder.decode_zerocopy(bytes^, schema.copy())
            self._append_from_record_batch(restored^)
            storage.release_chunk(chunk)
        self._spill_chunks.clear()
        self._restoring = False

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
