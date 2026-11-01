# =============================================================================
# asof_join_build -- `AsofJoinBuildTable[KB, TempK, *Payload]`, the build
# table of a stage's ASOF join, with its key blocks, payload columns and the
# free functions over typed values
# =============================================================================
#
# One variadic struct covers every (equi-key arity, temporal DType, payload
# arity, payload DType) shape: the payload columns are the `*Payload` pack
# (stored as `Tuple[*Payload]`), the equi keys a fixed key block `KB`
# (`AsofKeyBundle0`, `AsofKeyBundle1[K0]`, `AsofKeyBundle2[K0, K1]`), the
# temporal key a `TempK` parameter. A declaration takes one `*` pack, which is
# why the keys are a block and not a second pack.
#
# STORAGE. Dense append, one slot per stored build row, in lockstep across
# `keys`, `temporal` and every payload column. The caller appends rows in
# ascending temporal order (per partition for a keyed table); nothing here
# sorts or checks the order.
#
# PROBE. FORWARD (DuckDB `probe.t <= build.t`): the first stored row whose
# temporal key is at or after the probe's, -1 when there is none. Equal
# temporal keys resolve to the earliest stored row. No key block: a binary
# lower bound over the whole column (`probe_binary`; it relies on the
# ascending order and returns a wrong slot on unsorted rows). With keys: a
# scan of every stored row, keeping those whose keys equal the probe's, so
# one probe costs O(n) in the table size.
#
# THE KEY MODEL (DuckDB's). Every value of the temporal type is a key; no
# value stands for "empty" or "NULL". A NULL is not stored as a value: the
# batch-row build (`AsofJoinBuildState.feed_row`) skips a row whose temporal
# key is NULL, and the probe state never probes a NULL. Temporal keys compare
# in `komira_op_sort.sort.sort_key_lt` order (for floats: NaN equal to NaN
# and above +inf, -0.0 equal to +0.0); equi keys are equal when neither sorts
# before the other in that order.
#
# PAYLOADS. Each payload column stores its values at its own DType with a
# NULL flag per slot (`append_from_batch`), and emits a gathered output
# column itself (`gather_column`), so an INT64 payload keeps all 64 bits and a
# NULL stays NULL. `append_f64` / `read_slot_f64` are a Float64 channel for
# the typed free functions (an INT64 above 2^53 does not survive it).
# =============================================================================

from komira_arrow.batch_view import BatchView
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_op_sort.sort import sort_key_lt


comptime _BUILD_ASOF_DEFAULT_CAP: Int = 64
"""The initial capacity of a table (a sizing hint; storage grows)."""


@always_inline
def _key_eq[dt: DType](a: Scalar[dt], b: Scalar[dt]) -> Bool:
    """Equal in `sort_key_lt` order (NaN equals NaN, -0.0 equals +0.0)."""
    return not sort_key_lt[dt](a, b) and not sort_key_lt[dt](b, a)


def primitive_with_nulls[
    dt: DType
](var values: List[Scalar[dt]], valid: List[Bool]) raises -> Column[HeapRegion]:
    """A primitive column of `values`, with a validity bitmap from `valid`
    when some entry is False."""
    var pa = PrimitiveArray[dt].from_list(values)
    var n = len(valid)
    var nulls = 0
    for i in range(n):
        if not valid[i]:
            nulls += 1
    if nulls > 0:
        var bm = Bitmap.create(n)
        for i in range(n):
            if valid[i]:
                bm.set(i)
        pa.validity = Optional[Bitmap[HeapRegion]](bm^)
        pa.null_count = nulls
    return Column.from_primitive[dt](pa^)


# =============================================================================
# Payload columns
# =============================================================================


trait PayloadColumn(Movable, Copyable, Deinitable):
    """One dense-append payload column of an `AsofJoinBuildTable`. The table
    reaches its columns only through these trait methods (a pack element's
    struct parameters cannot be named in the table's body)."""

    comptime DT: DType
    """The element DType."""

    @staticmethod
    def make(capacity: Int) -> Self:
        """An empty column with `capacity` reserved."""
        ...

    def append_from_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], col: Int, row: Int
    ) raises:
        """Append `batch[col][row]` read at the column's DType; a NULL cell
        appends NULL."""
        ...

    def append_f64(mut self, value: Float64):
        """Append `value` cast to the column's DType (not NULL)."""
        ...

    def read_slot_f64(self, slot: Int) -> Float64:
        """The value at `slot` cast to Float64 (0 for a NULL)."""
        ...

    def slot_is_null(self, slot: Int) -> Bool:
        """True iff the value at `slot` is NULL."""
        ...

    def gather_column(self, slots: List[Int]) raises -> Column[HeapRegion]:
        """The values at `slots`, in order, as a column of the column's DType
        (NULL for a NULL slot and for a slot of -1)."""
        ...

    def length(self) -> Int:
        """The number of appended values."""
        ...

    def truncate(mut self, n: Int):
        """Drop the values past the first `n` (a no-op when there are `n` or
        fewer)."""
        ...


