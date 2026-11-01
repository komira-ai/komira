# =============================================================================
# aligned_buffer_trait.mojo — user-facing aligned-byte-buffer trait
# =============================================================================
#
# An extended (~30-method) consumer surface, so consumer functions can
# accept the trait as a parameter bound rather than spelling the concrete
# `SharedAlignedBuffer[K]` everywhere.
#
# Conformers:
#   * `OwnedAlignedBuffer` (single-owner heap; no Arc) — see
#     `owned_aligned_buffer.mojo`.
#   * `SharedAlignedBuffer[K]` (Arc-wrapped storage for mmap-backed
#     / format-reader-cached / borrowed cases) — see
#     `shared_aligned_buffer.mojo`.
#
# Encapsulation rule:
#   The trait declares only Span/ByteView/typed-scalar surface — concrete
#   origin, lifetime-bound to receiver. NO wildcard `UnsafePointer`
#   accessors on the trait. The two origin-tied typed pointer methods
#   (`view_typed_ro`, `view_typed_mut`) use `Origin[mut=_mut]` parameters
#   so the returned `UnsafePointer[Scalar[T], o]` carries a tracked
#   origin tied to the receiver — NOT a wildcard. Adding any
#   wildcard-origin accessor to a conformer is a HARD FAIL at code
#   review.
#
# Method surface (~32 methods):
#   * View/slice (6): as_view, view_ro, view_mut, view_range_ro,
#     view_range_mut, into_span_capacity
#   * Typed view (2): view_typed_ro[T], view_typed_mut[T]
#   * Typed scalar IO (4): get_typed[T], set_typed[T], load_simd[T,W],
#     store_simd[T,W]
#   * Read-LE (6): read_u8_at, read_u16_le_at, read_u32_le_at,
#     read_u64_le_at, read_i32_le_at, read_i64_le_at
#   * Write-LE (6): write_u8_at, write_u16_le_at, write_u32_le_at,
#     write_u64_le_at, write_i32_le_at, write_i64_le_at
#   * Copy helpers (4): copy_from_view, copy_from_view_at,
#     copy_from_bytes_list, copy_from_span_at
#   * State mutation (4): set_length, zero, reserve, free
#   * State inquiry (4): len, length, capacity, is_aligned, is_owned,
#     is_mmap_backed
#
# Methods INTENTIONALLY OMITTED (rationale inline below):
#   * `realign_to[align]` — returns `SharedAlignedBuffer[HeapRegion]` on
#     SAB, which does not generalise. Stays concrete-only on SAB.
#     OAB callers can `from_owned` -> `realign_to` if needed.
#   * `set_length(Int)` Int overload — OAB only has `set_length(Int64)`;
#     SAB has both. Trait declares the canonical `Int64` form. The `Int`
#     overload remains concrete-only on SAB.
#   * Extended read/write methods (read_f32_le_at, read_f64_le_at,
#     read_i128_le_at, read_i256_le_at, write_f{32,64}, write_i{128,256})
#     — present on SAB; stay concrete-only on SAB.
#   * `copy_from_int32_list`, `copy_from_bytes_list_at`,
#     `copy_from_aligned_buffer_at` — present on SAB; stay concrete-only on
#     SAB.
#   * `cap` (Int alias for capacity) — redundant with `capacity()`; the
#     trait declares only `capacity()`.
# =============================================================================

from std.memory import UnsafePointer
from std.sys import size_of

from komira_buffer.byte_view import ByteView


