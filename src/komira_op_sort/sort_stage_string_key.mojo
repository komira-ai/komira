# =============================================================================
# sort_stage_string_key -- the STRING key column of the stage sort buffer
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
from komira_counters.strdrain_counter import strdrain_note_site

from .sort_stage_columns import (
    SORT_DIR_DESC_U8,
    SortKeyColumn,
    SortKeyColumn_Typed,
)


# =============================================================================
# §3b — SortKeyColumn_String[col] — the STRING SORT-key conformer
# =============================================================================
#
# A STRING key has no fixed-width `Scalar[dt]`, so this conformer stores bytes:
#
#   * SORT channel (full frame): `data: List[UInt8]` (every buffered row's key
#     bytes, concatenated) and `offsets: List[Int]` (row `i` spans
#     `data[offsets[i] .. offsets[i+1]]`), addressed by append-order row index;
#   * TOP-N channel (bounded): a slot byte arena `slot_data` with a per-slot
#     `(slot_start, slot_len)`, addressed by a recycled slot id; a write
#     appends the new bytes and records `(start, len)`.
#
# All storage is POD lists (`UInt8` / `Int`), no `List[String]`.
#
# `compare_at(i, j)` is byte-wise over the common prefix, and on a prefix tie
# the shorter string is less: DuckDB's default (binary) VARCHAR collation and
# the order of `sort_string._string_lt`. The empty string sorts before every
# other. `SortBuffer` applies the direction and keeps ties in buffer order.
#
# The fixed-width surface (`append_value`, `append_bits`, `value_bits_at`,
# `value_at`, `set_bits_at`, `simd_reject_winner_mask`) cannot carry a
# variable-length string, so each aborts with a message rather than
# truncate a key. Bytes are read through `StringColumnView`, never pointers.

