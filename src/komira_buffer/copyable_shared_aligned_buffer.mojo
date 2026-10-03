# =============================================================================
# COPYABLE-SHARED-ALIGNED-BUFFER — Arc-clone shim around SharedAlignedBuffer[K]
# =============================================================================
#
# Wraps `SharedAlignedBuffer[K]` (the Arc-wrapped K-parametric buffer) with
# a comptime `Copyable` trait conformance so the resulting struct can be
# stored in `InlineArray[T, N]` and forwarded through `Tuple[*Pack]` /
# `Optional[Tuple[*Pack]].take()`.
#
# A wrapper around a heap-owning, Movable-only buffer would have to abort on
# a runtime copy (a copy would double-free). `SharedAlignedBuffer[K]` is
# internally Arc-wrapped: a shallow runtime copy is an `ArcPointer` refcount
# bump (cheap, sound, Deinitable-safe). This means the `__init__(*, copy:)`
# body here actually CLONES, rather than aborting.
#
# This shim therefore satisfies the comptime trait surface
# `(Copyable, Movable, Deinitable)` with REAL copy semantics (Arc++); the
# runtime invariant for the variadic-pack-forwarding hot path is unchanged
# (consumers move via `take()` / `*slots^` / `Optional.take()`), but a copy
# is a sound refcount bump.
#
# Encapsulation audit:
#   * Zero `UnsafePointer` in public sigs (the underlying SharedAlignedBuffer's
#     private MutExternalOrigin `_ptr` field is quarantined inside that
#     module per the PERF-CRITICAL cached-pointer carve-out).
#   * Zero new wildcard origins introduced by this wrapper.
#   * Zero `unsafe_from_address=Int(...)` in this file.
#   * Zero `take_pointee` partial-moves — `take()` returns the inner via
#     move + leave-empty sentinel; the K-parametric `SharedAlignedBuffer[K]`
#     Arc-empties to a placeholder HeapRegion (matches `free()` semantics).
#   * Hot-path accessors (`set_typed`, `view_range_ro`, `set_length`,
#     `copy_from_view`, `length`, `capacity`) are `@always_inline`
#     pass-through delegators with ZERO runtime overhead.
#
# Stale-pointer audit:
#   * Holds ONE `SharedAlignedBuffer[K]` Movable field. That struct's
#     internal `_region: ArcPointer[K]` keeps storage alive across the
#     wrapper's lifetime.
#   * The destroy-recreate consumer pattern (join probe output accumulators)
#     treats the wrapper as plumbing, not state.
#
# Cross-references:
#   * `shared_aligned_buffer.mojo` — the K-parametric Arc-wrapped buffer this
#     shim wraps.
# =============================================================================

from std.memory import ArcPointer

from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion
from komira_buffer.memory_region import MemoryRegion
from komira_buffer.mmap_region import MmapRegion

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer


