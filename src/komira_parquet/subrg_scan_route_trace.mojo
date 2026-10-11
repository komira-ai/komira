# =============================================================================
# subrg_scan_route_trace — the route accounting of the sub-row-group scan
# =============================================================================
#
# A row group scanned through the sub-row-group cursor (`subrg_column_cursor`)
# either streams, a chunk of rows at a time, or abandons the cursor and decodes
# the whole row group. Both produce the same values, so only these counters
# tell them apart, and they say it as a grain rather than a flag:
#
#   `rows_streamed / chunks_streamed`  the grain the cursor achieved (about
#                                      the caller's chunk size when healthy);
#   `rows_whole / fallback`            the grain a blocked route degraded to,
#                                      which is the row group's own size.
#
# Two more count the declines:
#
#   `open_declines`   chunks refused at open by the cursor's whole-chunk page
#                     header walk (a dictionary chunk with a PLAIN page after
#                     a dictionary spill, a DATA_PAGE_V2 page, a malformed
#                     header). Nothing was published, so the whole-row-group
#                     fallback is clean.
#   `retracted_rows`  rows published to a sink and then retracted because the
#                     cursor declined mid-decode (an OPTIONAL page that holds
#                     an actual null is only found by decoding its body). A
#                     non-zero count is the retraction path doing its job.
#
# The counters are process-global and always on, added once per row group or
# per chunk refused (never per row), so a test can read them back. Mechanism:
# the `_Global` slot, as in `scan_copy_trace`.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


def _init_route_slot() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn (non-raising): one counter per process, set to 0."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: module-private init. `Atomic` is not movable by value, so its
    # scalar is written in place before `OwnedPointer` takes ownership; the raw
    # pointer never leaves this function.
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _C_ROWS_STREAMED = _Global[
    "komira_parquet_subrg_scan_rows_streamed", _init_route_slot
]
comptime _C_CHUNKS_STREAMED = _Global[
    "komira_parquet_subrg_scan_chunks_streamed", _init_route_slot
]
comptime _C_ROWS_WHOLE = _Global[
    "komira_parquet_subrg_scan_rows_whole", _init_route_slot
]
comptime _C_FALLBACK = _Global[
    "komira_parquet_subrg_scan_fallback", _init_route_slot
]
comptime _C_OPEN_DECLINE = _Global[
    "komira_parquet_subrg_scan_open_decline", _init_route_slot
]
comptime _C_RETRACTED = _Global[
    "komira_parquet_subrg_scan_retracted_rows", _init_route_slot
]


# SAFETY (every `get_or_create_ptr` below): the pointer targets runtime-managed
# process-lifetime storage; it is dereferenced in place, never returned.


@always_inline
def add_scan_streamed(rows: Int, chunks: Int) raises:
    """Record one row group decoded through the cursor: `rows` rows handed to
    the sink in `chunks` chunks. Called once per row group."""
    _ = _C_ROWS_STREAMED.get_or_create_ptr()[][].fetch_add(Int64(rows))
    _ = _C_CHUNKS_STREAMED.get_or_create_ptr()[][].fetch_add(Int64(chunks))


@always_inline
def add_scan_fallback(rows: Int) raises:
    """Record one row group of `rows` rows that abandoned the cursor and was
    decoded whole."""
    _ = _C_ROWS_WHOLE.get_or_create_ptr()[][].fetch_add(Int64(rows))
    _ = _C_FALLBACK.get_or_create_ptr()[][].fetch_add(Int64(1))


def scan_rows_streamed_count() raises -> Int:
    """Rows decoded through the cursor, process-wide."""
    return Int(_C_ROWS_STREAMED.get_or_create_ptr()[][].load())


def scan_chunks_streamed_count() raises -> Int:
    """Chunks the cursor arm handed to a sink, process-wide."""
    return Int(_C_CHUNKS_STREAMED.get_or_create_ptr()[][].load())


def scan_rows_whole_count() raises -> Int:
    """Rows decoded by the whole-row-group fallback, process-wide."""
    return Int(_C_ROWS_WHOLE.get_or_create_ptr()[][].load())


def scan_fallback_count() raises -> Int:
    """Row groups that fell back to a whole-row-group decode, process-wide."""
    return Int(_C_FALLBACK.get_or_create_ptr()[][].load())


def scan_grain_streamed() raises -> Int:
    """`rows_streamed // chunks_streamed`, or 0 when nothing streamed."""
    var c = scan_chunks_streamed_count()
    return scan_rows_streamed_count() // c if c > 0 else 0


def scan_grain_whole() raises -> Int:
    """`rows_whole // fallback`, or 0 when nothing fell back."""
    var c = scan_fallback_count()
    return scan_rows_whole_count() // c if c > 0 else 0


@always_inline
def incr_scan_open_decline() raises:
    """Record one chunk refused by the cursor's open-time page header walk."""
    _ = _C_OPEN_DECLINE.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def add_scan_retracted(rows: Int) raises:
    """Record `rows` published and then retracted after a mid-decode decline.
    Called once per declining row group."""
    _ = _C_RETRACTED.get_or_create_ptr()[][].fetch_add(Int64(rows))


def scan_open_decline_count() raises -> Int:
    """Chunks refused by the open-time page header walk, process-wide."""
    return Int(_C_OPEN_DECLINE.get_or_create_ptr()[][].load())


def scan_retracted_rows_count() raises -> Int:
    """Rows published and then retracted, process-wide."""
    return Int(_C_RETRACTED.get_or_create_ptr()[][].load())


def reset_scan_route_counts() raises:
    """Zero every counter."""
    _C_ROWS_STREAMED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_CHUNKS_STREAMED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_ROWS_WHOLE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_FALLBACK.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_OPEN_DECLINE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_RETRACTED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
