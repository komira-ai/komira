# =============================================================================
# komira_libc.chunked_write — safe FileHandle.write for >2 GB payloads.
# =============================================================================
#
# Background — the underlying Mojo stdlib bug
# ---------------------------------------------------------------------------
# `std.io.FileHandle.write(s: String)` SILENTLY writes 0 bytes when the
# input string exceeds ~2 GB (Int32 max). The call returns without
# raising; the file ends up size 0 on disk. Root cause is presumed to be
# an Int32-sized `write(2)` count argument inside the stdlib
# `FileHandle.write` impl or the String view itself carrying an
# Int32-bounded length.
#
# **This file is the canonical workaround for the bug.** Every site
# that hands a `String` / `Span[UInt8]` / `List[UInt8]` whose length
# COULD exceed 2 GB to `FileHandle.write` MUST route through
# `write_chunked_*` below, NOT call `FileHandle.write` directly.
#
# Once the stdlib does its own internal chunking or raises, this helper
# becomes a thin pass-through.
#
# Chunk size selection
# ---------------------------------------------------------------------------
# 64 MiB per chunk. Reasoning:
# - Well below the 2 GB Int32 threshold (32× margin).
# - Large enough to amortize per-write syscall overhead (a 64 MiB
#   write(2) on macOS / Linux is one trip through the page cache layer).
# - Small enough that intermediate failures localize to one chunk.
# - Matches what production C++ writers (DuckDB Parquet sink, Arrow
#   IPC) use for their pwrite-loop batch size.
#
# API surface
# ---------------------------------------------------------------------------
# Two entry points cover every call shape:
#
#   `write_chunked(handle, bytes: Span[UInt8, _])` — preferred. Takes a
#     borrowed Span; no copy, no extra allocation. Callers that hold a
#     `List[UInt8]` use `Span(buf)`; callers that hold a `String` use
#     `String.as_bytes()` (returns Span).
#
#   `write_chunked_string(handle, s: String)` — convenience wrapper. The
#     caller already built a String; we extract the bytes view internally.
#     Same chunked-write semantics.
#
# Both:
#   - Are no-ops on empty input.
#   - Take the fast path (single `handle.write` call) when the input fits
#     in one chunk (≤ `CHUNK_BYTES`), which is the common case.
#   - Otherwise iterate `Span(ptr=buf.unsafe_ptr() + off, length=...)`
#     views and call `handle.write(String(unsafe_from_utf8=...))` per
#     chunk. Byte-identical output to one big write would have produced
#     (chunk boundaries are arbitrary byte offsets; the stdlib write(2)
#     does not interpret bytes).
#
# Encapsulation:
#   - No `UnsafePointer` in public signatures. Public API takes `Span`
#     (the canonical view-of-bytes).
#   - The internal `Span(ptr=..., length=...)` construction is INSIDE
#     this function — does not cross a module boundary.
#   - No wildcard origins. The Span parameter `Span[UInt8, _]` infers a
#     concrete origin per call site.
#   - No `unsafe_from_address=Int(...)`.
#   - No partial-move-via-UnsafePointer.
#
# The >2 GB cases need ~3 GB of free disk and ~10 s of wall time per
# case, so tests of that size are opt-in rather than part of every run.
# =============================================================================

from std.io import FileHandle


# 64 MiB chunk size. See file header for the rationale.
# Public `comptime` so callers can sanity-check.
comptime CHUNK_BYTES: Int = 64 * 1024 * 1024


# =============================================================================
# Public API
# =============================================================================


def write_chunked(
    mut handle: FileHandle, bytes: Span[UInt8, _]
) raises:
    """Write `bytes` to `handle` in chunks of at most `CHUNK_BYTES`.

    This is the safe replacement for `handle.write(String(unsafe_from_utf8=
    bytes))` for any payload whose length COULD exceed ~2 GB. The
    underlying Mojo stdlib `FileHandle.write(s)` silently flushes
    0 bytes for strings > ~2 GB; chunking at 64 MiB keeps every call
    well below that threshold.

    Byte-output guarantees:
      - Empty input is a no-op (no write call issued).
      - Single-chunk input (`len(bytes) <= CHUNK_BYTES`) takes the
        single-write fast path; the on-disk bytes are identical to what
        a hypothetical bug-free `handle.write` would have produced.
      - Multi-chunk input writes each 64 MiB slice as its own
        `handle.write` call; chunk boundaries are arbitrary byte offsets
        (the OS write(2) does not interpret bytes). The on-disk byte
        sequence is the concatenation of the chunks in order — identical
        to the input span.

    Encapsulation: takes a borrowed `Span[UInt8, _]` (origin inferred at
    the call site); the public surface carries no `UnsafePointer` and no
    wildcard origin. Internal `Span(ptr=..., length=...)` reconstruction
    is confined to this function body.
    """
    var n = len(bytes)
    if n == 0:
        return
    if n <= CHUNK_BYTES:
        # Fast path: single-write for sub-chunk payloads. This is the
        # common case (per-batch writes are typically MB, not GB).
        var s = String(unsafe_from_utf8=bytes)
        handle.write(s)
        return
    # Slow path: chunk the write to keep each `handle.write` call under
    # the stdlib's Int32 threshold.
    var off = 0
    while off < n:
        var end = off + CHUNK_BYTES
        if end > n:
            end = n
        var chunk_len = end - off
        # Build a Span over the sub-region. `bytes.unsafe_ptr()` returns
        # an UnsafePointer scoped to the borrowed origin of `bytes`; the
        # offset arithmetic stays inside this function (does not cross a
        # module boundary). The resulting `Span` shares the origin.
        var chunk = Span(
            unsafe_ptr=bytes.unsafe_ptr() + off, length=chunk_len
        )
        var s = String(unsafe_from_utf8=chunk)
        handle.write(s)
        off = end


def write_chunked_string(
    mut handle: FileHandle, s: String
) raises:
    """Convenience wrapper for callers that already hold a String.

    Equivalent to `write_chunked(handle, s.as_bytes())`. Use this when
    the natural shape at the call site is a String (e.g. the caller
    pre-built the entire payload via `String.write(...)` accumulation);
    use `write_chunked` directly when the natural shape is a
    `List[UInt8]` / `Span[UInt8]`.

    Same byte-output guarantees and same chunked semantics as
    `write_chunked`.
    """
    var bytes = s.as_bytes()
    write_chunked(handle, bytes)
