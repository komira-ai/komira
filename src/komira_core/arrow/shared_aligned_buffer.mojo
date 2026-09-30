# =============================================================================
# shared_aligned_buffer.mojo — Arc-wrapped K-parametric aligned buffer
# =============================================================================
#
# Role: Arc-wrapped aligned buffer; K declares the storage strategy
# (`HeapRegion` for format-reader-cached / response-body bytes;
# `MmapRegion` for LocalFs zero-copy borrows; `DmaMappedRegion`
# later). Used when bytes are shared across multiple consumers via
# Arc refcounting (Column._data, Bitmap.buffer, FsCompletion._
# mmap_aligned_buffer, etc.). Comptime-monomorphic over K — at LLVM-IR
# level, `SharedAlignedBuffer[MmapRegion]` and `SharedAlignedBuffer
# [HeapRegion]` are distinct concrete types. No Variant discriminant;
# no dynamic dispatch on the keepalive arm.
#
# Encapsulation rule:
#   The `_ptr` field is PRIVATE and uses MutExternalOrigin per the
#   allowlisted PERF-CRITICAL cached-pointer carve-out.
#   Public API exposes only `as_view()` -> `ByteView
#   [origin]`. Callers extract `.unsafe_ptr()` locally from the
#   returned view; the wildcard origin never crosses the module
#   boundary on a public method signature.
# =============================================================================

from std.memory import ArcPointer, UnsafePointer, unsafe_memcpy, unsafe_memset
from komira_core.simd.fast_copy import fast_copy_bytes
from std.sys import size_of

from komira_core.collections.byte_view import ByteView
from komira_core.io.heap_region import HeapRegion
from komira_core.io.memory_region import MemoryRegion
from komira_core.io.mmap_region import MmapRegion

from .aligned_buffer_trait import AlignedBufferTrait
from .owned_aligned_buffer import OwnedAlignedBuffer


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

# Compile-time alignment for SharedAlignedBuffer's cached `_ptr`.
# Mirror of OwnedAlignedBuffer's `_OWNED_ALIGN`.
comptime _SHARED_ALIGN: Int = 64


def bridge_oab_to_sab[
    K: MemoryRegion
](var buf: OwnedAlignedBuffer) -> SharedAlignedBuffer[K]:
    """Generic-over-K bridge: OwnedAlignedBuffer -> SharedAlignedBuffer[K].

    Used by the 10 holder
    OAB-accepting ctor overloads (Column, PrimitiveArray, BinaryArray,
    LargeStringArray, LargeBinaryArray, StringArray, ListArray, MapArray,
    Decimal128Array, IntervalMonthDayNanoArray). Each holder's field
    type is `SharedAlignedBuffer[Self.K]`; the OAB-accepting ctor body
    bridges here.

    Why a wrapper (vs direct `SharedAlignedBuffer.from_owned(buf^)` at
    the call site): `from_owned` is signed `... -> SAB[HeapRegion]`,
    but the holder field is `SAB[Self.K]`. SAB itself is NOT
    `ImplicitlyCopyable`, so `rebind[SAB[Self.K]](sab_heap)` fails to
    compile. We must rebind the underlying `ArcPointer` (which IS
    `ImplicitlyCopyable` via its Arc refcount) and reconstruct the SAB
    field-wise via `_field_init`. Mirror of `bridge_ab_to_sab` above for
    the OAB case.

    K=HeapRegion is the only supported K for OAB construction (OAB is
    heap-only by design; mmap-backed paths route through
    `SharedAlignedBuffer.borrow_from_mmap`). Hence the K=HeapRegion
    `constrained[]` proof.

    Parameters:
        K: MemoryRegion conformer of the destination SAB. Constrained
            to HeapRegion at compile time.

    Args:
        buf: OwnedAlignedBuffer to bridge. Consumed.

    Returns:
        A SharedAlignedBuffer[K] over the moved bytes (Arc keepalive
        adopted from a freshly-built HeapRegion wrap of OAB's bytes).
    """
    comptime assert (K == HeapRegion), ( "bridge_oab_to_sab: OAB ctor inputs are K=HeapRegion only" " (OAB is heap-only by construction); K=MmapRegion sources" " must build SAB directly via" " SharedAlignedBuffer.borrow_from_mmap." )
    # Replay `SAB.from_owned`'s body but rebind the ArcPointer's K from
    # HeapRegion -> K via the constrained-equivalent rebind, then call
    # the Self.K-typed `__init_unchecked`. Order of operations matches
    # `from_owned` exactly so the cached_ptr stays valid.
    var length = buf.length()
    var cached_ptr = buf._cached_ptr()
    var bytes = buf._take_bytes()
    var region = HeapRegion(bytes^)
    var region_arc_heap = ArcPointer[HeapRegion](region^)
    var out_region = rebind[ArcPointer[K]](region_arc_heap^)
    return SharedAlignedBuffer[K].__init_unchecked(
        region=out_region^,
        ptr=cached_ptr,
        offset=0,
        length=length,
    )


