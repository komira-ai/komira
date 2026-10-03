# =============================================================================
# string_contains_scan — a `%lit%` LIKE (and `contains()`) answered by ONE
# substring scan over the column's contiguous data buffer, not one libc
# `memmem` call per row.
# =============================================================================
#
# ★ WHY. A per-row `url LIKE '%google%'` issues ONE libc `memmem` CALL PER
#   ROW. glibc's generic `memmem` (no vectorised variant before 2.40) builds
#   a 256-byte shift table — a `memset` plus a pass over the needle — on
#   EVERY call, so a ~70-byte URL pays a fixed setup comparable to the search
#   itself; on a ClickBench-style `%lit%` filter over 100M URLs that is about
#   a quarter of the CPU. DuckDB v1.5.5 rewrites the same pattern to
#   `contains` (`optimizer/rule/like_optimizations.cpp`) and answers it with
#   `memchr` for the first byte plus a word compare
#   (`function/scalar/string/contains.cpp`, `FindStrInStr`) — no per-row
#   table.
#
# THE ALGORITHM. Arrow lays a string column out as ONE contiguous byte buffer
# with N+1 non-decreasing offsets, so the rows' bytes are exactly
# `data[offsets[0] ..< offsets[N])` with no gaps. Instead of N searches over N
# short haystacks, search that whole range ONCE with the SIMD first+last-byte
# filter (`simd/byte_class/byte_memmem.find_needle`), and map each hit back to
# its row:
#
#     pos = offsets[0]
#     loop:
#         p   = first occurrence of the needle at or after pos   (SIMD scan)
#         r   = the row with offsets[r] <= p < offsets[r+1]      (gallop+bisect)
#         row r matches  iff  p + len(needle) <= offsets[r+1]
#         pos = offsets[r+1]                                     (skip the row)
#
# ⭐ WHY SKIPPING THE REST OF ROW r IS EXACT IN BOTH OUTCOMES. `pos` is always a
# row START, so `p` is the FIRST occurrence that starts inside row r. If it
# fits, row r matches and nothing else in it matters. If it STRADDLES the row
# end, every later start inside row r straddles too (it starts later and has
# the same length), so row r cannot match. Either way the next row is the next
# question — which is also what bounds the loop at `length` iterations.
#
# ⚠ A HIT THAT STRADDLES A ROW BOUNDARY IS NOT A MATCH, and it is the one way
# this kernel could be wrong where the per-row one cannot: `["goo", "gle"]`
# concatenates to `google`. The test file pins that case, the straddle across
# EMPTY rows, and a straddle followed by a real match in the next row.
#
# ⚠ CONTRACT: the offsets are NON-DECREASING (Arrow's own invariant, which
# every string kernel here already relies on to size a copy as
# `offsets[N] - offsets[0]`). The kernel DECLINES — returns None, and the
# caller runs its per-row loop — when it cannot prove the scan range is inside
# the buffers it was handed: an offsets buffer shorter than N+1 entries, a
# negative start, an end before the start, or an end past the data buffer. A
# decline is never a wrong answer, only the per-row speed.
#
# WHAT IT DOES NOT COVER, deliberately:
#   * a 1-byte needle — `find_needle` routes that to its SCALAR byte loop,
#     which over a whole buffer would be slower than libc's per-row `memmem`
#     (glibc turns a 1-byte needle into a vector `memchr`). Declined.
#   * anchored or multi-segment LIKE (`g%`, `%g`, `%a%b%`) — those keep the
#     per-row `_like_plan_match`. The scan answers "does the row contain X",
#     which is exactly `%X%` and nothing more.
#   * NULL. The caller still ends in `_apply_validity`, exactly as the per-row
#     kernel does; a NULL slot's bytes (Arrow permits a non-empty one) are
#     searched by both kernels alike and masked by the same call.
#
# ⭐ THE ARM IS COUNTED, because it is value-identical to the per-row path by
# construction and so no value test can see it disappear. One relaxed atomic
# add per KERNEL CALL (per batch, never per row) into a process-global slot,
# the same `_Global` mechanism `string_eq_arm_counter.mojo` uses. A test
# asserts the counter in BOTH directions.
#
# Encapsulation: the public entry takes the two Arrow buffers by trait and the
# needle as a borrowed `Span`; no pointer crosses the module boundary.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc
from std.sys import size_of

from komira_simd.byte_class.byte_memmem import find_needle
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.bitmap import Bitmap
from komira_buffer.aligned_buffer_trait import AlignedBufferTrait
from komira_buffer.byte_view import ByteView


comptime CONTAINS_SCAN_MIN_NEEDLE = 2
"""Shortest needle the column scan takes. A 1-byte needle stays on the per-row
path — see the module header."""


# =============================================================================
# The arm counter
# =============================================================================


def _init_contains_scan_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: allocate the process-wide counter once, set to 0.
    Mirrors `string_eq_arm_counter._init_string_eq_ladder_counter`."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _CONTAINS_SCAN_COUNTER = _Global[
    "komira_core_string_contains_scan_calls",
    _init_contains_scan_counter,
]


