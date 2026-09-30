# =============================================================================
# column_builder.mojo — per-DType ColumnBuilder for single-materialize discipline
# =============================================================================
#
# Single-materialize discipline at stage-exit granularity:
# `Stage.process_batch` accumulates results into per-DType ColumnBuilders,
# then emits ONE RecordBatch via `RecordBatch(builders^.materialize())` at
# stage exit. Breaker stages accumulate into builders inside `finalize()`.
#
# Design:
#   - One parametric struct `ColumnBuilder[dtype: DType]` covering the
#     primitive numeric types (Int64 / Float64 / Int32 / Float32 + Date32
#     via Int32 alias).
#   - Two construction modes: empty `with_capacity(n)` for computed
#     projects, `from_existing_array(arr)` for passthrough projects
#     (`col(x)` Expr).
#   - Per-row append + SIMD-chunk append + indexed-append-at — covers
#     filter+project two-pass survivor shape and breaker-feed
#     sequential writes.
#   - `materialize()` consumes self and produces a Column wrapping the
#     accumulated data.
#
# Storage: internal `List[Scalar[Self.dtype]]` for the values + an
# `Optional[List[Bool]]` for per-row validity. Lists grow geometrically,
# so the builder needs no manual grow. `materialize()` memcpys the List
# into an MmapAlignedBuffer for emit; `from_existing_array` reads the
# existing PrimitiveArray's values into the List (copy-once; the
# materialize semantics are byte-correct).
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any public method signature.
#   - NO wildcard origins.
#   - List[Scalar[T]] for the value backing; List[Bool] for the validity
#     backing (lazy-allocated on first null).
#
# Per-DType arity:
#   - Int64 / Float64 / Int32 / Float32: this parametric struct covers
#     all four directly.
#   - Date32: clients construct `ColumnBuilder[DType.int32]` and at
#     materialize-time use `Column.from_primitive_with_arrow_type` with
#     `ArrowType.DATE32`. Not specialized here.
#   - Bool: IS in this file. Bool and String are NOT the same edge, and
#     only ONE of them needs a separate primitive.
#
#     `List[Scalar[DType.bool]]` accumulates fine — a `Scalar[DType.bool]`
#     is an ordinary 1-byte value and every append/append_simd/append_at
#     path already works on it. What needs care is the FINALIZE:
#     routing every dtype through `Column.from_primitive`,
#     which memcpys `length * size_of[Scalar[dt]]()` bytes and stamps
#     `ArrowType.BOOL` — while Arrow BOOLEAN is 1-BIT-PACKED and every
#     consumer reads it that way (`Column.as_boolean` copies
#     `(length + 7) >> 3` bytes and calls `Bitmap.test(i)`). So a BOOL
#     column built that way would CLAIM to be BOOL, have the right row
#     count, and return wrong VALUES from row 1 on. Reachable from the customer
#     surface: `Map1[..., DType.bool, ...]` -> `EvaluatorAdapterFor_Map`
#     -> `ColumnSlot[DType.bool]` -> here.
#
#     The handling is the `comptime if Self.dtype == DType.bool` arm in
#     `materialize()` below — the ONE place the layouts differ. The
#     build-time storage stays byte-per-value ON PURPOSE: a bit-packed
#     accumulator would make `append_at(idx, v)` a read-modify-write and
#     `append_simd[W]` a shift-merge, for a transient buffer that is
#     packed once at finalize anyway.
#
#   - String: DOES need a separate primitive, and it is
#     `StringColumnSlot` (`multi_column_builder.mojo`) over the existing
#     `ArrowStringBuilder`. `Scalar[DType]` cannot hold a String at all,
#     so no amount of finalize-side work reaches it — the value type
#     itself is wrong. That refusal is a COMPILE error, so the String
#     edge cannot produce a wrong answer.
#
# =============================================================================

from std.collections import Optional

from std.sys import size_of

from ..arrow.owned_aligned_buffer import OwnedAlignedBuffer
from ..io.heap_region import HeapRegion
from ..arrow.bitmap import Bitmap
from ..arrow.boolean_array import BooleanArray
from ..arrow.column import Column
from ..arrow.primitive_array import PrimitiveArray