struct PayloadSlot[dt: DType](PayloadColumn):
    """A fixed-width payload column: `List[Scalar[dt]]` and a NULL flag per
    slot. BOOL is not a payload type."""

    comptime DT: DType = Self.dt

    var values: List[Scalar[Self.dt]]
    var nulls: List[Bool]

    def __init__(out self, capacity: Int):
        comptime assert Self.dt != DType.bool, "PayloadSlot: BOOL payload"
        self.values = List[Scalar[Self.dt]](capacity=capacity)
        self.nulls = List[Bool](capacity=capacity)

    @staticmethod
    @always_inline
    def make(capacity: Int) -> Self:
        return Self(capacity)

    def append_from_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], col: Int, row: Int
    ) raises:
        if batch.col_is_null(col, row):
            self.values.append(Scalar[Self.dt](0))
            self.nulls.append(True)
        else:
            self.values.append(batch.col_scalar[Self.dt](col, row))
            self.nulls.append(False)

    @always_inline
    def append_f64(mut self, value: Float64):
        self.values.append(value.cast[Self.dt]())
        self.nulls.append(False)

    @always_inline
    def append_value(mut self, value: Scalar[Self.dt]):
        """Append `value` (not NULL), exactly."""
        self.values.append(value)
        self.nulls.append(False)

    @always_inline
    def read_slot_f64(self, slot: Int) -> Float64:
        return self.values[slot].cast[DType.float64]()

    @always_inline
    def read_value(self, slot: Int) -> Scalar[Self.dt]:
        """The value at `slot`, exactly (0 for a NULL)."""
        return self.values[slot]

    @always_inline
    def slot_is_null(self, slot: Int) -> Bool:
        return self.nulls[slot]

    def gather_column(self, slots: List[Int]) raises -> Column[HeapRegion]:
        var n = len(slots)
        var out = List[Scalar[Self.dt]](capacity=n)
        var valid = List[Bool](capacity=n)
        for i in range(n):
            var s = slots[i]
            if s < 0 or self.nulls[s]:
                out.append(Scalar[Self.dt](0))
                valid.append(False)
            else:
                out.append(self.values[s])
                valid.append(True)
        return primitive_with_nulls[Self.dt](out^, valid)

    @always_inline
    def length(self) -> Int:
        return len(self.values)

    def truncate(mut self, n: Int):
        while len(self.values) > n:
            _ = self.values.pop()
        while len(self.nulls) > n:
            _ = self.nulls.pop()


@always_inline
def payload_slot[dt: DType](capacity: Int) -> PayloadSlot[dt]:
    """An empty `PayloadSlot[dt]` with `capacity` reserved."""
    return PayloadSlot[dt](capacity)


struct PayloadBlock[*Payload: PayloadColumn](Movable):
    """The payload columns, packed for the table's constructor (which cannot
    take a `*` pack next to its other arguments). `take` lifts the tuple out
    once."""

    var _payload: Optional[Tuple[*Self.Payload]]

    def __init__(out self, var *slots: *Self.Payload):
        self._payload = Tuple(*slots^)

    @always_inline
    def take(mut self) -> Tuple[*Self.Payload]:
        """The payload tuple (once)."""
        return self._payload.take()


# =============================================================================
# Equi-key blocks
# =============================================================================


trait AsofKeyBundle(Movable, Copyable, Deinitable):
    """A dense-append block of typed equi-key (partition) columns at a fixed
    arity: `AsofKeyBundle0`, `AsofKeyBundle1[K0]`, `AsofKeyBundle2[K0, K1]`."""

    comptime ARITY: Int

    @staticmethod
    def make(capacity: Int) -> Self:
        """An empty block with `capacity` reserved."""
        ...


struct AsofKeyBundle0(AsofKeyBundle):
    """No equi keys: the probe searches the whole temporal column."""

    comptime ARITY: Int = 0

    def __init__(out self, capacity: Int):
        pass

    @staticmethod
    @always_inline
    def make(capacity: Int) -> Self:
        return Self(capacity)


