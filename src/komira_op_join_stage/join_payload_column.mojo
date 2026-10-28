# =============================================================================
# join_payload_column -- the payload columns of the stage join build table:
# `PayloadColumn`, the fixed-width `PayloadSlot[dt]`, the STRING
# `PayloadCol_JoinString`, and the one-pack constructor wrapper `PayloadBlock`
# =============================================================================
#
# A payload column is slot-indexed like a key column: a build row's payload is
# written at the slot its key landed in, and `JoinBuildTable._grow` moves
# every column's slots in lockstep (`rehash_in_place` against one remap).
#
# Every column records a NULL per slot, so a NULL build payload comes back
# out of the probe as NULL (not as 0 or ""). The exact channel is
# `write_slot_from_batch` (the value read at the column's own DType) with
# `read_slot_bits` / `read_slot_string` and `copy_slot`; `write_slot_f64` and
# `read_slot_f64` are a Float64 channel for callers that want one (an INT64
# above 2^53 does not survive it).
#
# The table's body cannot name a pack element's struct parameter, so the
# per-column work is all trait methods, and the trait publishes `DT` and
# `IS_STRING` as associated aliases a generic body can branch on. A method
# that does not apply to a column's storage (a string read of a number, a
# number read of a string) aborts; the callers branch on `IS_STRING` first.
# =============================================================================

from std.os import abort
from std.sys import size_of

from komira_arrow.batch_view import BatchView

from komira_op_join_stage.join_key_slot import (
    JOIN_BUILD_DEFAULT_CAP,
    key_bits_of,
)


trait PayloadColumn(Defaultable, Movable, Copyable, Deinitable):
    """One slot-indexed payload column of a `JoinBuildTable`. The no-argument
    constructor builds `JOIN_BUILD_DEFAULT_CAP` slots, the count the table's
    nullary constructor starts with."""

    comptime DT: DType
    """The element DType of a fixed-width column; `DType.uint8` for STRING."""

    comptime IS_STRING: Bool
    """True for a variable-length STRING column."""

    @staticmethod
    def make(capacity: Int) -> Self:
        """A column of `capacity` slots."""
        ...

    def rehash_in_place(mut self, new_capacity: Int, remap: List[Int]):
        """Grow to `new_capacity` slots, moving every old slot `s` to
        `remap[s]` (-1: the old slot was empty)."""
        ...

    def write_slot_from_batch[bo: Origin[mut=False]](
        mut self, slot: Int, batch: BatchView[bo], col: Int, row: Int
    ) raises:
        """Store `batch[col][row]` at `slot`, read at the column's own type;
        a NULL cell stores NULL."""
        ...

    def slot_is_null(self, slot: Int) -> Bool:
        """True iff the value at `slot` is NULL."""
        ...

    def copy_slot(mut self, dst: Int, other: Self, src: Int):
        """Copy `other`'s slot `src` (value and NULL) into slot `dst`."""
        ...

    def write_slot_f64(mut self, slot: Int, value: Float64):
        """Store `value` cast to the column's type at `slot` (not NULL)."""
        ...

    def read_slot_f64(self, slot: Int) -> Float64:
        """The value at `slot` cast to Float64."""
        ...

    def read_slot_i64(self, slot: Int) -> Int64:
        """The value at `slot` cast to Int64."""
        ...

    def read_slot_bits(self, slot: Int) -> UInt64:
        """`key_bits_of` the value at `slot` (fixed-width columns)."""
        ...

    def read_slot_string(self, slot: Int) raises -> String:
        """The string at `slot` (STRING columns)."""
        ...

    def memory_size_bytes(self) -> Int:
        """The heap footprint of the column's storage in bytes."""
        ...