@always_inline
def _contains_scan_counter_incr() -> None:
    """One relaxed atomic add per kernel call that took the column scan.

    Non-raising on purpose: every caller up the predicate chain is a
    non-raising `def`. `_Global.get_or_create_ptr` is declared `raises` only
    to allocate its process-lifetime slot — the statement
    `string_eq_arm_counter.string_eq_ladder_counter_incr` makes about the
    identical call. A lost increment cannot make the test pass vacuously: it
    asserts the counter MOVES for a `%lit%` pattern, so a missing increment
    reds that leg.
    """
    # SAFETY: FFI boundary. `get_or_create_ptr` targets KGEN-runtime-managed
    # static storage (process-lifetime); `MutUntrackedOrigin` is the stdlib
    # `_Global` API's own return type, confined to this helper.
    try:
        var gp = _CONTAINS_SCAN_COUNTER.get_or_create_ptr()
        _ = gp[][].fetch_add(Int64(1))
    except:
        pass


def contains_scan_call_count() raises -> Int:
    """Read the process-wide count of kernel calls that took the column scan."""
    # SAFETY: FFI boundary (see `_contains_scan_counter_incr`).
    var gp = _CONTAINS_SCAN_COUNTER.get_or_create_ptr()
    return Int(gp[][].load())


def reset_contains_scan_call_count() raises:
    """Reset the process-wide count to 0 (test setup)."""
    # SAFETY: FFI boundary (see `_contains_scan_counter_incr`).
    var gp = _CONTAINS_SCAN_COUNTER.get_or_create_ptr()
    gp[][].store(Scalar[DType.int64](0))


# =============================================================================
# The kernel
# =============================================================================


@always_inline
def _offset_at[OffsetType: DType](offsets_view: ByteView[_], i: Int) -> Int:
    return Int(offsets_view.get_typed[Scalar[OffsetType]](i))


@always_inline
def _row_containing[
    OffsetType: DType
](offsets_view: ByteView[_], start_row: Int, length: Int, p: Int) -> Int:
    """The row `r` in `[start_row, length)` with `offsets[r] <= p <
    offsets[r+1]`.

    Precondition: `offsets[start_row] <= p < offsets[length]`. Gallops forward
    from `start_row` (so a hit in the NEXT row — the dense-match case — costs
    one probe) and then bisects the bracket it found. Empty rows are skipped
    for free: an empty row `e` has `offsets[e] == offsets[e+1]`, so it can
    never be the answer to `offsets[r] <= p < offsets[r+1]`.

    ⚠ THE ERROR DIRECTIONS ARE NOT SYMMETRIC, and the caller depends on it. An
    answer that is too EARLY is harmless: its `offsets[r+1] <= p`, so the
    caller sets no bit and resumes at a position `<= p`, where the next scan
    finds `p` again with a later cursor (MEASURED: flipping the bisect's `<=`
    to `<` leaves every test green — an equivalent mutant, it only costs a
    re-scan). An answer that is too LATE would set the WRONG row's bit; the
    bracket invariant below (`offsets[lo_r] <= p`) is what forbids it.
    """
    var lo_r = start_row
    var hi_r = length  # offsets[length] > p by the precondition
    var step = 1
    while True:
        var probe = lo_r + step
        if probe >= length:
            break
        if _offset_at[OffsetType](offsets_view, probe) > p:
            hi_r = probe
            break
        lo_r = probe
        step <<= 1
    # Invariant: offsets[lo_r] <= p < offsets[hi_r].
    while hi_r - lo_r > 1:
        var mid = (lo_r + hi_r) >> 1
        if _offset_at[OffsetType](offsets_view, mid) <= p:
            lo_r = mid
        else:
            hi_r = mid
    return lo_r


def string_contains_scan_kernel[
    OffsetType: DType,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    needle: Span[UInt8, _],
) -> Optional[BooleanArray]:
    """Row `i`'s bit is set iff string `i` contains `needle` as a substring.

    Returns None — DECLINE, the caller runs its per-row kernel — for a needle
    shorter than `CONTAINS_SCAN_MIN_NEEDLE` bytes, an empty column, or buffers
    that do not provably hold the scan range (see the module header). The
    returned mask carries NO validity; the caller applies it, as it does for
    the per-row kernel.
    """
    var nlen = len(needle)
    if nlen < CONTAINS_SCAN_MIN_NEEDLE or length <= 0:
        return None

    var offsets_view = offsets.view_ro()
    var data_view = data.view_ro()
    if offsets_view.len() < (length + 1) * size_of[Scalar[OffsetType]]():
        return None
    var lo = _offset_at[OffsetType](offsets_view, 0)
    var hi = _offset_at[OffsetType](offsets_view, length)
    if lo < 0 or hi < lo or hi > data_view.len():
        return None

    var bm = Bitmap.create(length)  # all bits clear == no row matched yet
    var bm_view = bm.buffer.view_mut()
    var bytes = data_view.into_span()

    var pos = lo
    var row = 0
    while hi - pos >= nlen:
        var rel = find_needle(bytes[pos:hi], needle)
        if rel < 0:
            break
        var p = pos + rel
        # `pos` is a row start at or below `p`, and `p < hi == offsets[length]`
        # because the whole needle fit inside `[pos, hi)`.
        row = _row_containing[OffsetType](offsets_view, row, length, p)
        var row_end = _offset_at[OffsetType](offsets_view, row + 1)
        if p + nlen <= row_end:
            var byte_idx = row >> 3
            bm_view.write_u8_at(
                byte_idx,
                bm_view.read_u8_at(byte_idx) | (UInt8(1) << UInt8(row & 7)),
            )
        pos = row_end
        row += 1

    _contains_scan_counter_incr()
    return BooleanArray.from_bitmap(bm^)