trait AlignedBufferTrait(Movable, Deinitable):
    """The user-facing aligned-byte-buffer abstraction.

    Conformers:
        * `OwnedAlignedBuffer` (single-owner heap; no Arc) — see
          `owned_aligned_buffer.mojo`.
        * `SharedAlignedBuffer[K]` (Arc-wrapped storage for mmap-backed
          / format-reader-cached / borrowed cases) — see
          `shared_aligned_buffer.mojo`.

    NO raw pointer accessors on this trait. Callers receive ByteView
    (origin-tracked) or origin-tied typed pointers (view_typed_ro /
    view_typed_mut) and extract `.unsafe_ptr()` locally at SIMD/FFI
    sites where Mojo's lifetime tracker keeps the underlying buffer
    alive across the extracted pointer's use:

        # Caller-local extraction pattern:
        var view = buf.as_view()              # ByteView[origin]
        var ptr = view.unsafe_ptr()           # origin-bound; view alive
        # ... SIMD load / FFI call ...
        # view dropped at end of scope; ptr no longer valid

    This shape rules out wildcard-origin shims (`_unsafe_data_ptr`-style
    accessors, direct ptr extraction from a borrowed view).
    """

    # =========================================================================
    # View / slice surface
    # =========================================================================

    def as_view[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Borrow the buffer's bytes as a tracked ByteView whose origin
        is parametrically bound to `self`. Same shape as
        `MemoryRegion.as_view` (§2.1) — concrete origin throughout.

        Parameters:
            _mut: Whether the view permits mutation (inferred from
                `origin`).
            origin: The origin the returned view is tied to. Bound to
                the receiver's origin via `ref [origin] self`.
        """
        ...

    def view_ro[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Return an immutable byte-view over `[0, self.length())`.

        Mirror of `as_view` semantics, as a named method.
        """
        ...

    def view_mut[
        origin: Origin[mut=True], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Return a mutable byte-view over `[0, self.length())`.

        Receiver `ref [origin] self` with `origin: Origin[mut=True]`
        enforces a mutable borrow of `self`.
        """
        ...

    def view_range_ro[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self, start: Int, length: Int) -> ByteView[origin]:
        """Return an immutable sub-view over `[start, start+length)`.

        PANICS if start+length > self.length() or start < 0.
        """
        ...

    def view_range_mut[
        origin: Origin[mut=True], //,
    ](ref [origin] self, start: Int, length: Int) -> ByteView[origin]:
        """Return a mutable sub-view over `[start, start+length)`.

        PANICS if start+length > self.length() or start < 0.
        """
        ...

    def into_span_capacity[
        origin: Origin[mut=True], //,
    ](ref [origin] self) -> Span[Byte, origin]:
        """Return a `Span[Byte, origin]` over the buffer's mutable
        extent. For OwnedAlignedBuffer this is `[0, capacity())` (the
        Arrow-builder "write into then set_length" use case). For
        SharedAlignedBuffer this is `[0, length())` (no separate
        capacity field; shared buffers expose only the bytes their
        length claims).
        """
        ...

    # =========================================================================
    # Origin-tied typed pointer surface. A single method body with one
    # origin binding is required; the 2-line `view_ro` + `bitcast` form
    # severs the lifetime chain under AOT, manifesting as a use-after-free.
    # =========================================================================

    def view_typed_ro[
        _mut: Bool,
        o: Origin[mut=_mut],
        //,
        T: DType,
    ](ref [o] self) -> UnsafePointer[Scalar[T], o]:
        """Return a read-only typed pointer with origin tied to `self`.

        `T` is positional/explicit; `_mut` + `o` are inferred from the
        receiver borrow (inferred params precede `//`,
        explicit follow). Pointer's liveness is statically tracked
        against `self` via `o`.
        """
        ...

    def view_typed_mut[
        o: Origin[mut=True],
        //,
        T: DType,
    ](ref [o] self) -> UnsafePointer[Scalar[T], o]:
        """Return a mutable typed pointer with origin tied to `self`.

        Receiver `ref [o] self` with `o: Origin[mut=True]` enforces a
        mutable borrow of `self`. `T` is positional/explicit; `o` is
        inferred.
        """
        ...

    # =========================================================================
    # Typed scalar IO (element-index addressed)
    # =========================================================================

    def get_typed[
        T: TrivialRegisterPassable & Copyable
    ](self, index: Int) -> T:
        """Return the T at element-index `index` (byte-offset = index *
        size_of[T]()). PANICS on bounds violation.
        """
        ...

    def set_typed[
        T: TrivialRegisterPassable & Copyable
    ](mut self, index: Int, val: T):
        """Store the T at element-index `index`. PANICS on bounds
        violation.
        """
        ...

    def load_simd[
        T: DType, width: Int
    ](self, byte_offset: Int) -> SIMD[T, width]:
        """Load `width` lanes of `T` starting at `byte_offset`. PANICS
        on bounds violation.
        """
        ...

    def store_simd[
        T: DType, width: Int
    ](mut self, byte_offset: Int, val: SIMD[T, width]):
        """Store `width` lanes of `T` starting at `byte_offset`. PANICS
        on bounds violation.
        """
        ...

    # =========================================================================
    # Little-endian byte-offset reads
    # =========================================================================

    def read_u8_at(self, offset: Int) -> UInt8:
        """Read a UInt8 at `offset`. PANICS if offset+1 > length."""
        ...

    def read_u16_le_at(self, offset: Int) -> UInt16:
        """Read a little-endian UInt16 at `offset`. PANICS if
        offset+2 > length.
        """
        ...

    def read_u32_le_at(self, offset: Int) -> UInt32:
        """Read a little-endian UInt32 at `offset`. PANICS if
        offset+4 > length.
        """
        ...

    def read_u64_le_at(self, offset: Int) -> UInt64:
        """Read a little-endian UInt64 at `offset`. PANICS if
        offset+8 > length.
        """
        ...

    def read_i32_le_at(self, offset: Int) -> Int32:
        """Read a little-endian Int32 at `offset`. PANICS if
        offset+4 > length.
        """
        ...

    def read_i64_le_at(self, offset: Int) -> Int64:
        """Read a little-endian Int64 at `offset`. PANICS if
        offset+8 > length.
        """
        ...

    # =========================================================================
    # Little-endian byte-offset writes
    # =========================================================================

    def write_u8_at(mut self, offset: Int, val: UInt8):
        """Store a UInt8 at `offset`. PANICS if offset+1 > length."""
        ...

    def write_u16_le_at(mut self, offset: Int, val: UInt16):
        """Store a little-endian UInt16 at `offset`. PANICS if
        offset+2 > length.
        """
        ...

    def write_u32_le_at(mut self, offset: Int, val: UInt32):
        """Store a little-endian UInt32 at `offset`. PANICS if
        offset+4 > length.
        """
        ...

    def write_u64_le_at(mut self, offset: Int, val: UInt64):
        """Store a little-endian UInt64 at `offset`. PANICS if
        offset+8 > length.
        """
        ...

    def write_i32_le_at(mut self, offset: Int, val: Int32):
        """Store a little-endian Int32 at `offset`. PANICS if
        offset+4 > length.
        """
        ...

    def write_i64_le_at(mut self, offset: Int, val: Int64):
        """Store a little-endian Int64 at `offset`. PANICS if
        offset+8 > length.
        """
        ...

    # =========================================================================
    # Bulk copy helpers
    # =========================================================================

    def copy_from_view(mut self, src: ByteView[_]):
        """Copy `src.len()` bytes from `src` into this buffer starting
        at offset 0. Implementations may update logical length to
        `src.len()` (OAB-style) or leave length unchanged (SAB-style)
        — see concrete-struct docstrings.
        """
        ...

    def copy_from_view_at(mut self, dst_offset: Int, src: ByteView[_]):
        """Bulk memcpy: copy `src.len()` bytes from `src` into `self`
        at `dst_offset`. Does NOT update logical length.
        """
        ...

    def copy_from_bytes_list(mut self, src: List[UInt8]):
        """Bulk memcpy: copy `len(src)` bytes from `src` into this
        buffer. Implementations may update logical length to `len(src)`.
        """
        ...

    def copy_from_span_at(mut self, dst_offset: Int, src: Span[UInt8, _]):
        """Bulk memcpy: copy `len(src)` bytes from `src` into this
        buffer at `dst_offset`. Does NOT update logical length.
        """
        ...

    # =========================================================================
    # State mutation
    # =========================================================================

    def set_length(mut self, length: Int64):
        """Set the logical byte length. Must be `<= capacity()` (or
        equivalent conformer-specific upper bound).
        """
        ...

    def zero(mut self):
        """Zero the buffer's accessible bytes. Concrete-struct docs
        specify whether the range is `_capacity` (OAB) or `_length`
        (SAB); both satisfy the `clear-the-bytes-I-control` contract.
        """
        ...

    def reserve(mut self, min_size: Int):
        """Ensure the buffer has at least `min_size` usable bytes.
        Conformers backed by non-growable storage (e.g. mmap regions)
        MUST constrain[] this method off at compile time, or the
        runtime path MUST be a no-op when `min_size <= current
        capacity`.
        """
        ...

    def free(mut self):
        """Explicit release: drop the underlying storage; leave the
        buffer in an empty (drop-safe) state. Conformers backed by
        non-droppable storage (e.g. mmap regions) MUST constrain[] this
        off at compile time.
        """
        ...

    # =========================================================================
    # State inquiry
    # =========================================================================

    def len(self) -> Int:
        """Byte length as Int (the common caller-facing form)."""
        ...

    def length(self) -> Int64:
        """Byte length as Int64 (matches `MemoryRegion.length` and
        Arrow's i64 length convention; preferred when arithmetic with
        file offsets or buffer slot lengths).
        """
        ...

    def capacity(self) -> Int:
        """Usable byte capacity. For OAB this is the padded allocated
        bytes (the SIMD-tail-pad limit). For SAB this is `length()`
        (shared buffers expose only the bytes their length claims).
        """
        ...

    def is_aligned(self) -> Bool:
        """True iff the buffer's data pointer is aligned to the
        conformer's compile-time alignment (typically 64 bytes).
        Vacuously True for empty buffers with no allocation.
        """
        ...

    def is_owned(self) -> Bool:
        """True iff this buffer owns heap-allocated bytes (i.e. drop
        will free the underlying storage). False for mmap-backed
        buffers and for empty/borrowed placeholders.
        """
        ...

    def is_mmap_backed(self) -> Bool:
        """True iff the buffer's bytes are kept alive by an mmap
        region. Comptime-determined for K-parametric conformers; always
        False for OAB (heap-only by construction).
        """
        ...

    # __del__ inherited from Deinitable. Conformer-specific
    # cleanup happens there (e.g. OwnedAlignedBuffer.__del__ drops the
    # inner List; SharedAlignedBuffer.__del__ drops the ArcPointer[K]).
