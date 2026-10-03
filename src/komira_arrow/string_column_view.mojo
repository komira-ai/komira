# =============================================================================
# StringColumnView[origin] + BinaryColumnView[origin] -- typed borrow over a
# variable-length STRING / BINARY column from a RecordBatch.
# =============================================================================
#
# Substrate for the untyped row and column paths (hash aggregation, join
# build, sort buffer, distinct): `ColView[DType.uint8]` cannot expose the
# offset arithmetic a variable-length column needs.
#
# Shape (matches the typed `ColView` pattern in `batch_view.mojo`):
#
#     struct StringView[origin: Origin[mut=False]]
#         var _batch: Pointer[RecordBatch, origin]
#         var _col_idx: Int
#         var _byte_offset: Int
#         var _byte_length: Int
#         fn length(self) -> Int
#         fn byte_at(self, i: Int) raises -> UInt8
#         fn to_string(self) raises -> String   # copies; debug/test use
#
#     struct StringColumnView[origin: Origin[mut=False]]
#         var _batch: Pointer[RecordBatch, origin]
#         var _idx: Int
#         fn length(self) -> Int
#         fn get(self, row: Int) raises -> StringView[origin]
#         fn offset_at(self, row: Int) raises -> Int
#         fn n_data_bytes(self) raises -> Int
#
#     struct BinaryColumnView[origin: Origin[mut=False]]
#         (mirror; semantic-only distinction -- bytes are NOT validated as UTF-8)
#
# Encapsulation invariants:
# - No `UnsafePointer` in any public method signature.
# - All borrows are tracked via `Pointer[RecordBatch, origin]` with a concrete
#   `origin: Origin[mut=False]` parameter.
# - The wrapped `RecordBatch` lifetime is bound by `origin`; the views cannot
#   outlive the borrowed RecordBatch.
#
# IMPLEMENTATION NOTE — origin coercion (Mojo 1.0.0b1, mirrors `ColView`):
#   `RecordBatch.column_at(idx)` returns `ref [self._columns._bytes] Column`,
#   a sub-origin of the parent batch's lifetime. Mojo 1.0.0b1 does NOT
#   auto-coerce that sub-origin to the parent `origin` parameter, so we
#   side-step the issue by having `StringColumnView` / `BinaryColumnView`
#   store `(Pointer[RecordBatch, Self.origin], Int idx)` instead of
#   `Pointer[Column, ...]` -- the Column ref is re-derived inside each
#   `get(row)` / `offset_at(row)` call from the parent batch pointer.
# =============================================================================

from komira_arrow.arrow_types import ARROW_LAYOUT_OFFSETS_I64, ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch
from komira_buffer.byte_view import ByteView


# =============================================================================
# THE OFFSET WIDTH IS READ OFF THE COLUMN, NEVER ASSUMED.
# =============================================================================
#
# `string` / `binary` carry INT32 offsets; `large_string` / `large_binary` are
# the SAME logical types with INT64 offsets. An accessor that read the
# offsets buffer with a hardcoded `read_i32_le_at(row * 4)` without consulting
# `col.arrow_type` would decode a wide column at the wrong stride: index k
# would return low32(O[k/2]) for even k and high32(O[k/2]) for odd k. Real
# sub-2GB offsets have an all-zero high half, so [0, 5, 10] would decode as
# [0, 0, 5, ...] — every row would get the wrong byte span while `length()`,
# which is read off the Column and not off the offsets, stays exactly right.
#
# ⚠ THE PREDICATE IS THE LAYOUT CLASS, NOT A TYPE-TAG EQUALITY LIST. Spelling
# it `at == LARGE_STRING or at == LARGE_BINARY` puts a second, narrower copy of
# `physical_layout_class`'s knowledge here, and the next wide offsets-bearing
# type Arrow defines would be read at 4-byte stride again with nothing going
# red. `ARROW_LAYOUT_OFFSETS_I64` is the one definition of "this buffer is
# INT64-strided", and it is what the layout-conflict guard in
# `record_batch.mojo` already keys on.
#
# Both views branch identically because the two layouts are byte-identical —
# the STRING/BINARY distinction is semantic (UTF-8 validated or not), never
# structural — so a `large_binary` column reaching `col_str` and a
# `large_string` column reaching `col_binary` must both decode, exactly as the
# narrow pair already do.
# =============================================================================


