# =============================================================================
# sort_stage_columns -- the typed columns of the stage sort buffer: the key
# column trait and its fixed-width conformer, and the UInt64 bit channel
# =============================================================================
#
# The stage sort buffer (`sort_stage_buffer.SortBuffer[KB, *Payloads]`) is
# typed at compile time: each sort key is a `SortKeyColumn` (one per key, in a
# key block `KB`) and each carried column a `PayloadColumn`
# (`sort_stage_payloads`), each bound to an input column `col` and storing its
# values column-wise (`List[Scalar[dt]]`, or bytes for STRING in
# `sort_stage_string_key`). It is separate from `sort_buffer_untyped`, whose
# layout is known only at run time.
#
# A float key compares by `sort.sort_key_lt` (NaN above +inf, every NaN tied),
# in the merge comparator, the top-N candidate compare and the top-N SIMD
# reject mask alike, so every route orders floats as the sort kernels do.
# =============================================================================

from std.collections import Optional
from std.math import isnan
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

from .sort import sort_key_lt


# =============================================================================
# §1 — Constants
# =============================================================================

comptime MAX_SORT_ROWS: Int = 65536
"""The row count a sort buffer is sized for. It documents intent: the buffer's
lists grow past it, and a breaker that must bound memory spills (the
`SpillableOp` surface below)."""

comptime MAX_SORT_KEYS: Int = 8
"""The most sort keys a buffer takes. The per-key direction array
(`directions`) is a fixed `InlineArray[UInt8, MAX_SORT_KEYS]`, so the buffer
holds no heap-owning direction field."""

comptime SORT_DIR_ASC_U8: UInt8 = 0
comptime SORT_DIR_DESC_U8: UInt8 = 1


# =============================================================================
# §2 — typed read helpers (shared by key + payload column conformers)
# =============================================================================


@always_inline
def _read_sort_scalar[
    K: DType, bo: Origin[mut=False]
](batch: BatchView[bo], col: Int, row: Int) -> Scalar[K]:
    """Read the value of DType `K` at `row` from input column `col`.

    delegates to the single generic
    `BatchView.col_scalar_nonraising[K]` primitive — bit-exact over the FULL
    fixed-width numeric matrix (i8/16/32/64, u8/16/32/64, f32/f64), with NO
    silent `col_i64` else-fallthrough (an unhandled DType is a COMPILE ERROR).
    The all-handled-today DTypes (I64/I32/F64/F32) codegen byte-identical."""
    return batch.col_scalar_nonraising[K](col, row)


@always_inline
def _read_sort_simd[
    K: DType, W: Int, bo: Origin[mut=False]
](batch: BatchView[bo], col: Int, i: Int) -> SIMD[K, W]:
    """Vector read of W CONTIGUOUS values of DType `K` from input column `col`
    starting at row `i`. SIMD-W mirror of `_read_sort_scalar` — the comptime `K`
    branch folds to one typed `ColView.load[W]`. Used by the TOP-N SIMD reject
    fast path (`SortKeyColumn_Typed.simd_reject_winner_mask`). Caller guarantees
    `i + W <= n_rows`.

    delegates to the generic
    `BatchView.col_scalar_simd[K, W]` primitive — bit-exact over the full
    fixed-width numeric matrix, NO silent `col_i64` else-fallthrough."""
    return batch.col_scalar_simd[K, W](col, i)


@always_inline
def _sort_arrow_type[K: DType]() -> ArrowType:
    """Map a sort key / payload DType to its `ArrowType` for the drain schema.

    delegates to the generic
    `scalar_arrow_type[K]` — correct over the full fixed-width matrix, NO silent
    `INT64` else-fallthrough."""
    return scalar_arrow_type[K]()


# Backwards-compatible alias (older call sites named the key-only helper).
@always_inline
def _read_sort_key_scalar[
    K: DType, bo: Origin[mut=False]
](batch: BatchView[bo], col: Int, row: Int) -> Scalar[K]:
    return _read_sort_scalar[K, bo](batch, col, row)


@always_inline
def _sort_key_arrow_type[K: DType]() -> ArrowType:
    return _sort_arrow_type[K]()


# =============================================================================
# §2b — bit-exact UInt64 channel (the trait-erasure-wall round-trip)
# =============================================================================
#
# The generic `SortBuffer[KB, *Payloads]` body cannot project the per-column
# DType behind the `KB` wrap / `*Payloads` pack (a Mojo trait-projection
# limit). So the flat by-value append/read surface
# routes every key/payload cell through a UInt64 BIT channel: the concrete
# column `bitcast`s its native `Scalar[dt]` to/from the matching-width unsigned
# integer (zero-extended to UInt64). This is BIT-EXACT for every DType (i64 /
# f64 / i32 / f32 / ...) — NO lossy `cast` round-trip (unlike join_build's
# `read_slot_f64`). The caller (which knows its concrete DType) bitcasts at the
# boundary via `sort_bits_of` / `sort_from_bits`.


