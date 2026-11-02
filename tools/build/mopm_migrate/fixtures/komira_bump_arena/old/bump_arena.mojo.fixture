# =============================================================================
# BumpArena -- O(1)-reset bump allocator for the chunk container
# =============================================================================
#
# The arena backs the persistent `Chunk`'s per-column vectors: it is allocated
# ONCE at bind (capacity = grain x Sum(col-width) + headroom), bump-allocated
# per pull, and RESET at O(1) (bump pointer -> base; NO free, NO madvise, NO
# allocator churn). It NEVER grows -- a request that would exceed the fixed
# capacity DECLINEs (returns the sentinel handle), so the page faults of a
# growing buffer never come back inside the pull loop.
#
# Safety shape:
#   * Internal storage is a `List[UInt8]` byte-backed region -- a tracked
#     concrete origin, never a wildcard cast at a byte-slab boundary. The arena
#     itself lives behind an `OwnedPointer[BumpArena]` in `Chunk`, so the byte
#     region has a stable heap address a view derives from per call.
#   * The PUBLIC API returns `ByteView` and typed scalars -- NEVER a raw
#     pointer across the module boundary (the encapsulation rule). Byte
#     offsets ("handles") are POD `Int`s: an arena-index handle, not a pointer.
#   * All pointer arithmetic (64-alignment round-up, bump advance, typed
#     element addressing) is confined to the `# SAFETY:` helpers below with a
#     CONCRETE origin (`origin_of(self._storage)`) -- never a wildcard.
#
# Grain is bind-time-CONSTANT, which is exactly why reset is O(1): a bump arena
# over a FIXED geometry rewinds to base in one store. A per-pull-varying grain
# would make reset a re-derivation.
# =============================================================================

from std.sys import size_of

from komira_buffer.byte_view import ByteView


# The arena rounds every allocation up to this boundary so successive column
# vectors stay 64-aligned (SIMD tail-pad; the container's column format is
# 64-aligned). Matches OwnedAlignedBuffer's `_OWNED_ALIGN`.
comptime ARENA_ALIGN: Int = 64

# Sentinel returned by `alloc` when the request would exceed the fixed capacity
# (the DECLINE-on-overflow contract). A valid handle is always >= 0.
comptime ARENA_DECLINE: Int = -1