struct SharedAlignedBuffer[K: MemoryRegion = HeapRegion](
    AlignedBufferTrait, Movable, Deinitable
):
    """Arc-wrapped aligned buffer; K declares the storage strategy.

    Used when bytes are shared across multiple consumers:
      * K = HeapRegion (default): format-reader-cached heap bytes
        (e.g. `ParquetRowGroupState`'s per-row-group slab); coalesced
        get_ranges responses with N slices sharing one HeapRegion.
      * K = MmapRegion: LocalFs zero-copy mmap borrow; bytes live in
        the kernel page cache; the ArcPointer keeps the MmapRegion
        munmap-pinned until the last slice drops.
      * K = DmaMappedRegion (planned): pinned-page DMA; the pool returns
        the page when the last shared buffer's Arc decrements to 0.

    Arc refcount tracks consumers; storage drops when refcount = 0.

    Default K = HeapRegion preserves positional-compat for most
    existing call sites that don't care about the storage strategy.

    Fields:
        _region: ArcPointer to the underlying MemoryRegion. Refcount
                 keeps the storage alive until the last slice/consumer
                 drops.
        _ptr:    Cached aligned start pointer. PERF-CRITICAL.
                 Populated once at construction;
                 never re-derived. PRIVATE.
        _offset: Byte offset into `_region`'s bytes where this slice
                 begins.
        _length: Number of bytes currently in use.
    """

    var _region: ArcPointer[Self.K]
    var _ptr: UnsafePointer[UInt8, MutUntrackedOrigin]
    var _offset: Int64
    var _length: Int64
    # Single generic mmap impl, opaque keepalive cookie:
    #
    # Type-erased mmap keepalive. When this buffer is K=HeapRegion but the
    # bytes it points at actually live in an mmap'd kernel page-cache region
    # (zero-copy IPC/Parquet read), `_region` is an EMPTY HeapRegion
    # placeholder and `_mmap_keepalive` holds the `ArcPointer[MmapRegion]`
    # that pins the mapping. The refcount in this Optional Arc keeps the
    # mmap munmap-deferred until the last borrowing buffer (across every
    # Column → RecordBatch that shares the mapping) drops.
    #
    # This is the "opaque cookie" that lets a `SharedAlignedBuffer[HeapRegion]`
    # — the concrete field type required by the non-K-parametric
    # `RecordBatch._columns: Slab[Column[HeapRegion]]` — carry an mmap
    # refcount WITHOUT making K=MmapRegion. It sidesteps the cross-module
    # recursive-type cycle a typed-K approach hits (the keepalive's type is
    # `MmapRegion`, which `komira_core.io.mmap_region` provides DOWNSTREAM of
    # this file — see the imports — so there is NO import cycle, unlike a
    # `Slab[RecordBatch]` keepalive would create).
    #
    # `None` for the overwhelming majority of buffers (every heap-owned,
    # format-reader-cached, or response-body buffer). Non-None ONLY for the
    # zero-copy mmap-borrow path built by `borrow_mmap_erased`. The Optional
    # is a single Arc-handle POD (no inner heap-owning field subject to
    # ASAP-drop), so this is NOT a stale-pointer vector — same shape as the existing
    # `_region: ArcPointer[Self.K]` keepalive, just an additional optional arm.
    var _mmap_keepalive: Optional[ArcPointer[MmapRegion]]

    # -------------------------------------------------------------------------
    # Construction
    # -------------------------------------------------------------------------

    def __init__(
        out self,
        var region: ArcPointer[Self.K],
        offset: Int64,
        length: Int64,
    ):
        """Wrap an existing region. The cached `_ptr` is computed from
        `region[].as_view().unsafe_ptr() + offset`.

        SAFETY: `offset + length` MUST be `<= region[].length()`.
        Caller is responsible for the bounds check (or uses one of the
        static constructors below which do bounds-check internally).

        Args:
            region: ArcPointer to the underlying MemoryRegion. Moved.
            offset: Byte offset into the region.
            length: Byte length of this slice.
        """
        # SAFETY: read the region's base pointer via the trait-surface
        # `as_view()`. The returned ByteView's `_unsafe_ptr()` is the
        # raw bytes the region exposes. The widening to MutExternalOrigin
        # matches the PERF-CRITICAL cached-pointer carve-out.
        # The ArcPointer keepalive in `_region` keeps
        # the bytes alive for this struct's lifetime.
        var base = region[].as_view()._unsafe_ptr()
        var cached = (base + Int(offset)).unsafe_mut_cast[
            True
        ]().unsafe_origin_cast[MutUntrackedOrigin]()
        self._region = region^
        self._ptr = cached
        self._offset = offset
        self._length = length
        self._mmap_keepalive = None

    # -------------------------------------------------------------------------
    # Static constructors
    # -------------------------------------------------------------------------

    @staticmethod
    def from_owned(
        var buf: OwnedAlignedBuffer,
    ) -> SharedAlignedBuffer[HeapRegion]:
        """Promote an OwnedAlignedBuffer to shared ownership. Moves
        the underlying List into a fresh ArcPointer[HeapRegion]; the
        cached `_ptr` is preserved.

        After this call, `buf` is moved (and reset to empty by the
        swap-based `_take_bytes` extractor; see OwnedAlignedBuffer's
        `_take_bytes` implementation).

        Use when a caller has constructed an OwnedAlignedBuffer (no
        sharing yet) and now wants to hand it to N consumers via Arc
        refcounting (e.g. a Column field that expects Shared).

        Args:
            buf: The OwnedAlignedBuffer to promote. Consumed.

        Returns:
            A SharedAlignedBuffer[HeapRegion] wrapping the moved bytes.
            The cached pointer is preserved (the inner List's data
            pointer is stable across the move because tcmalloc returns
            stable addresses within capacity).
        """
        # SAFETY: bytes ownership transfers from OwnedAlignedBuffer to
        # ArcPointer[HeapRegion]. The cached `_ptr` from `buf` is
        # preserved because the inner List pointer is stable across
        # the move (List's data pointer doesn't change just because we
        # moved the List).
        var length = buf.length()
        # Snapshot the cached pointer BEFORE the bytes-take, since
        # _take_bytes resets buf._ptr to null.
        var cached_ptr = buf._cached_ptr()
        var bytes = buf._take_bytes()
        var region = HeapRegion(bytes^)
        var region_arc = ArcPointer[HeapRegion](region^)
        # Direct field-construct (the `(region, offset, length)` ctor
        # above would re-compute `_ptr` from `region[].as_view()`, but
        # we want to preserve the already-aligned pointer that
        # OwnedAlignedBuffer's constructor computed — the List's data
        # pointer is stable, so the offset from base to the aligned
        # cached pointer is unchanged).
        var result = SharedAlignedBuffer[HeapRegion]._field_init(
            region=region_arc^,
            ptr=cached_ptr,
            offset=0,
            length=length,
        )
        return result^

    @staticmethod
    def heap_owned(capacity: Int) -> SharedAlignedBuffer[HeapRegion]:
        """Convenience ctor: a heap buffer ready for immediate
        write_u8_at / read_u8_at access.

        Allocates an OAB of `capacity` bytes, marks the length = capacity,
        and promotes to SAB[HeapRegion].

        SAFETY: the returned buffer reports `length() == capacity`; callers
        that subsequently shrink the logical length must call `set_length`
        explicitly.

        Args:
            capacity: Byte count to allocate (also the initial logical length).

        Returns:
            SAB[HeapRegion] with `_length == capacity`.
        """
        var owned = OwnedAlignedBuffer(capacity=capacity)
        owned.set_length(Int64(capacity))
        return SharedAlignedBuffer[HeapRegion].from_owned(owned^)

    @staticmethod
    def from_borrowed_view(
        view: ByteView[_],
    ) -> SharedAlignedBuffer[HeapRegion]:
        """File-private: build a non-owning SharedAlignedBuffer over `view`'s bytes.

        Used by the borrowed-view factories (Column.from_borrowed_*,
        PrimitiveArray.from_view, Bitmap.from_borrowed_view).

        Returned buffer:
          * `_ptr` aliases the bytes referenced by `view`
          * `_region` is an empty HeapRegion placeholder (the bytes live
            in the caller's source ByteView; the placeholder satisfies
            the field type)
          * `_offset = 0`; `_length = view.len()`

        SAFETY: the byte region referenced by `view` MUST outlive the
        returned SharedAlignedBuffer. Callers (only
        Column.from_borrowed_*, PrimitiveArray.from_view,
        Bitmap.from_borrowed_view) propagate this contract through their
        own caller (typically a RecordBatch / Column / ByteView
        lifetime on a stack frame above the borrowing holder). The
        wildcard MutExternalOrigin on the returned buffer's `_ptr` is
        the existing field-shape (see struct header —
        PERF-CRITICAL cached-pointer carve-out); this factory
        does not introduce a new wildcard, it funnels the existing
        borrow primitive through a SAB-typed API instead of the OLD
        MmapAlignedBuffer struct's `_borrow_from_view`.

        Why this is NOT a wildcard-origin stale-pointer vector: the Movable
        struct stored at the call site (Column/PrimitiveArray/Bitmap)
        has `_data: SAB[Self.K]` — a single Arc-handle POD field with
        no inner heap-owning fields subject to ASAP-drop. The placeholder
        HeapRegion's empty List is the only owned heap (drops cleanly
        via the Arc refcount on this struct's death).

        Args:
            view: Source view; its bytes back the returned buffer. The
                view's origin is dropped by the wildcard cast on `_ptr`
                — the safety contract is upheld by the caller's caller.

        Returns:
            A SharedAlignedBuffer[HeapRegion] over the borrowed bytes.
        """
        # SAFETY: caller's source view supplies the bytes; the placeholder
        # empty HeapRegion in `_region` satisfies the field type but does
        # NOT own the bytes. Mirror of the `MmapAlignedBuffer._borrow_from_view`
        # body.
        var empty_region = HeapRegion(List[UInt8]())
        var region_arc = ArcPointer[HeapRegion](empty_region^)
        # Mut-cast first (view may be immutable), then widen origin to
        # MutExternalOrigin to match the cached `_ptr` field type per the
        # PERF-CRITICAL carve-out.
        var cached_ptr = view._unsafe_ptr().unsafe_mut_cast[
            True
        ]().unsafe_origin_cast[MutUntrackedOrigin]()
        var result = SharedAlignedBuffer[HeapRegion].__init_unchecked(
            region=region_arc^,
            ptr=cached_ptr,
            offset=0,
            length=Int64(view.len()),
        )
        return result^

    @staticmethod
    def from_borrowed_view(
        owner: SharedAlignedBuffer[Self.K],
        offset: Int64,
        length: Int64,
    ) -> Self:
        """Create a borrowing slice of `owner`. The borrow CLONES
        owner's ArcPointer (incrementing the refcount); the borrow's
        `_region` keeps the source storage alive until the borrow
        itself drops.

        A `_borrow_from_view(view, length)` that wildcard-casts the source
        view's ptr severs the borrow's `_region` from the owner's lifetime.
        Under this static
        constructor, the borrow holds its own Arc clone of the owner's
        region — no severance, no placeholder HeapRegion, no
        wildcard-origin laundering.

        Args:
            owner: Source SharedAlignedBuffer whose region is borrowed.
            offset: Byte offset within `owner` (NOT within owner's
                `_region`; the borrow's offset = owner._offset + offset).
            length: Byte length of the borrowed slice.

        Returns:
            A SharedAlignedBuffer over the same region as `owner` but
            sliced to `[offset, offset+length)`.
        """
        debug_assert(
            offset >= 0 and length >= 0,
            "SharedAlignedBuffer.from_borrowed_view: negative offset/length",
        )
        debug_assert(
            offset + length <= owner._length,
            (
                "SharedAlignedBuffer.from_borrowed_view: offset+length >"
                " owner._length"
            ),
        )
        # SAFETY: clone owner's ArcPointer (refcount++). The borrow's
        # `_region` holds its own ref; owner's storage is pinned for
        # the borrow's lifetime by the Arc refcount itself — no
        # placeholder HeapRegion, no source-lifetime severance.
        var region_clone = ArcPointer[Self.K](copy=owner._region)
        # Offset the cached pointer to point at the slice's start.
        var sliced_ptr = owner._ptr + Int(offset)
        var result = Self._field_init(
            region=region_clone^,
            ptr=sliced_ptr,
            offset=owner._offset + offset,
            length=length,
        )
        # MISS-ONE-FIELD (the same hazard `share` / `share_as` /
        # `CopyableSharedAlignedBuffer.__init__(*, copy:)` each call out):
        # cloning `_region` alone does NOT pin an mmap-erased owner. A buffer
        # built by `borrow_mmap_erased` has an EMPTY HeapRegion placeholder in
        # `_region` (owns nothing) and holds its SOLE lifetime anchor in
        # `_mmap_keepalive`. `_field_init` -> `__init_unchecked` hardcodes that
        # cookie to None, so without this clone the slice aliases mmap'd
        # page-cache bytes with nothing keeping the mapping alive: the owner's
        # last ref drop fires munmap(2) and every slice's `_ptr` dangles.
        # Live path: `LocalFs.read_at` (mmap-erased) ->
        # `FileSystemSpillStorage.read_chunk` -> `THSPLCDecoder
        # .decode_zerocopy`, which slices the chunk into per-column buffers
        # here and then drops the owner -> SIGSEGV on the first restored read.
        if owner._mmap_keepalive:
            result._mmap_keepalive = ArcPointer[MmapRegion](
                copy=owner._mmap_keepalive.value()
            )
        return result^

    @staticmethod
    def borrow_from_mmap(
        var region: ArcPointer[MmapRegion],
        offset: Int64,
        length: Int64,
    ) -> SharedAlignedBuffer[MmapRegion]:
        """LocalFs zero-copy borrow path. K is pinned to MmapRegion at
        the static-constructor level — the caller's broader K is not
        in scope; this is the explicit cross-K constructor for the
        mmap-backed case.

        Args:
            region: ArcPointer to the mmap region. Moved (the ref is
                consumed; if the caller wants to keep their own ref
                they should clone before calling).
            offset: Byte offset into the mmap region.
            length: Byte length of this slice.

        Returns:
            A SharedAlignedBuffer[MmapRegion] over the mmap'd bytes.
        """
        debug_assert(
            offset >= 0 and length >= 0,
            "SharedAlignedBuffer.borrow_from_mmap: negative offset/length",
        )
        debug_assert(
            offset + length <= region[].length(),
            (
                "SharedAlignedBuffer.borrow_from_mmap: offset+length >"
                " region.length()"
            ),
        )
        return SharedAlignedBuffer[MmapRegion](
            region=region^, offset=offset, length=length
        )

    @staticmethod
    def borrow_mmap_erased(
        var region: ArcPointer[MmapRegion],
        offset: Int64,
        length: Int64,
    ) -> SharedAlignedBuffer[HeapRegion]:
        """Zero-copy mmap borrow that returns K=HeapRegion via a type-erased
        keepalive cookie.

        The alternative boundary pattern, `borrow_from_mmap(...).realign_to[64]()`,
        allocates a fresh HeapRegion and memcpy's the bytes (one alloc +
        memcpy per buffer per column per RecordBatch). This factory
        eliminates the memcpy: the returned `SharedAlignedBuffer[HeapRegion]`
        points DIRECTLY at the mmap'd kernel page-cache bytes, and the
        `ArcPointer[MmapRegion]` keepalive cookie pins the mapping for the
        buffer's lifetime.

        Why K=HeapRegion (and not MmapRegion): the consumer is
        `Column[HeapRegion]` whose containing `RecordBatch._columns` is
        `Slab[Column[HeapRegion]]` (NOT K-parametric). A `SAB[MmapRegion]`
        cannot be stored into a `SAB[HeapRegion]` field — at LLVM-IR level
        they are distinct concrete types. The erased cookie threads the
        mmap refcount THROUGH the HeapRegion-typed buffer, so the whole
        Column → RecordBatch chain stays HeapRegion-typed (zero downstream
        churn) while the bytes remain zero-copy and the mapping stays alive.

        Layout of the returned buffer:
          * `_ptr`            — aliases the mmap bytes at `offset`.
          * `_region`         — EMPTY HeapRegion placeholder (owns nothing;
                                its empty List drops cleanly).
          * `_mmap_keepalive` — Some(ArcPointer[MmapRegion]) — the lifetime
                                anchor. Refcount-bumped here; decremented on
                                this buffer's drop; munmap fires on last ref.
          * `_offset`         — 0 (the cached `_ptr` already includes the
                                mmap-region offset; `_offset` is the offset
                                into `_region`, which is the empty
                                placeholder, so 0 is correct).
          * `_length`         — `length`.

        SAFETY: alignment. The mmap base address is page-aligned (4 KiB),
        but `offset` into the region need not be 64-aligned. Arrow IPC body
        buffers ARE 8-byte (often 64-byte) aligned by the encoder's padding
        discipline, and downstream SIMD loads on the Arrow read path use
        unaligned loads (`SIMD.load`/`loadu` semantics) — so a non-64-aligned
        cached pointer is correctness-safe (the realign in the alternative
        pattern is a K-bridge, NOT an alignment requirement). Callers that genuinely require 64-aligned bytes (none on
        the current read path) must `realign_to[64]()` explicitly.

        Args:
            region: ArcPointer to the mmap region. Moved; its refcount is
                the keepalive that pins the mapping.
            offset: Absolute byte offset into the mmap region where this
                buffer's bytes begin.
            length: Byte length of this buffer's slice.

        Returns:
            A SharedAlignedBuffer[HeapRegion] aliasing the mmap bytes,
            with the mmap mapping pinned via the keepalive cookie.
        """
        debug_assert(
            offset >= 0 and length >= 0,
            "SharedAlignedBuffer.borrow_mmap_erased: negative offset/length",
        )
        debug_assert(
            offset + length <= region[].length(),
            (
                "SharedAlignedBuffer.borrow_mmap_erased: offset+length >"
                " region.length()"
            ),
        )
        # SAFETY: derive the cached pointer from the mmap region's base via
        # the trait-surface `as_view()`. The widening to MutExternalOrigin
        # matches the PERF-CRITICAL cached-pointer carve-out.
        # The mmap bytes are pinned by the keepalive Arc
        # for this buffer's lifetime — the empty HeapRegion `_region`
        # placeholder owns nothing, so the keepalive is the SOLE lifetime
        # anchor (unlike a heap-owned SAB where `_region` is the anchor).
        var base = region[].as_view()._unsafe_ptr()
        var cached = (base + Int(offset)).unsafe_mut_cast[
            True
        ]().unsafe_origin_cast[MutUntrackedOrigin]()
        var empty_region = HeapRegion(List[UInt8]())
        var region_arc = ArcPointer[HeapRegion](empty_region^)
        var result = SharedAlignedBuffer[HeapRegion].__init_unchecked(
            region=region_arc^,
            ptr=cached,
            offset=0,
            length=length,
        )
        # Install the keepalive cookie (the move-consumed `region` Arc).
        result._mmap_keepalive = region^
        return result^

    @always_inline
    def has_mmap_keepalive(self) -> Bool:
        """True iff this buffer carries an mmap keepalive cookie (i.e. it
        was built by `borrow_mmap_erased` and aliases mmap'd page-cache
        bytes pinned by an `ArcPointer[MmapRegion]`).

        Diagnostic / test surface; the hot read path never branches on it.
        """
        return self._mmap_keepalive.__bool__()

    # -------------------------------------------------------------------------
    # Arc share (zero-copy refcount bump) —
    # -------------------------------------------------------------------------

    def share(self) -> Self:
        """Arc-SHARE this buffer: return a new SharedAlignedBuffer that
        aliases the SAME bytes (`[_offset, _offset+_length)` within the same
        region) with NO byte copy. The `_region` ArcPointer is cloned
        (refcount++), and — critically — the `_mmap_keepalive` cookie is
        cloned too when present, so a zero-copy `borrow_mmap_erased` buffer
        keeps its mapping munmap-pinned for the shared instance's lifetime.

        This is the buffer-level primitive behind `Column.share` /
        `share_batch` (the zero-copy dual of `copy_batch`, which memcpy's
        every buffer). Correctness rests on Arrow buffers being immutable on
        every reader/join/agg consumer path — the same invariant that lets the
        mmap zero-copy decode alias PROT_READ pages across the whole
        Column -> RecordBatch chain.

        MISS-ONE-FIELD is the whole hazard: dropping the `_mmap_keepalive`
        clone would leave an mmap-backed share aliasing bytes that can be
        munmap'd (UAF). Both Arcs are cloned below.

        SAFETY: `_ptr` is copied verbatim (it already points into the shared
        region's bytes at `_offset`); the cloned `_region` Arc keeps those
        bytes alive for the returned buffer's lifetime, exactly as for `self`.
        No raw pointer crosses the public boundary — the returned type is
        `Self`, and `_ptr` is threaded only through the file-private
        `__init_unchecked` static.
        """
        # SAFETY: clone the region Arc (refcount++, no byte copy). `_ptr`
        # aliases the same live bytes; the Arc clone pins them.
        var region_clone = ArcPointer[Self.K](copy=self._region)
        var result = Self.__init_unchecked(
            region=region_clone^,
            ptr=self._ptr,
            offset=self._offset,
            length=self._length,
        )
        # Clone the mmap keepalive cookie if present so the mapping stays
        # munmap-pinned for the shared buffer's lifetime (see docstring).
        if self._mmap_keepalive:
            result._mmap_keepalive = ArcPointer[MmapRegion](
                copy=self._mmap_keepalive.value()
            )
        return result^

    def share_as[K2: MemoryRegion](self) -> SharedAlignedBuffer[K2]:
        """`share()` with an EXPLICIT destination K — the K-rebinding sibling
        of `share`, for holders whose field is `SAB[Self.K]` but whose public
        return type is spelled `SAB[HeapRegion]` (e.g. `Column[K].as_primitive`
        returns `PrimitiveArray[dtype]` == `PrimitiveArray[dtype, HeapRegion]`).

        Same zero-copy semantics as `share`: Arc refcount++ on `_region`, the
        `_mmap_keepalive` cookie cloned when present, NO byte copy. `K2` is
        `constrained` equal to `Self.K`, so the rebind is type-equivalent —
        this is a typechecker bridge, not a region conversion. Mirrors the
        `bridge_oab_to_sab` rebind (SAB is not `ImplicitlyCopyable`, so
        `rebind[SAB[K2]](sab)` is rejected; the inner `ArcPointer` IS, so we
        rebind that and reconstruct field-wise via `__init_unchecked`).
        """
        comptime assert (Self.K == K2), ( "SharedAlignedBuffer.share_as[K2]: K2 must equal Self.K" " (this is a typechecker rebind, not a region conversion)." )
        # SAFETY: clone the region Arc (refcount++, no byte copy) then rebind
        # its K (constrained-equivalent above). `_ptr` aliases the same live
        # bytes; the cloned Arc pins them for the returned buffer's lifetime.
        var region_clone = ArcPointer[Self.K](copy=self._region)
        var out_region = rebind[ArcPointer[K2]](region_clone^)
        var result = SharedAlignedBuffer[K2].__init_unchecked(
            region=out_region^,
            ptr=self._ptr,
            offset=self._offset,
            length=self._length,
        )
        if self._mmap_keepalive:
            result._mmap_keepalive = ArcPointer[MmapRegion](
                copy=self._mmap_keepalive.value()
            )
        return result^

    def share_range_as[
        K2: MemoryRegion
    ](
        self, byte_offset: Int, byte_length: Int
    ) raises -> SharedAlignedBuffer[K2]:
        """`share_as[K2]` NARROWED TO A SUB-RANGE: Arc-share only the bytes
        `[byte_offset, byte_offset + byte_length)` of this buffer's own window,
        with NO byte copy. Refcount++ on `_region`, `_mmap_keepalive` cloned
        when present — identical lifetime semantics to `share_as`, different
        EXTENT.

        ## WHY THIS EXISTS, AND WHY IT IS NOT COSMETIC

        `share_as` hands back a buffer whose `len()` is this buffer's WHOLE
        window, so a holder that wants a sub-window must carry a separate
        offset alongside it and EVERY consumer must then honour that offset.
        This returns a buffer that IS the sub-window — `len() == byte_length` —
        so the holder's offset is 0 and the question "does this reader honour
        the offset?" does not arise for any of them.

        That distinction is load-bearing rather than stylistic, because an
        offset a consumer must honour is not the only thing at stake: a
        DOWNSTREAM copy sized off the wrong extent silently re-materialises the
        prefix. `Column.as_primitive`'s zero-copy arm is the worked example —
        it hands its result to 300+ call sites, two of whose ordinary
        continuations (`Column.from_primitive`, `PrimitiveArray.slice`) copy
        `[0, offset + length)` from byte 0. Handing them an offset-carrying
        whole-buffer share turns a window copy into a PREFIX copy — the exact
        O(n^2) prefix-copy shape, one level
        downstream, with correct values and no crash. A window share cannot
        express that bug: there is no prefix left to copy.

        It also keeps the `load_simd` / `store_simd` bounds check MEANINGFUL.
        Those assert against `_length`; a whole-buffer share widens `_length`
        to the source, so a kernel over-reading past its window stops being
        caught. A window share holds the copy path's bound exactly.

        ## BOUNDS

        `byte_offset` is relative to THIS buffer's window, not to the region —
        the returned buffer's `_offset` is `self._offset + byte_offset`, so
        nesting is well defined. Raises when the requested range is not wholly
        inside `[0, len())`; a silently-clamped share would alias bytes the
        caller did not ask for, which is a memory-safety question and must not
        be a `debug_assert` that folds out of the very optimized builds where the
        window arithmetic is hottest.

        Parameters:
            K2: Destination region type; `constrained` equal to `Self.K` (a
                typechecker rebind, exactly as in `share_as`).

        Args:
            byte_offset: Start of the sub-window, in bytes, relative to this
                buffer's own start.
            byte_length: Length of the sub-window in bytes.

        Returns:
            A SharedAlignedBuffer aliasing exactly that sub-window.
        """
        comptime assert (Self.K == K2), ( "SharedAlignedBuffer.share_range_as[K2]: K2 must equal Self.K" " (this is a typechecker rebind, not a region conversion)." )
        if byte_offset < 0 or byte_length < 0:
            raise Error(
                "SharedAlignedBuffer.share_range_as: negative range"
                " (byte_offset="
                + String(byte_offset)
                + ", byte_length="
                + String(byte_length)
                + ")"
            )
        if byte_offset + byte_length > Int(self._length):
            raise Error(
                "SharedAlignedBuffer.share_range_as: range ["
                + String(byte_offset)
                + ", "
                + String(byte_offset + byte_length)
                + ") exceeds buffer length "
                + String(Int(self._length))
            )
        # SAFETY: the range is inside `[0, _length)` per the two checks above,
        # and `_length` is itself inside the region (construction invariant),
        # so `_ptr + byte_offset` is a live address and the sub-window does not
        # leave the region. The cloned `_region` Arc pins those bytes for the
        # returned buffer's lifetime exactly as `share_as` does; the raw
        # pointer is threaded only through the file-private
        # `__init_unchecked` and never crosses the module boundary.
        var region_clone = ArcPointer[Self.K](copy=self._region)
        var out_region = rebind[ArcPointer[K2]](region_clone^)
        var result = SharedAlignedBuffer[K2].__init_unchecked(
            region=out_region^,
            ptr=self._ptr + byte_offset,
            offset=self._offset + Int64(byte_offset),
            length=Int64(byte_length),
        )
        if self._mmap_keepalive:
            result._mmap_keepalive = ArcPointer[MmapRegion](
                copy=self._mmap_keepalive.value()
            )
        return result^

    @staticmethod
    def from_byte_view[
        K_in: MemoryRegion
    ](
        var region: ArcPointer[K_in],
        view: ByteView[_],
    ) -> SharedAlignedBuffer[K_in]:
        """Construct a SharedAlignedBuffer from an ArcPointer + a
        ByteView slice INTO that region's bytes.

        Used when a caller has BOTH a tracked ArcPointer keepalive AND
        a ByteView slice into the same region's bytes (e.g. a holder
        being constructed inside an Arc-tracking factory, where the
        source view originated from `region[].as_view()...`). The Arc
        IS the keepalive; the ByteView supplies the {ptr, length} pair
        from which the offset is derived.

        The borrowed-view callers (Bitmap.from_borrowed_view,
        PrimitiveArray.from_view, Column.from_borrowed_*) take ONLY a
        ByteView and CANNOT use this ctor without first threading the
        ArcPointer through their own caller (the IPC decoder +
        nested-decoder path).

        Why this is NOT a `from_byte_view(view, length)` lifetime-severing
        shape: the `var region: ArcPointer[K_in]`
        IS the lifetime anchor — the region's bytes are pinned by the
        Arc refcount for the returned buffer's lifetime. The ByteView
        is only used to derive offset + length; its origin is
        irrelevant at the field-store boundary because the Arc owns
        the lifetime. Contrast with a `_borrow_from_view(view, length)`
        with NO Arc keepalive, which severs the source view's lifetime via
        a placeholder empty HeapRegion + wildcard-origin laundering.

        SAFETY (caller responsibilities):
          1. `view._unsafe_ptr()` MUST point inside `region[]`'s bytes.
          2. `view._unsafe_ptr() + view.len()` MUST be `<=
             region[].as_view()._unsafe_ptr() + region[].length()`.
          3. The view's bytes MUST originate from THIS region (not from
             another region's bytes that happen to fall in the same
             address range).
        debug_assert verifies (1) and (2); (3) is the caller's
        contract that the type system cannot enforce.

        Parameters:
            K_in: MemoryRegion conformer of the caller's ArcPointer.
                Inferred from `region`.

        Args:
            region: ArcPointer keepalive. Moved.
            view: ByteView slice into the region's bytes. Origin is
                irrelevant — only the ptr+length are read; the Arc
                refcount in `region` is the lifetime anchor.

        Returns:
            A SharedAlignedBuffer[K_in] whose `_region` clones the
            passed-in Arc, `_ptr` = view's pointer (cast to the
            cached-pointer field type), `_offset` = view's pointer -
            region's base, `_length` = view.len().
        """
        # Derive offset relative to the region's base via Int-coercion
        # pointer subtraction. This is the same pattern used by
        # is_aligned_to() / is_mmap_backed() elsewhere in this file.
        var region_base = region[].as_view()._unsafe_ptr()
        var view_ptr = view._unsafe_ptr()
        var offset_bytes = Int(view_ptr) - Int(region_base)
        var length_bytes = view.len()
        debug_assert(
            offset_bytes >= 0,
            (
                "SharedAlignedBuffer.from_byte_view: view's pointer is"
                " BEFORE region's base (view does not originate from"
                " region)"
            ),
        )
        debug_assert(
            Int64(offset_bytes + length_bytes) <= region[].length(),
            (
                "SharedAlignedBuffer.from_byte_view: view's pointer +"
                " length exceeds region's bounds (view does not"
                " originate from region or extends past region end)"
            ),
        )
        # SAFETY: see contract above. The Arc IS the keepalive. Cache
        # the pointer from the view (already aligned within the
        # region's bytes); widen origin to MutExternalOrigin per the
        # PERF-CRITICAL cached-pointer carve-out. The ArcPointer refcount in `_region` pins the
        # bytes for the buffer's lifetime.
        var cached_ptr = view_ptr.unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        var result = SharedAlignedBuffer[K_in].__init_unchecked(
            region=region^,
            ptr=cached_ptr,
            offset=Int64(offset_bytes),
            length=Int64(length_bytes),
        )
        return result^

    # Field-wise constructor (file-private — used by the static
    # constructors above to avoid re-computing the cached pointer when
    # the caller has already aligned it).
    @staticmethod
    def _field_init(
        var region: ArcPointer[Self.K],
        ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
        offset: Int64,
        length: Int64,
    ) -> Self:
        """File-private: direct field-wise construction with no
        recompute of `_ptr`. SOLE callers: `from_owned`,
        `from_borrowed_view`. NOT public — callers MUST uphold the
        invariant that `ptr == region[].as_view().unsafe_ptr() + offset`
        (or equivalent aligned position within the region's bytes).
        """
        var out = Self.__init_unchecked(
            region=region^, ptr=ptr, offset=offset, length=length
        )
        return out^

    def __init__(
        out self,
        var region: ArcPointer[Self.K],
        ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
        offset: Int64,
        length: Int64,
        unchecked: Bool,
    ):
        """File-private overload — direct field-wise construct with a
        precomputed `ptr`. Sentinel parameter `unchecked` distinguishes
        from the `(region, offset, length)` ctor that computes `_ptr`
        from `region[].as_view()`.
        """
        _ = unchecked  # parameter exists only to disambiguate overload
        self._region = region^
        self._ptr = ptr
        self._offset = offset
        self._length = length
        self._mmap_keepalive = None

    @staticmethod
    def __init_unchecked(
        var region: ArcPointer[Self.K],
        ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
        offset: Int64,
        length: Int64,
    ) -> Self:
        """File-private: build a SharedAlignedBuffer with a
        precomputed cached pointer. Caller MUST guarantee `ptr` points
        inside `region[]`'s bytes at offset `offset` from the region's
        base, and that `offset + length <= region[].length()`.
        """
        return Self(
            region=region^,
            ptr=ptr,
            offset=offset,
            length=length,
            unchecked=True,
        )

    # -------------------------------------------------------------------------
    # MmapAlignedBuffer trait surface
    # -------------------------------------------------------------------------

    def as_view[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Borrow the buffer's bytes as a tracked ByteView whose origin
        is parametrically bound to `self`.

        SAFETY: `_ptr` is live for `_length` bytes as long as `self` is
        alive (the ArcPointer in `_region` keeps the storage pinned).
        Receiver `ref [origin] self` ties the view's origin to self.
        The internal MutExternalOrigin cast is confined to this method
        body and never crosses the module boundary — the public return
        type `ByteView[origin]` is tracked.
        """
        # SAFETY: see method docstring. The receiver `ref [origin] self`
        # keeps `self` (and therefore the ArcPointer ref on _region)
        # alive for the view's lifetime. We flip mutability to match
        # the receiver, then widen origin to the named parameter.
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
    # Realignment
    # -------------------------------------------------------------------------

    def realign_to[align: Int](self) -> SharedAlignedBuffer[HeapRegion]:
        """If `is_aligned_to[align]()` is False, memcpy into a fresh
        aligned HeapRegion. Decoders that materialize Arrow buffer
        arrays from sliced bytes MUST call this.

        IMPORTANT — return-type K is ALWAYS HeapRegion regardless of
        input K. Realignment owns its memcpy'd bytes; the original K's
        lifetime obligation is severed at the memcpy. The return type
        cannot preserve an mmap-backed K because the new bytes are
        freshly heap-allocated. Callers that need to preserve the
        input K (e.g. for downstream zero-copy slice into the same
        mmap region) MUST NOT call realign_to.

        Parameters:
            align: Target alignment (compile-time; must be a power of
                2).

        Returns:
            An owning SharedAlignedBuffer[HeapRegion] with `_length`
            bytes copied from `self` and aligned to `align`.
        """
        var n = Int(self._length)
        # Allocate via OwnedAlignedBuffer (which handles the alignment
        # over-allocation), then promote to Shared.
        var owned = OwnedAlignedBuffer(capacity=n)
        if n > 0:
            # SAFETY: owned._cached_ptr() is valid for owned._capacity
            # >= n bytes; self._ptr is valid for self._length == n
            # bytes. memcpy is bounded by `n`.
            unsafe_memcpy(
                dest=owned._cached_ptr(),
                src=self._ptr,
                count=n,
            )
        owned.set_length(Int64(n))
        _ = align  # consumed by the comptime-monomorphic specialization
        return SharedAlignedBuffer[HeapRegion].from_owned(owned^)

    @always_inline
    def is_aligned_to[align: Int](self) -> Bool:
        """True iff the cached `_ptr` is aligned to `align` bytes.

        Parameters:
            align: The target alignment to check against (compile-time).
        """
        if Int(self._ptr) == 0:
            # null cached pointer (empty buffer) — vacuously aligned.
            return True
        return Int(self._ptr) % align == 0

    @always_inline
    def is_mmap_backed(self) -> Bool:
        """True iff this buffer aliases mmap'd page-cache bytes (zero-copy).

        Two provenance shapes count as mmap-backed:
          1. K = MmapRegion (comptime-determined) — the direct
             `borrow_from_mmap` path. Mirror of OLD
             `MmapAlignedBuffer.is_mmap_backed`.
          2. K = HeapRegion carrying an mmap keepalive cookie — the
             type-erased zero-copy path built by `borrow_mmap_erased`
.
             The `_region` is an empty HeapRegion placeholder (owns
             nothing); the bytes alias the mmap region and the mapping
             is pinned by `_mmap_keepalive`. This is still zero-copy
             mmap-backed provenance — the K-erasure to HeapRegion is a
             storage-typing bridge for `Slab[Column[HeapRegion]]`, NOT a
             copy. Without this arm, the keepalive-cookie path would
             mis-report as a heap-owning buffer (the bytes were never
             memcpy'd off the mapping).
        """
        return (Self.K == MmapRegion) or self.has_mmap_keepalive()

    @always_inline
    def is_owned(self) -> Bool:
        """True iff K = HeapRegion AND the buffer holds non-empty
        bytes AND it does NOT carry an mmap keepalive cookie (i.e. this
        is a genuinely owning heap-backed buffer, not a
        default-constructed placeholder NOR a zero-copy mmap-aliasing
        buffer built by `borrow_mmap_erased`).

        Mirror of `MmapAlignedBuffer.is_owned` — but SharedAlignedBuffer
        has no separate `_capacity` field; the distinguishing signal is
        `_length > 0` AND `K == HeapRegion`. Borrowed-by-Arc buffers
        (K=HeapRegion with bytes shared via from_borrowed_view) are
        ALSO `is_owned() == True` because they own a refcounted share
        of the HeapRegion; only K=MmapRegion buffers AND keepalive-cookie
        mmap-aliasing buffers are non-owning in the OLD sense.
        """
        return (
            (Self.K == HeapRegion)
            and self._length > 0
            and not self.has_mmap_keepalive()
        )

    @always_inline
    def is_aligned(self) -> Bool:
        """Verify the cached `_ptr` is aligned to `_SHARED_ALIGN` bytes
        (the OLD struct's `Self.ALIGN` default of 64). Mirror of OLD
        `MmapAlignedBuffer.is_aligned`.
        """
        if self._length == 0 and Int(self._ptr) == 0:
            return True
        return Int(self._ptr) % _SHARED_ALIGN == 0

    @always_inline
    def cap(self) -> Int:
        """Byte capacity = byte length for shared buffers (no separate
        `_capacity` field). Mirror of `MmapAlignedBuffer.cap` — for
        SharedAlignedBuffer the "capacity" is exactly `_length` (shared
        buffers expose only the bytes their length claims).
        """
        return Int(self._length)

    @always_inline
    def capacity(self) -> Int:
        """Alias for `cap()`. Mirror of OwnedAlignedBuffer.capacity
        for callers that use the Arrow-builder vocabulary.
        """
        return Int(self._length)

    # -------------------------------------------------------------------------
    # Mutation: length / lifecycle
    # -------------------------------------------------------------------------

    def set_length(mut self, new_length: Int64):
        """Set the logical byte length.

        Mirror of `MmapAlignedBuffer.set_length`. For SharedAlignedBuffer,
        `new_length` must be `<= self._length` (the shared bytes already
        committed at construction) OR equal to the underlying region's
        length — there is no separate `_capacity` field to grow into.
        For grow-the-buffer semantics, route through `reserve` first.

        Args:
            new_length: New logical byte length.
        """
        debug_assert(
            new_length >= 0,
            "SharedAlignedBuffer.set_length: negative length",
        )
        self._length = new_length

    def set_length(mut self, new_length: Int):
        """Int overload of `set_length(Int64)` for source-compat with the
        OLD struct's `set_length(Int)` shape.

        Args:
            new_length: New logical byte length.
        """
        debug_assert(
            new_length >= 0,
            "SharedAlignedBuffer.set_length: negative length",
        )
        self._length = Int64(new_length)

    def zero(mut self):
        """Zero all `_length` bytes of usable storage. Mirror of OLD
        `MmapAlignedBuffer.zero` — but constrained: SharedAlignedBuffer's
        bytes may be shared across N Arc refs; zeroing affects ALL
        sharers. The OLD struct made `zero` length-or-capacity-wide;
        we zero exactly `_length` bytes (the only ones the caller
        controls).

        SAFETY: writes through `_ptr` for `_length` bytes. If K =
        MmapRegion the mapping must be writable (PROT_WRITE); typical
        mmap-borrows are PROT_READ and will SIGBUS — debug callers
        gate this off `is_mmap_backed()` themselves.
        """
        if self._length > 0:
            unsafe_memset(self._ptr, 0, Int(self._length))

    def reserve(mut self, min_size: Int):
        """Ensure the buffer has at least `min_size` usable bytes.
        Constrained to K = HeapRegion (mmap regions are kernel-managed
        and cannot grow).

        Mirror of `MmapAlignedBuffer.reserve` — re-allocates a fresh
        HeapRegion-backed Arc if `min_size > self._length`. NOTE: on a
        shared buffer with refcount > 1, this re-allocation drops
        THIS instance's view onto the prior bytes (the prior Arc ref
        decrements when `self._region` is reassigned); OTHER sharers
        retain their refcounted view of the original bytes via their
        own Arc refs. This matches "reserve is a pre-share-or-unique-
        owner operation" semantics.

        Args:
            min_size: Minimum usable bytes after this call.
        """
        comptime assert (Self.K == HeapRegion), ( "SharedAlignedBuffer.reserve(min_size): grow path" " requires K=HeapRegion (K=MmapRegion is kernel-managed" " and cannot grow)." )
        if min_size <= Int(self._length):
            return
        # Re-allocate via OwnedAlignedBuffer (handles alignment over-
        # allocation), then promote to a fresh Arc and rebind.
        var fresh_owned = OwnedAlignedBuffer(capacity=min_size)
        fresh_owned.set_length(Int64(min_size))
        var fresh_shared = SharedAlignedBuffer[HeapRegion].from_owned(
            fresh_owned^
        )
        # Move the freshly-built buffer's state into self. Mojo doesn't
        # have a direct `self = other` re-init, so we swap into self
        # field-by-field — the prior `_region` Arc ref drops here.
        var new_region = rebind[ArcPointer[Self.K]](fresh_shared._region^)
        self._region = new_region^
        self._ptr = fresh_shared._ptr
        self._offset = fresh_shared._offset
        self._length = fresh_shared._length
        # Re-allocation severs any prior mmap borrow: the bytes now live in
        # the fresh HeapRegion, so drop the mmap keepalive (Arc decrement).
        self._mmap_keepalive = None

    def free(mut self):
        """Explicit release: drop the Arc ref to the underlying region,
        replace with an empty HeapRegion placeholder. Mirror of OLD
        `MmapAlignedBuffer.free` — constrained to K = HeapRegion.

        On last-ref the HeapRegion's List drop fires (heap bytes
        freed). If other Arc refs exist, the underlying bytes survive;
        only THIS instance's view is cleared.
        """
        comptime assert (Self.K == HeapRegion), ( "SharedAlignedBuffer.free(): explicit release requires" " K=HeapRegion (K=MmapRegion buffers drop via Arc decay)." )
        var empty_region = HeapRegion(List[UInt8]())
        var arc_heap = ArcPointer[HeapRegion](empty_region^)
        self._region = rebind[ArcPointer[Self.K]](arc_heap^)
        self._ptr = _null_ptr[UInt8, MutUntrackedOrigin]()
        self._offset = 0
        self._length = 0
        # Explicit release also drops any mmap keepalive (Arc decrement;
        # last ref triggers munmap).
        self._mmap_keepalive = None

    # -------------------------------------------------------------------------
    # Byte read methods (typed, byte-offset addressed)
    # -------------------------------------------------------------------------

    @always_inline
    def read_u8_at(self, offset: Int) -> UInt8:
        """Read a UInt8 at `offset`. PANICS if offset+1 > length."""
        debug_assert(
            offset >= 0 and offset + 1 <= Int(self._length),
            "SharedAlignedBuffer.read_u8_at: offset+1 > length",
        )
        return (self._ptr + offset)[]

    @always_inline
    def read_u16_le_at(self, offset: Int) -> UInt16:
        """Read a little-endian UInt16 at `offset`. PANICS if offset+2 > length."""
        debug_assert(
            offset >= 0 and offset + 2 <= Int(self._length),
            "SharedAlignedBuffer.read_u16_le_at: offset+2 > length",
        )
        return (self._ptr + offset).bitcast[UInt16]().load[alignment=1]()

    @always_inline
    def read_u32_le_at(self, offset: Int) -> UInt32:
        """Read a little-endian UInt32 at `offset`. PANICS if offset+4 > length."""
        debug_assert(
            offset >= 0 and offset + 4 <= Int(self._length),
            "SharedAlignedBuffer.read_u32_le_at: offset+4 > length",
        )
        return (self._ptr + offset).bitcast[UInt32]().load[alignment=1]()

    @always_inline
    def read_u64_le_at(self, offset: Int) -> UInt64:
        """Read a little-endian UInt64 at `offset`. PANICS if offset+8 > length."""
        debug_assert(
            offset >= 0 and offset + 8 <= Int(self._length),
            "SharedAlignedBuffer.read_u64_le_at: offset+8 > length",
        )
        return (self._ptr + offset).bitcast[UInt64]().load[alignment=1]()

    @always_inline
    def read_i32_le_at(self, offset: Int) -> Int32:
        """Read a little-endian Int32 at `offset`. PANICS if offset+4 > length."""
        debug_assert(
            offset >= 0 and offset + 4 <= Int(self._length),
            "SharedAlignedBuffer.read_i32_le_at: offset+4 > length",
        )
        return (self._ptr + offset).bitcast[Int32]().load[alignment=1]()

    @always_inline
    def read_i64_le_at(self, offset: Int) -> Int64:
        """Read a little-endian Int64 at `offset`. PANICS if offset+8 > length."""
        debug_assert(
            offset >= 0 and offset + 8 <= Int(self._length),
            "SharedAlignedBuffer.read_i64_le_at: offset+8 > length",
        )
        return (self._ptr + offset).bitcast[Int64]().load[alignment=1]()

    @always_inline
    def read_f32_le_at(self, offset: Int) -> Float32:
        """Read a little-endian Float32 at `offset`. PANICS if offset+4 > length."""
        debug_assert(
            offset >= 0 and offset + 4 <= Int(self._length),
            "SharedAlignedBuffer.read_f32_le_at: offset+4 > length",
        )
        return (self._ptr + offset).bitcast[Float32]().load[alignment=1]()

    @always_inline
    def read_f64_le_at(self, offset: Int) -> Float64:
        """Read a little-endian Float64 at `offset`. PANICS if offset+8 > length."""
        debug_assert(
            offset >= 0 and offset + 8 <= Int(self._length),
            "SharedAlignedBuffer.read_f64_le_at: offset+8 > length",
        )
        return (self._ptr + offset).bitcast[Float64]().load[alignment=1]()

    @always_inline
    def read_i128_le_at(self, offset: Int) -> SIMD[DType.int128, 1]:
        """Read a little-endian 128-bit signed int at `offset`. PANICS if offset+16 > length.
        """
        debug_assert(
            offset >= 0 and offset + 16 <= Int(self._length),
            "SharedAlignedBuffer.read_i128_le_at: offset+16 > length",
        )
        return (self._ptr + offset).bitcast[SIMD[DType.int128, 1]]().load[
            alignment=1
        ]()

    @always_inline
    def read_i256_le_at(self, offset: Int) -> SIMD[DType.int256, 1]:
        """Read a little-endian 256-bit signed int at `offset`. PANICS if offset+32 > length.
        """
        debug_assert(
            offset >= 0 and offset + 32 <= Int(self._length),
            "SharedAlignedBuffer.read_i256_le_at: offset+32 > length",
        )
        return (self._ptr + offset).bitcast[SIMD[DType.int256, 1]]().load[
            alignment=1
        ]()

    # -------------------------------------------------------------------------
    # Byte write methods (typed, byte-offset addressed)
    # -------------------------------------------------------------------------

    @always_inline
    def write_u8_at(mut self, offset: Int, val: UInt8):
        """Store a UInt8 at `offset`. PANICS if offset+1 > length."""
        debug_assert(
            offset >= 0 and offset + 1 <= Int(self._length),
            "SharedAlignedBuffer.write_u8_at: offset+1 > length",
        )
        (self._ptr + offset)[] = val

    @always_inline
    def write_u16_le_at(mut self, offset: Int, val: UInt16):
        """Store a little-endian UInt16 at `offset`. PANICS if offset+2 > length."""
        debug_assert(
            offset >= 0 and offset + 2 <= Int(self._length),
            "SharedAlignedBuffer.write_u16_le_at: offset+2 > length",
        )
        (self._ptr + offset).bitcast[UInt16]().store[alignment=1](val)

    @always_inline
    def write_u32_le_at(mut self, offset: Int, val: UInt32):
        """Store a little-endian UInt32 at `offset`. PANICS if offset+4 > length."""
        debug_assert(
            offset >= 0 and offset + 4 <= Int(self._length),
            "SharedAlignedBuffer.write_u32_le_at: offset+4 > length",
        )
        (self._ptr + offset).bitcast[UInt32]().store[alignment=1](val)

    @always_inline
    def write_u64_le_at(mut self, offset: Int, val: UInt64):
        """Store a little-endian UInt64 at `offset`. PANICS if offset+8 > length."""
        debug_assert(
            offset >= 0 and offset + 8 <= Int(self._length),
            "SharedAlignedBuffer.write_u64_le_at: offset+8 > length",
        )
        (self._ptr + offset).bitcast[UInt64]().store[alignment=1](val)

    @always_inline
    def write_i32_le_at(mut self, offset: Int, val: Int32):
        """Store a little-endian Int32 at `offset`. PANICS if offset+4 > length."""
        debug_assert(
            offset >= 0 and offset + 4 <= Int(self._length),
            "SharedAlignedBuffer.write_i32_le_at: offset+4 > length",
        )
        (self._ptr + offset).bitcast[Int32]().store[alignment=1](val)

    @always_inline
    def write_i64_le_at(mut self, offset: Int, val: Int64):
        """Store a little-endian Int64 at `offset`. PANICS if offset+8 > length."""
        debug_assert(
            offset >= 0 and offset + 8 <= Int(self._length),
            "SharedAlignedBuffer.write_i64_le_at: offset+8 > length",
        )
        (self._ptr + offset).bitcast[Int64]().store[alignment=1](val)

    @always_inline
    def write_f32_le_at(mut self, offset: Int, val: Float32):
        """Store a little-endian Float32 at `offset`. PANICS if offset+4 > length."""
        debug_assert(
            offset >= 0 and offset + 4 <= Int(self._length),
            "SharedAlignedBuffer.write_f32_le_at: offset+4 > length",
        )
        (self._ptr + offset).bitcast[Float32]().store[alignment=1](val)

    @always_inline
    def write_f64_le_at(mut self, offset: Int, val: Float64):
        """Store a little-endian Float64 at `offset`. PANICS if offset+8 > length."""
        debug_assert(
            offset >= 0 and offset + 8 <= Int(self._length),
            "SharedAlignedBuffer.write_f64_le_at: offset+8 > length",
        )
        (self._ptr + offset).bitcast[Float64]().store[alignment=1](val)

    @always_inline
    def write_i128_le_at(
        mut self, offset: Int, val: SIMD[DType.int128, 1]
    ):
        """Store a little-endian 128-bit signed int at `offset`. PANICS if offset+16 > length.
        """
        debug_assert(
            offset >= 0 and offset + 16 <= Int(self._length),
            "SharedAlignedBuffer.write_i128_le_at: offset+16 > length",
        )
        (self._ptr + offset).bitcast[SIMD[DType.int128, 1]]().store[
            alignment=1
        ](val)

    @always_inline
    def write_i256_le_at(
        mut self, offset: Int, val: SIMD[DType.int256, 1]
    ):
        """Store a little-endian 256-bit signed int at `offset`. PANICS if offset+32 > length.
        """
        debug_assert(
            offset >= 0 and offset + 32 <= Int(self._length),
            "SharedAlignedBuffer.write_i256_le_at: offset+32 > length",
        )
        (self._ptr + offset).bitcast[SIMD[DType.int256, 1]]().store[
            alignment=1
        ](val)

    # -------------------------------------------------------------------------
    # Bulk views (parameterized-origin pattern; mirror of OLD struct's
    # view_ro / view_mut / view_range_ro / view_range_mut). These are
    # additive on top of the trait-surface `as_view`; existing OLD-struct
    # callers using `view_ro` etc. can compile against SharedAlignedBuffer
    # without changing the call site.
    # -------------------------------------------------------------------------

    @always_inline
    def view_ro[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Return an immutable byte-view over `[0, self._length)`. Mirror
        of `MmapAlignedBuffer.view_ro` — same behavior; just routes
        through SharedAlignedBuffer's `_ptr` + `_length`.

        SAFETY: `_ptr` is alive while `self` is alive (the ArcPointer
        in `_region` keeps the storage pinned).
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
        of `MmapAlignedBuffer.view_mut`.

        SAFETY: caller's mutable borrow on `self` is enforced by
        `ref [origin] self` with `origin: Origin[mut=True]`.
        """
        var ptr = self._ptr.unsafe_origin_cast[origin]()
        return ByteView[origin](ptr, Int(self._length))

    @always_inline
    def view_range_ro[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self, start: Int, length: Int) -> ByteView[origin]:
        """Return an immutable sub-view over `[start, start+length)`.
        PANICS if start+length > self._length or start < 0.
        """
        debug_assert(
            start >= 0 and start + length <= Int(self._length),
            "SharedAlignedBuffer.view_range_ro: start+length > self._length",
        )
        var ptr = (self._ptr + start).unsafe_mut_cast[
            _mut
        ]().unsafe_origin_cast[origin]()
        return ByteView[origin](ptr, length)

    @always_inline
    def view_range_mut[
        origin: Origin[mut=True], //,
    ](ref [origin] self, start: Int, length: Int) -> ByteView[origin]:
        """Return a mutable sub-view over `[start, start+length)`.
        PANICS if start+length > self._length or start < 0.
        """
        debug_assert(
            start >= 0 and start + length <= Int(self._length),
            "SharedAlignedBuffer.view_range_mut: start+length > self._length",
        )
        var ptr = (self._ptr + start).unsafe_origin_cast[origin]()
        return ByteView[origin](ptr, length)

    # --- Origin-tied typed pointers ---
    # A single body with one origin binding is required: the 2-line
    # view_ro + bitcast form severs the lifetime chain under AOT, manifesting
    # as a use-after-free.

    @always_inline
    def view_typed_ro[
        _mut: Bool,
        o: Origin[mut=_mut],
        //,
        T: DType,
    ](ref [o] self) -> UnsafePointer[Scalar[T], o]:
        """Return a read-only typed pointer with origin tied to `self`.

        Pointer's liveness statically tracked against `self` via `o`.
        Use instead of `var v = buf.view_ro(); var p = v._unsafe_ptr().bitcast[Scalar[T]]()`
        (which loses the origin tie and can dangle under AOT).

        `T` is positional/explicit; `_mut` + `o` are inferred from the
        receiver borrow (Mojo 1.0.0b1: inferred precede `//`, explicit
        follow).

        SAFETY: `_ptr` is alive while `self` is alive (ArcPointer in
        `_region` keeps storage pinned).
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
        """Return a mutable typed pointer with origin tied to `self`.

        Receiver `ref [o] self` with `o: Origin[mut=True]` enforces a
        mutable borrow of `self`. Pointer lifetime tracked by `o`.
        `T` is positional/explicit; `o` is inferred.
        """
        var ptr = self._ptr.unsafe_origin_cast[o]()
        return ptr.bitcast[Scalar[T]]()

    @always_inline
    def into_span_capacity[
        origin: Origin[mut=True], //,
    ](ref [origin] self) -> Span[Byte, origin]:
        """Return a `Span[Byte, origin]` over the buffer's full extent
        (`[0, self._length)`). Mirror of `MmapAlignedBuffer.into_span_capacity`
        — but SharedAlignedBuffer has no separate `_capacity`, so the
        span is sized to `_length`.

        SAFETY: span lifetime tracked by `origin`.
        """
        var ptr = self._ptr.unsafe_origin_cast[origin]()
        return Span[Byte, origin](unsafe_ptr=ptr, length=Int(self._length))

    # -------------------------------------------------------------------------
    # Typed element access (element-index addressed)
    # -------------------------------------------------------------------------

    @always_inline
    def get_typed[
        T: TrivialRegisterPassable & Copyable
    ](self, index: Int) -> T:
        """Return the T at element-index `index` (byte-offset = index *
        size_of[T]()). PANICS if (index + 1) * size_of[T]() > length.
        """
        comptime sz = size_of[T]()
        debug_assert(
            index >= 0 and (index + 1) * sz <= Int(self._length),
            "SharedAlignedBuffer.get_typed: element index out of range",
        )
        return (self._ptr + index * sz).bitcast[T]()[]

    @always_inline
    def set_typed[
        T: TrivialRegisterPassable & Copyable
    ](mut self, index: Int, val: T):
        """Store the T at element-index `index` (byte-offset = index *
        size_of[T]()). PANICS if (index + 1) * size_of[T]() > length.
        """
        comptime sz = size_of[T]()
        debug_assert(
            index >= 0 and (index + 1) * sz <= Int(self._length),
            "SharedAlignedBuffer.set_typed: element index out of range",
        )
        (self._ptr + index * sz).bitcast[T]()[] = val

    # -------------------------------------------------------------------------
    # SIMD bulk access
    # -------------------------------------------------------------------------

    @always_inline
    def load_simd[
        T: DType, width: Int
    ](self, byte_offset: Int) -> SIMD[T, width]:
        """Load `width` lanes of `T` starting at `byte_offset`. PANICS if
        byte_offset + width*size_of[T]() > length.
        """
        comptime lane_bytes = size_of[T]() * width
        debug_assert(
            byte_offset >= 0
            and byte_offset + lane_bytes <= Int(self._length),
            "SharedAlignedBuffer.load_simd: byte_offset+lanes > length",
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
        """Store `width` lanes of `T` starting at `byte_offset`. PANICS if
        byte_offset + width*size_of[T]() > length.
        """
        comptime lane_bytes = size_of[T]() * width
        debug_assert(
            byte_offset >= 0
            and byte_offset + lane_bytes <= Int(self._length),
            "SharedAlignedBuffer.store_simd: byte_offset+lanes > length",
        )
        (self._ptr + byte_offset).bitcast[Scalar[T]]().store[alignment=1](
            val
        )

    # -------------------------------------------------------------------------
    # Bulk copy ops (mirror of OLD MmapAlignedBuffer.copy_from_*)
    # -------------------------------------------------------------------------

    def copy_from_view(mut self, src: ByteView[_]):
        """Copy `src.len()` bytes from `src` into this buffer starting at
        offset 0. Updates `_length` to `src.len()`. Mirror of OLD
        `MmapAlignedBuffer.copy_from_view`.

        NOTE: SharedAlignedBuffer has no separate `_capacity`; the bound
        is `self._length`. Callers must size the buffer (via `reserve`
        or initial allocation) BEFORE this call.
        """
        var count = src.len()
        debug_assert(
            count <= Int(self._length),
            "SharedAlignedBuffer.copy_from_view: src.len > self._length",
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
        # Note: OLD struct updated _length here, but for SharedAlignedBuffer
        # the buffer is already sized; reassigning to a smaller _length
        # would truncate. Match OLD semantics for source-compat.
        self._length = Int64(count)

    @always_inline
    def copy_from_view_at(mut self, dst_offset: Int, src: ByteView[_]):
        """Bulk memcpy: copy `src.len()` bytes from `src` into `self` at
        `dst_offset`. Does NOT update `_length`. Mirror of OLD
        `MmapAlignedBuffer.copy_from_view_at`.
        """
        var count = src.len()
        debug_assert(
            dst_offset >= 0 and dst_offset + count <= Int(self._length),
            (
                "SharedAlignedBuffer.copy_from_view_at: dst_offset+src.len"
                " > self._length"
            ),
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
    def copy_from_int32_list(mut self, src: List[Int32]):
        """Bulk memcpy `len(src)` Int32 elements from `src` into this
        buffer. Does NOT update `_length`. Mirror of OLD
        `MmapAlignedBuffer.copy_from_int32_list`.
        """
        var count = len(src)
        var bytes = count * 4
        debug_assert(
            bytes <= Int(self._length),
            (
                "SharedAlignedBuffer.copy_from_int32_list: src bytes"
                " > self._length"
            ),
        )
        if count > 0:
            unsafe_memcpy(
                dest=self._ptr,
                src=src.unsafe_ptr().bitcast[UInt8](),
                count=bytes,
            )

    @always_inline
    def copy_from_bytes_list(mut self, src: List[UInt8]):
        """Bulk memcpy: copy `len(src)` bytes from `src` into this
        buffer. Updates `_length` = len(src). Mirror of OLD
        `MmapAlignedBuffer.copy_from_bytes_list`.
        """
        var count = len(src)
        debug_assert(
            count <= Int(self._length),
            (
                "SharedAlignedBuffer.copy_from_bytes_list: src.len"
                " > self._length"
            ),
        )
        if count > 0:
            unsafe_memcpy(
                dest=self._ptr,
                src=src.unsafe_ptr(),
                count=count,
            )
        self._length = Int64(count)

    @always_inline
    def copy_from_span_at(
        mut self, dst_offset: Int, src: Span[UInt8, _]
    ):
        """Bulk memcpy: copy `len(src)` bytes from `src` into this
        buffer at `dst_offset`. Does NOT update `_length`. Mirror of OLD
        `MmapAlignedBuffer.copy_from_span_at`.
        """
        var count = len(src)
        debug_assert(
            dst_offset >= 0 and dst_offset + count <= Int(self._length),
            (
                "SharedAlignedBuffer.copy_from_span_at: dst_offset+src.len"
                " > self._length"
            ),
        )
        if count > 0:
            unsafe_memcpy(
                dest=self._ptr + dst_offset,
                src=src.unsafe_ptr(),
                count=count,
            )

    @always_inline
    def copy_from_bytes_list_at(
        mut self, dst_offset: Int, src: List[UInt8]
    ):
        """Bulk memcpy: copy `len(src)` bytes from `src` into this
        buffer at `dst_offset`. Does NOT update `_length`. Mirror of OLD
        `MmapAlignedBuffer.copy_from_bytes_list_at`.
        """
        var count = len(src)
        debug_assert(
            dst_offset >= 0 and dst_offset + count <= Int(self._length),
            (
                "SharedAlignedBuffer.copy_from_bytes_list_at: dst_offset+"
                "src.len > self._length"
            ),
        )
        if count > 0:
            unsafe_memcpy(
                dest=self._ptr + dst_offset,
                src=src.unsafe_ptr(),
                count=count,
            )

    @always_inline
    def copy_from_aligned_buffer_at[
        src_K: MemoryRegion, //,
    ](
        mut self,
        dst_offset: Int,
        src: SharedAlignedBuffer[src_K],
        src_offset: Int,
        count: Int,
    ):
        """Bulk memcpy from `src[src_offset:src_offset+count)` into
        `self[dst_offset:dst_offset+count)`. Mirror of OLD
        `MmapAlignedBuffer.copy_from_aligned_buffer_at` — adapted to take
        another `SharedAlignedBuffer[src_K]` instead of the OLD
        `MmapAlignedBuffer[src_alignment, src_K]`.

        Parameters:
            src_K: MemoryRegion conformer of the source buffer's
                Arc'd storage (inferred). Byte-granular memcpy is
                K-agnostic — the bytes are alive as long as `src` is
                borrowed for the call.
        """
        debug_assert(
            dst_offset >= 0 and dst_offset + count <= Int(self._length),
            (
                "SharedAlignedBuffer.copy_from_aligned_buffer_at:"
                " dst_offset+count > self._length"
            ),
        )
        debug_assert(
            src_offset >= 0 and src_offset + count <= Int(src._length),
            (
                "SharedAlignedBuffer.copy_from_aligned_buffer_at:"
                " src_offset+count > src._length"
            ),
        )
        if count > 0:
            unsafe_memcpy(
                dest=self._ptr + dst_offset,
                src=src._ptr + src_offset,
                count=count,
            )

    # __del__ inherited from Deinitable. The synthesized
    # destructor drops `_region: ArcPointer[K]` (refcount decrement;
    # on last-ref the underlying K is dropped, which fires munmap for
    # K=MmapRegion or List drop for K=HeapRegion).
