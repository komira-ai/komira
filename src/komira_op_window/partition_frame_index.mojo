# =============================================================================
# partition_frame_index -- each row's frame as row indices
# =============================================================================
#
# A frame bound becomes a row index here and nowhere else. Every framed
# kernel (the bounded aggregates of `partition_sliding_frame`, FIRST_VALUE /
# LAST_VALUE / NTH_VALUE of `partition_value_fns`) takes two per-row lists,
# `lo[row]` (inclusive) and `hi[row]` (exclusive), absolute into the sorted
# batch, and never decodes a bound itself.
#
#   * ROWS: a bound is a row count. `1 PRECEDING` is the row before.
#   * RANGE with no offset (`UNBOUNDED PRECEDING`, `CURRENT ROW`,
#     `UNBOUNDED FOLLOWING`): `CURRENT ROW` is the current row's whole peer
#     group, so peers get the same frame. Peers are rows equal on every
#     order key under `partition_keys.key_cells_equal` (NULLs are peers of
#     each other, NaNs of each other), so this serves every key type, any
#     number of order keys, and NULL keys.
#   * RANGE with an offset (`n PRECEDING` / `n FOLLOWING`): the bound is a
#     VALUE offset on the one ORDER BY key: `1 PRECEDING` selects the rows of
#     the partition whose key lies in `[k - 1, k]`. Served for one INT64 or
#     FLOAT64 key with no NULL and no NaN; anything else raises rather than
#     answering with ROWS semantics.
#
# Both lists are non-decreasing in `row` within a partition, under every
# unit: the ring-buffer kernels need that. ROWS clamps an affine function;
# RANGE walks a key that is sorted inside the partition.
# =============================================================================

from std.math import isnan

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.partition_expr import (
    FRAME_BOUND_CURRENT_ROW,
    FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_UNITS_RANGE,
    FRAME_UNITS_ROWS,
    PartitionFrame,
)

from .partition_keys import _peer_bounds, _segment_ends, column_has_nulls


comptime _UNBOUNDED_NEG: Int = -(1 << 62)
comptime _UNBOUNDED_POS: Int = (1 << 62)


struct FrameIdx(Movable):
    """Per-row `[lo, hi)` frames, absolute indices into the sorted batch."""

    var lo: List[Int]
    var hi: List[Int]

    def __init__(out self, var lo: List[Int], var hi: List[Int]):
        self.lo = lo^
        self.hi = hi^


def _zeros(n: Int) -> List[Int]:
    var out = List[Int](capacity=n)
    for _ in range(n):
        out.append(0)
    return out^


@always_inline
def _is_offset_bound(tag: UInt8) -> Bool:
    """True for `<n> PRECEDING` / `<n> FOLLOWING`, the bounds with a number."""
    return tag == FRAME_BOUND_PRECEDING or tag == FRAME_BOUND_FOLLOWING


# =============================================================================
# ROWS
# =============================================================================


def _rows_offset(tag: UInt8, offset: Int64) -> Int:
    """A ROWS bound as a row offset from the current row."""
    if tag == FRAME_BOUND_UNBOUNDED_PRECEDING:
        return _UNBOUNDED_NEG
    elif tag == FRAME_BOUND_PRECEDING:
        return -Int(offset)
    elif tag == FRAME_BOUND_CURRENT_ROW:
        return 0
    elif tag == FRAME_BOUND_FOLLOWING:
        return Int(offset)
    return _UNBOUNDED_POS


@always_inline
def _clamp(v: Int, lo: Int, hi: Int) -> Int:
    if v < lo:
        return lo
    if v > hi:
        return hi
    return v


def _rows_frame_index(
    bounds: List[Int], ends: List[Int], n: Int, frame: PartitionFrame
) -> FrameIdx:
    """ROWS: each bound is a constant row offset, clamped to the partition."""
    var start_off = _rows_offset(frame.start_tag, frame.start_offset)
    var end_off = _rows_offset(frame.end_tag, frame.end_offset)
    var lo = _zeros(n)
    var hi = _zeros(n)
    for p in range(len(bounds)):
        var s = bounds[p]
        var e = ends[p]
        var plen = e - s
        for row in range(s, e):
            var r = row - s
            var l = s + _clamp(r + start_off, 0, plen)
            var h = s + _clamp(r + end_off + 1, 0, plen)
            if h < l:
                h = l
            lo[row] = l
            hi[row] = h
    return FrameIdx(lo^, hi^)


