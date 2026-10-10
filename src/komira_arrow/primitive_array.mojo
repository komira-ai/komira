# =============================================================================
# PrimitiveArray[dtype] — Arrow-compatible fixed-width columnar array
# =============================================================================
#
# Arrow format: contiguous buffer of Scalar[dtype] values with an optional
# validity bitmap (1 bit per element, LSB-first, 1=valid, 0=null).
#
# Memory is managed by MmapAlignedBuffer (data) and Bitmap (validity).
# UnsafePointer usage is contained in those primitives — this struct only
# uses bitcast at the boundary for typed access to the raw byte buffer.
#
# The `offset` field enables zero-copy slicing: a slice is just a new
# PrimitiveArray pointing at the same buffer with a different offset and
# length. All element access methods account for the offset transparently.
# =============================================================================

# =============================================================================
# WILDCARD-ORIGIN SITES: pending migration
# =============================================================================
# Each remaining MutExternalOrigin in this file is either (a) a load-bearing
# interior pointer awaiting redesign onto a tight origin, or (b) a temporary
# shim into a primitive that will be removed (e.g. Slab /
# Slab / Slab / AtomicSlab _mut_ptr / _unsafe_base_ptr helpers
# preserved for migration source callers).
#
# Remediation: replace each wildcard with one of
#   * a typed `ref [origin] T` return / parameter,
#   * a private `UnsafePointer[T, concrete_origin]` field + `# SAFETY:`
#     comment (inside a single struct only),
#   * a byte-view (`ByteView` / `ByteViewMut`) + typed scalar reads/writes.
#
# Do NOT add new wildcard sites to this file.
# =============================================================================