@always_inline
def sort_bits_of[dt: DType](value: Scalar[dt]) -> UInt64:
    """Reinterpret a typed scalar as its zero-extended UInt64 bit pattern."""
    comptime if dt == DType.int64 or dt == DType.uint64 or dt == DType.float64:
        return bitcast[DType.uint64, 1](SIMD[dt, 1](value))[0]
    elif dt == DType.int32 or dt == DType.uint32 or dt == DType.float32:
        return UInt64(bitcast[DType.uint32, 1](SIMD[dt, 1](value))[0])
    elif dt == DType.int16 or dt == DType.uint16:
        return UInt64(bitcast[DType.uint16, 1](SIMD[dt, 1](value))[0])
    elif dt == DType.int8 or dt == DType.uint8 or dt == DType.bool:
        return UInt64(bitcast[DType.uint8, 1](SIMD[dt, 1](value))[0])
    else:
        return bitcast[DType.uint64, 1](SIMD[dt, 1](value))[0]


@always_inline
def sort_from_bits[dt: DType](bits: UInt64) -> Scalar[dt]:
    """Reconstruct a typed scalar from its zero-extended UInt64 bit pattern.
    Exact inverse of `sort_bits_of[dt]`."""
    comptime if dt == DType.int64 or dt == DType.uint64 or dt == DType.float64:
        return rebind[Scalar[dt]](bitcast[dt, 1](SIMD[DType.uint64, 1](bits))[0])
    elif dt == DType.int32 or dt == DType.uint32 or dt == DType.float32:
        return rebind[Scalar[dt]](
            bitcast[dt, 1](SIMD[DType.uint32, 1](UInt32(bits)))[0]
        )
    elif dt == DType.int16 or dt == DType.uint16:
        return rebind[Scalar[dt]](
            bitcast[dt, 1](SIMD[DType.uint16, 1](UInt16(bits)))[0]
        )
    elif dt == DType.int8 or dt == DType.uint8 or dt == DType.bool:
        return rebind[Scalar[dt]](
            bitcast[dt, 1](SIMD[DType.uint8, 1](UInt8(bits)))[0]
        )
    else:
        return rebind[Scalar[dt]](bitcast[dt, 1](SIMD[DType.uint64, 1](bits))[0])


@always_inline
def _key_cmp3[dt: DType](a: Scalar[dt], b: Scalar[dt]) -> Int:
    """-1 / 0 / +1 in the `sort_key_lt` order: for a float, NaN above +inf and
    every NaN tied (the IEEE `<` / `>` would tie a NaN with every value)."""
    if sort_key_lt(a, b):
        return -1
    if sort_key_lt(b, a):
        return 1
    return 0


# =============================================================================
# §3 — SortKeyColumn — the per-key column trait + conformer (KB pack element)
# =============================================================================