# =============================================================================
# RANGE without an offset: peer groups
# =============================================================================


def _range_peer_frame_index(
    batch: RecordBatch,
    bounds: List[Int],
    ends: List[Int],
    order_keys: List[String],
    frame: PartitionFrame,
) raises -> FrameIdx:
    """RANGE whose two bounds are UNBOUNDED or CURRENT ROW: `CURRENT ROW` as a
    start is the first row of the current peer group, as an end its last."""
    var n = batch.num_rows()
    var peers = _peer_bounds(batch, bounds, order_keys)
    var peer_ends = _segment_ends(peers, n)
    var lo = _zeros(n)
    var hi = _zeros(n)
    var g = 0
    for p in range(len(bounds)):
        var s = bounds[p]
        var e = ends[p]
        for row in range(s, e):
            while g + 1 < len(peers) and peers[g + 1] <= row:
                g += 1
            var l: Int
            if frame.start_tag == FRAME_BOUND_UNBOUNDED_PRECEDING:
                l = s
            elif frame.start_tag == FRAME_BOUND_CURRENT_ROW:
                l = peers[g]
            else:
                l = e
            var h: Int
            if frame.end_tag == FRAME_BOUND_UNBOUNDED_FOLLOWING:
                h = e
            elif frame.end_tag == FRAME_BOUND_CURRENT_ROW:
                h = peer_ends[g]
            else:
                h = s
            if h < l:
                h = l
            lo[row] = l
            hi[row] = h
    return FrameIdx(lo^, hi^)


# =============================================================================
# RANGE with an offset: a value window on the one order key
# =============================================================================


def _range_value_fill[
    dt: DType
](
    key_col: Column[HeapRegion],
    bounds: List[Int],
    ends: List[Int],
    n: Int,
    frame: PartitionFrame,
    desc: Bool,
) raises -> FrameIdx:
    """RANGE over one INT64 or FLOAT64 order key with no NULL and no NaN.

    `desc` mirrors every threshold rather than swapping the bounds: under
    `ORDER BY k DESC`, PRECEDING still means earlier in the window's order,
    which is a larger key, so `n PRECEDING` is `key <= k + n` where ascending
    it is `key >= k - n`. The offset is converted to the key's own type; an
    INT64 key is never routed through FLOAT64, where a key above 2^53 would
    lose its low bits and move a frame edge.
    """
    var lo = _zeros(n)
    var hi = _zeros(n)
    var s_off = Scalar[dt](frame.start_offset)
    var e_off = Scalar[dt](frame.end_offset)
    for p in range(len(bounds)):
        var seg_start = bounds[p]
        var seg_end = ends[p]
        var cur_lo = seg_start
        var cur_hi = seg_start
        for row in range(seg_start, seg_end):
            var k = key_col._data.get_typed[Scalar[dt]](key_col._offset + row)

            var new_lo: Int
            if frame.start_tag == FRAME_BOUND_UNBOUNDED_PRECEDING:
                new_lo = seg_start
            elif frame.start_tag == FRAME_BOUND_UNBOUNDED_FOLLOWING:
                new_lo = seg_end
            else:
                var b: Scalar[dt]
                if frame.start_tag == FRAME_BOUND_PRECEDING:
                    b = (k + s_off) if desc else (k - s_off)
                elif frame.start_tag == FRAME_BOUND_FOLLOWING:
                    b = (k - s_off) if desc else (k + s_off)
                else:
                    b = k
                while cur_lo < seg_end:
                    var kv = key_col._data.get_typed[Scalar[dt]](
                        key_col._offset + cur_lo
                    )
                    var before = (kv > b) if desc else (kv < b)
                    if not before:
                        break
                    cur_lo += 1
                new_lo = cur_lo

            var new_hi: Int
            if frame.end_tag == FRAME_BOUND_UNBOUNDED_FOLLOWING:
                new_hi = seg_end
            elif frame.end_tag == FRAME_BOUND_UNBOUNDED_PRECEDING:
                new_hi = seg_start
            else:
                var b2: Scalar[dt]
                if frame.end_tag == FRAME_BOUND_PRECEDING:
                    b2 = (k + e_off) if desc else (k - e_off)
                elif frame.end_tag == FRAME_BOUND_FOLLOWING:
                    b2 = (k - e_off) if desc else (k + e_off)
                else:
                    b2 = k
                while cur_hi < seg_end:
                    var kv2 = key_col._data.get_typed[Scalar[dt]](
                        key_col._offset + cur_hi
                    )
                    var inside = (kv2 >= b2) if desc else (kv2 <= b2)
                    if not inside:
                        break
                    cur_hi += 1
                new_hi = cur_hi

            # An end bound before the start bound is an empty frame.
            if new_hi < new_lo:
                new_hi = new_lo
            lo[row] = new_lo
            hi[row] = new_hi
    return FrameIdx(lo^, hi^)


