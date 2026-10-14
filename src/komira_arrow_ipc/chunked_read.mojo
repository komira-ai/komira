# =============================================================================
# komira_arrow_ipc.chunked_read — safe whole-file read for >2 GB inputs.
# =============================================================================
#
# Background — the underlying Mojo stdlib bug
# ---------------------------------------------------------------------------
# `pathlib.Path.read_bytes()` (and its hot-path conduit, the underlying
# `FileHandle.read` / `FileHandle.read_bytes(count)` syscall wrapper)
# RAISES `"Failed to read from file: Invalid argument"` (or silently
# truncates, depending on the call shape) when the file size exceeds
# ~2 GB (Int32 max for the underlying `read(2)` count argument). The
# call returns without raising on the silent-truncate arms; the
# resulting `List[UInt8]` is shorter than the file on disk and any
# downstream decoder sees corrupted / truncated input.
#
# This is the READ-SIDE analog of the write-side bug worked around in
# `chunked_write.mojo`: the same Int32 count overflow inside the stdlib's
# `FileHandle.read*` path.
#
# **This file is the canonical workaround for the read-side bug.**
# Every site that hands a possibly >2 GB file path to `Path.read_bytes()`
# MUST use `read_chunked(path)` below instead.
#
# Once the stdlib does its own internal chunking or raises, this helper
# becomes a thin pass-through.
#
# Why mmap, not chunked-FileHandle.read
# ---------------------------------------------------------------------------
# A naive read-side analog to `write_chunked` would loop
# `FileHandle.read_bytes(64 MiB)` and concatenate into a
# `List[UInt8]`. That works but:
#
#  1. Requires a full file-size heap allocation (e.g. a 2.7 GB List[UInt8]
#     copy from kernel page cache to heap), doubling resident memory
#     vs. the kernel page cache alone.
#  2. Pays the kernel-to-userspace copy cost twice (once per `read(2)`
#     syscall, then a List grow to the final size unless we pre-size).
#  3. The List[UInt8] concatenation/grow loop has its own >2 GB
#     allocator concerns.
#  4. The downstream decoders (JSONL inferrer / materializer, CSV
#     reader, ORC reader) all consume a `Span[UInt8, _]` — they have
#     no requirement for an owned `List[UInt8]`. Routing through mmap
#     drops them onto the kernel's page cache directly, zero-copy.
#
# `MmapRegion.open_readonly(path)` plus the Arc-wrapped `MmapRegion` +
# non-owning aligned-buffer keepalive is the proven shape (the Avro read
# path uses it). This helper packages it in the same the core packages
# namespace as `chunked_write.mojo` so every downstream package (sdk, csv,
# orc) can import it without an upward layering hop.
#
# API surface
# ---------------------------------------------------------------------------
#   `read_chunked(path: String) -> MmapAlignedBuffer[64]` — mmap-backed
#     read of the entire file at `path`. Returns a non-owning
#     `MmapAlignedBuffer[64]` whose bytes alias directly into the kernel
#     mmap region; the buffer's `_keepalive` is an
#     `ArcPointer[MmapRegion]` that keeps `munmap(2)` from firing
#     until the buffer drops. The caller consumes the bytes via
#     `Span[UInt8, _]` over the mmap'd bytes.
#
#   `read_chunked_into_list(path: String) -> List[UInt8]` — own-heap
#     variant for the rare caller that genuinely needs a `List[UInt8]`
#     (e.g. to mutate the bytes). Internally mmaps + copies into a
#     pre-sized List. Chunked at 64 MiB to keep any per-`memcpy`
#     operation bounded.
# Byte-output guarantees
# ---------------------------------------------------------------------------
# The returned buffer / List has length == file size on disk, byte-
# identical to what a hypothetical bug-free `Path.read_bytes()` would
# have produced for ANY file size up to the limits of the underlying
# `mmap(2)` (effectively the process's virtual address space).
#
# Encapsulation:
#   - No `UnsafePointer` in public signatures. Public API takes
#     `String` (path) and returns `MmapAlignedBuffer[64]` /
#     `List[UInt8]` — both standard owned-value shapes.
#   - No wildcard origins crossing the helper's boundary. The
#     `ArcPointer[MmapRegion]` keepalive's wildcard hop is internal to
#     `MmapAlignedBuffer.borrow_from_mmap`'s body.
#   - No `unsafe_from_address=Int(...)`.
#   - No partial-move-via-UnsafePointer.
#
# A zero-byte file raises (mmap of a zero-length file is undefined per
# POSIX).
# =============================================================================