trait SortKeyColumn(Defaultable, Movable, Deinitable):
    """One sort-key column — the per-slot element type of a `SortKeyBlock` key
    pack. Owns the `List[Scalar[DT]]` of that key's values across all buffered
    rows.

    Conformers carry their key DType via the comptime `DT` member and expose
    `append_value`, `length`, `value_at`, and a 3-way `compare_at(i, j)` used by
    the lexicographic comparator. The single in-tree conformer is
    `SortKeyColumn_Typed[dt, col]` (below).

    `read_and_append` / `restore_append` / `emit_sorted_column` /
    `add_sort_key_schema_field` are the EXECUTABLE surface — they keep the
    per-key DType / input-column reads (and the native-DType drain emit) INSIDE
    the concrete conformer (where `Scalar[dt]` + `col` are in scope), so the
    owning `SortKeyBlock` / `SortBuffer` can drive any arity uniformly without
    naming a concrete key type (the trait-erasure wall).

    `compare_at(i, j)` returns -1 / 0 / +1 (row i's key < / == / > row j's key)
    for ASCENDING order; the buffer flips the sign per-key for DESCENDING runtime
    direction.

    `Defaultable` (the empty column) lets a key pack be default-constructed
    as `Tuple[*Keys]()`.

    `IS_VARLEN` is a comptime discriminator (False for fixed-width DType keys,
    True for the variable-length STRING key). The bounded global TOP-N
    reads it (via `SortKeyBlock.key0_is_varlen()`) to elide
    the single-key SIMD reject fast path at COMPTIME for a STRING order key — a
    variable-length key cannot be loaded into a fixed-width SIMD vector, so the
    STRING arity-1 case takes the scalar `feed_row` path (the byte-native
    random-access channel below)."""

    comptime DT: DType
    comptime IS_VARLEN: Bool

    @staticmethod
    def make(capacity: Int) -> Self:
        """Construct an empty column with reserved capacity."""
        ...

    def append_value(mut self, value: Scalar[Self.DT]):
        """Append one key value (one buffered row)."""
        ...

    def append_bits(mut self, bits: UInt64):
        """Append one key value supplied as its UInt64 bit pattern (the
        trait-erasure-wall channel — `sort_from_bits[DT]` reconstructs)."""
        ...

    def value_bits_at(self, i: Int) -> UInt64:
        """Read key value at buffered row `i` as its UInt64 bit pattern."""
        ...

    def read_and_append[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ):
        """Read this column's bound input column at `row` off `batch` and append
        the value (one buffered row)."""
        ...

    def restore_append[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], spill_col: Int, row: Int
    ):
        """SPILL restore path. Read this key's value at `row` off `batch` column
        `spill_col` (the key's OUTPUT-slot position `k` in the spill image — NOT
        the breaker's input-bound `col`) and append it as one buffered row."""
        ...

    def input_is_null[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int
    ) -> Bool:
        """True iff this key's bound input cell at `row` is NULL. The column
        stores values without validity, so the buffer refuses such a row."""
        ...

    def length(self) -> Int:
        """Number of buffered key values."""
        ...

    def clear_values(mut self):
        """Drop all buffered key values (after spill serialization). Leaves the
        column empty + reusable."""
        ...

    def value_at(self, i: Int) -> Scalar[Self.DT]:
        """The raw key value at buffered row index `i`."""
        ...

    def append_other(mut self, other: Self):
        """Append every buffered value of `other` (cross-worker combine)."""
        ...

    def ensure_len(mut self, n: Int):
        """Grow the backing buffer to at least `n` slots (zero-filled). Enables
        RANDOM-ACCESS overwrite via `set_bits_at` / `read_into_slot` — the
        bounded global TOP-N buffer reuses recycled slot
        indices for the key columns (same recycled-slot shape `PayloadColumn`
        carries for a partitioned top-N), so the key column must be indexable beyond
        strict append order."""
        ...

    def set_bits_at(mut self, i: Int, bits: UInt64):
        """Overwrite slot `i`'s value with the UInt64 bit pattern. Caller has
        `ensure_len(i + 1)`'d. Random-access write for the recycled-slot buffer
        (global TOP-N combine path)."""
        ...

    def read_into_slot[bo: Origin[mut=False]](
        mut self, slot: Int, batch: BatchView[bo], row: Int
    ):
        """Read this key column's bound input column at `row` off `batch` and
        write the value into random-access slot `slot` (the bounded recycled-slot
        global TOP-N buffer). Caller has `ensure_len(slot + 1)`'d."""
        ...

    def copy_slot(mut self, dst: Int, other: Self, src: Int):
        """Copy this key column's value at `other`'s slot `src` into `self`'s
        random-access slot `dst` (the cross-worker TOP-N combine path). A
        CHANNEL-NATIVE slot-to-slot copy: fixed-width keys route through the
        UInt64 bit channel; the variable-length STRING key copies its byte slice
        directly (the bit channel cannot carry a string). Caller has `self`
        `ensure_len(dst + 1)`'d."""
        ...

    def compare_at(self, i: Int, j: Int) -> Int:
        """3-way ascending compare of row i's key against row j's key."""
        ...

    def simd_reject_winner_mask[W: Int, bo: Origin[mut=False]](
        self, batch: BatchView[bo], i: Int, root: Scalar[Self.DT], dir_u8: UInt8
    ) -> SIMD[DType.bool, W]:
        """TOP-N SIMD reject-path. Load W
        CONTIGUOUS candidate keys off this column's bound input column starting at
        row `i` (one vector load), and return the lane mask where the candidate
        key sorts STRICTLY BEFORE `root` under the (ASC/DESC) direction — i.e. the
        lane is a POTENTIAL winner against the current heap root.

        Only valid for the SINGLE-key TOP-N case (the lexicographic tie-break of a
        multi-key comparator cannot be resolved by a one-column SIMD mask). The
        overwhelming-common steady-state result is an ALL-FALSE mask (no winner in
        the chunk), letting the caller skip the whole W-wide chunk with zero
        per-row work."""
        ...

    def compare_batch_row_to_slot[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int, slot: Int
    ) -> Int:
        """3-way ascending compare of a CANDIDATE key read DIRECTLY off `batch`
        at `row` (native DType, no slot store) against this column's buffered
        `slot` value. The TOP-N reject-path fast compare: a candidate is tested
        against the bounded heap's worst kept row WITHOUT first copying it into a
        recycled slot (the dominant cost on the ~all-rows reject path)."""
        ...

    def emit_sorted_column(self, order: List[Int], mut rb: RecordBatchBuilder):
        """Append this key column — in native DType, materialized over the
        sorted `order` permutation — to `rb`."""
        ...

    def add_sort_key_schema_field(self, mut sb: SchemaBuilder, k: Int):
        """Append this key's output schema field (`k<k>`, native DType)."""
        ...