struct CopyableSharedAlignedBuffer[K: MemoryRegion = HeapRegion](
    Copyable, Movable, Deinitable
):
    """K-parametric Arc-clone shim around `SharedAlignedBuffer[K]`.

    A variadic-pack-forwarding shim with Arc refcount semantics:
    `__init__(*, copy:)` performs a real shallow clone (ArcPointer++) rather
    than aborting. Consumers still reach the field via MOVE for the hot
    path, and the comptime trait-surface copy is genuinely sound.

    Parameters:
        K: MemoryRegion conformer for the underlying storage. Default
            `HeapRegion` (the 64-byte alignment carve-out is internal to
            SharedAlignedBuffer's
            `_SHARED_ALIGN` constant; this wrapper exposes `is_aligned()`
            for callers that need to check).

    Fields:
        _buf: The wrapped SharedAlignedBuffer[K]. Internally Arc-backed.
    """

    var _buf: SharedAlignedBuffer[Self.K]

    # -------------------------------------------------------------------------
    # Construction
    # -------------------------------------------------------------------------

    def __init__(out self, var buf: SharedAlignedBuffer[Self.K]):
        """Wrap an existing SharedAlignedBuffer (zero-copy; move ownership)."""
        self._buf = buf^

    def __init__(out self: CopyableSharedAlignedBuffer[HeapRegion], size: Int):
        """Allocate a fresh HeapRegion-backed SharedAlignedBuffer of `size`
        bytes.

        Only available when `K = HeapRegion` (the default). For K=MmapRegion
        or K=DmaMappedRegion the bytes come from an external source; use the
        `(buf: SharedAlignedBuffer[K])` move-wrap constructor instead.

        Allocation routes through OwnedAlignedBuffer (which handles the
        SIMD-tail-pad + 64-byte alignment over-allocation) then promotes
        via `SharedAlignedBuffer[HeapRegion].from_owned`.

        Post-condition: `length() == max(size, 0)` — the freshly-allocated
        bytes are immediately admitted into the SharedAlignedBuffer's
        `_length` window (capacity-bound `set_typed` accepts writes anywhere
        in `[0, capacity)`), so consumer call sites can pre-allocate then
        `set_typed[T](row, val)` without first calling `set_length`.
        Otherwise the `set_typed` `_length` gate fires
        `debug_assert(_length > 0)` on the first write after
        `CSAB[HeapRegion](cap * es)` init (e.g. a join probe output
        accumulator's first push_match).
        """
        var owned = OwnedAlignedBuffer(capacity=size)
        owned.set_length(Int64(max(size, 0)))
        self._buf = SharedAlignedBuffer[HeapRegion].from_owned(owned^)

    def __init__(out self, *, copy: Self):
        """Arc-clone copy constructor — SAFE shallow refcount bump.

        Copying a heap-owning Movable-only buffer would double-free or
        silently 2x memory; `SharedAlignedBuffer[K]`'s underlying
        `ArcPointer[K]` makes the shallow copy sound: the refcount bumps,
        both wrappers see the same bytes, the storage drops when the last
        Arc decays.

        This is therefore a REAL copy with O(1) atomic refcount cost. The
        runtime variadic-pack-forwarding contract still routes through MOVE
        in the hot path (`take()`, `Optional.take()`); copy is the
        previously-impossible edge-case that's now sound.
        """
        # SharedAlignedBuffer's Movable + Deinitable shape means
        # we cannot use a default-Copyable synthesizer; build the inner via
        # the field-init constructor with a freshly-cloned Arc + identical
        # cached pointer + offset + length. The cached pointer is valid for
        # the clone because both Arc refs point at the same MemoryRegion
        # bytes (the Arc keeps them pinned for both wrappers' lifetimes).
        var region_clone = ArcPointer[Self.K](copy=copy._buf._region)
        self._buf = SharedAlignedBuffer[Self.K].__init_unchecked(
            region=region_clone^,
            ptr=copy._buf._ptr,
            offset=copy._buf._offset,
            length=copy._buf._length,
        )
        # `__init_unchecked` hardcodes `_mmap_keepalive = None`. If `copy`'s
        # underlying SAB is an mmap-borrowed buffer (empty-HeapRegion
        # placeholder `_region` + the real munmap-keepalive Arc held in
        # `_mmap_keepalive`), the clone built above would DROP that keepalive
        # — leaving the clone's cached `_ptr` dangling into a mapping that can
        # be munmap'd while the clone is still live (write-after-free / garbage
        # read). Clone the keepalive Arc (refcount++) so the mapping stays
        # munmap-pinned for the copy's lifetime too. Mirror of the `_region`
        # Arc clone above; same producer-owns / consumer-borrows-with-keepalive
        # contract. (Heap-owned buffers never reach this copy ctor with a
        # non-None keepalive; an mmap-borrowed CopyableSAB copy — e.g.
        # variadic-pack copy forwarding of a zero-copy mmap column — does.)
        if copy._buf._mmap_keepalive:
            self._buf._mmap_keepalive = ArcPointer[MmapRegion](
                copy=copy._buf._mmap_keepalive.value()
            )

    # -------------------------------------------------------------------------
    # Pass-through delegators
    # -------------------------------------------------------------------------

    @always_inline
    def set_typed[
        T: TrivialRegisterPassable & Copyable
    ](mut self, index: Int, val: T):
        """Pass-through to `SharedAlignedBuffer.set_typed[T]`."""
        self._buf.set_typed[T](index, val)

    @always_inline
    def view_range_ro[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self, start: Int, length: Int) -> ByteView[
        origin_of(self._buf)
    ]:
        """Pass-through to `SharedAlignedBuffer.view_range_ro`.

        Returns a view parameterized on the inner-field origin
        (`origin_of(self._buf)`) — the field's origin is bounded by the
        receiver's borrow.
        """
        return self._buf.view_range_ro(start, length)

    @always_inline
    def set_length(mut self, n: Int):
        """Pass-through to `SharedAlignedBuffer.set_length(Int)`."""
        self._buf.set_length(n)

    @always_inline
    def copy_from_view(mut self, src: ByteView[_]):
        """Pass-through to `SharedAlignedBuffer.copy_from_view` (bulk
        memcpy used in `_ensure_one`'s doubling-grow path)."""
        self._buf.copy_from_view(src)

    @always_inline
    def copy_from_view_at(mut self, dst_offset: Int, src: ByteView[_]):
        """Pass-through to `SharedAlignedBuffer.copy_from_view_at` — bulk
        memcpy that does NOT truncate `_length`.

        Use this (NOT `copy_from_view`) in any doubling-grow path: the
        fresh buffer is allocated at the FULL new capacity and the live
        prefix is copied into it; `copy_from_view` would reset `_length`
        to the copied-prefix size, leaving the rest of the freshly-
        allocated region unaddressable by the `_length`-bounded
        `set_typed` writers (a join probe accumulator would be truncated).
        `copy_from_view_at` leaves `_length` at the full allocation."""
        self._buf.copy_from_view_at(dst_offset, src)

    @always_inline
    def length(self) -> Int:
        """Pass-through to `SharedAlignedBuffer.len()` (logical byte count).

        Returned as Int (not Int64) — most callers compute byte offsets in
        Int.
        """
        return self._buf.len()

    @always_inline
    def has_mmap_keepalive(self) -> Bool:
        """Pass-through to `SharedAlignedBuffer.has_mmap_keepalive()` — True
        when the inner buffer's bytes live in an mmap'd page-cache region
        pinned by the type-erased `_mmap_keepalive` Arc cookie. Used to
        assert the copy ctor preserves the keepalive (a regression guard)."""
        return self._buf.has_mmap_keepalive()

    @always_inline
    def capacity(self) -> Int:
        """Pass-through to `SharedAlignedBuffer.capacity()`.

        For SharedAlignedBuffer, "capacity" is byte length (no separate
        `_capacity` field) — the buffer exposes only the bytes its `_length`
        claims, since the underlying region's bytes may be shared across
        multiple Arc refs.
        """
        return self._buf.capacity()

    @always_inline
    def is_aligned(self) -> Bool:
        """Pass-through to `SharedAlignedBuffer.is_aligned()` — checks
        64-byte alignment of the cached pointer (the default
        `_SHARED_ALIGN`).
        """
        return self._buf.is_aligned()

    # `take` is NOT a METHOD -- see `take_heap_buffer` below, a module-level
    # function.
    #
    # A K-refined receiver (`def take(mut self:
    # CopyableSharedAlignedBuffer[HeapRegion])`) is rejected: "'self' argument
    # must have type 'Self'". A `where Self.K == HeapRegion` clause compiles
    # as a SIGNATURE and then fails in the BODY -- "cannot implicitly convert
    # 'SharedAlignedBuffer' value to 'SharedAlignedBuffer[K]'" -- because
    # `where` gates the call without refining the body.
    #
    # For a MUT refinement that gap is closable at one cast
    # (`unsafe_mut_cast[True]()`, see byte_view). For a TYPE-PARAMETER
    # refinement it is not: `rebind[SharedAlignedBuffer[Self.K]]` re-opens as
    # an implicit-copy error on a non-ImplicitlyCopyable type, so closing it
    # would mean adding an unsafe reinterpret of a whole owning struct.
    #
    # A free function is the honest shape: `self` is what carries the
    # "must be Self" rule, and an ordinary argument does not, so the body
    # sees a CONCRETE `HeapRegion` and needs no refinement at all.