from std.collections.optional import Optional
from std.memory import ArcPointer

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.mmap_region import MmapRegion


# =============================================================================
# Public API
# =============================================================================


# =============================================================================
# Internal helper — the canonical mmap-open + MmapAlignedBuffer-borrow recipe.
# =============================================================================
#
# This is the ONE place that wraps an `MmapRegion.open_readonly` call in
# the `ArcPointer + borrow_from_mmap` keepalive shape. Both `read_chunked`
# (whole-file) and `read_chunked_range` (sub-range) call into this helper,
# and the local filesystem's `read_whole` / `read_range` delegate to those
# two public functions — so there is exactly one site that opens an mmap
# and binds an aligned-buffer keepalive over it.
#
# The "whole-file" variant (`offset == 0`, `length == None`) is what
# `read_whole` and `read_chunked` use; the range variant takes a
# pre-validated `offset` and `length`. Caller is responsible for the
# `offset + length <= region.len()` bounds check — the helper does NOT
# repeat it (the caller has better error messages with format context).


def _mmap_borrow(
    var region: MmapRegion, offset: Int, length: Int
) raises -> SharedAlignedBuffer[MmapRegion]:
    """Internal: wrap an already-opened `MmapRegion` in an `ArcPointer`
    and return a `SharedAlignedBuffer[MmapRegion]` borrowing
    `[offset, offset+length)` out of it. Caller-validated bounds.

    This is the single canonical mmap-wrap site. Every public read
    entry point — `read_chunked`, `read_chunked_range`, and the local
    filesystem's `read_whole` / `read_range` — funnels through this
    helper. The helper takes ownership of `region`; the returned
    buffer's `_region` is an `ArcPointer[MmapRegion]` whose drop
    triggers `munmap(2)` via `MmapRegion.__del__`.

    See file header for the rationale.
    """
    var region_arc = ArcPointer[MmapRegion](region^)
    # `borrow_from_mmap` takes the Arc by value and copies internally
    # (refcount = 2 after the call; both this Arc and the buf's
    # _region hold a refcount). The local Arc drops at function end,
    # leaving refcount = 1 in the returned buffer.
    return SharedAlignedBuffer.borrow_from_mmap(
        ArcPointer[MmapRegion](copy=region_arc),
        Int64(offset),
        Int64(length),
    )


def read_chunked(path: String) raises -> SharedAlignedBuffer[MmapRegion]:
    """Whole-file read via mmap, safe for >2 GB inputs.

    Drop-in replacement for `Path(path).read_bytes()` at any read site
    whose input could exceed ~2 GB (the Int32 ceiling on the stdlib's
    `FileHandle.read*` count argument). Returns an
    `MmapAlignedBuffer[64, MmapRegion]` whose bytes alias directly into the
    kernel's mmap region for `path`; consumes are zero-copy off the
    page cache.

    The return type is parameterized on `MmapRegion` (not the default
    `HeapRegion`), because the bytes are file-backed.
    The returned buffer is **non-owning** (`capacity == 0` sentinel;
    `is_owned() == False`). Its `_keepalive` is an
    `ArcPointer[MmapRegion]` that keeps `munmap(2)` from firing until
    the buffer drops. Downstream consumers extract bytes via:

        var buf = read_chunked(path)
        var span = buf.view_range_ro(0, buf.length).into_span()
        var batch = some_decoder(span)  # decoder is Span-poly

    Lifetime: the returned buffer is `Movable`; downstream callers may
    move it freely. The Arc keepalive moves with the buffer; the mmap
    region survives any move. When the LAST `MmapAlignedBuffer` / Arc copy
    drops, `MmapRegion.__del__` fires `munmap(2)`.

    Args:
        path: Filesystem path to read. Must exist + be non-zero-length
            (mmap of an empty file is implementation-defined; raises).

    Returns:
        A non-owning `MmapAlignedBuffer[64]` aliasing the entire file
        contents, with the mmap region kept alive by the buffer's
        Arc keepalive.

    Raises:
        * Open failure (file not found / no read permission).
        * fstat failure.
        * mmap failure (e.g. address space exhaustion on huge files
          in a small VA).
        * Zero-length file (mmap with len=0 is implementation-defined;
          we raise rather than rely on POSIX behavior).
    """
    # Open the region once, take its length, then hand the region to
    # the canonical mmap-borrow helper which Arc-wraps + borrows.
    var region = MmapRegion.open_readonly(path)
    var n = region.len()
    return _mmap_borrow(region^, 0, n)