struct PayloadSlot[dt: DType](PayloadColumn):
    """A fixed-width payload column: `List[Scalar[dt]]` plus a NULL flag per
    slot."""

    comptime DT: DType = Self.dt
    comptime IS_STRING: Bool = False

    var values: List[Scalar[Self.dt]]
    var nulls: List[Bool]

    def __init__(out self, capacity: Int):
        self.values = List[Scalar[Self.dt]](capacity=capacity)
        self.nulls = List[Bool](capacity=capacity)
        for _ in range(capacity):
            self.values.append(Scalar[Self.dt](0))
            self.nulls.append(False)

    def __init__(out self):
        """`JOIN_BUILD_DEFAULT_CAP` slots."""
        self = Self(JOIN_BUILD_DEFAULT_CAP)

    @staticmethod
    @always_inline
    def make(capacity: Int) -> Self:
        return Self(capacity)

    def rehash_in_place(mut self, new_capacity: Int, remap: List[Int]):
        var fresh = List[Scalar[Self.dt]](capacity=new_capacity)
        var fresh_nulls = List[Bool](capacity=new_capacity)
        for _ in range(new_capacity):
            fresh.append(Scalar[Self.dt](0))
            fresh_nulls.append(False)
        for old_slot in range(len(remap)):
            var dst = remap[old_slot]
            if dst >= 0:
                fresh[dst] = self.values[old_slot]
                fresh_nulls[dst] = self.nulls[old_slot]
        self.values = fresh^
        self.nulls = fresh_nulls^

    @always_inline
    def write_slot_from_batch[bo: Origin[mut=False]](
        mut self, slot: Int, batch: BatchView[bo], col: Int, row: Int
    ) raises:
        if batch.col_is_null(col, row):
            self.values[slot] = Scalar[Self.dt](0)
            self.nulls[slot] = True
        else:
            self.values[slot] = batch.col_scalar[Self.dt](col, row)
            self.nulls[slot] = False

    @always_inline
    def slot_is_null(self, slot: Int) -> Bool:
        return self.nulls[slot]

    @always_inline
    def copy_slot(mut self, dst: Int, other: Self, src: Int):
        self.values[dst] = other.values[src]
        self.nulls[dst] = other.nulls[src]

    @always_inline
    def write_slot_f64(mut self, slot: Int, value: Float64):
        self.values[slot] = value.cast[Self.dt]()
        self.nulls[slot] = False

    @always_inline
    def read_slot_f64(self, slot: Int) -> Float64:
        return self.values[slot].cast[DType.float64]()

    @always_inline
    def write_slot(mut self, slot: Int, value: Scalar[Self.dt]):
        """Store `value` at `slot` (not NULL)."""
        self.values[slot] = value
        self.nulls[slot] = False

    @always_inline
    def read_slot(self, slot: Int) -> Scalar[Self.dt]:
        """The value at `slot` (0 for a NULL)."""
        return self.values[slot]

    @always_inline
    def read_slot_i64(self, slot: Int) -> Int64:
        return Int64(self.values[slot])

    @always_inline
    def read_slot_bits(self, slot: Int) -> UInt64:
        return key_bits_of[Self.dt](self.values[slot])

    def read_slot_string(self, slot: Int) raises -> String:
        abort(
            "PayloadSlot.read_slot_string: a fixed-width payload column holds"
            " no string; branch on IS_STRING"
        )

    def memory_size_bytes(self) -> Int:
        return len(self.values) * size_of[Scalar[Self.dt]]() + len(self.nulls)


@always_inline
def payload_slot[dt: DType](capacity: Int) -> PayloadSlot[dt]:
    """A `PayloadSlot[dt]` of `capacity` slots."""
    return PayloadSlot[dt](capacity)