def _range_value_frame_index(
    batch: RecordBatch,
    bounds: List[Int],
    ends: List[Int],
    order_keys: List[String],
    descending: List[Bool],
    frame: PartitionFrame,
) raises -> FrameIdx:
    """RANGE with an offset bound, resolved against the order key's values."""
    if len(order_keys) == 0:
        raise Error(
            "partition_frame_index: `RANGE BETWEEN <n> PRECEDING/FOLLOWING`"
            " measures its bound against the ORDER BY key, and this window"
            " has no ORDER BY; add one, or write the frame in ROWS"
        )
    if len(order_keys) != 1:
        raise Error(
            "partition_frame_index: a RANGE frame with an offset needs exactly"
            " one ORDER BY key; this window has "
            + String(len(order_keys))
        )
    var n = batch.num_rows()
    ref key_col = batch.column_at(batch.schema.column_index(order_keys[0]))
    var desc = False
    if len(descending) > 0:
        desc = descending[0]
    if column_has_nulls(key_col):
        raise Error(
            "partition_frame_index: a RANGE frame with an offset over an ORDER"
            " BY key that holds NULLs is not supported; filter the NULLs, or"
            " write the frame in ROWS"
        )
    if key_col.arrow_type == ArrowType.INT64:
        return _range_value_fill[DType.int64](key_col, bounds, ends, n, frame, desc)
    elif key_col.arrow_type == ArrowType.FLOAT64:
        for r in range(n):
            if isnan(key_col._data.get_typed[Scalar[DType.float64]](key_col._offset + r)):
                raise Error(
                    "partition_frame_index: a RANGE frame with an offset over"
                    " an ORDER BY key that holds NaN is not supported; write"
                    " the frame in ROWS"
                )
        return _range_value_fill[DType.float64](
            key_col, bounds, ends, n, frame, desc
        )
    raise Error(
        "partition_frame_index: a RANGE frame with an offset needs an INT64 or"
        " FLOAT64 ORDER BY key; got "
        + String(key_col.arrow_type)
    )


# =============================================================================
# The entry point
# =============================================================================


def frame_index(
    batch: RecordBatch,
    bounds: List[Int],
    order_keys: List[String],
    descending: List[Bool],
    frame: PartitionFrame,
) raises -> FrameIdx:
    """Every row's frame, the units decision made once for the operator.

    `batch` is sorted by (partition keys ++ order keys) and `bounds` holds
    the partition starts (`partition_keys._detect_partition_boundaries`).
    """
    var n = batch.num_rows()
    var ends = _segment_ends(bounds, n)
    if frame.units == FRAME_UNITS_RANGE:
        if _is_offset_bound(frame.start_tag) or _is_offset_bound(frame.end_tag):
            return _range_value_frame_index(
                batch, bounds, ends, order_keys, descending, frame
            )
        return _range_peer_frame_index(batch, bounds, ends, order_keys, frame)
    if frame.units != FRAME_UNITS_ROWS:
        raise Error(
            "partition_frame_index: unknown frame units "
            + String(Int(frame.units))
        )
    return _rows_frame_index(bounds, ends, n, frame)
