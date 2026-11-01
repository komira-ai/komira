# =============================================================================
# owned_aligned_buffer.mojo — single-owner heap-allocated aligned buffer
# =============================================================================
#
# Role: single-owner heap-allocated aligned buffer. No Arc cost.
# Used at construction zones BEFORE bytes are shared (aggregation
# outputs, projection results, new-allocation paths). Promotes to
# `SharedAlignedBuffer[HeapRegion]` via `from_owned` when handed to
# downstream Column / RecordBatch / IPC encoder consumers.
#
# Storage: `List[UInt8]` via Mojo's allocator (tcmalloc). NOT
# `aligned_alloc(3)` FFI — with tcmalloc under the hood, the buffer must not
# bypass it. Sub-4KB allocations route through tcmalloc's
# size-classed ThreadCache with weaker alignment guarantees, so the
# constructor over-allocates by `ALIGN - 1` and rounds the cached
# `_ptr` to the next ALIGN boundary.
#
# Encapsulation rule:
#   The `_ptr` field is PRIVATE and uses an untracked origin per the
#   PERF-CRITICAL cached-pointer carve-out. Public API exposes only `as_view()` -> `ByteView
#   [origin]`. Callers extract `.unsafe_ptr()` locally from the
#   returned view; the wildcard origin never crosses the module
#   boundary on a public method signature.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer, unsafe_memcpy, unsafe_memset
from std.sys import size_of
from std.sys.info import CompilationTarget

from komira_buffer.byte_view import ByteView
from komira_simd.fast_copy import fast_copy_bytes

from komira_buffer.aligned_buffer_trait import AlignedBufferTrait
from komira_buffer.hugepage_span import (
    ADVICE_HUGEPAGE,
    ADVICE_OFF,
    ADVICE_POPULATE,
    HUGEPAGE_MIN_ALLOC_BYTES,
    HugepageSpan,
    hugepage_span,
)


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer (the stdlib has no `UnsafePointer[T, o]()` null
    ctor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer (the non-null-pointer layout guarantee); `None` is
    # the all-zero (NULL) bit pattern. Used for the empty/zero-capacity
    # buffer sentinel (`_length == 0`), never dereferenced.
    #
    # NOTE: the `_ptr` field origin remains `MutExternalOrigin` (a cached
    # pointer into the struct's own `_bytes`/region). Migrating it to a
    # concrete self-referential origin is a separate follow-on.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]

# Compile-time alignment for OwnedAlignedBuffer's cached `_ptr`.
# Matches the `ALIGN = 64` default of the other aligned buffers.
comptime _OWNED_ALIGN: Int = 64


# -----------------------------------------------------------------------------
# LEVER P — large-allocation memory advice (madvise(2)).
#
# `madvise` is declared HERE, in the module that owns the allocation, and
# nowhere else in the tree (verified: zero other `madvise` external_call sites).
# That satisfies both the encapsulation rule (no pointer crosses a module
# boundary — the pure span math in `hugepage_span.mojo` trades in plain Ints)
# and the MLIR one-declaration-per-symbol-per-link-unit invariant documented in
# `komira_libc/posix.mojo`.
#
# The advice constants are Linux ABI values from `asm-generic/mman-common.h`,
# stable since 2.6.38 (`MADV_HUGEPAGE`) and 5.14 (`MADV_POPULATE_WRITE`) and
# identical on x86_64 and aarch64 (both use the asm-generic header; only alpha
# and parisc override, neither of which we target). Every use is gated behind
# `comptime if CompilationTarget.is_linux()` so the symbol is never emitted on
# macOS — the same wrong-OS-branch discipline as
# `komira_async/reactor/epoll_subsystem.mojo`.
# -----------------------------------------------------------------------------

comptime _MADV_HUGEPAGE: Int32 = 14
comptime _MADV_POPULATE_WRITE: Int32 = 23


def _apply_memory_hint(
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin], size: Int, mode: Int
) -> Int32:
    """Apply the LEVER-P `madvise(2)` advice selected by `mode` to the
    hugepage-aligned interior of `[ptr, ptr + size)`. Returns 0 on success or
    when nothing was advised; otherwise the rc of the first failing call.

    `madvise` is a pure HINT: it changes only how the kernel backs the pages,
    never their contents. `MADV_HUGEPAGE` sets `VM_HUGEPAGE` on the VMA;
    `MADV_POPULATE_WRITE` pre-faults writable page-table entries and is
    documented (man 2 madvise) NOT to modify contents. Byte-equivalence is
    therefore true by construction and pinned by
    `tests/test_hugepage_hint.mojo`.

    KILL-SWITCH ORDERING: `mode` is the caller-supplied memory advice
    and tested here BEFORE any span math or syscall, so `mode == ADVICE_OFF`
    performs literally zero side-effecting work.

    SAFETY: file-private; the raw pointer never leaves this module (the span
    math in `hugepage_span.mojo` takes an `Int` address and returns a RELATIVE
    offset, so no pointer is ever reconstructed from an integer). `span` is
    guaranteed by `hugepage_span`'s CONTAINMENT clause to satisfy
    `0 <= offset` and `offset + length <= size`, so `ptr + span.offset` for
    `span.length` bytes stays strictly inside the caller's own allocation —
    the advice can never touch a neighbouring mapping.
    """
    if mode == ADVICE_OFF:
        return Int32(0)
    var span = hugepage_span(Int(ptr), size)
    if span.is_empty():
        return Int32(0)

    # Defense in depth. `madvise` with MADV_HUGEPAGE / MADV_POPULATE_WRITE is
    # non-destructive, so an overshoot cannot corrupt a neighbour's bytes — but
    # it WOULD silently apply a residency hint to memory we do not own (an RSS
    # and hugepage-budget leak onto another allocation). tcmalloc keeps its
    # spans inside one big arena mapping, so an overshoot stays MAPPED and
    # `madvise` still returns 0: the syscall rc cannot detect this. This assert
    # is the check that can.
    debug_assert(
        span.offset >= 0 and span.offset + span.length <= size,
        (
            "_apply_memory_hint: advised span escapes the allocation"
            " (hugepage_span CONTAINMENT violated)"
        ),
    )

    var rc = Int32(0)
    comptime if CompilationTarget.is_linux():
        var target = ptr + span.offset
        var length = UInt64(span.length)
        if (mode & ADVICE_HUGEPAGE) != 0:
            var r = external_call["madvise", Int32](
                target, length, _MADV_HUGEPAGE
            )
            if r != Int32(0):  # cov: unreachable madvise(MADV_HUGEPAGE) on our own mapped, aligned span fails only on a kernel built without transparent hugepages
                rc = r
        if (mode & ADVICE_POPULATE) != 0:
            var r2 = external_call["madvise", Int32](
                target, length, _MADV_POPULATE_WRITE
            )
            if r2 != Int32(0) and rc == Int32(0):  # cov: unreachable madvise(MADV_POPULATE_WRITE) on our own mapped, writable span fails only on a kernel before 5.14 or when memory runs out
                rc = r2
    return rc


