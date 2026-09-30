# =============================================================================
# memory_region.mojo — MemoryRegion trait: substrate for "bytes kept alive
# by *something* the conformer owns".
#
# The trait hoists the `MmapRegion.data()` shape (`mmap_region.mojo`) to
# a reusable trait surface. Conformers expose a stable byte view via
# `as_view` whose origin is parametrically bound to the receiver `self`.
#
# Conformers:
#   * `MmapRegion` (this file's sibling at `mmap_region.mojo`) —
#     file-backed `MAP_PRIVATE+PROT_READ`. Gains MemoryRegion
#     conformance via its trait header; its `data()` method IS the
#     canonical `as_view` shape.
#   * `HeapRegion` — owned `List[UInt8]`. Used by cloud FS
#     conformers (S3Fs / GcsFs / AzureFs) for the response-body
#     bytes of one ranged GET.
#
# Future plug-points (one struct + trait conformance each,
# zero change to MmapAlignedBuffer or any caller):
#   * `DmaMappedRegion` — mlock'd pinned page pool.
#   * `RegisteredRegion` — io_uring `IORING_REGISTER_BUFFERS`.
#   * `CudaUnifiedRegion` / RDMA / etc.
#
# Encapsulation rule (no raw pointer in a public surface, no wildcard origin):
#   The trait surface returns `ByteView[origin]` — concrete origin,
#   never a wildcard `UnsafePointer`. The receiver `ref [origin] self`
#   ties the view's origin to the conformer's `self`, so the borrow
#   checker enforces:
#     * ByteView dropped before MemoryRegion conformer's __del__.
#     * No mutation of the region while the view is live.
# =============================================================================

from komira_core.collections.byte_view import ByteView


trait MemoryRegion(Movable, Deinitable):
    """A region of memory whose bytes are kept alive by *something* the
    conformer owns. The conformer's `__del__` runs the backend-specific
    cleanup (munmap / List drop / GPU free / RDMA dereg / etc.).

    Conformers expose a stable byte view via `as_view`. The returned
    ByteView's origin is parametrically bound to the receiver `self`,
    so the borrow checker enforces:
        * ByteView dropped before MemoryRegion conformer's __del__.
        * No mutation of the region while the view is live.

    This is the `MmapRegion.data()` shape (`mmap_region.mojo`) HOISTED
    to a trait surface — concrete origin throughout; NO wildcard
    `UnsafePointer` in the public trait surface. The wildcard cast lives
    ONLY inside each conformer's body, at its FFI or heap-cast boundary.
    """

    def length(self) -> Int64:
        """Byte length of the region."""
        ...

    def as_view[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Borrow the region's bytes as a tracked ByteView whose origin
        is parametrically bound to `self`. Mirrors the
        `MmapRegion.data()` shape in `mmap_region.mojo`.

        Parameters:
            _mut: Whether the view permits mutation (inferred from
                `origin`).
            origin: The origin the returned view is tied to. Bound to
                the receiver's origin via `ref [origin] self`.
        """
        ...

    # __del__ inherited from Deinitable. Conformer-specific
    # cleanup happens there (e.g. MmapRegion.__del__ → munmap(2);
    # HeapRegion.__del__ → List drop).
