# =============================================================================
# sort_stage_payloads -- the payload columns of the stage sort buffer: the
# trait, the fixed-width conformer and the STRING conformer
# =============================================================================
#
# A payload column is carried with the sort keys and never compared.

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
    _read_sort_scalar,
    _sort_arrow_type,
    sort_bits_of,
    sort_from_bits,
)


# =============================================================================
# §4 — PayloadColumn — the per-payload column trait + conformer (*Payloads pack)
# =============================================================================


trait PayloadColumn(Defaultable, Movable, Deinitable):
    """One payload column — the per-slot element type of a `SortBuffer`'s
    `*Payloads` pack. Owns the `List[Scalar[DT]]` of that payload's values across
    all buffered rows, carried alongside the sort keys but NOT participating in
    the comparator.

    Mirror of `SortKeyColumn` minus `compare_at` (payloads are never compared).
    Conformers: `PayloadCol_Typed[dt, col]` and `PayloadCol_String[col]`.
    `Defaultable` (the empty column) lets a payload pack be default-constructed
    as `Tuple[*Payloads]()`."""

    comptime DT: DType

    @staticmethod
    def make(capacity: Int) -> Self:
        """Construct an empty column with reserved capacity."""
        ...

    def append_value(mut self, value: Scalar[Self.DT]):
        """Append one payload value (one buffered row)."""
        ...

    def append_bits(mut self, bits: UInt64):
        """Append one payload value supplied as its UInt64 bit pattern."""
        ...

    def value_bits_at(self, i: Int) -> UInt64:
        """Read payload value at buffered row `i` as its UInt64 bit pattern."""
        ...

    def ensure_len(mut self, n: Int):
        """Grow the backing buffer to at least `n` slots (zero-filled). Enables
        RANDOM-ACCESS overwrite via `set_bits_at` — the bounded full-frame
        partitioned top-N buffer reuses recycled slot indices, so the column must
        be indexable beyond strict append order."""
        ...

    def set_bits_at(mut self, i: Int, bits: UInt64):
        """Overwrite slot `i`'s value with the UInt64 bit pattern. Caller has
        `ensure_len(i + 1)`'d. Random-access write for the recycled-slot buffer."""
        ...

    def read_and_append[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ):
        """Read this column's bound input column at `row` and append the value."""
        ...

    def restore_append[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], spill_col: Int, row: Int
    ):
        """SPILL restore path — read at spill-image column `spill_col`."""
        ...

    def input_is_null[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int
    ) -> Bool:
        """True iff this payload's bound input cell at `row` is NULL. The sort
        buffer stores values without validity and refuses such a row. Required:
        a conformer that answered False for every row would let a NULL be
        buffered as a value."""
        ...

    def input_column(self) -> Int:
        """The index of the input column this payload reads (its bound `col`),
        for error messages."""
        ...

    def length(self) -> Int:
        """Number of buffered payload values."""
        ...

    def clear_values(mut self):
        """Drop all buffered payload values."""
        ...

    def value_at(self, i: Int) -> Scalar[Self.DT]:
        """The raw payload value at buffered row index `i`."""
        ...

    def append_other(mut self, other: Self):
        """Append every buffered value of `other` (cross-worker combine)."""
        ...

    def copy_slot(mut self, dst: Int, other: Self, src: Int):
        """Copy `other`'s slot `src` value into `self`'s random-access slot `dst`
        (the bounded recycled-slot TOP-N cross-worker combine). Caller has
        `self.ensure_len(dst + 1)`'d. The numeric conformer routes through the
        UInt64 bit channel (`set_bits_at` / `value_bits_at`); the STRING conformer
        routes through its string-native slot arena (a varlen value cannot ride
        the 8-byte bit channel). This replaces the prior bit-channel-only combine
        so a STRING payload survives the recycled-slot combine path."""
        ...

    def emit_sorted_column(self, order: List[Int], mut rb: RecordBatchBuilder):
        """Append this payload column — native DType, materialized over the
        sorted `order` permutation — to `rb`."""
        ...

    def read_into_slot[bo: Origin[mut=False]](
        mut self, slot: Int, batch: BatchView[bo], row: Int
    ):
        """Read this column's bound input column at `row` off `batch` and write
        the value into random-access slot `slot` (the bounded recycled-slot
        partitioned top-N buffer). Caller has `ensure_len(slot + 1)`'d."""
        ...

    def emit_at_slots(self, slots: List[Int], mut rb: RecordBatchBuilder):
        """Append this payload column materialized over the per-output-row
        `slots` (global-buffer slot ids) — the full-frame partitioned top-N
        drain (mirror of `emit_sorted_column` over an explicit slot list)."""
        ...

    def add_payload_schema_field(self, mut sb: SchemaBuilder, p: Int):
        """Append this payload's output schema field (`payload<p>`, native
        DType)."""
        ...