struct ColumnBuilder[dtype: DType](Movable):
    """Per-DType append-only column builder honoring the
    single-materialize discipline.

    State:
        _values: List[Scalar[Self.dtype]] — accumulated typed values.
        _validity_bits: Optional[List[Bool]] — lazy-allocated on first
            `append_null`; None when no nulls have been appended.
        _null_count: Int — running null count.

    Usage shapes:
        # Computed projection (two-pass filter+project):
        var b = ColumnBuilder[DType.int64].with_capacity(survivors.len())
        for k in range(survivors.len()):
            var phys = survivors[k]
            var v = compute_projected_value(batch, phys)
            b.append(v)
        var col = b^.materialize()

        # Passthrough (col(x)) projection:
        var b = ColumnBuilder[DType.int64].from_existing_array(batch_col^)
        var col = b^.materialize()

    Parameters:
        dtype: The Arrow primitive DType this builder emits.
    """

    var _values: List[Scalar[Self.dtype]]
    var _validity_bits: Optional[List[Bool]]
    var _null_count: Int

    # --- Constructors ---

    @staticmethod
    def with_capacity(capacity: Int) -> ColumnBuilder[Self.dtype]:
        """Allocate an empty builder with `capacity` rows of headroom.

        The builder's lifetime is bounded by the
        Stage.process_batch (or .finalize) scope. Caller materializes
        before scope exit.

        Cap is a hint; the underlying List grows geometrically on
        demand so over- or under-sizing is non-fatal.
        """
        var vals = List[Scalar[Self.dtype]]()
        if capacity > 0:
            vals.reserve(capacity)
        return ColumnBuilder[Self.dtype](vals^, Optional[List[Bool]](None), 0)

    @staticmethod
    def from_existing_array(
        var arr: PrimitiveArray[Self.dtype],
    ) raises -> ColumnBuilder[Self.dtype]:
        """Construct from an existing PrimitiveArray — passthrough-projection
        fast path.

        Copies the source array's values into the builder's List.
        The List intermediate costs one copy.
        """
        var length = arr.length
        var vals = List[Scalar[Self.dtype]]()
        if length > 0:
            vals.reserve(length)
        for i in range(length):
            vals.append(arr.get(i))

        var null_count = arr.null_count
        var validity: Optional[List[Bool]] = None
        if arr.validity:
            var bits = List[Bool]()
            bits.reserve(length)
            ref bm = arr.validity.value()
            for i in range(length):
                # Read bit at logical row i. The Bitmap exposes
                # bit-level access via the buffer (the same pattern
                # `PrimitiveArray` uses).
                var abs_idx = arr.offset + i
                var byte = bm.buffer.read_u8_at(abs_idx >> 3)
                var bit = (byte >> UInt8(abs_idx & 7)) & UInt8(1)
                bits.append(bit == UInt8(1))
            validity = bits^

        return ColumnBuilder[Self.dtype](vals^, validity^, null_count)

    def __init__(
        out self,
        var values: List[Scalar[Self.dtype]],
        var validity_bits: Optional[List[Bool]],
        null_count: Int,
    ):
        """Internal full constructor. Prefer `with_capacity` /
        `from_existing_array`."""
        self._values = values^
        self._validity_bits = validity_bits^
        self._null_count = null_count

    # --- Length accessors ---

    @always_inline
    def length(self) -> Int:
        """Current logical row count."""
        return len(self._values)

    @always_inline
    def capacity(self) -> Int:
        """Current allocated element capacity (best-effort; List
        capacity is implementation-defined)."""
        return self._values.capacity()

    @always_inline
    def has_nulls(self) -> Bool:
        """True iff at least one null has been appended (validity
        list allocated)."""
        return Bool(self._validity_bits)

    @always_inline
    def null_count(self) -> Int:
        """Number of nulls appended so far."""
        return self._null_count

    # --- Append API ---

    def _backfill_validity_to_length(mut self):
        """Lazy-allocate the validity List and back-fill existing
        slots as VALID (True). Called from the first `append_null` so
        prior `append`s automatically become VALID slots.
        """
        if self._validity_bits:
            return
        var bits = List[Bool]()
        var n = len(self._values)
        bits.reserve(n if n > 0 else 1)
        for _ in range(n):
            bits.append(True)
        self._validity_bits = bits^

    @always_inline
    def append(mut self, value: Scalar[Self.dtype]):
        """Append one value at the current logical end. Always VALID."""
        self._values.append(value)
        if self._validity_bits:
            self._validity_bits.value().append(True)

    def append_null(mut self):
        """Append one null slot.

        Lazy-allocates the validity bitmap on first call. The new
        value slot is set to a deterministic 0 (Arrow null-slot bytes
        are unspecified, but deterministic zero is friendlier).
        """
        self._backfill_validity_to_length()
        self._values.append(Scalar[Self.dtype](0))
        self._validity_bits.value().append(False)
        self._null_count += 1

    @always_inline
    def append_simd[W: Int](mut self, values: SIMD[Self.dtype, W]):
        """Append W contiguous values via SIMD.

        Each lane lands at the next logical row. If validity is
        already allocated, all W new slots are marked VALID.
        """
        comptime for k in range(W):
            self._values.append(values[k])
            if self._validity_bits:
                self._validity_bits.value().append(True)

    def append_at(mut self, idx: Int, value: Scalar[Self.dtype]):
        """Indexed append at a specific logical row position (NOT
        sequential).

        Used by the two-pass survivor shape: pass 1 builds a
        survivor index list; pass 2 walks the survivor list, gathers
        from input columns, and writes to specific output rows.

        If `idx + 1 > length()`, extends the List with default values
        + (if validity allocated) marks the intermediate slots as
        VALID. Caller is responsible for ordering (typically
        sequential 0, 1, 2, ...).
        """
        # Grow values to idx+1 if needed.
        while len(self._values) <= idx:
            self._values.append(Scalar[Self.dtype](0))
            if self._validity_bits:
                self._validity_bits.value().append(True)
        self._values[idx] = value
        if self._validity_bits:
            self._validity_bits.value()[idx] = True

    # --- Materialize ---

    def materialize(var self) raises -> Column[HeapRegion]:
        """Consume self; emit a Column[HeapRegion] owning the accumulated data.

        Honors the single-materialize invariant. The
        internal List is consumed; the produced Column owns a fresh
        MmapAlignedBuffer with byte-identical content.

        Output ArrowType is derived from `dtype` via
        `ArrowType.from_dtype(dtype)`. Callers that need a semantic
        wrapper (Date32 over Int32 storage, Decimal128 (p,s), etc.)
        can wrap or override the arrow_type field via
        `Column.from_primitive_with_arrow_type`.

        ⚠ BOOL TAKES A DIFFERENT ARM, AND MUST. Arrow BOOLEAN is
        1-bit-packed; `PrimitiveArray[DType.bool]` is 1 BYTE per value.
        Emitting the byte buffer under `ArrowType.BOOL` would produce a column
        with the correct row COUNT and wrong VALUES from row 1 on (see the
        module header). The `comptime if` below is the only place the two
        layouts diverge, so it is the only place that handling belongs.
        """
        var length = len(self._values)

        comptime if Self.dtype == DType.bool:
            return self^._materialize_boolean()
        comptime elem_size = size_of[Scalar[Self.dtype]]()
        var buf = OwnedAlignedBuffer(max(length, 1) * elem_size)
        for i in range(length):
            buf.set_typed[Scalar[Self.dtype]](i, self._values[i])
        buf.set_length(Int64(length * elem_size))


        var validity = Optional[Bitmap[HeapRegion]](None)
        if self._validity_bits:
            ref bits = self._validity_bits.value()
            var bm = Bitmap.create(length)
            for i in range(length):
                if bits[i]:
                    bm.set(i)
                else:
                    bm.clear(i)
            validity = bm^

        var arr = PrimitiveArray[Self.dtype](
            buf^,
            length,
            validity^,
            self._null_count,
            0,
        )
        return Column.from_primitive[Self.dtype](arr^)

    def _materialize_boolean(var self) raises -> Column[HeapRegion]:
        """The `DType.bool` finalize: pack the byte-per-value accumulator
        into Arrow's 1-bit-per-value BOOLEAN layout.

        Only ever reached from `materialize()`'s `comptime if
        Self.dtype == DType.bool` arm, so the `rebind` below is an
        identity cast the type checker cannot see through on its own
        (`Self.dtype` is still a parameter inside the method body).

        Validity is a SEPARATE bitmap from the data bitmap — a null slot
        and a `False` value are different rows and Arrow distinguishes
        them exactly here. `append_null` writes `Scalar[dtype](0)` into
        the value slot, so a null row's data bit is deterministically 0.
        """
        var length = len(self._values)
        var arr = BooleanArray.allocate(length)
        for i in range(length):
            if rebind[Scalar[DType.bool]](self._values[i]):
                arr.set(i, True)

        if self._validity_bits:
            ref bits = self._validity_bits.value()
            var bm = Bitmap.create(length)
            for i in range(length):
                if bits[i]:
                    bm.set(i)
                else:
                    bm.clear(i)
            arr.validity = Optional[Bitmap[HeapRegion]](bm^)
            arr.null_count = self._null_count

        return Column.from_boolean(arr^)
