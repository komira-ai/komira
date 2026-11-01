# =============================================================================
# heap_region.mojo — HeapRegion: owned `List[UInt8]` MemoryRegion conformer.
#
# HeapRegion is the canonical default `MemoryRegion` conformer for cloud
# / non-mmap paths. Cloud FS conformers (S3Fs / GcsFs / AzureFs) drop
# response-body bytes from one ranged GET into a HeapRegion; bytes are
# freed when this region's ArcPointer ref count hits zero. Mirror
# conformer to `MmapRegion` (file-backed mappings) — both satisfy the
# same `MemoryRegion` trait surface so `MmapAlignedBuffer[ALIGN, K]` can
# parameterize on either substrate without code duplication.
#
# Trait sig: `memory_region.mojo`. Sibling conformer (mmap-backed):
# `mmap_region.mojo`.
#
# Encapsulation rule (no raw pointer in a public surface, no wildcard origin):
#   The public `as_view` trait surface returns `ByteView[origin]` —
#   concrete origin, lifetime-bound to the receiver `self`. The
#   wildcard `unsafe_origin_cast` is private to the trait method body;
#   it does NOT cross the module boundary. Same pattern as
#   `MmapRegion.data()` in `mmap_region.mojo`.
# =============================================================================

from std.memory import UnsafePointer

from komira_buffer.byte_view import ByteView
from komira_buffer.memory_region import MemoryRegion


struct HeapRegion(MemoryRegion, Movable):
    """Heap-owned byte buffer. Used by cloud FS conformers (S3Fs / GcsFs
    / AzureFs) for the response-body bytes of one ranged GET.

    Bytes are owned by the inner `List[UInt8]` and freed when this
    region's explicit `__deinit__` fires (see the `__deinit__` body for why the
    destructor is declared explicitly rather than synthesized — it is a
    load-bearing lifetime anchor for the `ArcPointer[HeapRegion]` drop).
    Typically wrapped in an `ArcPointer[HeapRegion]` so multiple
    `MmapAlignedBuffer` slices over the same merged-group bytes share one
    owning region; the underlying List lives until the last slice drops.

    Conforms to `MemoryRegion` — sibling shape to `MmapRegion` (which
    backs file-backed `MAP_PRIVATE+PROT_READ` mappings). Both
    conformers expose the same `length()` + `as_view()` trait surface,
    so `MmapAlignedBuffer[ALIGN, K]` is K-parametric over either substrate.

    Examples:

    ```mojo
    var bytes = List[UInt8](capacity=4096)
    # ... populate bytes from HTTP response body ...
    var region = HeapRegion(bytes^)
    var view = region.as_view()
    # use view.len() / view.read_*_at(...) ...
    # region drops at end of scope -> List drops -> bytes freed.
    ```
    """

    var _bytes: List[UInt8]

    # -------------------------------------------------------------------------
    # Construction
    # -------------------------------------------------------------------------

    def __init__(out self, var bytes: List[UInt8]):
        """Construct from an owned `List[UInt8]`.

        The caller transfers ownership of `bytes` to this region; the
        region's explicit `__deinit__` runs the List drop.

        Args:
            bytes: The owned byte buffer to wrap.
        """
        self._bytes = bytes^

    @staticmethod
    def with_capacity(cap: Int) -> Self:
        """Construct an empty `HeapRegion` with `cap` bytes reserved.

        The region's length is 0; bytes can be appended via the inner
        `List` until the desired length is reached and then the region
        handed to consumers. Typically used by the HTTP body collector
        to pre-size the buffer to the Content-Length.

        Args:
            cap: Capacity to reserve in the underlying List.
        """
        return Self(List[UInt8](capacity=cap))

    # -------------------------------------------------------------------------
    # MemoryRegion trait surface
    # -------------------------------------------------------------------------

    def length(self) -> Int64:
        """Byte length of the region (matches the inner List length).

        Trait-method override. Mirror of `MmapRegion.length(self) -> Int64`
        in `mmap_region.mojo`.
        """
        return Int64(self._bytes.__len__())

    def as_view[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Borrow the region's bytes as a tracked `ByteView` whose origin
        is parametrically bound to `self`.

        Mirrors the `MmapRegion.data()` shape in `mmap_region.mojo`
        byte-for-byte — same trailing `//`
        separator, same `ref [origin] self` receiver, same
        `unsafe_mut_cast[_mut]().unsafe_origin_cast[origin]()` body
        pattern — only the pointer source differs (List's data pointer
        here vs mmap's `_addr` field there).

        Borrow checker enforces:
            * ByteView dropped before HeapRegion (the underlying List
              outlives the view).
            * No `as_view()` call mutates the region.

        Parameters:
            _mut: Whether the view permits mutation (inferred from
                `origin`).
            origin: The origin the returned view is tied to. Bound to
                the receiver's origin via `ref [origin] self`.

        SAFETY: `_bytes.unsafe_ptr()` is alive for `_bytes.__len__()`
        bytes until `__deinit__` fires (List<UInt8> drop). The receiver
        `ref [origin] self` keeps `self` (and therefore the List, and
        therefore its data buffer) alive for the view's origin
        lifetime. Same pattern as `MmapRegion.data()` in
        `mmap_region.mojo`. The wildcard `unsafe_origin_cast`
        is confined to this single method body and never crosses the
        module boundary — the public return type `ByteView[origin]` is
        tracked. List does not realloc while `self` is borrowed (we
        return a view; we do not mutate `_bytes`).
        """
        # SAFETY: see method docstring. The receiver `ref [origin] self`
        # ties the view's origin to self; the pointer is unchanged
        # through the cast — we first flip mutability to match the
        # receiver's `_mut`, then widen origin to the named parameter.
        var ptr = self._bytes.unsafe_ptr().unsafe_mut_cast[_mut](
        ).unsafe_origin_cast[origin]()
        return ByteView[origin](ptr, self._bytes.__len__())

    # HeapRegion declares an EXPLICIT `__deinit__` rather than inheriting
    # the synthesized `Deinitable` destructor.
    #
    # Why: `HeapRegion` is the payload of `ArcPointer[HeapRegion]`, which
    # backs `Column._data._region` for every SNAPPY-decompressed parquet
    # read region. An earlier Mojo compiler lost the lifetime/origin chain
    # from the Arc control-block drop down to the inner `List[UInt8]` free
    # when several `Slab[Column]` owners shared one region, so the same
    # heap buffer was freed twice (tcmalloc free-list corruption at
    # teardown). An explicit `__deinit__` gives the compiler a concrete
    # destructor anchor it CAN track through the ArcPointer drop, which
    # restores correct ASAP-destruction ordering and the single-free-per-
    # region invariant.
    #
    # ⚠ THIS DESTRUCTOR HAS NO FALSIFIER. The current compiler tracks the
    # synthesized destructor correctly, so reverting it does not crash; a
    # deliberately injected double free of this buffer DOES crash, so the
    # teardown path is exercised. The explicit destructor is kept because it
    # is behaviourally identical to the synthesized one (see SAFETY below),
    # costs nothing, and guards against a compiler that regresses the same
    # way. Do not add a test claiming to guard it, and do not cite it as an
    # example of a guarded fix.
    #
    # SAFETY: this is a pure ownership destructor — no raw pointer logic.
    # The inner `_bytes` (List[UInt8]) drops at this method's scope exit
    # (`deinit self` semantics: the body runs, then field destructors fire),
    # which frees the heap buffer exactly once. Behaviourally identical to
    # the synthesized destructor; the difference is purely that an explicit
    # destructor is a tracked anchor for the compiler's liveness analysis.
    def __deinit__(deinit self):
        pass