struct PayloadCol_Typed[dt: DType, col: Int](PayloadColumn):
    """Concrete per-payload column wrapping a `List[Scalar[dt]]`, bound to input
    batch column `col`. Mirror of `SortKeyColumn_Typed` (minus `compare_at`).

    One type per payload DType. A caller that appends pre-extracted values
    with `append_value` uses a sentinel `col`."""

    comptime DT: DType = Self.dt
    var values: List[Scalar[Self.dt]]

    def __init__(out self):
        # Defaultable identity: empty column (pack-aware `Tuple[*Payloads]()`).
        self.values = List[Scalar[Self.dt]]()

    def __init__(out self, var values: List[Scalar[Self.dt]]):
        self.values = values^

    @staticmethod
    def new(initial_capacity: Int) -> PayloadCol_Typed[Self.dt, Self.col]:
        return PayloadCol_Typed[Self.dt, Self.col](
            values=List[Scalar[Self.dt]](capacity=initial_capacity)
        )

    @staticmethod
    def make(capacity: Int) -> Self:
        return Self(List[Scalar[Self.dt]](capacity=capacity))

    @always_inline
    def append_value(mut self, value: Scalar[Self.DT]):
        self.values.append(value)

    @always_inline
    def append_bits(mut self, bits: UInt64):
        self.values.append(sort_from_bits[Self.dt](bits))

    @always_inline
    def value_bits_at(self, i: Int) -> UInt64:
        return sort_bits_of[Self.dt](self.values[i])

    @always_inline
    def read_and_append[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ):
        self.values.append(_read_sort_scalar[Self.dt, bo](batch, Self.col, row))

    @always_inline
    def restore_append[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], spill_col: Int, row: Int
    ):
        self.values.append(
            _read_sort_scalar[Self.dt, bo](batch, spill_col, row)
        )

    @always_inline
    def input_is_null[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int
    ) -> Bool:
        return batch.col_is_null(Self.col, row)

    @always_inline
    def input_column(self) -> Int:
        return Self.col

    @always_inline
    def length(self) -> Int:
        return len(self.values)

    @always_inline
    def clear_values(mut self):
        self.values.clear()

    @always_inline
    def value_at(self, i: Int) -> Scalar[Self.DT]:
        return self.values[i]

    def append_other(mut self, other: Self):
        for i in range(len(other.values)):
            self.values.append(other.values[i])

    def ensure_len(mut self, n: Int):
        while len(self.values) < n:
            self.values.append(Scalar[Self.dt](0))

    @always_inline
    def set_bits_at(mut self, i: Int, bits: UInt64):
        self.values[i] = sort_from_bits[Self.dt](bits)

    @always_inline
    def copy_slot(mut self, dst: Int, other: Self, src: Int):
        # Recycled-slot combine: bit-exact value copy by slot id. Caller has
        # `ensure_len(dst + 1)`'d; `other.values[src]` is a populated slot.
        self.values[dst] = other.values[src]

    def emit_sorted_column(self, order: List[Int], mut rb: RecordBatchBuilder):
        var vals = List[Scalar[Self.dt]](capacity=len(order))
        for si in range(len(order)):
            vals.append(self.values[order[si]])
        var arr = PrimitiveArray[Self.dt].from_list(vals)
        rb.add_column(Column.from_primitive[Self.dt](arr^))

    @always_inline
    def read_into_slot[bo: Origin[mut=False]](
        mut self, slot: Int, batch: BatchView[bo], row: Int
    ):
        self.values[slot] = _read_sort_scalar[Self.dt, bo](batch, Self.col, row)

    def emit_at_slots(self, slots: List[Int], mut rb: RecordBatchBuilder):
        var vals = List[Scalar[Self.dt]](capacity=len(slots))
        for si in range(len(slots)):
            vals.append(self.values[slots[si]])
        var arr = PrimitiveArray[Self.dt].from_list(vals)
        rb.add_column(Column.from_primitive[Self.dt](arr^))

    def add_payload_schema_field(self, mut sb: SchemaBuilder, p: Int):
        sb.add_field(
            Field(
                String("payload") + String(p),
                _sort_arrow_type[Self.dt](),
                True,
            )
        )