struct AsofKeyBundle1[K0: DType](AsofKeyBundle):
    """One equi-key column."""

    comptime ARITY: Int = 1

    var c0: List[Scalar[Self.K0]]

    def __init__(out self, capacity: Int):
        self.c0 = List[Scalar[Self.K0]](capacity=capacity)

    @staticmethod
    @always_inline
    def make(capacity: Int) -> Self:
        return Self(capacity)

    @always_inline
    def append_keys(mut self, k0: Scalar[Self.K0]):
        self.c0.append(k0)

    @always_inline
    def matches_at(self, slot: Int, probe_k0: Scalar[Self.K0]) -> Bool:
        """The key at `slot` equals `probe_k0` (the key model)."""
        return _key_eq[Self.K0](self.c0[slot], probe_k0)


struct AsofKeyBundle2[K0: DType, K1: DType](AsofKeyBundle):
    """Two equi-key columns; a row matches when both are equal."""

    comptime ARITY: Int = 2

    var c0: List[Scalar[Self.K0]]
    var c1: List[Scalar[Self.K1]]

    def __init__(out self, capacity: Int):
        self.c0 = List[Scalar[Self.K0]](capacity=capacity)
        self.c1 = List[Scalar[Self.K1]](capacity=capacity)

    @staticmethod
    @always_inline
    def make(capacity: Int) -> Self:
        return Self(capacity)

    @always_inline
    def append_keys(mut self, k0: Scalar[Self.K0], k1: Scalar[Self.K1]):
        self.c0.append(k0)
        self.c1.append(k1)

    @always_inline
    def matches_at(
        self, slot: Int, probe_k0: Scalar[Self.K0], probe_k1: Scalar[Self.K1]
    ) -> Bool:
        """Both keys at `slot` equal the probe's (the key model)."""
        return _key_eq[Self.K0](self.c0[slot], probe_k0) and _key_eq[Self.K1](
            self.c1[slot], probe_k1
        )


# =============================================================================
# The table
# =============================================================================


struct AsofJoinBuildTable[
    KB: AsofKeyBundle, TempK: DType, *Payload: PayloadColumn
](Movable):
    """The dense-append ASOF build table (see the module header). Moved, never
    copied."""

    var keys: Self.KB
    var temporal: List[Scalar[Self.TempK]]
    var payload: Tuple[*Self.Payload]
    var n_used: Int

    def __init__(
        out self,
        var payload_block: PayloadBlock[*Self.Payload],
        initial_capacity: Int = _BUILD_ASOF_DEFAULT_CAP,
    ):
        """An empty table with `initial_capacity` reserved; the payload
        columns come from `payload_block`."""
        self.keys = Self.KB.make(initial_capacity)
        self.temporal = List[Scalar[Self.TempK]](capacity=initial_capacity)
        self.payload = payload_block.take()
        self.n_used = 0

    @staticmethod
    @always_inline
    def key_arity() -> Int:
        """The number of equi-key columns."""
        return Self.KB.ARITY

    @staticmethod
    @always_inline
    def payload_arity() -> Int:
        """The number of payload columns."""
        return Self.Payload.__len__()

    @always_inline
    def n_rows(self) -> Int:
        """The number of stored rows."""
        return self.n_used

    @always_inline
    def temp_at(self, slot: Int) -> Scalar[Self.TempK]:
        """The temporal key at `slot`."""
        return self.temporal[slot]

    @always_inline
    def payload_read_f64[p: Int](self, slot: Int) -> Float64:
        """Payload column `p` at `slot`, cast to Float64."""
        return self.payload[p].read_slot_f64(slot)

    @always_inline
    def payload_is_null[p: Int](self, slot: Int) -> Bool:
        """True iff payload column `p` is NULL at `slot`."""
        return self.payload[p].slot_is_null(slot)

    @always_inline
    def append_temporal(mut self, temp: Scalar[Self.TempK]):
        """Store a temporal key at the next slot. The caller appends the keys
        and the payloads of the same row in lockstep."""
        self.temporal.append(temp)
        self.n_used += 1

    def truncate_rows(mut self, n: Int):
        """Drop every stored row past the first `n` from the temporal column
        and every payload column (a no-op when there are `n` or fewer). The
        equi-key block is not touched: only a table without keys is fed
        row by row."""
        while len(self.temporal) > n:
            _ = self.temporal.pop()
        self.n_used = len(self.temporal)
        comptime for p in range(Self.Payload.__len__()):
            self.payload[p].truncate(n)

    def probe_binary(self, probe_temp: Scalar[Self.TempK]) -> Int:
        """No key block: the first slot whose temporal key is at or after
        `probe_temp`, or -1. Precondition: the rows were appended in
        ascending temporal order (`sort_key_lt` order); on unsorted rows the
        slot is not meaningful. Nothing checks the order."""
        comptime assert Self.KB.ARITY == 0, (
            "probe_binary is the probe of a table without equi keys"
        )
        var lo = 0
        var hi = self.n_used
        while lo < hi:
            var mid = (lo + hi) // 2
            if sort_key_lt[Self.TempK](self.temporal[mid], probe_temp):
                lo = mid + 1
            else:
                hi = mid
        if lo >= self.n_used:
            return -1
        return lo