struct OwnedAlignedBuffer(
    AlignedBufferTrait, Movable, Deinitable
):
    """Single-owner heap-allocated aligned buffer. No Arc cost.

    For Columns / Bitmaps / PrimitiveArrays that own their bytes
    outright (the typical case after aggregation, projection, or any
    new-allocation path). Construction routes through Mojo's
    allocator (tcmalloc) via `List[UInt8]`; cached `_ptr` field
    populated once at construction for SIMD/decode hot paths.

    Lifetime: Movable (single-owner); transfers via `^`; drops via
    `__del__` returning the List's pages to tcmalloc.

    To borrow from an OwnedAlignedBuffer, **promote it to
    SharedAlignedBuffer[HeapRegion] first** via the static
    `SharedAlignedBuffer.from_owned(buf^)` constructor. This keeps
    Owned's role narrow — pure single-owner heap allocation.

    Fields:
        _bytes:    Owning storage. Drops on __del__; pages return to
                   tcmalloc.
        _ptr:      Cached aligned start pointer. PERF-CRITICAL.
                   Populated once at
                   construction; never re-derived. PRIVATE.
        _length:   Logical byte length (written via `set_length`; bounded
                   by `_capacity`).
        _capacity: Padded usable bytes (excluding over-allocation
                   epilogue). Equal to the result of rounding up the
                   constructor's `capacity` arg to the next 64-byte
                   boundary; the inner `_bytes.__len__()` is
                   `_capacity + ALIGN - 1`.
    """

    var _bytes: List[UInt8]
    var _ptr: UnsafePointer[UInt8, MutUntrackedOrigin]
    var _length: Int64
    var _capacity: Int

    # -------------------------------------------------------------------------
    # Construction
    # -------------------------------------------------------------------------

    def __init__(out self, capacity: Int):
        """Allocate at least `capacity` bytes; never issues a memory hint.

        Same as `OwnedAlignedBuffer(capacity, memory_advice=ADVICE_OFF)`.
        The large-buffer memory advice is a TARGETED opt-in (see
        `hugepage_span.mojo`): only a caller that knows its destination is
        densely filled passes a mode.

        Args:
            capacity: Minimum usable bytes (see the keyword overload).
        """
        self = Self(capacity, memory_advice=ADVICE_OFF)

    def __init__(out self, capacity: Int, *, memory_advice: Int):
        """Allocate at least `capacity` bytes through Mojo's allocator.

        Construction strategy: `List[UInt8]` over-allocated by
        `_OWNED_ALIGN - 1` bytes so the cached `_ptr` can round up to
        the next 64-byte boundary. The Mojo runtime is tcmalloc-based;
        allocations at capacity-4096+ are page-aligned by PageHeap. Sub-4KB requests
        route through size-classed ThreadCache where alignment is
        weaker, so the over-allocate-and-round-up dance is required.

        Args:
            capacity: Minimum usable bytes. `<= 0` yields an empty
                unallocated buffer (capacity=0, length=0, null
                cached pointer), the empty-buffer shape used as a
                default-construction placeholder.
            memory_advice: An ADVICE_* bitmask (`hugepage_span.mojo`,
                `parse_memory_advice`) applied to allocations of at least
                `HUGEPAGE_MIN_ALLOC_BYTES`. `ADVICE_OFF` issues no syscall.

        Post-condition: `length() == max(capacity, 0)` — the freshly-
        allocated bytes are immediately admitted into the buffer's
        `_length` window (capacity-bound `set_typed` / `write_*_at`
        accept writes anywhere in `[0, capacity)`), which serves the
        "allocate then write then set_length" Arrow-builder idiom: with
        `_length == capacity`, the per-byte `write_*_at` calls pass OAB's
        `_length`-bounded debug_assert without an interim
        `set_length(capacity)`. `CopyableSharedAlignedBuffer` has the same
        contract, for the same reason.
        """
        if capacity <= 0:
            self._bytes = List[UInt8]()
            self._ptr = _null_ptr[UInt8, MutUntrackedOrigin]()
            self._length = 0
            self._capacity = 0
            return

        # SIMD tail-pad: round capacity up to the next 64-byte boundary
        # so SIMD loads at the buffer tail never read past the
        # allocation (PERF-CRITICAL).
        var padded_size = ((capacity + 63) // 64) * 64
        var raw_size = padded_size + _OWNED_ALIGN - 1

        var bytes = List[UInt8](capacity=raw_size)
        bytes.resize(unsafe_uninit_length=raw_size)

        # SAFETY: compute the aligned offset within the List's bytes.
        # The List owns the inner buffer; the data pointer is stable
        # for the List's lifetime (we never grow it after this point).
        # The untracked origin is the PERF-CRITICAL cached pointer
        # carve-out.
        var raw_base = bytes.unsafe_ptr().bitcast[UInt8]().unsafe_mut_cast[
            True
        ]().unsafe_origin_cast[MutUntrackedOrigin]()
        var raw_addr = Int(raw_base)
        var aligned_addr = (
            (raw_addr + _OWNED_ALIGN - 1) // _OWNED_ALIGN
        ) * _OWNED_ALIGN
        var aligned_offset = aligned_addr - raw_addr
        var aligned = raw_base + aligned_offset

        # LEVER P — large-allocation memory advice, supplied by the caller
        # (`memory_advice`). With `ADVICE_OFF` (the plain ctor, and the
        # engine configuration's default) nothing is issued: the only cost is
        # one integer compare.
        #
        # PLACEMENT IS LOAD-BEARING: this runs BEFORE the tail-pad memset —
        # i.e. before the FIRST page of the allocation is touched. THP is
        # decided at fault time, so advising after first touch would leave the
        # region as 4 KiB pages and rely on khugepaged to collapse it later.
        #
        # KILL-SWITCH ORDERING: the mode check and the size gate both
        # strictly precede the `madvise` they disable.
        if memory_advice != ADVICE_OFF and padded_size >= HUGEPAGE_MIN_ALLOC_BYTES:
            _ = _apply_memory_hint(aligned, padded_size, memory_advice)

        # Zero the SIMD tail-pad bytes so over-read sees deterministic
        # zeros.
        if padded_size > capacity:
            unsafe_memset(aligned + capacity, 0, padded_size - capacity)

        self._bytes = bytes^
        self._ptr = aligned
        # Set `_length = capacity` (NOT 0) — see __init__ post-
        # condition docstring. Same contract as CSAB.
        # Bounded by `_capacity` (= padded_size) for the set_length
        # debug_assert; `max(capacity, 0)` is redundant here because the
        # `capacity <= 0` branch returned above, but kept for symmetry
        # with `set_length`'s typed Int64 conversion.
        self._length = Int64(max(capacity, 0))
        self._capacity = padded_size

    def apply_memory_hint(mut self, mode: Int) -> Int32:
        """Apply the LEVER-P `madvise(2)` advice `mode` to this buffer's
        hugepage-aligned interior; return the syscall rc (0 = success or
        nothing advised).

        Public seam so the hugepage hint tests can drive the hint
        deterministically on an existing buffer. The rc is the test's
        DISCRIMINATING ORACLE: `madvise` returns ENOMEM (-1) if any part of the
        range is unmapped, so a span-math bug that walked past the end of the
        allocation makes the guard test go RED. Returns only a typed scalar —
        no pointer crosses the boundary.

        Args:
            mode: An ADVICE_* bitmask from `hugepage_span.mojo`.

        Returns:
            0 on success or when no advice applied; the failing rc otherwise.
        """
        if self._capacity <= 0:
            return Int32(0)
        return _apply_memory_hint(self._ptr, self._capacity, mode)

    def memory_hint_span(self) -> HugepageSpan:
        """The exact span `apply_memory_hint` would advise for THIS buffer's
        real allocation, as a relative (offset, length).

        Public seam so the guard test can assert the CONTAINMENT invariant
        against a genuine tcmalloc-backed address rather than only against
        synthetic addresses. Returns a plain two-integer value — no pointer
        crosses the boundary, and no pointer can be rebuilt from it.

        Why this is needed on top of the syscall rc: `madvise` returns 0 for an
        overshoot that stays inside tcmalloc's arena mapping, so rc alone
        cannot falsify a span that runs past the buffer. This can.
        """
        return hugepage_span(Int(self._ptr), self._capacity)

    @staticmethod
    def with_capacity(capacity: Int) -> Self:
        """Construct an OwnedAlignedBuffer of at least `capacity`
        bytes, length 0. The Arrow-builder pattern.
        """
        return Self(capacity)

    # -------------------------------------------------------------------------
    # MmapAlignedBuffer trait surface
    # -------------------------------------------------------------------------

    def as_view[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Borrow the buffer's bytes as a tracked ByteView whose origin
        is parametrically bound to `self`.

        SAFETY: `_ptr` is live for `_length` bytes as long as `self` is
        alive (the inner `_bytes` List owns the storage; List drop fires
        on `__del__`). Receiver `ref [origin] self` ties the view's
        origin to self. The internal MutExternalOrigin cast is confined
        to this method body and never crosses the module boundary —
        the public return type `ByteView[origin]` is tracked.
        """
        # SAFETY: see method docstring. The receiver `ref [origin] self`
        # keeps `self` (and therefore _bytes) alive for the view's
        # lifetime. We flip mutability to match the receiver, then
        # widen origin to the named parameter.
        var ptr = self._ptr.unsafe_mut_cast[_mut]().unsafe_origin_cast[
            origin
        ]()
        return ByteView[origin](ptr, Int(self._length))

    @always_inline
    def len(self) -> Int:
        return Int(self._length)

    @always_inline
    def length(self) -> Int64:
        return self._length

    # -------------------------------------------------------------------------
    # Mutating ops (owned-only by construction; no capacity==0 sentinel
    # gate needed because OwnedAlignedBuffer never holds a borrow)
    # -------------------------------------------------------------------------

    def set_length(mut self, length: Int64):
        """Set the logical byte length. Must be `<= capacity()`.

        Args:
            length: New length in bytes.
        """
        debug_assert(
            length >= 0 and Int(length) <= self._capacity,
            "OwnedAlignedBuffer.set_length: length out of bounds",
        )
        self._length = length

    @always_inline
    def capacity(self) -> Int:
        """Padded usable bytes (the SIMD-tail-pad limit; over-allocation
        epilogue beyond this is invisible to callers).
        """
        return self._capacity

    def zero(mut self):
        """Zero all `_capacity` bytes of usable storage. Used by
        Arrow-builder pre-allocation paths that want a clean buffer
        before writing.
        """
        if self._capacity > 0:
            unsafe_memset(self._ptr, 0, self._capacity)

    # -------------------------------------------------------------------------
    # MmapAlignedBuffer trait surface — extended consumer methods.
    # Mirror of SharedAlignedBuffer's same-named methods; OAB-specific
    # semantics (no Arc, no `_region`, no `_offset`; capacity is the
    # padded allocation, `_length` is the logical written-to length).
    # -------------------------------------------------------------------------

    @always_inline
    def view_ro[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Return an immutable byte-view over `[0, self._length)`. Mirror
        of SAB.view_ro.
        """
        var ptr = self._ptr.unsafe_mut_cast[_mut]().unsafe_origin_cast[
            origin
        ]()
        return ByteView[origin](ptr, Int(self._length))

    @always_inline
    def view_mut[
        origin: Origin[mut=True], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Return a mutable byte-view over `[0, self._length)`. Mirror
        of SAB.view_mut.
        """
        var ptr = self._ptr.unsafe_origin_cast[origin]()
        return ByteView[origin](ptr, Int(self._length))

    @always_inline
    def view_range_ro[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self, start: Int, length: Int) -> ByteView[origin]:
        """Immutable sub-view over `[start, start+length)`. Bound by
        `_length` for parity with SAB.view_range_ro.
        """
        debug_assert(
            start >= 0 and start + length <= Int(self._length),
            "OwnedAlignedBuffer.view_range_ro: start+length > self._length",
        )
        var ptr = (self._ptr + start).unsafe_mut_cast[
            _mut
        ]().unsafe_origin_cast[origin]()
        return ByteView[origin](ptr, length)

    @always_inline
    def view_range_mut[
        origin: Origin[mut=True], //,
    ](ref [origin] self, start: Int, length: Int) -> ByteView[origin]:
        """Mutable sub-view over `[start, start+length)`."""
        debug_assert(
            start >= 0 and start + length <= Int(self._length),
            "OwnedAlignedBuffer.view_range_mut: start+length > self._length",
        )
        var ptr = (self._ptr + start).unsafe_origin_cast[origin]()
        return ByteView[origin](ptr, length)

    @always_inline
    def into_span_capacity[
        origin: Origin[mut=True], //,
    ](ref [origin] self) -> Span[Byte, origin]:
        """`Span[Byte, origin]` over the buffer's FULL capacity (NOT
        length). The Arrow-builder write-then-set_length use case —
        OAB-specific because OAB carries a real `_capacity` field.
        Mirror of `MmapAlignedBuffer.into_span_capacity`.
        """
        var ptr = self._ptr.unsafe_origin_cast[origin]()
        return Span[Byte, origin](unsafe_ptr=ptr, length=self._capacity)

    # ---- Origin-tied typed pointer surface (no wildcard origin) ----

    @always_inline
    def view_typed_ro[
        _mut: Bool,
        o: Origin[mut=_mut],
        //,
        T: DType,
    ](ref [o] self) -> UnsafePointer[Scalar[T], o]:
        """Read-only typed pointer with origin tied to `self`. Mirror of
        SAB.view_typed_ro / MmapAlignedBuffer.view_typed_ro.
        """
        var ptr = self._ptr.unsafe_mut_cast[_mut]().unsafe_origin_cast[
            o
        ]()
        return ptr.bitcast[Scalar[T]]()

    @always_inline
    def view_typed_mut[
        o: Origin[mut=True],
        //,
        T: DType,
    ](ref [o] self) -> UnsafePointer[Scalar[T], o]:
        """Mutable typed pointer with origin tied to `self`."""
        var ptr = self._ptr.unsafe_origin_cast[o]()
        return ptr.bitcast[Scalar[T]]()

    # ---- Typed element access (element-index addressed) ----

    @always_inline
    def get_typed[
        T: TrivialRegisterPassable & Copyable
    ](self, index: Int) -> T:
        """Return the T at element-index `index`. PANICS if
        (index+1)*size_of[T]() > _length.
        """
        comptime sz = size_of[T]()
        debug_assert(
            index >= 0 and (index + 1) * sz <= Int(self._length),
            "OwnedAlignedBuffer.get_typed: element index out of range",
        )
        return (self._ptr + index * sz).bitcast[T]()[]

    @always_inline
    def set_typed[
        T: TrivialRegisterPassable & Copyable
    ](mut self, index: Int, val: T):
        """Store the T at element-index `index`. PANICS on bounds
        violation.
        """
        comptime sz = size_of[T]()
        debug_assert(
            index >= 0 and (index + 1) * sz <= Int(self._length),
            "OwnedAlignedBuffer.set_typed: element index out of range",
        )
        (self._ptr + index * sz).bitcast[T]()[] = val

    # ---- SIMD bulk access ----

    @always_inline
    def load_simd[
        T: DType, width: Int
    ](self, byte_offset: Int) -> SIMD[T, width]:
        """Load `width` lanes of T starting at `byte_offset`."""
        comptime lane_bytes = size_of[T]() * width
        debug_assert(
            byte_offset >= 0
            and byte_offset + lane_bytes <= Int(self._length),
            "OwnedAlignedBuffer.load_simd: byte_offset+lanes > _length",
        )
        return (
            (self._ptr + byte_offset)
            .bitcast[Scalar[T]]()
            .load[width=width, alignment=1]()
        )

    @always_inline
    def store_simd[
        T: DType, width: Int
    ](mut self, byte_offset: Int, val: SIMD[T, width]):
        """Store `width` lanes of T starting at `byte_offset`."""
        comptime lane_bytes = size_of[T]() * width
        debug_assert(
            byte_offset >= 0
            and byte_offset + lane_bytes <= Int(self._length),
            "OwnedAlignedBuffer.store_simd: byte_offset+lanes > _length",
        )
        (self._ptr + byte_offset).bitcast[Scalar[T]]().store[alignment=1](
            val
        )

    # ---- Byte-offset typed reads (LE; bounded by _length) ----

    @always_inline
    def read_u8_at(self, offset: Int) -> UInt8:
        debug_assert(
            offset >= 0 and offset + 1 <= Int(self._length),
            "OwnedAlignedBuffer.read_u8_at: offset+1 > _length",
        )
        return (self._ptr + offset)[]

    @always_inline
    def read_u16_le_at(self, offset: Int) -> UInt16:
        debug_assert(
            offset >= 0 and offset + 2 <= Int(self._length),
            "OwnedAlignedBuffer.read_u16_le_at: offset+2 > _length",
        )
        return (self._ptr + offset).bitcast[UInt16]().load[alignment=1]()

    @always_inline
    def read_u32_le_at(self, offset: Int) -> UInt32:
        debug_assert(
            offset >= 0 and offset + 4 <= Int(self._length),
            "OwnedAlignedBuffer.read_u32_le_at: offset+4 > _length",
        )
        return (self._ptr + offset).bitcast[UInt32]().load[alignment=1]()

    @always_inline
    def read_u64_le_at(self, offset: Int) -> UInt64:
        debug_assert(
            offset >= 0 and offset + 8 <= Int(self._length),
            "OwnedAlignedBuffer.read_u64_le_at: offset+8 > _length",
        )
        return (self._ptr + offset).bitcast[UInt64]().load[alignment=1]()

    @always_inline
    def read_i32_le_at(self, offset: Int) -> Int32:
        debug_assert(
            offset >= 0 and offset + 4 <= Int(self._length),
            "OwnedAlignedBuffer.read_i32_le_at: offset+4 > _length",
        )
        return (self._ptr + offset).bitcast[Int32]().load[alignment=1]()

    @always_inline
    def read_i64_le_at(self, offset: Int) -> Int64:
        debug_assert(
            offset >= 0 and offset + 8 <= Int(self._length),
            "OwnedAlignedBuffer.read_i64_le_at: offset+8 > _length",
        )
        return (self._ptr + offset).bitcast[Int64]().load[alignment=1]()

    # ---- Byte-offset typed writes (LE) ----

    @always_inline
    def write_u8_at(mut self, offset: Int, val: UInt8):
        debug_assert(
            offset >= 0 and offset + 1 <= Int(self._length),
            "OwnedAlignedBuffer.write_u8_at: offset+1 > _length",
        )
        (self._ptr + offset)[] = val

    @always_inline
    def write_u16_le_at(mut self, offset: Int, val: UInt16):
        debug_assert(
            offset >= 0 and offset + 2 <= Int(self._length),
            "OwnedAlignedBuffer.write_u16_le_at: offset+2 > _length",
        )
        (self._ptr + offset).bitcast[UInt16]().store[alignment=1](val)

    @always_inline
    def write_u32_le_at(mut self, offset: Int, val: UInt32):
        debug_assert(
            offset >= 0 and offset + 4 <= Int(self._length),
            "OwnedAlignedBuffer.write_u32_le_at: offset+4 > _length",
        )
        (self._ptr + offset).bitcast[UInt32]().store[alignment=1](val)

    @always_inline
    def write_u64_le_at(mut self, offset: Int, val: UInt64):
        debug_assert(
            offset >= 0 and offset + 8 <= Int(self._length),
            "OwnedAlignedBuffer.write_u64_le_at: offset+8 > _length",
        )
        (self._ptr + offset).bitcast[UInt64]().store[alignment=1](val)

    @always_inline
    def write_i32_le_at(mut self, offset: Int, val: Int32):
        debug_assert(
            offset >= 0 and offset + 4 <= Int(self._length),
            "OwnedAlignedBuffer.write_i32_le_at: offset+4 > _length",
        )
        (self._ptr + offset).bitcast[Int32]().store[alignment=1](val)

    @always_inline
    def write_i64_le_at(mut self, offset: Int, val: Int64):
        debug_assert(
            offset >= 0 and offset + 8 <= Int(self._length),
            "OwnedAlignedBuffer.write_i64_le_at: offset+8 > _length",
        )
        (self._ptr + offset).bitcast[Int64]().store[alignment=1](val)

    # ---- Bulk copy helpers ----

    def copy_from_view(mut self, src: ByteView[_]):
        """Copy `src.len()` bytes into this buffer starting at offset 0.
        Updates `_length` to `src.len()`. Caller MUST have sized the
        buffer (via constructor or `reserve`) to at least src.len()
        bytes; OAB bounds against `_capacity`.
        """
        var count = src.len()
        debug_assert(
            count <= self._capacity,
            "OwnedAlignedBuffer.copy_from_view: src.len > _capacity",
        )
        if count > 0:
            # LEVER M: `fast_copy_bytes` is the UNCONDITIONAL bulk-copy
            # kernel here; there is no switch that selects the stdlib
            # `memcpy` instead. A comparison against `memcpy` needs a build
            # that calls it at these sites.
            fast_copy_bytes(
                Span[UInt8, MutUntrackedOrigin](
                    unsafe_ptr=self._ptr, length=count
                ),
                Span[UInt8, src.origin](
                    unsafe_ptr=src._unsafe_ptr(), length=count
                ),
            )
        self._length = Int64(count)

    @always_inline
    def copy_from_view_at(mut self, dst_offset: Int, src: ByteView[_]):
        """Bulk memcpy at `dst_offset`. Does NOT update `_length`.
        Bounded by `_capacity` (the writable-region upper bound).
        """
        var count = src.len()
        debug_assert(
            dst_offset >= 0 and dst_offset + count <= self._capacity,
            "OwnedAlignedBuffer.copy_from_view_at: dst_offset+src.len > _capacity",
        )
        if count > 0:
            # LEVER M: unconditional (see copy_from_view).
            fast_copy_bytes(
                Span[UInt8, MutUntrackedOrigin](
                    unsafe_ptr=self._ptr + dst_offset, length=count
                ),
                Span[UInt8, src.origin](
                    unsafe_ptr=src._unsafe_ptr(), length=count
                ),
            )

    @always_inline
    def copy_from_bytes_list(mut self, src: List[UInt8]):
        """Bulk memcpy from a List[UInt8]. Updates `_length` =
        len(src).
        """
        var count = len(src)
        debug_assert(
            count <= self._capacity,
            "OwnedAlignedBuffer.copy_from_bytes_list: src.len > _capacity",
        )
        if count > 0:
            unsafe_memcpy(
                dest=self._ptr,
                src=src.unsafe_ptr(),
                count=count,
            )
        self._length = Int64(count)

    @always_inline
    def copy_from_int32_list(mut self, src: List[Int32]):
        """Bulk memcpy `len(src)` Int32 elements from `src` into this buffer.

        Mirror of `MmapAlignedBuffer.copy_from_int32_list` and
        `SharedAlignedBuffer.copy_from_int32_list`. Replaces a scalar
        `for i: set_typed[Int32](i, src[i])` loop with one
        `memcpy(count=len(src)*4)`. Does NOT update `self._length` (caller
        sets it to the byte length explicitly).

        SAFETY: `src.unsafe_ptr()` is a module-internal escape; `src` is
        alive for the call. The dest is byte-addressed; Int32 is trivially
        copyable so a raw byte memcpy reproduces the LE element layout
        exactly.
        """
        var count = len(src)
        var bytes = count * 4
        debug_assert(
            bytes <= self._capacity,
            "OwnedAlignedBuffer.copy_from_int32_list: src bytes > _capacity",
        )
        if count > 0:
            unsafe_memcpy(
                dest=self._ptr,
                src=src.unsafe_ptr().bitcast[UInt8](),
                count=bytes,
            )

    @always_inline
    def copy_from_span_at(
        mut self, dst_offset: Int, src: Span[UInt8, _]
    ):
        """Bulk memcpy from a Span[UInt8, _] at `dst_offset`. Does NOT
        update `_length`.
        """
        var count = len(src)
        debug_assert(
            dst_offset >= 0 and dst_offset + count <= self._capacity,
            "OwnedAlignedBuffer.copy_from_span_at: dst_offset+src.len > _capacity",
        )
        if count > 0:
            unsafe_memcpy(
                dest=self._ptr + dst_offset,
                src=src.unsafe_ptr(),
                count=count,
            )

    # ---- State inquiry ----

    @always_inline
    def is_aligned(self) -> Bool:
        """True iff `_ptr` is aligned to `_OWNED_ALIGN` (64) bytes.
        Vacuously True for empty buffers (null cached pointer).
        """
        if self._capacity == 0 and Int(self._ptr) == 0:  # cov: unreachable every path that sets _capacity to 0 also nulls _ptr, so the right operand is never False when the left is True
            return True
        return Int(self._ptr) % _OWNED_ALIGN == 0

    @always_inline
    def is_owned(self) -> Bool:
        """OAB always owns its heap bytes when capacity > 0; the
        capacity == 0 case is the default-constructed empty placeholder.
        Mirror of MmapAlignedBuffer.is_owned (capacity-based).
        """
        return self._capacity > 0

    @always_inline
    def is_mmap_backed(self) -> Bool:
        """OAB is heap-only by construction; mmap-backed paths route
        through `SharedAlignedBuffer.borrow_from_mmap`. Always False.
        """
        return False

    # ---- State mutation (reserve / free) — required by the trait ----

    def reserve(mut self, min_size: Int):
        """Ensure the buffer has at least `min_size` usable bytes.
        Grows monotonically (never shrinks). If already sufficient,
        this is a no-op. On grow, the existing bytes are preserved
        and the cached pointer is re-derived against the new
        allocation.
        """
        if min_size <= self._capacity:
            return
        # Allocate a fresh backing List, copy the existing _length
        # bytes, swap into self. The prior _bytes List drops here
        # (refcount-free; List is single-owner so the pages return to
        # tcmalloc immediately).
        var padded_size = ((min_size + 63) // 64) * 64
        var raw_size = padded_size + _OWNED_ALIGN - 1
        var fresh = List[UInt8](capacity=raw_size)
        fresh.resize(unsafe_uninit_length=raw_size)

        # SAFETY: same alignment dance as __init__; the new List's
        # data pointer is stable for the List's lifetime (we never
        # grow it after this point), so the cached pointer below is
        # valid as long as `self` is alive.
        var raw_base = fresh.unsafe_ptr().bitcast[
            UInt8
        ]().unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin]()
        var raw_addr = Int(raw_base)
        var aligned_addr = (
            (raw_addr + _OWNED_ALIGN - 1) // _OWNED_ALIGN
        ) * _OWNED_ALIGN
        var aligned_offset = aligned_addr - raw_addr
        var aligned = raw_base + aligned_offset

        # Preserve existing bytes
        var keep = Int(self._length)
        if keep > 0:
            unsafe_memcpy(dest=aligned, src=self._ptr, count=keep)
        # Zero tail padding (deterministic SIMD over-read)
        if padded_size > keep:  # cov: unreachable keep is _length, which the set_length precondition (length <= capacity) holds <= the old _capacity < min_size <= padded_size, so the comparison is never False
            unsafe_memset(aligned + keep, 0, padded_size - keep)

        # ★★ THIS LINE IS LOAD-BEARING. IT IS NOT DEAD CODE. DO NOT DELETE IT.
        #
        # `_ptr` is `UnsafePointer[UInt8, MutExternalOrigin]` — a WILDCARD
        # origin — so the compiler CANNOT SEE that the `memcpy` above reads
        # THROUGH `self._bytes`. Nothing else in this function touches
        # `self._bytes` between entry and the move below, so the old List is
        # destroyable BEFORE the memcpy runs. tcmalloc then writes its
        # free-list linkage over the first bytes of the freed block, and a
        # tail-of-list `next` is NULL.
        #
        # ⚠ THIS IS NOT THEORETICAL. Whether the destroy lands before or after
        # the memcpy depends only on the compiler's destruction timing, so a
        # compiler whose timing happens to place it AFTER hides the hole
        # without preventing it. Without this line the damage is EXACTLY 8
        # bytes at offset 0: the first u64 reads back as the NULL tail-of-list
        # free-list `next`, and everything after it is intact.
        #
        # This borrow is a genuine use of `self._bytes` AFTER the copy, which is
        # what pins the destruction below it. This is the wildcard-origin-field
        # + tcmalloc byte-reuse hazard; the STRUCTURAL repair is to give `_ptr`
        # a real origin tied to `_bytes` so the borrow is expressed in the type
        # system rather than by this statement. Until that lands, deleting this
        # line silently corrupts the first 8 bytes of EVERY OwnedAlignedBuffer
        # regrow.
        #
        # ★ A TEST GUARDS THIS, NOT JUST THIS COMMENT: the reserve-regrow unit
        # test writes a sentinel u64 at offset 0, forces a regrow, and reads it
        # straight back.
        var _alive = len(self._bytes)

        self._bytes = fresh^
        self._ptr = aligned
        self._capacity = padded_size
        # `_length` preserved (the logical written-to range stays the
        # same; just expanded backing storage).

    def free(mut self):
        """Explicit release: drop the inner List + null cached pointer.
        Buffer becomes empty (drop-safe; subsequent operations on the
        empty buffer are well-defined as `capacity == 0` no-ops).
        """
        var empty = List[UInt8]()
        swap(self._bytes, empty)
        self._ptr = _null_ptr[UInt8, MutUntrackedOrigin]()
        self._length = 0
        self._capacity = 0

    # -------------------------------------------------------------------------
    # Internal extractor — swap-based, destructor-safe (the partial-move
    # replacement). SharedAlignedBuffer.from_owned
    # needs to take ownership of `_bytes` to construct a HeapRegion-Arc
    # wrap; the swap leaves `self` in a destructor-safe state (empty
    # List + null cached pointer + zero length/capacity).
    # -------------------------------------------------------------------------

    def _take_bytes(mut self) -> List[UInt8]:
        """File-private: take ownership of the inner `_bytes` List.
        Leaves `self` in a destructor-safe empty state.

        SOLE caller: `SharedAlignedBuffer.from_owned` (cross-file but
        same package). After this call, `self` is an empty buffer
        (`capacity == 0`, `length == 0`, null cached pointer) that
        drops cleanly.

        Returns:
            The previously-held `List[UInt8]` containing the buffer's
            allocated bytes. Caller is responsible for managing the
            List's lifetime (typically by wrapping it in a HeapRegion +
            Arc).
        """
        # swap-based extraction per Hard Ban #11 (Optional.take /
        # swap idiom). Default `List[UInt8]()` is empty; the swap
        # leaves `self._bytes` empty and returns the original bytes
        # via `out`.
        var out = List[UInt8]()
        swap(self._bytes, out)
        # Reset cached pointer + bookkeeping so the post-swap struct
        # is internally consistent (the cached pointer would otherwise
        # dangle into freed bytes if we left it stale).
        self._ptr = _null_ptr[UInt8, MutUntrackedOrigin]()
        self._length = 0
        self._capacity = 0
        return out^

    @always_inline
    def _cached_ptr(self) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
        """File-private: read the cached aligned pointer. Used by
        `SharedAlignedBuffer.from_owned` to preserve the pre-computed
        alignment when promoting an OwnedAlignedBuffer into a Shared.
        The returned pointer is valid only while `self` is alive AND
        before `_take_bytes` is called.
        """
        return self._ptr

    # __del__ inherited from Deinitable. The synthesized
    # destructor drops `_bytes` (List<UInt8>), returning pages to
    # tcmalloc. The cached `_ptr` becomes invalid at the same instant;
    # callers MUST drop any ByteView borrowed via `as_view()` before
    # this struct's drop (enforced by Mojo's origin tracking).