struct PayloadCol_JoinString(PayloadColumn):
    """A STRING payload column: one append-only byte arena (`data`) and, per
    slot, the start and length of the slot's bytes in it and a NULL flag.
    Rehashing moves only the per-slot records; the bytes stay where they are.
    The fixed-width channel (`read_slot_bits`, `read_slot_f64`,
    `read_slot_i64`, `write_slot_f64`) aborts."""

    comptime DT: DType = DType.uint8
    comptime IS_STRING: Bool = True

    var data: List[UInt8]
    var slot_start: List[Int]
    var slot_len: List[Int]
    var nulls: List[Bool]

    def __init__(out self):
        """`JOIN_BUILD_DEFAULT_CAP` slots."""
        self = Self(JOIN_BUILD_DEFAULT_CAP)

    def __init__(out self, capacity: Int):
        self.data = List[UInt8]()
        self.slot_start = List[Int](capacity=capacity)
        self.slot_len = List[Int](capacity=capacity)
        self.nulls = List[Bool](capacity=capacity)
        for _ in range(capacity):
            self.slot_start.append(0)
            self.slot_len.append(0)
            self.nulls.append(False)

    @staticmethod
    @always_inline
    def make(capacity: Int) -> Self:
        return Self(capacity)

    def rehash_in_place(mut self, new_capacity: Int, remap: List[Int]):
        var fresh_start = List[Int](capacity=new_capacity)
        var fresh_len = List[Int](capacity=new_capacity)
        var fresh_nulls = List[Bool](capacity=new_capacity)
        for _ in range(new_capacity):
            fresh_start.append(0)
            fresh_len.append(0)
            fresh_nulls.append(False)
        for old_slot in range(len(remap)):
            var dst = remap[old_slot]
            if dst >= 0:
                fresh_start[dst] = self.slot_start[old_slot]
                fresh_len[dst] = self.slot_len[old_slot]
                fresh_nulls[dst] = self.nulls[old_slot]
        self.slot_start = fresh_start^
        self.slot_len = fresh_len^
        self.nulls = fresh_nulls^

    def write_slot_from_batch[bo: Origin[mut=False]](
        mut self, slot: Int, batch: BatchView[bo], col: Int, row: Int
    ) raises:
        """Append the string at `batch[col][row]` to the arena and record it at
        `slot`; a NULL cell records NULL and appends nothing."""
        if batch.col_is_null(col, row):
            self.slot_start[slot] = len(self.data)
            self.slot_len[slot] = 0
            self.nulls[slot] = True
            return
        var sv = batch.col_str(col).get(row)
        var n = sv.length()
        var start = len(self.data)
        for i in range(n):
            self.data.append(sv.byte_at(i))
        self.slot_start[slot] = start
        self.slot_len[slot] = n
        self.nulls[slot] = False

    @always_inline
    def slot_is_null(self, slot: Int) -> Bool:
        return self.nulls[slot]

    def copy_slot(mut self, dst: Int, other: Self, src: Int):
        var base = other.slot_start[src]
        var n = other.slot_len[src]
        var start = len(self.data)
        for i in range(n):
            self.data.append(other.data[base + i])
        self.slot_start[dst] = start
        self.slot_len[dst] = n
        self.nulls[dst] = other.nulls[src]

    def read_slot_string(self, slot: Int) raises -> String:
        """The `slot_len` bytes recorded at `slot` ("" for a NULL)."""
        var base = self.slot_start[slot]
        var n = self.slot_len[slot]
        var bytes = List[UInt8](capacity=n)
        for k in range(n):
            bytes.append(self.data[base + k])
        # The bytes were copied out of a STRING column, so they are UTF-8.
        return String(unsafe_from_utf8=Span(bytes))

    def write_slot_f64(mut self, slot: Int, value: Float64):
        abort(
            "PayloadCol_JoinString.write_slot_f64: a STRING payload column"
            " stores no number; branch on IS_STRING"
        )

    def read_slot_f64(self, slot: Int) -> Float64:
        abort(
            "PayloadCol_JoinString.read_slot_f64: a STRING payload column"
            " holds no number; branch on IS_STRING"
        )

    def read_slot_i64(self, slot: Int) -> Int64:
        abort(
            "PayloadCol_JoinString.read_slot_i64: a STRING payload column"
            " holds no number; branch on IS_STRING"
        )

    def read_slot_bits(self, slot: Int) -> UInt64:
        abort(
            "PayloadCol_JoinString.read_slot_bits: a STRING payload column"
            " holds no fixed-width value; branch on IS_STRING"
        )

    def memory_size_bytes(self) -> Int:
        return (
            len(self.data)
            + len(self.slot_start) * size_of[Int]()
            + len(self.slot_len) * size_of[Int]()
            + len(self.nulls)
        )


@always_inline
def payload_column_join_string(capacity: Int) -> PayloadCol_JoinString:
    """A `PayloadCol_JoinString` of `capacity` slots."""
    return PayloadCol_JoinString.make(capacity)


struct PayloadBlock[*Payload: PayloadColumn](Movable):
    """Carries a pack of payload columns into the `JoinBuildTable`
    constructor (a parameter list holds one variadic pack). The pack is lifted
    out once with `Optional.take()`."""

    var _payload: Optional[Tuple[*Self.Payload]]

    def __init__(out self, var *slots: *Self.Payload):
        self._payload = Tuple(*slots^)

    @always_inline
    def take(mut self) -> Tuple[*Self.Payload]:
        """The payload columns (once)."""
        return self._payload.take()