def read_chunked_range(
    path: String, offset: Int, length: Int,
) raises -> SharedAlignedBuffer[MmapRegion]:
    """Sub-range read via mmap, safe for >2 GB files.

    Range-bounded sibling of `read_chunked`. Returns a non-owning
    `MmapAlignedBuffer[64, MmapRegion]` aliasing `[offset, offset+length)`
    of `path`.

    The return type is parameterized on `MmapRegion` (not the default
    `HeapRegion`), because the bytes are file-backed.
    The keepalive Arc keeps the FULL mmap region alive — the kernel
    page cache only pages in the bytes actually touched.

    Used by random-access readers (Arrow IPC per-RB scatter, Avro
    block-parallel decode, ORC stripes) that consume sub-ranges of
    a file without slurping the whole thing.

    Args:
        path: Filesystem path to read. Must exist + be non-zero-length.
        offset: Byte offset into the file. Must be >= 0.
        length: Bytes to expose through the returned buffer. Must be
            >= 0. `offset + length` must be <= file_size; out-of-bounds
            raises a structured error.

    Returns:
        A non-owning `MmapAlignedBuffer[64]` aliasing the requested range.

    Raises:
        * `MmapRegion.open_readonly` failures (open/fstat/mmap;
          zero-length file).
        * Negative offset/length.
        * Range out of bounds (`offset + length > file_size`).
    """
    if offset < 0 or length < 0:
        raise Error(
            "read_chunked_range: negative offset/length: offset=",
            offset, " length=", length, " path=", path,
        )
    var region = MmapRegion.open_readonly(path)
    var region_len = region.len()
    # Compare without forming `offset + length`: both are caller-supplied and
    # their sum can wrap Int to a negative value that passes a `> region_len`
    # test, leaving a borrow far outside the mapping.
    if offset > region_len or length > region_len - offset:
        raise Error(
            "read_chunked_range: range out of bounds: offset=",
            offset, " length=", length, " file_size=", region_len,
            " path=", path,
        )
    return _mmap_borrow(region^, offset, length)


# =============================================================================
# Own-heap variant — for the rare caller that needs a List[UInt8].
# =============================================================================
#
# Every decoder consumes `Span[UInt8, _]` directly off the mmap'd
# buffer; this entry point is for a caller that needs an owned, mutable
# byte buffer (e.g. a decoder that rewrites the input in place).
#
# Implementation: mmap once, copy into a pre-sized List in 64 MiB
# chunks. Chunking the memcpy bounds per-operation memory churn and
# matches `chunked_write.mojo`'s symmetric 64 MiB cadence.


# 64 MiB chunk size — matches `chunked_write.mojo:CHUNK_BYTES`.
# See file header for the rationale.
comptime CHUNK_BYTES: Int = 64 * 1024 * 1024


def read_chunked_into_list(path: String) raises -> List[UInt8]:
    """Whole-file read into an owned `List[UInt8]`, safe for >2 GB inputs.

    Use this only if the caller genuinely needs an owned, mutable
    `List[UInt8]` (every decoder consumes a `Span[UInt8, _]` directly
    via `read_chunked`).
    Internally: mmap the file once, copy into a pre-sized List in 64
    MiB chunks. The mmap region drops at end of this call; only the
    copied `List[UInt8]` lives on.

    Args:
        path: Filesystem path to read.

    Returns:
        An owned `List[UInt8]` containing the entire file contents.

    Raises:
        Same as `read_chunked` (the underlying mmap path).
    """
    var buf = read_chunked(path)
    var n = buf.len()
    var out = List[UInt8](capacity=n)
    if n == 0:
        return out^  # cov: unreachable read_chunked raises on an empty file
    # Copy in 64 MiB chunks. The single-chunk fast path covers the
    # common case (any file under 64 MiB takes one loop iteration).
    var src_span = buf.view_range_ro(0, n).into_span()
    var off = 0
    while off < n:
        var end = off + CHUNK_BYTES
        if end > n:
            end = n
        var i = off
        while i < end:
            out.append(src_span[i])
            i += 1
        off = end
    return out^
