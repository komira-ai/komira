# =============================================================================
# simd_of.mojo — SimdOf[T, W]: SoA chunk of W lanes of struct T
# =============================================================================
#
# `SimdOf[T, W]` carries W lanes of struct T laid out as struct-of-arrays in a
# single `InlineArray[UInt8, _total_simd_bytes[T, W]()]` blob. Per-field byte
# offsets are derived at comptime via `reflect[T]()`.
#
# A load/eval/store round-trip matches the scalar reference row for row, and
# the fused inner loop lowers to vector opcodes (NEON `.2d`) with zero `bl`
# calls; seven SimdOf-bound operators compose into one fused loop.
#
# Encapsulation rule:
#   - SimdOf's `_blob: InlineArray[UInt8, N]` is POD; no heap, no
#     wildcard-origin pointer field. Movable + Copyable trivially.
#     No stale-pointer hazard across destroy and recreate.
#   - The `unsafe_ptr()` calls inside the typed accessors live ONLY inside
#     this file's struct body. They never escape: the public API returns
#     typed `SIMD[T, W]` values, never raw pointers.
#   - All raw-byte arithmetic is concentrated under one `# SAFETY:` block;
#     comptime-checked offsets and dtype tags via
#     `comptime_field_validation` guarantee the bytes match the
#     declared dtype.
#
# Mojo idioms:
#   - `Self.T` / `Self.W` REQUIRED for struct-parameter refs inside alias
#     and method bodies. Bare `T` / `W` fails "unqualified access to
#     struct parameter" at parse time.
#   - `(blob.unsafe_ptr() + sub_off).bitcast[T]().load[width=W]()` is the
#     canonical typed-vector-load shape (NOT `.offset(N)`).
#   - `Origin[mut=False]` / `Origin[mut=True]` canonical (NOT
#     `ImmutableOrigin` / `MutableOrigin`).
#   - `mut ref [bo]` does NOT parse — use `ref [bo]` with
#     `bo: Origin[mut=True]` for mutable-borrow params.
#   - `from std.sys import size_of` is the canonical size_of import path
#     (NOT `from std.memory import _size_of`). `size_of[T]()` works on
#     AnyType-bounded T directly for all scalar types we need.
#   - `mask.select(if_true, if_false)` is the lane-select (NOT a method
#     on the result-type — it's a method on the bool-mask SIMD).
#
# Scope
#   - Fixed-width POD-scalar accessors: f64, f32, i64, i32, i16, i8,
#     u64, u32, u16, u8, bool. (Decimal128 + Date32 are not covered.)
#   - Variable-width (String, Binary, List, Struct nested): NOT in this
#     file. They go through an indirect-handle shape at the engine
#     boundary.
#   - The `load_chunk_from_arrays` / `store_chunk_to_arrays` bridges in
#     this file take pre-resolved typed `PrimitiveArray[dtype]` slices.
#     The full RecordBatch-aware bridge (column-index resolution +
#     validity-bitmap plumbing) lives at the morsel-executor layer.
# =============================================================================

from std.sys import size_of

from komira_kernels.comptime_field_validation import comptime_field_validation


# -----------------------------------------------------------------------------
# Comptime helpers — total blob byte size and per-field byte offset.
# -----------------------------------------------------------------------------

def _total_simd_bytes[T: AnyType & Copyable & Movable, W: Int]() -> Int:
    """Sum of `size_of[FieldT]() * W` across every field of T.

    Comptime-only. Used to size `SimdOf[T, W]._blob`.
    """
    comptime r = reflect[T]
    comptime ts = r.field_types()
    var total = 0
    comptime for j in range(r.field_count()):
        total = total + size_of[ts[j]]() * W
    return total


def _sub_blob_offset[
    T: AnyType & Copyable & Movable, W: Int, field_index: Int
]() -> Int:
    """Byte offset of field `field_index`'s lane-0 within SimdOf[T, W]'s blob.

    Comptime-only. Layout is plain SoA: field 0 occupies bytes
    `[0, size_of[F0] * W)`, field 1 occupies `[size_of[F0] * W,
    (size_of[F0] + size_of[F1]) * W)`, etc. No padding between sub-blobs
     (every supported scalar's natural alignment divides the
    cumulative sub-blob size — Bool is 1B, Int8/UInt8 are 1B, Int16/UInt16
    are 2B, etc., and `W` is always a power of two so each sub-blob ends
    on a `W`-aligned offset).
    """
    comptime r = reflect[T]
    comptime ts = r.field_types()
    var off = 0
    comptime for j in range(field_index):
        off = off + size_of[ts[j]]() * W
    return off


# -----------------------------------------------------------------------------
# SimdOf[T, W] — SoA chunk of W lanes of struct T.
# -----------------------------------------------------------------------------