# ⚠ THE WIDTH IS RESOLVED ONCE PER VIEW, NOT ONCE PER ROW. `get` / `offset_at`
# are the per-ROW surface under the sort/top-N payload ingest, the untyped hash
# agg and the untyped join build, and `physical_layout_class` is a ~20-compare
# ladder. Calling it per row would put that ladder inside the row loop for a
# property that cannot change within a column, so each view caches the answer
# at construction. The ctor resolves it DEFENSIVELY — an out-of-range index
# stores False rather than indexing `_columns`, so a view built over a bad
# index still fails where it always did (in the method that reads it) and not
# newly at construction.


@always_inline
def _offset_is_i64(at: ArrowType) -> Bool:
    """Does a column of this type carry an INT64 (8-byte) offsets buffer?

    Args:
        at: The column's own Arrow type tag.

    Returns:
        True for the wide varlen layouts (`large_string` / `large_binary`).
    """
    return at.physical_layout_class() == ARROW_LAYOUT_OFFSETS_I64


# =============================================================================
# StringView[origin] -- borrowed view of a single STRING / BINARY cell
# =============================================================================


struct StringView[origin: Origin[mut=False]](
    Copyable, Movable, ImplicitlyCopyable
):
    """Borrowed view over a single STRING / BINARY cell within a
    `StringColumnView` / `BinaryColumnView`.

    Carries `(parent batch pointer, col_idx, byte_offset, byte_length)` --
    no copy. The underlying bytes are tied to `origin`; the `StringView`
    cannot outlive that origin.

    Used for both STRING and BINARY semantics; the distinction is held at
    the parent view (`StringColumnView` vs `BinaryColumnView`) -- this
    type is the storage shape (offset+length pair).
    """

    var _batch: Pointer[RecordBatch, Self.origin]
    var _col_idx: Int
    var _byte_offset: Int
    var _byte_length: Int

    @always_inline
    def __init__(
        out self,
        ptr: Pointer[RecordBatch, Self.origin],
        col_idx: Int,
        byte_offset: Int,
        byte_length: Int,
    ):
        """Construct a `StringView`. Caller passes `(batch, col_idx,
        offset, length)`; the view holds them as-is.

        Normally constructed by `StringColumnView.get(row)` /
        `BinaryColumnView.get(row)`; not instantiated directly.
        """
        self._batch = ptr
        self._col_idx = col_idx
        self._byte_offset = byte_offset
        self._byte_length = byte_length

    @always_inline
    def length(self) -> Int:
        """Byte length of this cell."""
        return self._byte_length

    @always_inline
    def byte_offset(self) -> Int:
        """Starting byte offset in the parent column's data buffer."""
        return self._byte_offset

    @always_inline
    def byte_at(self, i: Int) raises -> UInt8:
        """Read byte at position `i` within this cell.

        Production hot paths use SIMD bulk byte access or libc memcmp via
        the parent column's data buffer; this accessor is for scalar /
        diagnostic use.

        Raises:
            On `i < 0` or `i >= length()`.
        """
        if i < 0 or i >= self._byte_length:
            raise Error(
                "StringView.byte_at: index out of range [0, "
                + String(self._byte_length)
                + ")"
            )
        ref col = self._batch[].column_at(self._col_idx)
        return col._data.read_u8_at(self._byte_offset + i)

    @always_inline
    def bytes_view(self) -> ByteView[Self.origin]:
        """Borrow THIS CELL's bytes as a batch-origin `ByteView`.

        The primitive for string group-key hot loops.
        `byte_at(i)` re-derives the whole
        `batch -> columns slab -> Column -> _data buffer` chain on EVERY BYTE,
        plus a bounds check and a raise edge. A key-hash / key-compare loop
        therefore pays that chain `len(key)` times per row. This resolves it
        ONCE and hands back a plain `(ptr, len)` window, so the loop body
        becomes a single load — and, because a `ByteView` can be read 8 bytes
        at a time (`read_u64_le_at`), a comparison over it is a word loop
        rather than a byte loop.

        The returned view spans EXACTLY this cell: `[_byte_offset,
        _byte_offset + _byte_length)` of the parent column's values buffer,
        the same window `byte_at` addresses. Reading byte `i` of it is
        therefore byte-identical to `byte_at(i)` for every `i` in range.

        ⚠ It does NOT bounds-check on read the way `byte_at` does —
        `ByteView.read_u8_at` is `debug_assert`-only and inert at
        `ASSERT=none`. Callers iterate `0 .. len()` and must not index past it.

        SAFETY: module-private `_unsafe_ptr` escape, permitted for files under
        `komira_core/collections/`; this is the same
        seam `BatchView.col_string_dict_bytes_view` uses. The cast widens the
        column slab's sub-origin to the enclosing BATCH origin — both are
        ASAP-tracked real origins, neither is a wildcard — and the batch owns
        the column slab, so the widened origin is bounded by the narrower one.
        """
        ref col = self._batch[].column_at(self._col_idx)
        var v = col.values_view_native()
        return ByteView[Self.origin](
            v._unsafe_ptr().unsafe_origin_cast[Self.origin](), v.len()
        ).sub(self._byte_offset, self._byte_length)

    def to_string(self) raises -> String:
        """Materialize the bytes as a Mojo `String` (copies).

        Useful for testing + diagnostics; production hot paths use
        `byte_at()` + libc memcmp directly. Treats the bytes as UTF-8.
        For BINARY cells, callers may use this for debug logging only.
        """
        ref col = self._batch[].column_at(self._col_idx)
        var buf = List[UInt8]()
        for i in range(self._byte_length):
            buf.append(col._data.read_u8_at(self._byte_offset + i))
        return String(StringSlice(unsafe_from_utf8=Span(buf)))


