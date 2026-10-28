# =============================================================================
# sort_stage_key_block -- SortKeyBlockTrait and SortKeyBlock[*Keys], the key
# pack of a SortBuffer
# =============================================================================
#
# Split out of `sort_stage_buffer` to keep that file under the size limit;
# `sort_stage_buffer` re-exports every name here.
# =============================================================================

from komira_arrow.batch_view import BatchView
from komira_arrow.schema import RecordBatchBuilder, SchemaBuilder

from .sort_stage_columns import (
    MAX_SORT_KEYS,
    SORT_DIR_DESC_U8,
    SortKeyColumn,
    SortKeyColumn_Typed,
)
from .sort_stage_string_key import SortKeyColumn_String


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

    def null_key_slot[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int
    ) -> Int:
        """The first key slot whose bound input cell at `row` is NULL, or -1
        when every key cell is valid. The key columns carry no validity."""
        ...

    def key_input_column(self, slot: Int) -> Int:
        """The input column index bound to key slot `slot`, for error messages."""
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

    def null_key_slot[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int
    ) -> Int:
        comptime for k in range(Self.Keys.__len__()):
            if self.cols[k].input_is_null[bo](batch, row):
                return k
        return -1

    def key_input_column(self, slot: Int) -> Int:
        comptime for k in range(Self.Keys.__len__()):
            if k == slot:
                return self.cols[k].input_column()
        return -1

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