def take_heap_buffer(
    mut shim: CopyableSharedAlignedBuffer[HeapRegion],
) -> SharedAlignedBuffer[HeapRegion]:
    """Move the underlying `SharedAlignedBuffer[HeapRegion]` out of `shim`.

    A free function rather than a K-refined METHOD; see the note above
    `take_heap_buffer` for why a `where` clause does not work.

    Pinned to K=HeapRegion (the only K with a synthesizable empty
    placeholder via `OwnedAlignedBuffer(0)`).

    The zero-copy drain shape used by a join probe output accumulator's
    `take_column[col]`.

    Non-HeapRegion K (MmapRegion, DmaMappedRegion, etc.) cannot drain
    through this path — the kernel-managed bytes can only be released via
    Arc decay (drop the wrapper) or explicit munmap on the source region.
    Callers needing a typed drain on those variants should use the Arc-clone
    copy constructor (`__init__(*, copy:)`) to obtain an independent owning
    wrapper without moving the source.
    """
    var out = shim._buf^
    # Replace with an empty HeapRegion placeholder so the shim's destructor
    # is a no-op on the empty Arc + empty List[UInt8].
    var empty_owned = OwnedAlignedBuffer(capacity=0)
    shim._buf = SharedAlignedBuffer[HeapRegion].from_owned(empty_owned^)
    return out^