@always_inline
def _round_up(n: Int, to: Int) -> Int:
    """Round `n` up to the next multiple of `to` (`to` a power of two >= 1)."""
    if n <= 0:
        return 0
    return ((n + to - 1) // to) * to


struct BumpArena(Movable, Deinitable):
    """A fixed-capacity, O(1)-reset bump allocator over an owned 64-aligned
    byte region.

    Constructed once with `capacity` usable bytes; `alloc(n)` hands out a
    64-aligned byte offset ("handle") into the region and advances the bump
    pointer; `reset()` rewinds the bump pointer to zero WITHOUT freeing. The
    region NEVER grows -- `alloc` returns `ARENA_DECLINE` rather than
    reallocating.

    Fields (all tracked; NO wildcard origin):
        _storage: The owning byte region. Over-allocated by `ARENA_ALIGN - 1`
                  so `_base` can round up to a 64-aligned start. Drops on
                  destruction; pages return to the allocator.
        _base:    Aligned start offset within `_storage` (POD Int).
        _cap:     Usable capacity from `_base` (POD Int) -- the fixed geometry.
        _pos:     Current bump offset from `_base` (POD Int) -- the ONLY field
                  `reset()` touches (besides being an alloc cursor).
    """

    var _storage: List[UInt8]
    var _base: Int
    var _cap: Int
    var _pos: Int

    # -------------------------------------------------------------------------
    # Construction / teardown
    # -------------------------------------------------------------------------

    def __init__(out self, capacity: Int):
        """Allocate an owned byte region with at least `capacity` usable bytes,
        64-aligned. `capacity <= 0` yields an empty arena (every `alloc`
        DECLINEs).

        The region is over-allocated by `ARENA_ALIGN - 1` and zero-filled so
        the aligned base is deterministic and over-reads at the tail see zeros.
        """
        if capacity <= 0:
            self._storage = List[UInt8]()
            self._base = 0
            self._cap = 0
            self._pos = 0
            return
        var usable = _round_up(capacity, ARENA_ALIGN)
        var raw = usable + ARENA_ALIGN - 1
        var storage = List[UInt8](capacity=raw)
        storage.resize(raw, UInt8(0))
        # SAFETY: derive the aligned base OFFSET (not a stored pointer). We read
        # the current address of the List's buffer to compute the round-up
        # offset once; the offset -- not the address -- is the stable field.
        # The List never grows after this point, so the buffer address (and
        # thus the aligned offset) is stable for the arena's lifetime.
        var raw_addr = Int(storage.unsafe_ptr())
        var aligned_addr = _round_up(raw_addr, ARENA_ALIGN)
        self._base = aligned_addr - raw_addr
        self._storage = storage^
        self._cap = usable
        self._pos = 0

    # -------------------------------------------------------------------------
    # Bind-time / per-pull allocation
    # -------------------------------------------------------------------------

    def alloc(mut self, nbytes: Int) -> Int:
        """Bump-allocate `nbytes` (rounded up to `ARENA_ALIGN`). Returns the
        byte-offset handle of the allocation, or `ARENA_DECLINE` if it would
        exceed the fixed capacity (the arena NEVER grows).

        A returned handle `h` addresses bytes `[h, h + nbytes)` within the
        arena; pass it to `view` / `store_simd` / `load_simd`. Handles are
        stable until `reset()`.
        """
        if nbytes <= 0:
            return self._pos
        var need = _round_up(nbytes, ARENA_ALIGN)
        if self._pos + need > self._cap:
            return ARENA_DECLINE
        var handle = self._pos
        self._pos += need
        return handle

    def reset(mut self):
        """O(1) reset: rewind the bump pointer to zero. Does NOT free, madvise,
        or touch the allocator. All handles from before the reset are INVALID
        after it (the generation guard on `Chunk` catches a stale view).
        """
        self._pos = 0

    # -------------------------------------------------------------------------
    # Capacity queries (POD scalars; no pointer surface)
    # -------------------------------------------------------------------------

    @always_inline
    def capacity(self) -> Int:
        """Total usable bytes (the fixed geometry)."""
        return self._cap

    @always_inline
    def used(self) -> Int:
        """Bytes currently handed out since the last reset."""
        return self._pos

    @always_inline
    def remaining(self) -> Int:
        """Bytes still allocatable before an `alloc` would DECLINE."""
        return self._cap - self._pos

    @always_inline
    def would_fit(self, nbytes: Int) -> Bool:
        """True iff an `alloc(nbytes)` would succeed (not DECLINE)."""
        if nbytes <= 0:
            return True
        return self._pos + _round_up(nbytes, ARENA_ALIGN) <= self._cap

    # -------------------------------------------------------------------------
    # Typed element access -- the fill / fold seam.
    # Byte offset = _base + handle + elem_i * size_of[dt]. Bounds-checked
    # against the fixed capacity. Only typed scalars / SIMD lanes cross the
    # boundary; the pointer arithmetic stays in these `# SAFETY:` bodies.
    # -------------------------------------------------------------------------

    @always_inline
    def store_simd[dt: DType, W: Int](
        mut self, handle: Int, elem_i: Int, val: SIMD[dt, W]
    ):
        """Store `W` lanes of `dt` at element index `elem_i` within the
        allocation at `handle`. PANICS (debug) if the range exceeds capacity.
        """
        comptime elem = size_of[Scalar[dt]]()
        var boff = self._base + handle + elem_i * elem
        debug_assert(
            handle >= 0 and handle + (elem_i + W) * elem <= self._cap,
            "BumpArena.store_simd: element range out of arena capacity",
        )
        # SAFETY: boff is bounds-checked above; the concrete origin
        # `origin_of(self._storage)` ties the store to the owning region for its
        # lifetime; unaligned store is sound on x86/arm.
        (
            self._storage.unsafe_ptr()
            .unsafe_origin_cast[origin_of(self._storage)]()
            + boff
        ).bitcast[Scalar[dt]]().store[alignment=1](val)

    @always_inline
    def load_simd[dt: DType, W: Int](self, handle: Int, elem_i: Int) -> SIMD[
        dt, W
    ]:
        """Load `W` lanes of `dt` at element index `elem_i` within the
        allocation at `handle`. PANICS (debug) if the range exceeds capacity.
        """
        comptime elem = size_of[Scalar[dt]]()
        var boff = self._base + handle + elem_i * elem
        debug_assert(
            handle >= 0 and handle + (elem_i + W) * elem <= self._cap,
            "BumpArena.load_simd: element range out of arena capacity",
        )
        # SAFETY: see store_simd. Read-only; concrete-origin, unaligned load.
        return (
            self._storage.unsafe_ptr()
            .unsafe_origin_cast[origin_of(self._storage)]()
            + boff
        ).bitcast[Scalar[dt]]().load[width=W, alignment=1]()

    @always_inline
    def store_scalar[dt: DType](mut self, handle: Int, elem_i: Int, val: Scalar[dt]):
        """Scalar sibling of `store_simd[dt, 1]`."""
        self.store_simd[dt, 1](handle, elem_i, SIMD[dt, 1](val))

    @always_inline
    def load_scalar[dt: DType](self, handle: Int, elem_i: Int) -> Scalar[dt]:
        """Scalar sibling of `load_simd[dt, 1]`."""
        return self.load_simd[dt, 1](handle, elem_i)[0]

    # -------------------------------------------------------------------------
    # ByteView surface. The view's origin is `origin_of(self._storage)` -- the
    # compiler tracks it against the owning region, so the view cannot outlive
    # the arena. No wildcard.
    # -------------------------------------------------------------------------

    @always_inline
    def view(mut self, handle: Int, nbytes: Int) -> ByteView[
        origin_of(self._storage)
    ]:
        """Return a mutable `ByteView` over `nbytes` bytes at `handle`. Callers
        get bulk SIMD store/load + typed byte access WITHOUT ever seeing a raw
        pointer. PANICS (debug) if the range exceeds capacity.
        """
        var boff = self._base + handle
        debug_assert(
            handle >= 0 and handle + nbytes <= self._cap,
            "BumpArena.view: byte range out of arena capacity",
        )
        # SAFETY: bounds-checked above; concrete-origin pointer tied to the
        # owning region. The ByteView carries `origin_of(self._storage)`, so the
        # compiler forbids it outliving the arena.
        var p = (
            self._storage.unsafe_ptr()
            .unsafe_origin_cast[origin_of(self._storage)]()
            + boff
        )
        return ByteView[origin_of(self._storage)](p, nbytes)