# =============================================================================
# Free functions over typed values, per key arity
# =============================================================================
#
# The table cannot name a pack element's DType, so the typed append and probe
# entry points are free functions with the key DTypes as parameters. The
# appends take the payload values on the Float64 channel.


@always_inline
def asof_build_append_0_f64[TempK: DType, *Payload: PayloadColumn](
    mut table: AsofJoinBuildTable[AsofKeyBundle0, TempK, *Payload],
    temp: Scalar[TempK],
    payload_vals: List[Float64],
):
    """Append a row to a table without keys: its temporal key and one Float64
    per payload column, in column order."""
    table.append_temporal(temp)
    comptime for p in range(Payload.__len__()):
        table.payload[p].append_f64(payload_vals[p])


@always_inline
def asof_probe_forward_0[TempK: DType, *Payload: PayloadColumn](
    table: AsofJoinBuildTable[AsofKeyBundle0, TempK, *Payload],
    probe_temp: Scalar[TempK],
) -> Int:
    """The first row at or after `probe_temp`, or -1."""
    return table.probe_binary(probe_temp)


@always_inline
def asof_build_append_1_f64[K0: DType, TempK: DType, *Payload: PayloadColumn](
    mut table: AsofJoinBuildTable[AsofKeyBundle1[K0], TempK, *Payload],
    k0: Scalar[K0],
    temp: Scalar[TempK],
    payload_vals: List[Float64],
):
    """Append a row to a one-key table."""
    table.keys.append_keys(k0)
    table.append_temporal(temp)
    comptime for p in range(Payload.__len__()):
        table.payload[p].append_f64(payload_vals[p])


def asof_probe_forward_1[K0: DType, TempK: DType, *Payload: PayloadColumn](
    table: AsofJoinBuildTable[AsofKeyBundle1[K0], TempK, *Payload],
    probe_k0: Scalar[K0],
    probe_temp: Scalar[TempK],
) -> Int:
    """Among the rows whose key equals `probe_k0`, the one with the smallest
    temporal key at or after `probe_temp` (the earliest such row on a tie),
    or -1."""
    var best_slot = -1
    for i in range(table.n_used):
        if table.keys.matches_at(i, probe_k0):
            var t = table.temporal[i]
            if not sort_key_lt[TempK](t, probe_temp):
                if best_slot < 0 or sort_key_lt[TempK](
                    t, table.temporal[best_slot]
                ):
                    best_slot = i
    return best_slot


@always_inline
def asof_build_append_2_f64[
    K0: DType, K1: DType, TempK: DType, *Payload: PayloadColumn
](
    mut table: AsofJoinBuildTable[AsofKeyBundle2[K0, K1], TempK, *Payload],
    k0: Scalar[K0],
    k1: Scalar[K1],
    temp: Scalar[TempK],
    payload_vals: List[Float64],
):
    """Append a row to a two-key table."""
    table.keys.append_keys(k0, k1)
    table.append_temporal(temp)
    comptime for p in range(Payload.__len__()):
        table.payload[p].append_f64(payload_vals[p])


def asof_probe_forward_2[
    K0: DType, K1: DType, TempK: DType, *Payload: PayloadColumn
](
    table: AsofJoinBuildTable[AsofKeyBundle2[K0, K1], TempK, *Payload],
    probe_k0: Scalar[K0],
    probe_k1: Scalar[K1],
    probe_temp: Scalar[TempK],
) -> Int:
    """`asof_probe_forward_1` over both keys."""
    var best_slot = -1
    for i in range(table.n_used):
        if table.keys.matches_at(i, probe_k0, probe_k1):
            var t = table.temporal[i]
            if not sort_key_lt[TempK](t, probe_temp):
                if best_slot < 0 or sort_key_lt[TempK](
                    t, table.temporal[best_slot]
                ):
                    best_slot = i
    return best_slot