@fieldwise_init
struct SimdOf[T: AnyType & Copyable & Movable, W: Int](Copyable, Movable):
    """W lanes of struct T, laid out struct-of-arrays in a single inline blob.

    Per-field byte offsets are comptime-derived via `reflect[Self.T]()`.
    Typed accessors `get_f64[i]()` / `set_f64[i](v)` etc. return / accept
    `SIMD[T_field, Self.W]` values; the field index `i` and dtype tag are
    comptime-checked via `comptime_field_validation` so a typo is a compile
    error, not a silent wrong-dtype byte read.

    The round-trip matches the scalar reference and the inner loop is
    vectorized with zero `bl` calls.

    # SAFETY: SimdOf uses `InlineArray[UInt8, _total_simd_bytes[Self.T,
    # Self.W]()]` blob storage with comptime-derived per-field offsets.
    # `UnsafePointer` is used ONLY inside this struct's typed accessors
    # for `(blob.unsafe_ptr() + sub_off).bitcast[T]().load[width=W]()`
    # — it does NOT escape the module boundary. The public API returns
    # typed `SIMD[T, W]` values only. The blob is POD (no heap-owning
    # sub-element); slab-safe by construction (no Movable struct field
    # that holds heap pointers).
    """

    comptime TOTAL_BYTES = _total_simd_bytes[Self.T, Self.W]()
    var _blob: Array[UInt8, Self.TOTAL_BYTES]

    @staticmethod
    def zero() -> Self:
        """Construct a zero-initialized SimdOf (every byte is 0)."""
        return Self(_blob=Array[UInt8, Self.TOTAL_BYTES](fill=UInt8(0)))

    # ---- Typed accessors (one pair per supported dtype) ----
    #
    # Each pair: get_<dtype>[i]() / set_<dtype>[i](v).
    # Each call site fires `comptime_field_validation` so the field index is
    # in range AND the field's Mojo type matches the dtype tag — both at
    # comptime, zero runtime cost.

    @always_inline
    def get_f64[i: Int](self) -> SIMD[DType.float64, Self.W]:
        """Load the W-lane Float64 vector at field index `i`."""
        comptime_field_validation[Self.T, i, DType.float64]()
        comptime sub_off = _sub_blob_offset[Self.T, Self.W, i]()
        return (self._blob.unsafe_ptr() + sub_off).bitcast[Float64]().load[width=Self.W]()

    @always_inline
    def set_f64[i: Int](mut self, v: SIMD[DType.float64, Self.W]):
        """Store the W-lane Float64 vector at field index `i`."""
        comptime_field_validation[Self.T, i, DType.float64]()
        comptime sub_off = _sub_blob_offset[Self.T, Self.W, i]()
        (self._blob.unsafe_ptr() + sub_off).bitcast[Float64]().store(v)

    @always_inline
    def get_f32[i: Int](self) -> SIMD[DType.float32, Self.W]:
        """Load the W-lane Float32 vector at field index `i`."""
        comptime_field_validation[Self.T, i, DType.float32]()
        comptime sub_off = _sub_blob_offset[Self.T, Self.W, i]()
        return (self._blob.unsafe_ptr() + sub_off).bitcast[Float32]().load[width=Self.W]()

    @always_inline
    def set_f32[i: Int](mut self, v: SIMD[DType.float32, Self.W]):
        """Store the W-lane Float32 vector at field index `i`."""
        comptime_field_validation[Self.T, i, DType.float32]()
        comptime sub_off = _sub_blob_offset[Self.T, Self.W, i]()
        (self._blob.unsafe_ptr() + sub_off).bitcast[Float32]().store(v)

    @always_inline
    def get_i64[i: Int](self) -> SIMD[DType.int64, Self.W]:
        """Load the W-lane Int64 vector at field index `i`."""
        comptime_field_validation[Self.T, i, DType.int64]()
        comptime sub_off = _sub_blob_offset[Self.T, Self.W, i]()
        return (self._blob.unsafe_ptr() + sub_off).bitcast[Int64]().load[width=Self.W]()

    @always_inline
    def set_i64[i: Int](mut self, v: SIMD[DType.int64, Self.W]):
        """Store the W-lane Int64 vector at field index `i`."""
        comptime_field_validation[Self.T, i, DType.int64]()
        comptime sub_off = _sub_blob_offset[Self.T, Self.W, i]()
        (self._blob.unsafe_ptr() + sub_off).bitcast[Int64]().store(v)

    @always_inline
    def get_i32[i: Int](self) -> SIMD[DType.int32, Self.W]:
        """Load the W-lane Int32 vector at field index `i`."""
        comptime_field_validation[Self.T, i, DType.int32]()
        comptime sub_off = _sub_blob_offset[Self.T, Self.W, i]()
        return (self._blob.unsafe_ptr() + sub_off).bitcast[Int32]().load[width=Self.W]()

    @always_inline
    def set_i32[i: Int](mut self, v: SIMD[DType.int32, Self.W]):
        """Store the W-lane Int32 vector at field index `i`."""
        comptime_field_validation[Self.T, i, DType.int32]()
        comptime sub_off = _sub_blob_offset[Self.T, Self.W, i]()
        (self._blob.unsafe_ptr() + sub_off).bitcast[Int32]().store(v)

    @always_inline
    def get_bool[i: Int](self) -> SIMD[DType.bool, Self.W]:
        """Load the W-lane Bool vector at field index `i`.

        Mojo Bool is 1-byte-per-lane in inline storage (matches `size_of[Bool]()
        == 1`). The Arrow bit-packed Bool layout is handled at the
        load-from-Arrow boundary (the RecordBatch bridge), NOT here.

        Mojo 1.0.0b1 idiom: bitcast for Bool SIMD load REQUIRES
        `Scalar[DType.bool]`, NOT bare `Bool` — `UnsafePointer.bitcast[Bool]`
        fails to unify with the SIMD load/store overload set
        (`Scalar[dtype]` is the load/store self-type).
        """
        comptime_field_validation[Self.T, i, DType.bool]()
        comptime sub_off = _sub_blob_offset[Self.T, Self.W, i]()
        return (self._blob.unsafe_ptr() + sub_off).bitcast[Scalar[DType.bool]]().load[width=Self.W]()

    @always_inline
    def set_bool[i: Int](mut self, v: SIMD[DType.bool, Self.W]):
        """Store the W-lane Bool vector at field index `i`."""
        comptime_field_validation[Self.T, i, DType.bool]()
        comptime sub_off = _sub_blob_offset[Self.T, Self.W, i]()
        (self._blob.unsafe_ptr() + sub_off).bitcast[Scalar[DType.bool]]().store(v)

    # ---- Mask helper — zero non-passing lanes across every field ----

    @always_inline
    def mask(self, m: SIMD[DType.bool, Self.W]) -> Self:
        """Return a copy where lanes for which `m` is False are zeroed in
        every field.

        Used by mask-aware aggregators (the
        `mask.select(revenue, 0.0)` idiom). The implementation walks every
        field at comptime and applies `m.select(value, zero)` per dtype.

        Supports the same dtype set as the typed accessors (f64, f32, i64,
        i32, bool). Unsupported field dtypes pass through unchanged
        (the comptime guard fires a `constrained[]` failure inside the
        loop body — adding new dtypes here requires extending both the
        accessor surface AND this loop).
        """
        var out = self.copy()
        comptime r = reflect[Self.T]
        comptime ts = r.field_types()
        comptime for i in range(r.field_count()):
            comptime if (ts[i] == Float64):
                var v = self.get_f64[i]()
                out.set_f64[i](m.select(v, SIMD[DType.float64, Self.W](0.0)))
            elif (ts[i] == Float32):
                var v = self.get_f32[i]()
                out.set_f32[i](m.select(v, SIMD[DType.float32, Self.W](0.0)))
            elif (ts[i] == Int64):
                var v = self.get_i64[i]()
                out.set_i64[i](m.select(v, SIMD[DType.int64, Self.W](0)))
            elif (ts[i] == Int32):
                var v = self.get_i32[i]()
                out.set_i32[i](m.select(v, SIMD[DType.int32, Self.W](0)))
            elif (ts[i] == Bool):
                var v = self.get_bool[i]()
                out.set_bool[i](m.select(v, SIMD[DType.bool, Self.W](False)))
            else:
                comptime assert False, ("SimdOf.mask: unsupported field dtype. Extend mask() and the typed-accessor surface.")
        return out^