from std.sys import size_of
from std.memory import unsafe_memcpy

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import (
    SharedAlignedBuffer,
    bridge_oab_to_sab,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.memory_region import MemoryRegion
from komira_arrow.bitmap import Bitmap
from komira_buffer.byte_view import ByteView


struct PrimitiveArray[dtype: DType, K: MemoryRegion = HeapRegion](Movable):
    """A typed column of fixed-width values with optional null bitmap.

    Parameters:
        dtype: The Arrow data type (e.g., DType.int32, DType.float64).
        K: The MemoryRegion type backing the data buffer. Defaults to
           HeapRegion (owning). K=MmapRegion is the zero-copy IPC path
           (read-only mmap-borrowed data; mutating methods are valid as
           long as the underlying region permits it via its trait
           contract). The K parameter carries the buffer region type
           through the holder. Default K=HeapRegion means
           `PrimitiveArray[dtype]` sites need no annotation.

    Fields:
        data: Aligned byte buffer holding Scalar[dtype] values contiguously.
        validity: Optional validity bitmap (Arrow convention: bit=1 means
            valid, bit=0 means null). None means "no nulls" (fast path).
        length: Number of logical elements (visible through this view).
        null_count: Number of null (invalid) elements. 0 when validity is None.
        offset: Element offset into the data buffer. Enables zero-copy slicing:
            a slice shares the same underlying buffer but starts at a different
            element position. Default is 0 (no offset).
    """

    # Holder field flipped
    # `MmapAlignedBuffer[64, Self.K]` -> `SharedAlignedBuffer[Self.K]`. MmapAlignedBuffer
    # ctor callers continue to construct `MmapAlignedBuffer[64](N)` and the
    # ctor body bridges via `SharedAlignedBuffer.from_aligned_buffer`.
    var data: SharedAlignedBuffer[Self.K]
    var validity: Optional[Bitmap[Self.K]]
    var length: Int
    var null_count: Int
    var offset: Int

    # --- Constructors ---

    @staticmethod
    def allocate(length: Int) -> PrimitiveArray[Self.dtype]:
        """Allocate a non-nullable array. Data is zero-initialized."""
        comptime elem_size = size_of[Scalar[Self.dtype]]()
        var buf = OwnedAlignedBuffer(max(length, 1) * elem_size)
        buf.zero()
        buf.set_length(Int64(length * elem_size))

        return PrimitiveArray[Self.dtype](buf^, length, None, 0, 0)

    @staticmethod
    def allocate_uninitialized(length: Int) -> PrimitiveArray[Self.dtype]:
        """Allocate a non-nullable array WITHOUT zero-initialising the data.

        ⛔ THE CALLER MUST WRITE EVERY ELEMENT IN [0, length) BEFORE ANY IS
        READ. There is no partial-fill contract: an element the caller does not
        write holds whatever the allocator last left there, which on a warm
        tcmalloc heap is recycled application data — plausible-looking bytes,
        not an obvious sentinel, and therefore not something a downstream
        assertion will reliably notice.

        ⚠ USE THIS ONLY WHERE THE FILL IS UNCONDITIONAL AND TOTAL. The shape it
        exists for is the sub-row-group decode kernels, where a main loop writes
        `[0, rows_val)` and a tail loop writes `[rows_val, length)` with no
        branch between them that can skip either — so `allocate`'s `buf.zero()`
        is a DEAD STORE over a buffer that is about to be written in full, i.e.
        a whole extra DRAM write pass per column chunk. If your fill has an arm
        that can leave a gap, call `allocate` and keep the zero-fill.

        `allocate` remains the default and is what every other caller should
        use; this is deliberately a SEPARATE factory rather than a flag on
        `allocate`, so that reading a call site tells you which contract is in
        force without looking up an argument's value.
        """
        comptime elem_size = size_of[Scalar[Self.dtype]]()
        var buf = OwnedAlignedBuffer(max(length, 1) * elem_size)
        buf.set_length(Int64(length * elem_size))

        return PrimitiveArray[Self.dtype](buf^, length, None, 0, 0)

    @staticmethod
    def allocate_nullable(length: Int) -> PrimitiveArray[Self.dtype]:
        """Allocate a nullable array with data + validity bitmap.

        All elements start as valid (bitmap bits set to 1).
        """
        comptime elem_size = size_of[Scalar[Self.dtype]]()
        var buf = OwnedAlignedBuffer(max(length, 1) * elem_size)
        buf.zero()
        buf.set_length(Int64(length * elem_size))


        var bm = Bitmap.create_all_valid(length)

        return PrimitiveArray[Self.dtype](buf^, length, bm^, 0, 0)

    @staticmethod
    def from_view(
        view: ByteView[_],
        length: Int,
        offset: Int = 0,
    ) -> PrimitiveArray[Self.dtype]:
        """Create a non-owning PrimitiveArray that borrows `view`'s bytes.

        Zero-copy entry point that replaces the deleted
        `MmapAlignedBuffer.borrow_from`. The returned
        PrimitiveArray's `data` field is a non-owning MmapAlignedBuffer
        with `capacity == 0` (sentinel: __del__ is a no-op), so no
        memory is freed when the array drops. The visible logical
        range is `[offset, offset + length)` elements; the underlying
        view must contain at least `(offset + length) * sizeof(Scalar
        [dtype])` bytes.

        Validity is omitted (None) because all current callers borrow
        from a parent RecordBatch buffer that does not surface a
        per-slice bitmap through this path. Callers needing nullable
        borrows can extend this factory with a `validity:
        Optional[Bitmap[HeapRegion]]` argument.

        Args:
            view: Source bytes. Origin is dropped at the
                MmapAlignedBuffer-field boundary; the safety contract is
                "view's bytes outlive the returned PrimitiveArray".
            length: Number of logical elements visible through the
                returned array.
            offset: Starting element index into the view (default 0).

        Returns:
            A non-owning PrimitiveArray over the requested element
            range. Drops are no-ops; the caller is responsible for the
            lifetime contract.

        SAFETY: the byte region referenced by `view` MUST outlive the
        returned PrimitiveArray. Typical pattern: the view is taken
        from a parent RecordBatch's `Column._data.view_range_ro(...)`,
        and the RecordBatch is held alive across the borrow's use.

        Replaces the
        public `MmapAlignedBuffer.borrow_from` non-owning factory. The
        non-owning MmapAlignedBuffer is no longer constructable across
        module boundaries -- it is built by `_borrow_from_view` inside
        MmapAlignedBuffer (file-private) and returned only as part of a
        PrimitiveArray that owns the safety contract.
        """
        comptime elem_size = size_of[Scalar[Self.dtype]]()
        var byte_len = (offset + length) * elem_size
        debug_assert(
            byte_len <= view.len(),
            "PrimitiveArray.from_view: view too short for (offset+length) elements",
        )
        # SAFETY: see method docstring. The non-owning SAB's _region is
        # an empty HeapRegion placeholder (the bytes live in the
        # caller's source ByteView); the view's origin is dropped at
        # the SAB boundary because the cached `_ptr` field is
        # MutExternalOrigin (PERF-CRITICAL carve-out).
        # Caller upholds the lifetime contract.
        # Migrated from
        # `MmapAlignedBuffer[64]._borrow_from_view(view, byte_len)` to
        # `SharedAlignedBuffer.from_borrowed_view(view)`.
        _ = byte_len
        var buf = SharedAlignedBuffer.from_borrowed_view(view)
        return PrimitiveArray[Self.dtype](
            buf^, length, Optional[Bitmap[HeapRegion]](None), 0, offset
        )

    @staticmethod
    def from_owner(
        ref owner: SharedAlignedBuffer[HeapRegion],
        length: Int,
        offset: Int = 0,
    ) -> PrimitiveArray[Self.dtype]:
        """Create a non-owning PrimitiveArray that borrows `owner`'s bytes
        WITH a refcounted keepalive on the owner's region.

        Unlike `from_view` (which takes a bare `ByteView` and severs the
        origin via the `MutExternalOrigin` cached-pointer carve-out), this
        factory takes the owning `SharedAlignedBuffer` directly and routes
        through `SharedAlignedBuffer.from_borrowed_view(owner, offset_bytes,
        length_bytes)` — the Arc-clone borrow overload. The returned
        array's `data` field holds its OWN Arc clone of `owner._region`,
        so the underlying HeapRegion bytes stay alive for the borrow's
        lifetime EVEN IF the caller's `owner` local is ASAP-dropped before
        the borrow is last read.

        This closes the lifetime hole that `from_view` leaves open: with
        `from_view`, the wildcard `_ptr` does not keep `owner` alive, so
        the compiler is free to drop `owner` right after the `view` is
        constructed, leaving the borrow dangling into freed bytes
        (observed as garbage / denormal reads). `from_owner` is the
        spec-correct shape (consumer holds a refcounted share, mirroring
        the Arrow C Data Interface producer-owns / consumer-borrows-with-
        keepalive contract).

        Args:
            owner: The owning SharedAlignedBuffer[HeapRegion]. Borrowed by
                `ref`; its `_region` Arc is cloned (refcount++), NOT moved.
            length: Number of logical elements visible through the borrow.
            offset: Starting element index into `owner` (default 0). The
                logical visible range is `[offset, offset + length)`.

        Returns:
            A non-owning PrimitiveArray over the requested element range
            whose `data` buffer pins `owner`'s region via an Arc clone.
        """
        comptime elem_size = size_of[Scalar[Self.dtype]]()
        var offset_bytes = offset * elem_size
        var length_bytes = length * elem_size
        debug_assert(
            offset_bytes + length_bytes <= owner.len(),
            (
                "PrimitiveArray.from_owner: owner too short for"
                " (offset+length) elements"
            ),
        )
        # Arc-clone borrow: the returned SAB holds its own ref to owner's
        # region. The borrow's element-0 maps to owner byte `offset_bytes`,
        # so the PrimitiveArray's own `offset` is 0 (the SAB already points
        # at the slice start).
        var buf = SharedAlignedBuffer[HeapRegion].from_borrowed_view(
            owner, Int64(offset_bytes), Int64(length_bytes)
        )
        return PrimitiveArray[Self.dtype](
            buf^, length, Optional[Bitmap[HeapRegion]](None), 0, 0
        )

    @staticmethod
    def from_list(values: List[Scalar[Self.dtype]]) -> PrimitiveArray[Self.dtype]:
        """Create a non-nullable array from a list of values."""
        # Migrated `_unsafe_data_ptr().bitcast[Scalar[dtype]]()` +
        # `init_pointee_copy` onto `MmapAlignedBuffer.set_typed[Scalar[dtype]]`.
        # Scalar[dtype] is TrivialRegisterPassable so set_typed is sound.
        var length = len(values)
        comptime elem_size = size_of[Scalar[Self.dtype]]()
        var buf = OwnedAlignedBuffer(max(length, 1) * elem_size)
        for i in range(length):
            buf.set_typed[Scalar[Self.dtype]](i, values[i])
        buf.set_length(Int64(length * elem_size))

        return PrimitiveArray[Self.dtype](buf^, length, None, 0, 0)

    def __init__(
        out self,
        var data: SharedAlignedBuffer[Self.K],
        length: Int,
        var validity: Optional[Bitmap[Self.K]],
        null_count: Int,
        offset: Int = 0,
    ):
        """Construct a PrimitiveArray directly from a SharedAlignedBuffer.

        Overload — the canonical ctor. Callers that already hold a SAB
        (e.g. mmap-backed K=MmapRegion) skip the OwnedAlignedBuffer bridge.

        Args:
            data: The underlying byte buffer (SAB).
            length: Number of logical elements visible through this view.
            validity: Optional validity bitmap.
            null_count: Number of null elements.
            offset: Element offset into the buffer (default 0).
        """
        self.data = data^
        self.validity = validity^
        self.length = length
        self.null_count = null_count
        self.offset = offset

    def __init__(
        out self,
        var data: OwnedAlignedBuffer,
        length: Int,
        var validity: Optional[Bitmap[Self.K]],
        null_count: Int,
        offset: Int = 0,
    ):
        """Construct a PrimitiveArray directly from an OwnedAlignedBuffer.

        OAB-accepting overload. The OAB is
        promoted to SAB[HeapRegion] via `from_owned`. Constrained to
        `Self.K == HeapRegion` because OAB is heap-only by construction;
        mmap-backed K=MmapRegion paths must use the SAB overload above
        with a borrowed-from-mmap SAB.
        """
        comptime assert (Self.K == HeapRegion), ( "PrimitiveArray.__init__(OwnedAlignedBuffer...): OAB ctor" " requires K=HeapRegion (OAB is heap-only); borrowed-K" " arrays must use the SAB-accepting overload above." )
        self.data = bridge_oab_to_sab[Self.K](data^)
        self.validity = validity^
        self.length = length
        self.null_count = null_count
        self.offset = offset

    # --- Destructor ---
    # MmapAlignedBuffer and Bitmap handle their own cleanup — no manual free needed.

    # --- Typed Pointer Access ---

    @always_inline
    def _unsafe_data_ptr(self) -> UnsafePointer[Scalar[Self.dtype], MutUntrackedOrigin]:
        """Get raw typed pointer for SIMD operations, adjusted for offset.

        TODO: delete when the remaining callers move to the typed API
        (`load_simd`, `store_simd`, `get_typed`, `set_typed`,
        `_typed_ptr_ro`, `_typed_ptr_mut`, `view_ro`, `view_mut`). The
        remaining callers are the `vectorize()` closure patterns in
        `eval/arithmetic.mojo` + `cast_null.mojo`, and the PERF-CRITICAL
        join / sort probe pointer caches that live in
        `List[UnsafePointer[T, MutExternalOrigin]]` storage.

        SAFETY: UnsafePointer required for SIMD vectorize() closures and sort
        algorithms that need raw typed pointers for bulk load/store operations.
        Cannot use smart pointers because vectorize() captures raw pointers
        in its kernel closure, and SIMD load/store operate on raw addresses.
        The caller MUST ensure this PrimitiveArray outlives the returned pointer.

        The returned pointer is advanced by `offset` elements so callers
        can index from 0 without knowing about the offset.

        The body goes through `self.data.view_ro() + view._unsafe_ptr()`
        (never a wildcard-shim accessor). Same wildcard return semantics.
        """
        # SAFETY: see method docstring. The view ties to `self.data`'s
        # origin for the duration of this expression; the
        # `unsafe_origin_cast[MutExternalOrigin]` widens the returned
        # pointer to the legacy wildcard shape the existing 1,272 call
        # sites consume. Cluster Z deletes those callers' wildcard
        # consumption — when that lands, this method itself is deleted.
        var view = self.data.view_ro()
        var ptr = view._unsafe_ptr().bitcast[Scalar[Self.dtype]]() + self.offset
        return ptr.unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()

    # --- Element Access ---

    @always_inline
    def get(self, index: Int) raises -> Scalar[Self.dtype]:
        """Bounds-checked single value access (offset-aware).

        `@always_inline`: per-row hot loops (temporal extract kernels,
        cast loops, predicate evaluation) invoke this O(N) times.
        Inlining elides the call/ret pair; with `ASSERT=none`
        (optimized builds) the bounds-check arm folds out too.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "PrimitiveArray.get: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        # Migrated to `get_typed[Scalar[dtype]]` (offset-aware).
        return self.data.get_typed[Scalar[Self.dtype]](self.offset + index)

    @always_inline
    def set(mut self, index: Int, value: Scalar[Self.dtype]) raises:
        """Bounds-checked single value write (offset-aware).

        If the array is nullable, marks the position as valid.

        `@always_inline`: mirror of `get` — per-row hot loops invoke this
        O(N) times, the call/ret pair is wasted overhead under
        `ASSERT=none`.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "PrimitiveArray.set: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        # Migrated to `set_typed[Scalar[dtype]]` (offset-aware).
        self.data.set_typed[Scalar[Self.dtype]](self.offset + index, value)
        # If nullable, mark this position as valid
        if self.validity:
            if self.is_null(index):
                self.null_count -= 1
            self._set_valid(index)

    # --- SIMD Bulk Access ---

    @always_inline
    def load[width: Int](self, index: Int) -> SIMD[Self.dtype, width]:
        """SIMD bulk load: read `width` contiguous elements starting at index.

        The index is relative to the logical start (offset is applied
        internally).

        Migrated from `_unsafe_data_ptr().bitcast[Scalar[dtype]]()
        .load[width](elem_idx)` onto `MmapAlignedBuffer.load_simd[dtype, width]
        (byte_offset)`. byte_offset = (self.offset + index) * size_of[
        Scalar[dtype]](). @always_inline preserves codegen.
        """
        comptime elem_size = size_of[Scalar[Self.dtype]]()
        var byte_off = (self.offset + index) * elem_size
        return self.data.load_simd[Self.dtype, width](byte_off)

    @always_inline
    def store[width: Int](mut self, index: Int, value: SIMD[Self.dtype, width]):
        """SIMD bulk store: write `width` contiguous elements starting at index.

        The index is relative to the logical start (offset is applied
        internally).

        Migrated onto `MmapAlignedBuffer.store_simd[dtype, width]`.
        """
        comptime elem_size = size_of[Scalar[Self.dtype]]()
        var byte_off = (self.offset + index) * elem_size
        self.data.store_simd[Self.dtype, width](byte_off, value)

    # --- SIMD validity load ---
    #
    # `validity_load[W]` returns a `SIMD[DType.bool, W]` for `W`
    # contiguous elements starting at `index`. Per-lane semantics:
    # `True` = valid (not null), `False` = null. When the array has no
    # validity bitmap, returns all-True (the no-null fast path).
    #
    # The implementation is intentionally a per-lane unpack of the
    # bitmap byte(s) — the Mojo stdlib does not ship a packed-bit
    # `expand_bits[W]()` SIMD op; the per-lane byte+shift+mask is the
    # canonical hand-roll. The compiler's autovectorizer typically
    # converts the loop to a NEON cnt/and/cmp sequence at -O2 (verified
    # via objdump on the load_simd_chunk caller).
    #
    # SAFETY: bounds checked at the top; bitmap byte reads go through
    # `MmapAlignedBuffer.read_u8_at` which is itself bounds-aware.

    def validity_load[W: Int](self, index: Int) raises -> SIMD[DType.bool, W]:
        """SIMD validity load: read `W` contiguous validity bits starting
        at `index`.

        Returns a `SIMD[DType.bool, W]` where lane `j` is `True` if
        element `index + j` is VALID (not null). When the array has no
        validity bitmap (the no-nulls fast path), returns all-True.

        The index is offset-aware (mirrors `load[W]`'s behavior).

        Args:
            index: Starting element index (relative to this array's view).

        Returns:
            A SIMD bool vector of length W with per-lane validity.

        Raises:
            On out-of-bounds (`index + W > self.length`).
        """
        if index < 0 or index + W > self.length:
            raise Error(
                "PrimitiveArray.validity_load: range ["
                + String(index)
                + ", "
                + String(index + W)
                + ") out of bounds [0, "
                + String(self.length)
                + ")"
            )
        # No-bitmap fast path: every element is valid.
        if not self.validity:
            return SIMD[DType.bool, W](fill=True)
        # Per-lane unpack from the bitmap. The bitmap is LSB-first
        # (Arrow spec); element `(offset + index + j)` lives in byte
        # `((offset + index + j) >> 3)` at bit `((offset + index + j) & 7)`.
        # Building the SIMD lane-by-lane keeps the body branch-free and
        # sympathetic to autovectorization. The `ref bm` binding avoids a
        # `Bitmap` copy (Bitmap is Movable-only, not ImplicitlyCopyable).
        var out = SIMD[DType.bool, W](fill=False)
        ref bm = self.validity.value()
        var base = self.offset + index
        comptime for j in range(W):
            var bit_idx = base + j
            var byte_idx = bit_idx >> 3
            var bit_off = bit_idx & 7
            var byte = bm.buffer.read_u8_at(byte_idx)
            var lane_valid = ((byte >> UInt8(bit_off)) & UInt8(1)) == UInt8(1)
            out[j] = lane_valid
        return out

    # --- Typed element access + origin-polymorphic typed ptrs ---
    #
    # These are the migration targets for `_unsafe_data_ptr().bitcast[T]()`
    # callers. They mirror the MmapAlignedBuffer new-API (Wave Z.4-unblock) but
    # address elements by logical index (offset-aware) instead of byte
    # offset. `@always_inline` preserves codegen equivalence vs the
    # `_ptr + i[]` pattern at hot sites.
    #
    # Why both `load_simd` (byte offset) and `load` (element index) exist:
    # `load[width]` (above) is the offset-aware element-indexed SIMD helper. `load_simd[T, width]` here takes a byte offset
    # and is the drop-in for `_unsafe_data_ptr().bitcast[T]().load[width]
    # (byte_off / sizeof(T))`. New callers should prefer `load[width]`.

    @always_inline
    def get_typed[
        T: TrivialRegisterPassable & Copyable
    ](self, index: Int) -> T:
        """Read a T at element-index `index` (offset-aware).

        `debug_assert`-checked variant of `get` — use in `@always_inline`
        hot loops where the `raises` signature of `get` is undesirable.
        Offset-aware: byte_offset = (self.offset + index) * size_of[T]().
        """
        comptime sz = size_of[T]()
        debug_assert(
            index >= 0,
            "PrimitiveArray.get_typed: negative index",
        )
        var elem_idx = self.offset + index
        return self.data.get_typed[T](elem_idx)

    @always_inline
    def set_typed[
        T: TrivialRegisterPassable & Copyable
    ](mut self, index: Int, val: T):
        """Write a T at element-index `index` (offset-aware).

        `debug_assert`-checked variant of `set`. Does NOT touch the
        validity bitmap — callers that need null-tracking must use `set`.
        """
        debug_assert(
            index >= 0,
            "PrimitiveArray.set_typed: negative index",
        )
        var elem_idx = self.offset + index
        self.data.set_typed[T](elem_idx, val)

    @always_inline
    def load_simd[
        T: DType, width: Int
    ](self, byte_offset: Int) -> SIMD[T, width]:
        """SIMD bulk load at a raw byte-offset (origin-preserving).

        Drop-in for `_unsafe_data_ptr().bitcast[Scalar[T]]().load[width]
        (byte_offset / sizeof(T))` at callers that still think in byte
        offsets. `load[width]` (element-index, offset-aware) is the
        preferred form for new code.

        The offset here is a RAW byte offset from the buffer's aligned
        base — it does NOT include `self.offset`. Callers that want
        offset-aware SIMD access should use `self.load[width](elem_index)`.
        """
        return self.data.load_simd[T, width](byte_offset)

    @always_inline
    def store_simd[
        T: DType, width: Int
    ](mut self, byte_offset: Int, val: SIMD[T, width]):
        """SIMD bulk store at a raw byte-offset. See `load_simd`."""
        self.data.store_simd[T, width](byte_offset, val)

    # --- Origin-polymorphic typed pointers (internal-but-shared) ---
    #
    # Origin-polymorphic typed pointer accessors,
    # mirroring MmapAlignedBuffer._typed_ptr_{mut,ro}. Use these at hot
    # call sites so the propagated origin is `o = origin_of(self)`
    # rather than the legacy wildcard.
    #
    # The pointer already accounts for `self.offset` — callers index from
    # 0. `@always_inline` preserves codegen.

    @always_inline
    def _typed_ptr_mut[
        o: Origin[mut=True], //,
    ](ref [o] self) -> UnsafePointer[Scalar[Self.dtype], o]:
        """Mutable typed pointer at `self.offset` (origin-polymorphic).

        SAFETY: pointer valid while `self` is alive. Callers must not
        read past `self.length` or write past `self.data.capacity /
        size_of[T]()`. Offset-aware: the returned pointer is pre-
        advanced by `self.offset` elements, matching the legacy
        `_unsafe_data_ptr()` semantics.

        The inner `self.data` call returns a pointer tied to
        `origin_of(self.data)` (a sub-origin of `o`). We widen to `o`
        via `unsafe_origin_cast` — sound because `self.data` outlives
        exactly as long as `self`, i.e. `o`.

        The body goes through
        `self.data.view_mut() + view._unsafe_ptr().bitcast[Scalar[T]]`
        (never a wildcard-shim accessor). Same origin-poly return semantics.

        Parameters:
            o: The receiver's origin (inferred from `self`'s borrow).
        """
        # SAFETY: `view_mut` is callable because `o: Origin[mut=True]`
        # propagates through the `ref [o] self` receiver into the inner
        # `ref [origin_of(self.data)] self.data` borrow. The view's
        # `_unsafe_ptr` yields a pointer tied to `self.data`'s origin
        # (a sub-origin of `o`); `unsafe_origin_cast[o]()` widens to `o`
        # — sound because `self.data` outlives exactly as long as `self`.
        var view = self.data.view_mut()
        var ptr = view._unsafe_ptr().bitcast[Scalar[Self.dtype]]() + self.offset
        return ptr.unsafe_origin_cast[o]()

    @always_inline
    def _typed_ptr_ro[
        _mut: Bool, o: Origin[mut=_mut], //,
    ](ref [o] self) -> UnsafePointer[Scalar[Self.dtype], o]:
        """Immutable-or-mutable typed pointer at `self.offset` (origin/mut-poly).

        SAFETY: pointer valid while `self` is alive. Mutability follows
        the caller's borrow on `self`. Use this for read-only kernels
        (scatter, scan, SIMD load-only loops). Widens the
        `origin_of(self.data)` inner origin to `o` (the receiver's
        origin) via `unsafe_origin_cast` — sound because `self.data`
        outlives exactly as long as `self`.

        The body goes through
        `self.data.view_ro() + view._unsafe_ptr().bitcast[Scalar[T]]`
        (never a wildcard-shim accessor). Same origin/mut-poly return
        semantics.

        Parameters:
            _mut: Inferred from the receiver origin's mutability.
            o: The receiver's origin (inferred from `self`'s borrow).
        """
        # SAFETY: `view_ro` is `_mut`-poly so the receiver's origin
        # mutability flows through unchanged. The view's `_unsafe_ptr`
        # yields a pointer tied to `self.data`'s origin (a sub-origin of
        # `o`); `unsafe_origin_cast[o]()` widens to `o` — sound because
        # `self.data` outlives exactly as long as `self`.
        var view = self.data.view_ro()
        var ptr = view._unsafe_ptr().bitcast[Scalar[Self.dtype]]() + self.offset
        return ptr.unsafe_origin_cast[o]()

    # --- Byte views over the element buffer ---
    #
    # Currently used sparingly — most callers that want "raw bytes" drop
    # into the underlying MmapAlignedBuffer directly (`arr.data.view_ro()`).
    # These are provided for callers that already hold a PrimitiveArray
    # and want a ByteView over [offset * sizeof(T), (offset + length) *
    # sizeof(T)).

    @always_inline
    def view_ro[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Immutable byte-view over the logical element range.

        Returns a view over `self.length` elements starting at
        `self.offset`. The view's origin is tied to `self`, so the
        compiler tracks its liveness against this PrimitiveArray.

        The inner `self.data.view_range_ro` call yields a view tied to
        `origin_of(self.data)` (a sub-origin of `origin`). We rebuild a
        ByteView with the outer `origin` via a pointer-origin cast —
        sound because `self.data` shares `self`'s lifetime.
        """
        comptime sz = size_of[Scalar[Self.dtype]]()
        var inner = self.data.view_range_ro(
            self.offset * sz, self.length * sz
        )
        var ptr = inner._unsafe_ptr().unsafe_origin_cast[origin]()
        return ByteView[origin](ptr, inner.len())

    @always_inline
    def view_mut[
        origin: Origin[mut=True], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Mutable byte-view over the logical element range.

        Receiver `ref [origin] self` enforces a mutable borrow. Rebuilds
        the ByteView with the outer `origin` — sound because `self.data`
        shares `self`'s lifetime.
        """
        comptime sz = size_of[Scalar[Self.dtype]]()
        var inner = self.data.view_range_mut(
            self.offset * sz, self.length * sz
        )
        var ptr = inner._unsafe_ptr().unsafe_origin_cast[origin]()
        return ByteView[origin](ptr, inner.len())

    # --- Null Handling ---

    @always_inline
    def is_null(self, index: Int) raises -> Bool:
        """Check if element at index is null (offset-aware).

        Returns False if no validity bitmap (all values are valid).

        `@always_inline`: per-row null-guard hot loops invoke this O(N)
        times. Inlining elides the call/ret pair and lets the compiler
        hoist the `not self.validity` no-bitmap fast-path check.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "PrimitiveArray.is_null: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        if not self.validity:
            return False
        return not self.validity.value().test(self.offset + index)

    def _set_valid(mut self, index: Int):
        """Mark element at index as valid (set bit to 1, offset-aware)."""
        self.validity.value().set(self.offset + index)

    def _set_null(mut self, index: Int):
        """Mark element at index as null (clear bit to 0, offset-aware).

        ⛔ THE BUMP IS CONDITIONAL ON THE ROW BEING VALID RIGHT NOW, so
        marking an ALREADY-NULL row is a no-op on the count. An
        UNCONDITIONAL bump double-counts every row two writers both impose a
        NULL on -- validity BITMAP correct, COUNT wrong, which no value
        assertion can see (`BooleanArray._set_null` has the same rule).

        It is not enough that callers ASSIGN the count AFTER a `_set_null`
        loop so the assignment overwrites the increment: **when the
        assignment comes FIRST** -- an `_apply_validity` that stamps the
        count, and a later arm that re-imposes the same validity -- nothing
        overwrites it, and unconditional increments are pure error.

        Clearing the validity BIT without touching `null_count` would be a
        silent footgun: any consumer that gates on `null_count` (the ORC
        PRESENT-stream emit, the arrow IPC validity-buffer emit, the parquet
        def-level emit) would see `null_count == 0` and skip emitting nulls,
        so a nullable INT64/FLOAT64 whose bits were cleared via `_set_null`
        would read back as 0 / -0.0 in pyarrow (silent data corruption).

        Callers that ALSO stamp `null_count` explicitly after a `_set_null`
        loop (csv reader, json materializer, orc decoder, avro, row-join) use
        an ASSIGNMENT (`arr.null_count = computed`) computed independently of
        `_set_null`, so that authoritative assignment stays correct."""
        if self.validity.value().test(self.offset + index):
            self.null_count += 1
        self.validity.value().clear(self.offset + index)

    # --- Slicing ---

    def slice(self, start: Int, length: Int) raises -> PrimitiveArray[Self.dtype]:
        """Create a zero-copy slice of this array.

        The returned array shares the same underlying data buffer but views
        a different range of elements. No data is copied.

        Args:
            start: Starting element index (relative to this array's view).
            length: Number of elements in the slice.

        Returns:
            A new PrimitiveArray viewing [start, start+length) of this array.

        Raises:
            Error if the slice range is out of bounds.
        """
        if start < 0 or length < 0 or start + length > self.length:
            raise Error(
                "PrimitiveArray.slice: range ["
                + String(start)
                + ", "
                + String(start + length)
                + ") out of bounds [0, "
                + String(self.length)
                + ")"
            )
        # Compute null_count for the slice range. For non-nullable arrays
        # this is always 0. For nullable arrays we count the null bits in
        # the slice range.
        var slice_nulls = 0
        if self.validity:
            for i in range(length):
                if not self.validity.value().test(self.offset + start + i):
                    slice_nulls += 1

        # Create a new PrimitiveArray that shares the same buffer.
        # We need to create a "view" — but since MmapAlignedBuffer owns the
        # memory and will free on drop, we create a new MmapAlignedBuffer that
        # points to the same data. For now, we copy the buffer metadata
        # (pointer + capacity) but mark it as a non-owning reference by
        # creating a fresh zero-capacity buffer and swapping pointers.
        #
        # IMPORTANT: This is a simplified approach — the slice copies the
        # underlying data to a new buffer offset at position 0. True zero-
        # copy slicing requires shared ownership (ArcPointer) which we'll
        # add in a future iteration. The offset field is still useful for
        # documenting the logical position and for future zero-copy support.
        comptime elem_size = size_of[Scalar[Self.dtype]]()
        var new_offset = self.offset + start
        var total_elems = new_offset + length
        var buf = OwnedAlignedBuffer(total_elems * elem_size)
        buf.zero()
        # Copy the relevant portion of the source buffer (memcpy, not scalar loop)
        # Migrated `memcpy(_unsafe_data_ptr(), _unsafe_data_ptr(), N)` onto
        # `MmapAlignedBuffer.copy_from_view` — memcpy under the hood; takes a
        # ByteView[_] source that is origin-tied to `self.data`. This sets
        # `buf.length = copy_bytes` automatically.
        var copy_bytes = total_elems * elem_size
        if copy_bytes > 0:
            buf.copy_from_view(self.data.view_range_ro(0, copy_bytes))
        else:
            buf.set_length(0)

        # Keep buf.length the canonical element-byte count.
        buf.set_length(Int64(total_elems * elem_size))


        # Copy validity bitmap for the full range if present
        var new_validity = Optional[Bitmap[HeapRegion]](None)
        if self.validity:
            var bm = Bitmap.create_all_valid(total_elems)
            for i in range(total_elems):
                if not self.validity.value().test(i):
                    bm.clear(i)
            new_validity = bm^

        return PrimitiveArray[Self.dtype](buf^, length, new_validity^, slice_nulls, new_offset)