# =============================================================================
# StringColumnView[origin] -- typed borrow over a STRING column
# =============================================================================


struct StringColumnView[origin: Origin[mut=False]](
    Copyable, Movable, ImplicitlyCopyable
):
    """Typed borrow-view over a variable-length STRING column.

    Exposes offset+length arithmetic that `ColView[DType.uint8, origin]`
    does NOT.

    Internal storage mirrors `BatchView` / `ColView`: hold a parent
    `Pointer[RecordBatch, origin]` + column index; re-derive the `Column`
    ref per call. The `origin` keeps the wrapped batch's bytes alive.

    Parameters:
        origin: `Origin[mut=False]` under which the borrowed parent
            `RecordBatch` lives. The compiler tracks the lifetime;
            encapsulation is preserved.
    """

    var _batch: Pointer[RecordBatch, Self.origin]
    var _idx: Int
    var _wide_offsets: Bool
    """Does the borrowed column carry INT64 offsets? Resolved once, here,
    because `get` / `offset_at` are the per-ROW surface."""

    @always_inline
    def __init__(
        out self,
        ptr: Pointer[RecordBatch, Self.origin],
        idx: Int,
    ):
        """Borrow STRING column `idx` from the RecordBatch under
        `Self.origin`.

        Constructed by `BatchView.col_str(idx)`; not normally
        instantiated by callers directly.
        """
        self._batch = ptr
        self._idx = idx
        self._wide_offsets = False
        if idx >= 0 and idx < ptr[].num_columns():
            self._wide_offsets = _offset_is_i64(ptr[].column_at(idx).arrow_type)

    @always_inline
    def length(self) -> Int:
        """Logical row count of this column."""
        ref col = self._batch[].column_at(self._idx)
        return col._length

    @always_inline
    def get(self, row: Int) raises -> StringView[Self.origin]:
        """Get a borrowed view over the string at logical row `row`.

        Offset arithmetic: the offsets buffer holds `n_rows + 1` cumulative
        byte offsets and the cell at row spans
        `data[offsets[row] .. offsets[row + 1]]`. The ENTRY WIDTH follows the
        column's own type -- Int32 for `string` / `binary`, Int64 for
        `large_string` / `large_binary` -- resolved once into
        `_wide_offsets` at construction.

        Raises:
            On `not _offsets` (column is not varlen STRING) OR on
            `row < 0` or `row >= length()`.
        """
        ref col = self._batch[].column_at(self._idx)
        if not col._offsets:
            raise Error(
                "StringColumnView.get: column has no offsets buffer"
                + " (not a varlen STRING column)"
            )
        if row < 0 or row >= col._length:
            raise Error(
                "StringColumnView.get: row index out of range [0, "
                + String(col._length)
                + ")"
            )
        ref offsets = col._offsets.value()
        # Honor the column's logical offset (zero-copy slicing).
        var base = col._offset
        var start: Int
        var end: Int
        if self._wide_offsets:
            start = Int(offsets.read_i64_le_at((base + row) * 8))
            end = Int(offsets.read_i64_le_at((base + row + 1) * 8))
        else:
            start = Int(offsets.read_i32_le_at((base + row) * 4))
            end = Int(offsets.read_i32_le_at((base + row + 1) * 4))
        return StringView[Self.origin](
            self._batch, self._idx, start, end - start
        )

    @always_inline
    def offset_at(self, row: Int) raises -> Int:
        """Read the offset for logical row `row` (start byte in data
        buffer).

        SIMD-bulk offset arithmetic primitive: callers can load a SIMD
        chunk of N offsets at a time via this primitive.

        Raises:
            On `not _offsets` or `row` out of range `[0, length()]`.
            Note that `row == length()` is valid (returns the
            sentinel-end offset = total data bytes).
        """
        ref col = self._batch[].column_at(self._idx)
        if not col._offsets:
            raise Error(
                "StringColumnView.offset_at: column has no offsets buffer"
            )
        if row < 0 or row > col._length:
            raise Error(
                "StringColumnView.offset_at: row index out of range [0, "
                + String(col._length)
                + "]"
            )
        ref offsets = col._offsets.value()
        var base = col._offset
        if self._wide_offsets:
            return Int(offsets.read_i64_le_at((base + row) * 8))
        return Int(offsets.read_i32_le_at((base + row) * 4))

    @always_inline
    def n_data_bytes(self) raises -> Int:
        """Total data-buffer byte length (= `offset_at(length())`)."""
        return self.offset_at(self.length())