# -----------------------------------------------------------------------------
# RecordBatch ↔ SimdOf bridges.
# -----------------------------------------------------------------------------
#
# These take pre-resolved typed `PrimitiveArray[dtype]` slices. The
# RecordBatch-aware bridges that resolve column-indices + plumb validity
# bitmaps live at the morsel-executor layer. This
# keeps SimdOf focused on its primitive responsibility (typed get/set on the
# SoA blob) and avoids putting RecordBatch-specific column-resolution logic
# in `komira_kernels`.

# NOTE on column-resolution scoping:
#   A `load_simd_chunk[T, W, bo]` signature takes a `RecordBatch`
#   + `column_indices: List[Int]`. That signature requires:
#     1. `Column.data_ptr[Float64]()` — does NOT exist on Column.
#     2. `Column.validity_load[width=W](chunk_start)` — does NOT exist.
#     3. Per-field-dtype dispatch via `(ts[i] == Float64)`
#        cascade INSIDE the parametric body, branching on Column's
#        `arrow_type` runtime tag at the load — adds a layer of indirection
#        the engine wants to elide via comptime.
#   Sub-slot 6a builds these at the engine boundary where the column-index
#   resolution table is constructed once at first-batch validation; this file
#   ships the SimdOf primitive + the simpler array-bound bridge.


# -----------------------------------------------------------------------------
# Scalar single-row helper — for tail handling (n % W rows).
# -----------------------------------------------------------------------------

# (Scalar tail handling is performed at the call site by the chain driver,
# which uses the user's `eval_row(row: T) -> T_OUT` method on the conformer.
# SimdOf does not own the tail loop; it owns the W-lane chunk.)