struct SortKeyColumn_String[col: Int](SortKeyColumn):
    """STRING SORT-key column bound to input batch column `col`. Stores each
    buffered row's key string as bytes in a flat `List[UInt8]` data buffer + a
    `List[Int]` offsets array (Arrow varlen SoA). Byte-wise lexicographic
    `compare_at` (DuckDB default VARCHAR collation). POD storage
    (`List[UInt8]` / `List[Int]`).

    `DT` is the `DType.uint8` per-byte sentinel — a STRING key has no fixed-width
    `Scalar[dt]`; the conformer NEVER reads `Scalar[DT]` off the batch (it reads
    bytes via the `StringColumnView`). The sentinel exists only so the trait's
    `comptime DT` member resolves + the `memory_usage_bytes` per-row hint has a
    width (string rows are variable-width; 1 byte/row is a conservative spill
    estimate, not load-bearing)."""

    comptime DT: DType = DType.uint8
    comptime IS_VARLEN: Bool = True
    var data: List[UInt8]
    var offsets: List[Int]  # offsets[i]..offsets[i+1] is buffered row i's slice
    # --- STRING-NATIVE RANDOM-ACCESS (recycled-slot) CHANNEL  ---
    # The bounded global TOP-N addresses key cells by a
    # RECYCLED SLOT id (not strict append order), so a STRING key needs a
    # random-access (slot -> byte slice) view that can OVERWRITE a slot with a
    # different-length string. The append-only `offsets` array above (SORT
    # carrier) cannot rewrite a slot in place. The slot channel keeps a parallel
    # per-slot `(start, len)` SoA into a slot-private byte arena `slot_data`: a
    # write APPENDS the new bytes to `slot_data` and records `(start, len)` at the
    # slot. Bytes are never reclaimed (matching `data`'s append-only philosophy);
    # the bounded heap only WRITES on a winning candidate, so the arena growth is
    # bounded by the winner count, not the input row count. All POD
    # `List[UInt8]` / `List[Int]`.
    var slot_data: List[UInt8]  # slot byte arena (append-on-write)
    var slot_start: List[Int]  # slot_start[s] = byte offset of slot s in slot_data
    var slot_len: List[Int]  # slot_len[s] = byte length of slot s

    def __init__(out self):
        # Defaultable identity: empty column with the varlen-SoA sentinel offset
        # (offsets[0] == 0). Resolves the pack-aware `Tuple[*Keys]()` ctor.
        self.data = List[UInt8]()
        self.offsets = List[Int]()
        self.offsets.append(0)
        self.slot_data = List[UInt8]()
        self.slot_start = List[Int]()
        self.slot_len = List[Int]()

    def __init__(
        out self,
        var data: List[UInt8],
        var offsets: List[Int],
    ):
        self.data = data^
        self.offsets = offsets^
        self.slot_data = List[UInt8]()
        self.slot_start = List[Int]()
        self.slot_len = List[Int]()

    @staticmethod
    def make(capacity: Int) -> Self:
        var d = List[UInt8](capacity=capacity * 8)
        var o = List[Int](capacity=capacity + 1)
        o.append(0)
        return Self(d^, o^)

    @always_inline
    def _len_of(self, i: Int) -> Int:
        return self.offsets[i + 1] - self.offsets[i]

    # -------------------------------------------------------------------------
    # Channel selector . A `SortKeyColumn_String` instance is driven by
    # EXACTLY ONE channel for its lifetime — the full-frame SORT path (the
    # APPEND arena `data`/`offsets`, addressed by append-order ROW index) OR the
    # bounded global TOP-N path (the recycled-slot arena
    # `slot_data`/`slot_start`/`slot_len`, addressed by SLOT id). The two never
    # interleave on one column. `_use_slot_channel()` is True once the slot
    # channel has been sized (`ensure_len`), so the index-addressed comparator /
    # emit / materialize helpers select the right arena structurally — NOT a
    # per-call mode flag (the channel is a lifetime invariant of the owning
    # state). When neither channel has data (empty column), the append arena is
    # the harmless default (no rows to compare/emit).
    @always_inline
    def _use_slot_channel(self) -> Bool:
        return len(self.slot_start) > 0

    @always_inline
    def _cell_base(self, i: Int) -> Int:
        """Byte base of indexed cell `i` in the active channel's arena (SLOT id in
        TOP-N mode, append-order ROW index in SORT mode)."""
        if self._use_slot_channel():
            return self.slot_start[i]
        return self.offsets[i]

    @always_inline
    def _cell_len(self, i: Int) -> Int:
        """Byte length of indexed cell `i` in the active channel."""
        if self._use_slot_channel():
            return self.slot_len[i]
        return self.offsets[i + 1] - self.offsets[i]

    @always_inline
    def _append_bytes_from[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], read_col: Int, row: Int):
        """Append `batch[row]`'s string (off column `read_col`) as one buffered
        row: copy its bytes into `data`, push the new end-offset.

        The `SortKeyColumn` trait surface is NON-raising, but the
        `StringColumnView` accessors raise (Arrow bounds-checks). The row index
        is always in-bounds on the feed/restore paths (the buffer iterates valid
        rows of a valid Arrow string column), so a raise here is unreachable;
        catch + `abort` to satisfy the non-raising contract (the numeric
        conformer avoids this because its `col_iNN().load` accessor is
        non-raising)."""
        try:
            var sv = batch.col_str(read_col).get(row)
            var n = sv.length()
            for i in range(n):
                self.data.append(sv.byte_at(i))
            self.offsets.append(len(self.data))
        except e:
            abort(String("SortKeyColumn_String._append: ") + String(e))

    @always_inline
    def read_and_append[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ):
        self._append_bytes_from[bo](batch, Self.col, row)

    @always_inline
    def restore_append[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], spill_col: Int, row: Int
    ):
        self._append_bytes_from[bo](batch, spill_col, row)

    @always_inline
    def input_is_null[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int
    ) -> Bool:
        return batch.col_is_null(Self.col, row)

    @always_inline
    def length(self) -> Int:
        return len(self.offsets) - 1

    @always_inline
    def clear_values(mut self):
        self.data.clear()
        self.offsets.clear()
        self.offsets.append(0)
        self.slot_data.clear()
        self.slot_start.clear()
        self.slot_len.clear()

    def append_other(mut self, other: Self):
        """Append every buffered key of `other` (cross-worker combine) — byte-SoA
        concatenation: copy each stored slice + push the new end-offset."""
        var n = other.length()
        for r in range(n):
            var base = other.offsets[r]
            var slen = other.offsets[r + 1] - base
            for i in range(slen):
                self.data.append(other.data[base + i])
            self.offsets.append(len(self.data))

    @always_inline
    def compare_at(self, i: Int, j: Int) -> Int:
        """3-way ASCENDING byte-wise lexicographic compare of cell `i`'s key vs
        cell `j`'s key (append-order ROW indices in SORT mode; recycled SLOT ids
        in TOP-N mode — `_use_slot_channel` selects the active arena). Bytes
        compared over the common prefix; on a prefix tie the SHORTER string is
        less. Matches DuckDB default VARCHAR (binary) collation + the in-tree
        `sort_string.mojo:_string_lt` kernel."""
        var ibase = self._cell_base(i)
        var ilen = self._cell_len(i)
        var jbase = self._cell_base(j)
        var jlen = self._cell_len(j)
        var slot = self._use_slot_channel()
        var min_len = ilen if ilen < jlen else jlen
        var p = 0
        while p < min_len:
            var ca = self.slot_data[ibase + p] if slot else self.data[ibase + p]
            var cb = self.slot_data[jbase + p] if slot else self.data[jbase + p]
            if ca != cb:
                return -1 if ca < cb else 1
            p += 1
        # Common prefix matched -- shorter string is less.
        if ilen < jlen:
            return -1
        if ilen > jlen:
            return 1
        return 0

    def _to_string(self, i: Int) raises -> String:
        # Materialize cell `i`'s byte slice as a String — span EXACTLY the n
        # bytes (NO trailing NUL; a NUL would round-trip as "key\0" and break
        # byte-exact equality with the input). Channel-aware (slot id in
        # TOP-N mode, row index in SORT mode). Mirrors `StringView.to_string`.
        var base = self._cell_base(i)
        var n = self._cell_len(i)
        var slot = self._use_slot_channel()
        var bytes = List[UInt8]()
        for k in range(n):
            if slot:
                bytes.append(self.slot_data[base + k])
            else:
                bytes.append(self.data[base + k])
        return String(StringSlice(unsafe_from_utf8=Span(bytes)))

    def emit_sorted_column(self, order: List[Int], mut rb: RecordBatchBuilder):
        """Append this key column — materialized as a STRING column over the
        sorted `order` permutation — to `rb`."""
        try:
            var strs = List[String](capacity=len(order))
            for si in range(len(order)):
                strs.append(self._to_string(order[si]))
            strdrain_note_site(1, len(order))  # sort_buffer
            var arr = StringArray.from_strings(strs)
            rb.add_column(Column.from_string(arr^))
        except e:
            # Non-raising on the trait; a UTF-8 decode failure on a stored key is
            # unreachable for well-formed string input (bytes were copied
            # verbatim off a valid Arrow column).
            abort(String("SortKeyColumn_String.emit: ") + String(e))

    def add_sort_key_schema_field(self, mut sb: SchemaBuilder, k: Int):
        sb.add_field(Field(String("k") + String(k), ArrowType.STRING, True))

    # -------------------------------------------------------------------------
    # The fixed-width UInt64 BIT-CHANNEL surface. A variable-length string CANNOT
    # ride the 8-byte channel, so these `abort` LOUDLY rather than silently
    # truncating a key — they are NOT called by either the full-frame SORT path
    # OR the STRING-native TOP-N path (TOP-N's recycled-slot store / compare /
    # combine route through the string-native channel below, NOT the bit
    # channel). They survive only for trait completeness + as a loud guard if a
    # future caller wrongly tries to push a STRING key through the bit channel.
    # -------------------------------------------------------------------------

    @always_inline
    def append_value(mut self, value: Scalar[Self.DT]):
        abort(
            "SortKeyColumn_String.append_value: STRING keys have no fixed-width"
            " Scalar channel; the SORT path feeds via read_and_append (byte"
            " SoA)."
        )

    @always_inline
    def append_bits(mut self, bits: UInt64):
        abort(
            "SortKeyColumn_String.append_bits: a variable-length STRING key"
            " cannot ride the 8-byte UInt64 bit channel. STRING uses the byte"
            " SoA (SORT) / string-native slot channel (TOP-N), never bits."
        )

    @always_inline
    def value_bits_at(self, i: Int) -> UInt64:
        abort(
            "SortKeyColumn_String.value_bits_at: a STRING key cannot be read as"
            " an 8-byte UInt64. STRING uses the byte SoA / slot channel."
        )

    @always_inline
    def value_at(self, i: Int) -> Scalar[Self.DT]:
        abort(
            "SortKeyColumn_String.value_at: STRING keys have no fixed-width"
            " Scalar. STRING uses the byte SoA / slot channel."
        )

    @always_inline
    def set_bits_at(mut self, i: Int, bits: UInt64):
        abort(
            "SortKeyColumn_String.set_bits_at: a STRING key cannot be written"
            " from an 8-byte UInt64. TOP-N slot writes use read_into_slot /"
            " copy_slot (string-native)."
        )

    # -------------------------------------------------------------------------
    # STRING-NATIVE RANDOM-ACCESS (recycled-slot) TOP-N channel . These
    # replace the bit-channel aborts for the bounded global TOP-N
    # — they address the slot byte arena (`slot_data` + per-slot
    # `(slot_start, slot_len)`) so a variable-length key can be stored,
    # overwritten, compared, and copied by SLOT id. The comparison-driven TOP-N
    # heap orders by `compare_at` / `compare_batch_row_to_slot` (lexicographic),
    # NOT by an order-preserving fixed-width key, so a STRING order key is
    # byte-identical to "ORDER BY str_key LIMIT N".
    # -------------------------------------------------------------------------

    def ensure_len(mut self, n: Int):
        """Grow the slot SoA to at least `n` slots (each a fresh empty slice at
        the current arena end). Enables random-access overwrite via
        `read_into_slot` / `copy_slot` for the bounded recycled-slot TOP-N
        buffer."""
        while len(self.slot_start) < n:
            self.slot_start.append(len(self.slot_data))
            self.slot_len.append(0)

    @always_inline
    def read_into_slot[bo: Origin[mut=False]](
        mut self, slot: Int, batch: BatchView[bo], row: Int
    ):
        """Read `batch[row]`'s string (off this column's bound input column) into
        random-access `slot`: APPEND its bytes to the slot arena, record the new
        `(start, len)` at `slot`. Caller has `ensure_len(slot + 1)`'d. Bytes are
        never reclaimed (append-on-write, bounded by the winner count — the
        bounded heap only stores a row on a winning candidate)."""
        try:
            var sv = batch.col_str(Self.col).get(row)
            var n = sv.length()
            var start = len(self.slot_data)
            for i in range(n):
                self.slot_data.append(sv.byte_at(i))
            self.slot_start[slot] = start
            self.slot_len[slot] = n
        except e:
            abort(String("SortKeyColumn_String.read_into_slot: ") + String(e))

    @always_inline
    def copy_slot(mut self, dst: Int, other: Self, src: Int):
        """Copy `other`'s slot `src` byte slice into `self`'s slot `dst` (TOP-N
        cross-worker combine): APPEND the bytes to `self`'s slot arena, record the
        new `(start, len)` at `dst`. Caller has `self` `ensure_len(dst + 1)`'d."""
        var base = other.slot_start[src]
        var n = other.slot_len[src]
        var start = len(self.slot_data)
        for i in range(n):
            self.slot_data.append(other.slot_data[base + i])
        self.slot_start[dst] = start
        self.slot_len[dst] = n

    @always_inline
    def compare_batch_row_to_slot[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int, slot: Int
    ) -> Int:
        """3-way ASCENDING byte-wise lexicographic compare of a CANDIDATE key read
        DIRECTLY off `batch` at `row` (off this column's bound input column)
        against this column's buffered `slot` key — NO slot store (the TOP-N
        reject-path fast compare). Byte-wise over the common prefix; shorter is
        less on a prefix tie (DuckDB binary collation, identical to
        `compare_at`)."""
        try:
            var sv = batch.col_str(Self.col).get(row)
            var clen = sv.length()
            var sbase = self.slot_start[slot]
            var slen = self.slot_len[slot]
            var min_len = clen if clen < slen else slen
            var p = 0
            while p < min_len:
                var ca = sv.byte_at(p)
                var cb = self.slot_data[sbase + p]
                if ca != cb:
                    return -1 if ca < cb else 1
                p += 1
            if clen < slen:
                return -1
            if clen > slen:
                return 1
            return 0
        except e:
            abort(
                String("SortKeyColumn_String.compare_batch_row_to_slot: ")
                + String(e)
            )

    @always_inline
    def simd_reject_winner_mask[W: Int, bo: Origin[mut=False]](
        self, batch: BatchView[bo], i: Int, root: Scalar[Self.DT], dir_u8: UInt8
    ) -> SIMD[DType.bool, W]:
        # A variable-length STRING key cannot be loaded into a fixed-width SIMD
        # vector. the bounded TOP-N state gates this OFF at
        # COMPTIME for a varlen key (`KB.key0_is_varlen()` -> the scalar feed
        # path), so this is structurally unreachable; the abort is a loud guard.
        abort(
            "SortKeyColumn_String.simd_reject_winner_mask: the TOP-N SIMD"
            " reject path is not supported for STRING keys (no contiguous"
            " fixed-width vector load); the caller must comptime-gate via"
            " key0_is_varlen()."
        )


@always_inline
def sort_key_column_i64(
    initial_capacity: Int,
) -> SortKeyColumn_Typed[DType.int64, 0]:
    """Factory for an Int64 sort-key column (the production key DType) bound to a
    sentinel column index (a caller that appends pre-extracted values
    via `append_value`, so the column index is unused there)."""
    return SortKeyColumn_Typed[DType.int64, 0].new(initial_capacity)


@always_inline
def sort_key_column_f64(
    initial_capacity: Int,
) -> SortKeyColumn_Typed[DType.float64, 0]:
    """Factory for a Float64 sort-key column. Mirror of `sort_key_column_i64`."""
    return SortKeyColumn_Typed[DType.float64, 0].new(initial_capacity)
