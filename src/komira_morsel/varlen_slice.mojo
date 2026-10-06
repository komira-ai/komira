# =============================================================================
# varlen_slice.mojo -- STRING / BINARY row-window slicing for split_record_batch
# =============================================================================
#
# Split out of `morsel.mojo` (lane G L3, 2026-09-25) when the variable-width
# slice grew its payload-VIEW arm: `morsel.mojo` was already past the
# 1000-line ceiling, and this is the one self-contained piece of it that the
# L3 review has to read in full. `split_record_batch` (in `morsel.mojo`) is the
# only production caller; `_slice_column`'s STRING / BINARY arm reaches the
# COPY arm here, the split loop reaches the VIEW arm directly.
#
# No `UnsafePointer` in this file. The payload VIEW is a
# `SharedAlignedBuffer.share_range_as` -- an Arc refcount bump whose raw
# pointer never leaves `shared_aligned_buffer.mojo`.
# =============================================================================

from std.sys import size_of

from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion


def _payload_window_shareable(
    col: Column[HeapRegion], start: Int, length: Int
) -> Bool:
    """True iff rows `[start, start+length)` of a STRING / BINARY `col` can take
    the payload-VIEW arm of `_slice_variable_width` — i.e. the byte window
    `[offsets[start], offsets[start+length])` provably lies inside `col._data`'s
    own extent, so `SharedAlignedBuffer.share_range_as` cannot refuse it.

    A CORRECTNESS gate for the share, never a heuristic. Every refusal routes
    the window to the COPY arm, which is exactly what ran before lane G L3, so
    a refused window is never a new failure mode:

    * no offsets buffer — the copy arm raises its own named error;
    * an offsets buffer too short for `start + length + 1` entries;
    * a negative or decreasing byte window (corrupt offsets — the copy arm
      raises on the negative length);
    * a byte window that ends past `col._data.len()`. A payload buffer whose
      logical length is SHORTER than its own offsets claim is a malformed
      producer; the copy arm reads it through `view_range_ro`, whose bound is a
      `debug_assert`, and so tolerates it. `share_range_as` raises instead (a
      silently clamped share would alias bytes nobody asked for). Declining
      keeps the old tolerance for that producer rather than turning it into a
      query error on the next split.
    """
    if not col._offsets:
        return False
    comptime int32_size = size_of[Int32]()
    ref off = col._offsets.value()
    if start < 0 or length < 0 or (start + length + 1) * int32_size > off.len():
        return False
    var b0 = Int(off.get_typed[Int32](start))
    var b1 = Int(off.get_typed[Int32](start + length))
    return b0 >= 0 and b1 >= b0 and b1 <= col._data.len()