struct SortKeyColumn_Typed[dt: DType, col: Int](SortKeyColumn):
    """Concrete per-key column wrapping a `List[Scalar[dt]]` of sort-key values,
    bound to input batch column `col`.

    One type per key DType: a new key DType is a new
    `SortKeyColumn_Typed[dt, col]` instantiation, not a new struct. A float key
    compares by `sort.sort_key_lt` (NaN above +inf, every NaN tied).

    `col` is the comptime input-batch column index this key is read from. A
    caller that appends pre-extracted values with `append_value` uses a
    sentinel `col`."""

    comptime DT: DType = Self.dt
    comptime IS_VARLEN: Bool = False
    var values: List[Scalar[Self.dt]]

    def __init__(out self):
        # The empty column (so `Tuple[*Keys]()` default-constructs).
        self.values = List[Scalar[Self.dt]]()

    def __init__(out self, var values: List[Scalar[Self.dt]]):
        self.values = values^

    @staticmethod
    def new(initial_capacity: Int) -> SortKeyColumn_Typed[Self.dt, Self.col]:
        """Construct empty column with reserved capacity."""
        return SortKeyColumn_Typed[Self.dt, Self.col](
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
    def read_into_slot[bo: Origin[mut=False]](
        mut self, slot: Int, batch: BatchView[bo], row: Int
    ):
        self.values[slot] = _read_sort_scalar[Self.dt, bo](batch, Self.col, row)

    @always_inline
    def copy_slot(mut self, dst: Int, other: Self, src: Int):
        # Fixed-width slot copy via the bit channel (byte-identical to the prior
        # `set_bits_at(dst, value_bits_at(src))` round-trip).
        self.values[dst] = other.values[src]

    @always_inline
    def compare_at(self, i: Int, j: Int) -> Int:
        return _key_cmp3[Self.dt](self.values[i], self.values[j])

    @always_inline
    def compare_batch_row_to_slot[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int, slot: Int
    ) -> Int:
        # Native-DType direct compare: candidate read off the batch (the comptime
        # `_read_sort_scalar` branch folds to one typed load), stored slot read
        # off the column List. NO bit channel, NO trait-dispatched runtime-k loop.
        var a = _read_sort_scalar[Self.dt, bo](batch, Self.col, row)
        return _key_cmp3[Self.dt](a, self.values[slot])

    @always_inline
    def simd_reject_winner_mask[W: Int, bo: Origin[mut=False]](
        self, batch: BatchView[bo], i: Int, root: Scalar[Self.DT], dir_u8: UInt8
    ) -> SIMD[DType.bool, W]:
        # One W-wide load of candidate keys and one compare against the
        # broadcast `root`. ASC: a lane wins iff `sort_key_lt(cand, root)`;
        # DESC: iff `sort_key_lt(root, cand)`. For a float key that is the IEEE
        # compare plus the NaN rule (a NaN is above every number), so a NaN
        # candidate wins against a numeric root DESC and never ASC.
        var cands = _read_sort_simd[Self.dt, W, bo](batch, Self.col, i)
        var rv = SIMD[Self.dt, W](root)
        comptime if Self.dt.is_floating_point():
            var cand_nan = isnan(cands)
            var root_nan = isnan(rv)
            if dir_u8 == SORT_DIR_DESC_U8:
                return cands.gt(rv) | (cand_nan & ~root_nan)
            return cands.lt(rv) | (root_nan & ~cand_nan)
        else:
            if dir_u8 == SORT_DIR_DESC_U8:
                return cands.gt(rv)
            return cands.lt(rv)

    def emit_sorted_column(self, order: List[Int], mut rb: RecordBatchBuilder):
        var vals = List[Scalar[Self.dt]](capacity=len(order))
        for si in range(len(order)):
            vals.append(self.values[order[si]])
        var arr = PrimitiveArray[Self.dt].from_list(vals)
        rb.add_column(Column.from_primitive[Self.dt](arr^))

    def add_sort_key_schema_field(self, mut sb: SchemaBuilder, k: Int):
        sb.add_field(
            Field(String("k") + String(k), _sort_arrow_type[Self.dt](), True)
        )