# =============================================================================
# BinaryColumnView[origin] -- typed borrow over a BINARY column
# =============================================================================


struct BinaryColumnView[origin: Origin[mut=False]](
    Copyable, Movable, ImplicitlyCopyable
):
    """Typed borrow-view over a variable-length BINARY column.

    Identical shape to `StringColumnView`; bytes are NOT validated as
    UTF-8. The two views share the same internal storage; the distinction
    is semantic (UTF-8 vs arbitrary bytes).

    Parameters:
        origin: `Origin[mut=False]` under which the borrowed parent
            `RecordBatch` lives.
    """

    var _batch: Pointer[RecordBatch, Self.origin]
    var _idx: Int
    var _wide_offsets: Bool
    """Does the borrowed column carry INT64 offsets? Resolved once, here,
    because `get` / `offset_at` are the per-ROW surface."""

    @always_inline
    def __init__(
        out self,
        ptr: Pointer[RecordBatch, Self.origin],
        idx: Int,
    ):
        """Borrow BINARY column `idx` from the RecordBatch under
        `Self.origin`.
        """
        self._batch = ptr
        self._idx = idx
        self._wide_offsets = False
        if idx >= 0 and idx < ptr[].num_columns():
            self._wide_offsets = _offset_is_i64(ptr[].column_at(idx).arrow_type)

    @always_inline
    def length(self) -> Int:
        """Logical row count of this column."""
        ref col = self._batch[].column_at(self._idx)
        return col._length

    @always_inline
    def get(self, row: Int) raises -> StringView[Self.origin]:
        """Get a borrowed view over the binary blob at row.

        Returns `StringView` for storage symmetry (the type is the same
        offset+length pair; the caller knows it's BINARY not UTF-8 by
        context).

        Raises:
            On `not _offsets` or `row` out of range.
        """
        ref col = self._batch[].column_at(self._idx)
        if not col._offsets:
            raise Error(
                "BinaryColumnView.get: column has no offsets buffer"
                + " (not a varlen BINARY column)"
            )
        if row < 0 or row >= col._length:
            raise Error(
                "BinaryColumnView.get: row index out of range [0, "
                + String(col._length)
                + ")"
            )
        ref offsets = col._offsets.value()
        var base = col._offset
        var start: Int
        var end: Int
        if self._wide_offsets:
            start = Int(offsets.read_i64_le_at((base + row) * 8))
            end = Int(offsets.read_i64_le_at((base + row + 1) * 8))
        else:
            start = Int(offsets.read_i32_le_at((base + row) * 4))
            end = Int(offsets.read_i32_le_at((base + row + 1) * 4))
        return StringView[Self.origin](
            self._batch, self._idx, start, end - start
        )

    @always_inline
    def offset_at(self, row: Int) raises -> Int:
        """Read the offset for logical row `row` (mirror of
        `StringColumnView.offset_at`)."""
        ref col = self._batch[].column_at(self._idx)
        if not col._offsets:
            raise Error(
                "BinaryColumnView.offset_at: column has no offsets buffer"
            )
        if row < 0 or row > col._length:
            raise Error(
                "BinaryColumnView.offset_at: row index out of range [0, "
                + String(col._length)
                + "]"
            )
        ref offsets = col._offsets.value()
        var base = col._offset
        if self._wide_offsets:
            return Int(offsets.read_i64_le_at((base + row) * 8))
        return Int(offsets.read_i32_le_at((base + row) * 4))

    @always_inline
    def n_data_bytes(self) raises -> Int:
        """Total data-buffer byte length."""
        return self.offset_at(self.length())