# =============================================================================
# §4b — PayloadCol_String[col] — the STRING non-key PAYLOAD conformer
# =============================================================================
#
# The payload form of `SortKeyColumn_String` (no comparator): the same two byte
# channels, SORT (`data` + `offsets`, by append-order row) and TOP-N (the slot
# arena, by recycled slot id, appended on write), POD storage only. The
# fixed-width bit channel (`append_bits`, `value_bits_at`, `set_bits_at`,
# `value_at`, `append_value`) cannot carry a variable-length value and aborts
# with a message; the SORT and TOP-N paths, and the combine (`copy_slot`),
# never call it.

struct PayloadCol_String[col: Int](PayloadColumn):
    """STRING non-key PAYLOAD column bound to input batch column `col`. Stores
    each buffered row's payload string as bytes in a flat `List[UInt8]` data
    buffer + a `List[Int]` offsets array (Arrow varlen SoA, SORT channel), plus a
    parallel slot-arena SoA (`slot_data` + `slot_start` + `slot_len`) for the
    bounded recycled-slot TOP-N channel. POD (`List[UInt8]` / `List[Int]`
    POD). The `PayloadColumn` analogue of `SortKeyColumn_String` — minus
    `compare_at` (a payload never participates in the comparator).

    `DT` is the `DType.uint8` per-byte sentinel — a STRING payload has no
    fixed-width `Scalar[dt]`; the conformer NEVER reads `Scalar[DT]` off the batch
    (it reads bytes via the `StringColumnView`). The sentinel exists only so the
    trait's `comptime DT` member resolves; the fixed-width UInt64 bit channel
    (`append_bits` / `value_bits_at` / `set_bits_at` / `append_value` /
    `value_at`) aborts loudly (a varlen value cannot ride the 8-byte channel)."""

    comptime DT: DType = DType.uint8
    var data: List[UInt8]
    var offsets: List[Int]  # offsets[i]..offsets[i+1] is buffered row i's slice
    # --- STRING-NATIVE RANDOM-ACCESS (recycled-slot) TOP-N channel ---
    var slot_data: List[UInt8]  # slot byte arena (append-on-write)
    var slot_start: List[Int]  # slot_start[s] = byte offset of slot s in slot_data
    var slot_len: List[Int]  # slot_len[s] = byte length of slot s

    def __init__(out self):
        # Defaultable identity: empty column with the varlen-SoA sentinel offset
        # (offsets[0] == 0). Resolves the pack-aware `Tuple[*Payloads]()` ctor.
        self.data = List[UInt8]()
        self.offsets = List[Int]()
        self.offsets.append(0)
        self.slot_data = List[UInt8]()
        self.slot_start = List[Int]()
        self.slot_len = List[Int]()

    def __init__(out self, var data: List[UInt8], var offsets: List[Int]):
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

    # -------------------------------------------------------------------------
    # Channel selector (mirror of SortKeyColumn_String). A `PayloadCol_String`
    # instance is driven by EXACTLY ONE channel for its lifetime — the SORT path
    # (the APPEND arena `data`/`offsets`, addressed by append-order ROW index) OR
    # the bounded global TOP-N path (the recycled-slot arena
    # `slot_data`/`slot_start`/`slot_len`, addressed by SLOT id). The two never
    # interleave on one column. `_use_slot_channel()` is True once the slot
    # channel has been sized (`ensure_len`), so the index-addressed emit /
    # materialize helpers select the right arena structurally.
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

        The `PayloadColumn` trait surface is NON-raising, but the
        `StringColumnView` accessors raise (Arrow bounds-checks). The row index is
        always in-bounds on the feed/restore paths, so a raise here is
        unreachable; catch + `abort` to satisfy the non-raising contract."""
        try:
            var sv = batch.col_str(read_col).get(row)
            var n = sv.length()
            for i in range(n):
                self.data.append(sv.byte_at(i))
            self.offsets.append(len(self.data))
        except e:
            abort(String("PayloadCol_String._append: ") + String(e))

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
    def input_column(self) -> Int:
        return Self.col

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
        """Append every buffered payload value of `other` (cross-worker combine,
        SORT channel) — byte-SoA concatenation: copy each stored slice + push the
        new end-offset."""
        var n = other.length()
        for r in range(n):
            var base = other.offsets[r]
            var slen = other.offsets[r + 1] - base
            for i in range(slen):
                self.data.append(other.data[base + i])
            self.offsets.append(len(self.data))

    def _to_string(self, i: Int) raises -> String:
        # Materialize cell `i`'s byte slice as a String — span EXACTLY the n
        # bytes (NO trailing NUL; a NUL would round-trip as "val\0" and break
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
        """Append this payload column — materialized as a STRING column over the
        sorted `order` permutation — to `rb` (SORT drain)."""
        try:
            var strs = List[String](capacity=len(order))
            for si in range(len(order)):
                strs.append(self._to_string(order[si]))
            strdrain_note_site(1, len(order))  # sort_buffer
            var arr = StringArray.from_strings(strs)
            rb.add_column(Column.from_string(arr^))
        except e:
            # Non-raising on the trait; a UTF-8 decode failure on a stored value
            # is unreachable for well-formed string input (bytes copied verbatim
            # off a valid Arrow column).
            abort(String("PayloadCol_String.emit_sorted_column: ") + String(e))

    def add_payload_schema_field(self, mut sb: SchemaBuilder, p: Int):
        sb.add_field(Field(String("payload") + String(p), ArrowType.STRING, True))

    # -------------------------------------------------------------------------
    # The fixed-width UInt64 BIT-CHANNEL surface. A variable-length string CANNOT
    # ride the 8-byte channel, so these `abort` LOUDLY rather than silently
    # truncating a value — they are NOT called by either the SORT path OR the
    # STRING-native TOP-N path (TOP-N's recycled-slot store / combine route
    # through the string-native channel below, NOT the bit channel). They survive
    # only for trait completeness + as a loud guard if a future caller wrongly
    # tries to push a STRING payload through the bit channel.
    # -------------------------------------------------------------------------

    @always_inline
    def append_value(mut self, value: Scalar[Self.DT]):
        abort(
            "PayloadCol_String.append_value: STRING payloads have no fixed-width"
            " Scalar channel; the SORT path feeds via read_and_append (byte SoA)."
        )

    @always_inline
    def append_bits(mut self, bits: UInt64):
        abort(
            "PayloadCol_String.append_bits: a variable-length STRING payload"
            " cannot ride the 8-byte UInt64 bit channel. STRING uses the byte SoA"
            " (SORT) / string-native slot channel (TOP-N), never bits."
        )

    @always_inline
    def value_bits_at(self, i: Int) -> UInt64:
        abort(
            "PayloadCol_String.value_bits_at: a STRING payload cannot be read as"
            " an 8-byte UInt64. STRING uses the byte SoA / slot channel."
        )

    @always_inline
    def value_at(self, i: Int) -> Scalar[Self.DT]:
        abort(
            "PayloadCol_String.value_at: STRING payloads have no fixed-width"
            " Scalar. STRING uses the byte SoA / slot channel."
        )

    @always_inline
    def set_bits_at(mut self, i: Int, bits: UInt64):
        abort(
            "PayloadCol_String.set_bits_at: a STRING payload cannot be written"
            " from an 8-byte UInt64. TOP-N slot writes use read_into_slot /"
            " copy_slot (string-native)."
        )

    # -------------------------------------------------------------------------
    # STRING-NATIVE RANDOM-ACCESS (recycled-slot) TOP-N channel. These replace the
    # bit-channel surface for the bounded global TOP-N — they
    # address the slot byte arena (`slot_data` + per-slot `(slot_start, slot_len)`)
    # so a variable-length payload can be stored, overwritten, copied, and emitted
    # by SLOT id. Mirror of `SortKeyColumn_String`'s slot channel minus the compare.
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
        bounded heap only stores a payload on a winning candidate)."""
        try:
            var sv = batch.col_str(Self.col).get(row)
            var n = sv.length()
            var start = len(self.slot_data)
            for i in range(n):
                self.slot_data.append(sv.byte_at(i))
            self.slot_start[slot] = start
            self.slot_len[slot] = n
        except e:
            abort(String("PayloadCol_String.read_into_slot: ") + String(e))

    @always_inline
    def copy_slot(mut self, dst: Int, other: Self, src: Int):
        """Copy `other`'s slot `src` byte slice into `self`'s slot `dst` (TOP-N
        cross-worker combine): APPEND the bytes to `self`'s slot arena, record the
        new `(start, len)` at `dst`. Caller has `self` `ensure_len(dst + 1)`'d.
        The string-native replacement for the bit-channel combine."""
        var base = other.slot_start[src]
        var n = other.slot_len[src]
        var start = len(self.slot_data)
        for i in range(n):
            self.slot_data.append(other.slot_data[base + i])
        self.slot_start[dst] = start
        self.slot_len[dst] = n

    def emit_at_slots(self, slots: List[Int], mut rb: RecordBatchBuilder):
        """Append this payload column materialized as a STRING column over the
        per-output-row `slots` (global-buffer slot ids) — the bounded TOP-N drain
        (mirror of `emit_sorted_column` over an explicit slot list)."""
        try:
            var strs = List[String](capacity=len(slots))
            for si in range(len(slots)):
                strs.append(self._to_string(slots[si]))
            strdrain_note_site(1, len(slots))  # sort_buffer
            var arr = StringArray.from_strings(strs)
            rb.add_column(Column.from_string(arr^))
        except e:
            abort(String("PayloadCol_String.emit_at_slots: ") + String(e))


@always_inline
def payload_column_string[
    col: Int = 0
](initial_capacity: Int) -> PayloadCol_String[col]:
    """Factory for a STRING payload column bound to input batch column `col`
    (mirror of `payload_column_i64` / `payload_column_f64`)."""
    return PayloadCol_String[col].make(initial_capacity)


@always_inline
def payload_column_i64(
    initial_capacity: Int,
) -> PayloadCol_Typed[DType.int64, 0]:
    """Factory for an Int64 payload column (the row-id payload DType)."""
    return PayloadCol_Typed[DType.int64, 0].new(initial_capacity)


@always_inline
def payload_column_f64(
    initial_capacity: Int,
) -> PayloadCol_Typed[DType.float64, 0]:
    """Factory for a Float64 payload column ."""
    return PayloadCol_Typed[DType.float64, 0].new(initial_capacity)