def _slice_variable_width(
    col: Column[HeapRegion],
    start: Int,
    length: Int,
    arrow_type: ArrowType,
    share_payload: Bool,
) raises -> Column[HeapRegion]:
    """Slice a STRING / BINARY column from [start, start+length).

    Arrow variable-width layout:
        offsets: Int32 array of (N+1) entries. offsets[i] is the byte
            position where element i starts in the data buffer;
            offsets[N] is the total data length.
        data:    contiguous UTF-8 (STRING) or raw (BINARY) payload bytes.
        validity: optional Bitmap, bit i == 1 means valid.

    Both arms build, FRESH:
        - (length + 1) offsets, rebased so offsets[0] == 0.
        - Validity bitmap slice (bit i -> bit i of new bitmap).
    and differ ONLY in the payload bytes
    `[src_offsets[start], src_offsets[start + length])`:
        - `share_payload=False` (the COPY arm): memcpy'd into a fresh buffer.
        - `share_payload=True` (the VIEW arm, lane G L3, 2026-09-25): an Arc
          WINDOW share of `col._data` (`SharedAlignedBuffer.share_range_as`) —
          a refcount bump, no byte moves. The caller must have checked
          `_payload_window_shareable`; an out-of-extent window raises.

    ## WHY THE VIEW ARM NEEDS NO `_offset` AUDIT

    The result has the COPY arm's layout exactly: `_offset == 0`,
    `offsets[0] == 0`, `_data.len() == offsets[length]`, validity from bit 0.
    `share_range_as` returns a buffer that IS the window (its `len()` is the
    window's, its `_ptr` already advanced), so every reader that reads the data
    buffer from byte 0 — `as_string`, `as_binary`, `share_as_string`, the
    Arrow C-data export, concat, `deep_copy` — reads the window and nothing
    else. `Column.supports_zero_copy_slice` still excludes STRING/BINARY, and
    must: that whitelist is about `_offset`-honouring accessors, and this arm
    never sets `_offset`.

    ## WHY SHARING THE PAYLOAD IS SOUND (the argument a reviewer must check)

    1. LIFETIME. The window share clones `col._data`'s region Arc (and its
       `_mmap_keepalive` cookie when the bytes are an mmap borrow), so the
       returned column pins the source bytes for its own lifetime. It survives
       the source batch (which `split_record_batch` CONSUMES) and every sibling
       morsel. No raw pointer leaves this function or `SharedAlignedBuffer`.
    2. ALIASING. After the split the payload region is held by the N morsels
       (DISJOINT byte windows) plus whatever already shared the source column
       before the split — the scan cache's `share_batch`, the parquet decoder's
       string-share. That second set is NOT widened by this arm: an unsplit row
       group (rows <= morsel_rows) hands the SAME consumers the source column
       itself. The invariant relied on is the one `Column.share` and the
       fixed-width `Column.slice` arm (live) already rely on:
       Arrow buffers are read-only on every consumer path.
    3. EXTENT. `share_range_as` bounds the result to the window, so a SIMD
       kernel's `load_simd` bound check stays as tight as it was on the copy.
       A kernel that over-reads PAST an element's end reads the next morsel's
       bytes (or, for the last window, past the source's end — exactly what it
       would read on the unsplit source column); the lane G L1 review
       (`borrowed_column_string_share_review_2026_09_23`) found every string
       kernel stays inside `[start, start+len)`.
    4. ALIGNMENT. The window starts at an arbitrary byte, so the data pointer
       is not 64-byte aligned. Individual strings already start at arbitrary
       bytes, every payload read in the tree is a byte-offset `view_range_ro`
       or an `alignment=1` load, and gather.mojo's nullable-page window share
       made the same argument on 2026-09-21. Do not add an aligned SIMD load
       over a STRING payload without re-checking this.
    5. RETENTION. A retained morsel now pins its source row group's WHOLE
       payload, not just its own window — the same retention the fixed-width
       Arc reslice has had. Bounded by one decoded row group
       per retained morsel.

    Note: source column's `_offset` is NOT used by as_string() / as_binary()
    (those read offsets from position 0). Row `start` therefore addresses
    the same logical element the Column exposes via length/offsets.
    """
    comptime int32_size = size_of[Int32]()

    if not col._offsets:
        raise Error("_slice_variable_width: column missing offsets buffer")

    # Z.4c: typed element reads on MmapAlignedBuffer (offsets buffer holds Int32).
    ref src_offsets_buf = col._offsets.value()

    # Rebase: byte_start = src_offsets[start], payload_bytes = src_offsets[start+length] - byte_start.
    var src_byte_start = Int(src_offsets_buf.get_typed[Int32](start))
    var src_byte_end = Int(src_offsets_buf.get_typed[Int32](start + length))
    var payload_bytes = src_byte_end - src_byte_start
    if payload_bytes < 0:
        raise Error("_slice_variable_width: negative payload length -- corrupt offsets")

    # New offsets buffer: (length + 1) Int32 entries, rebased.
    var offsets_bytes = (length + 1) * int32_size
    var new_offsets_buf = OwnedAlignedBuffer(max(offsets_bytes, int32_size))
    # Z.4c: typed element writes (set_typed) replace bitcast+index ptr writes.
    for i in range(length + 1):
        new_offsets_buf.set_typed[Int32](
            i, Int32(Int(src_offsets_buf.get_typed[Int32](start + i)) - src_byte_start)
        )
    new_offsets_buf.set_length(Int64(offsets_bytes))


    # Payload: an Arc WINDOW share (VIEW arm) or a fresh copy (COPY arm).
    var data_sab: SharedAlignedBuffer[HeapRegion]
    if share_payload:
        # Raises (never clamps) if the window leaves `col._data`'s extent; the
        # caller's `_payload_window_shareable` makes that unreachable.
        data_sab = col._data.share_range_as[HeapRegion](
            src_byte_start, payload_bytes
        )
    else:
        var data_buf = OwnedAlignedBuffer(max(payload_bytes, 1))
        if payload_bytes > 0:
            # Z.4c: bulk byte copy via origin-preserving view.
            data_buf.copy_from_view(
                col._data.view_range_ro(src_byte_start, payload_bytes)
            )
        else:
            data_buf.set_length(0)
        data_sab = SharedAlignedBuffer[HeapRegion].from_owned(data_buf^)


    # Validity slice: bit-for-bit copy.
    #
    # SIMD sprint 1/2: same primitive as
    # `_slice_fixed_width` validity above; bundled into the same
    # dispatch.
    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if col._validity:
        var bm = Bitmap.create(length)
        Bitmap.copy_bits_into(bm, 0, col._validity.value(), start, length)
        null_count = length - bm.popcount()
        validity = bm^

    return Column[HeapRegion](
        arrow_type=arrow_type,
        data=data_sab^,
        offsets=Optional(
            SharedAlignedBuffer[HeapRegion].from_owned(new_offsets_buf^)
        ),
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )
