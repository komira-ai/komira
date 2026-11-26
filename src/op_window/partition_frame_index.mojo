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
#     the partition whose key lies in `[k - 1, k]`. Served for one INT64,
#     INT32 or FLOAT64 key, as DuckDB v1.5.6 answers it (measured):
#       - a row whose key is NULL frames over the NULL peer group: each bound
#         with an offset, and CURRENT ROW, is the group's edge; an UNBOUNDED
#         bound stays the partition's edge. The NULL group is at one end of
#         the partition: the end when the key's placement is NULLS LAST, the
#         start when it is NULLS FIRST (the same rule, mirrored);
#       - a row whose key is not NULL searches its offset bounds among the
#         rows whose key is not NULL; UNBOUNDED FOLLOWING still reaches the
#         partition's end, NULL keys included;
#       - floats compare in DuckDB's order (`sort_key_lt`: NaN above +inf and
#         equal to NaN), and NaN or an infinity plus or minus an offset is
#         itself, so each offset bound of a NaN key is an edge of the NaN
#         peer group;
#       - an integer bound that leaves the key's type raises DuckDB's
#         `Overflow in subtraction / addition` error. DuckDB computes the
#         bound in the wider of the key's type and the offset literal's
#         (INTEGER when the offset fits in 32 bits, else BIGINT), so an
#         INT32 key overflows at INT32 for a small offset and at INT64 for a
#         wide one.
#
# Both lists are non-decreasing in `row` within a partition, under every
# unit: the ring-buffer kernels need that. ROWS clamps an affine function;
# RANGE walks a key that is sorted inside the partition.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.record_batch import RecordBatch
from byte_buffer.heap_region import HeapRegion
from op_sort.sort import sort_key_lt
from plan_expr.null_order_policy import derived_nulls_first
from plan_expr.partition_expr import (
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


# A ROWS offset is clamped to this magnitude before it is added to a row
# position: past any partition's length it frames the same rows, and the sum
# of a position and a clamped offset cannot overflow (`9223372036854775807
# FOLLOWING` would).
comptime _ROWS_OFFSET_LIMIT: Int64 = Int64(1 << 61)


def _clamped(offset: Int64) -> Int:
    if offset > _ROWS_OFFSET_LIMIT:
        return Int(_ROWS_OFFSET_LIMIT)
    if offset < -_ROWS_OFFSET_LIMIT:
        return -Int(_ROWS_OFFSET_LIMIT)
    return Int(offset)


def _rows_offset(tag: UInt8, offset: Int64) -> Int:
    """A ROWS bound as a row offset from the current row. A negative offset
    looks the other way (`-1 PRECEDING` is the row after). Lowering refuses a
    negative offset (`cut_window`), so a SQL frame never brings one here."""
    if tag == FRAME_BOUND_UNBOUNDED_PRECEDING:
        return _UNBOUNDED_NEG
    elif tag == FRAME_BOUND_PRECEDING:
        return -_clamped(offset)
    elif tag == FRAME_BOUND_CURRENT_ROW:
        return 0
    elif tag == FRAME_BOUND_FOLLOWING:
        return _clamped(offset)
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


comptime _INT32_MIN: Int64 = -2147483648
comptime _INT32_MAX: Int64 = 2147483647


def _overflow(
    toward_larger: Bool, type_name: String, k: Int64, off: Int64, key: String
) -> Error:
    """DuckDB's error for a RANGE bound that leaves the key's type."""
    var op = String("addition") if toward_larger else String("subtraction")
    var sign = String(" + ") if toward_larger else String(" - ")
    return Error(
        "partition_frame_index: Out of Range Error: Overflow in "
        + op
        + " of "
        + type_name
        + " ("
        + String(k)
        + sign
        + String(off)
        + ")! (the RANGE frame bound of the ORDER BY key '"
        + key
        + "')"
    )


def _int_bound(
    k: Int64, off: Int64, toward_larger: Bool, key_is_int32: Bool, key: String
) raises -> Int64:
    """`k + off` or `k - off` for an integer key, raising where DuckDB does:
    at INT64 always, and at INT32 for an INT32 key whose offset fits in 32
    bits (DuckDB types such an offset INTEGER)."""
    var r: Int64
    if toward_larger:
        if (off > 0 and k > Int64.MAX - off) or (off < 0 and k < Int64.MIN - off):
            raise _overflow(toward_larger, "INT64", k, off, key)
        r = k + off
    else:
        if (off > 0 and k < Int64.MIN + off) or (off < 0 and k > Int64.MAX + off):
            raise _overflow(toward_larger, "INT64", k, off, key)
        r = k - off
    if (
        key_is_int32
        and off >= _INT32_MIN
        and off <= _INT32_MAX
        and (r < _INT32_MIN or r > _INT32_MAX)
    ):
        raise _overflow(toward_larger, "INT32", k, off, key)
    return r


def _bound_value[
    dt: DType, wide: DType
](
    k: Scalar[wide], tag: UInt8, offset: Int64, desc: Bool, key: String
) raises -> Scalar[wide]:
    """The key value a PRECEDING, FOLLOWING or CURRENT ROW bound measures
    against. Under `ORDER BY k DESC`, PRECEDING still means earlier in the
    window's order, which is a larger key: `n PRECEDING` is `k + n` there and
    `k - n` ascending."""
    if tag == FRAME_BOUND_CURRENT_ROW:
        return k
    var toward_larger = (tag == FRAME_BOUND_PRECEDING) == desc
    comptime if wide.is_floating_point():
        var o = offset.cast[wide]()
        return (k + o) if toward_larger else (k - o)
    else:
        var r = _int_bound(
            k.cast[DType.int64](), offset, toward_larger, dt == DType.int32, key
        )
        return r.cast[wide]()


@always_inline
def _key_at[
    dt: DType, wide: DType
](key_col: Column[HeapRegion], row: Int) -> Scalar[wide]:
    return key_col._data.get_typed[Scalar[dt]](key_col._offset + row).cast[
        wide
    ]()


@always_inline
def _before[wide: DType](kv: Scalar[wide], b: Scalar[wide], desc: Bool) -> Bool:
    """True iff key `kv` comes before the bound value `b` in the window's
    order (DuckDB's float order: NaN last ascending, first descending)."""
    return sort_key_lt[wide](b, kv) if desc else sort_key_lt[wide](kv, b)


def _non_null_end(key_col: Column[HeapRegion], seg_start: Int, seg_end: Int) -> Int:
    """The first row of the partition's trailing NULL-key group (NULLs placed
    last), or `seg_end` when no key is NULL."""
    var e = seg_end
    while e > seg_start and key_col.is_null_at(e - 1):
        e -= 1
    return e


def _non_null_start(key_col: Column[HeapRegion], seg_start: Int, seg_end: Int) -> Int:
    """The first row after the partition's leading NULL-key group (NULLs
    placed first), or `seg_start` when no key is NULL."""
    var s = seg_start
    while s < seg_end and key_col.is_null_at(s):
        s += 1
    return s


def _check_bounds[
    dt: DType, wide: DType
](
    key_col: Column[HeapRegion],
    key: String,
    bounds: List[Int],
    ends: List[Int],
    nullable: Bool,
    nulls_first: Bool,
    tag: UInt8,
    offset: Int64,
    desc: Bool,
) raises:
    """Compute one bound of every row whose key is not NULL, so that a bound
    that leaves the key's type raises before any frame is built. DuckDB
    computes every start bound before any end bound, so the row its error
    names is the first start bound that overflows, else the first end bound:
    `RANGE BETWEEN 1 FOLLOWING AND 10 FOLLOWING` over INTEGER keys 2147483642
    and 2147483647 names `2147483647 + 1`, not `2147483642 + 10`."""
    if tag != FRAME_BOUND_PRECEDING and tag != FRAME_BOUND_FOLLOWING:
        return
    for p in range(len(bounds)):
        var nn_start = bounds[p]
        var nn_end = ends[p]
        if nullable:
            if nulls_first:
                nn_start = _non_null_start(key_col, bounds[p], ends[p])
            else:
                nn_end = _non_null_end(key_col, bounds[p], ends[p])
        for row in range(nn_start, nn_end):
            _ = _bound_value[dt, wide](
                _key_at[dt, wide](key_col, row), tag, offset, desc, key
            )


def _range_value_fill[
    dt: DType, wide: DType
](
    key_col: Column[HeapRegion],
    key: String,
    bounds: List[Int],
    ends: List[Int],
    n: Int,
    frame: PartitionFrame,
    desc: Bool,
    nulls_first: Bool,
) raises -> FrameIdx:
    """RANGE over one INT64, INT32 or FLOAT64 order key, every bound compared
    in `wide` (INT64 for an integer key, FLOAT64 for a float one): an INT64
    key is never routed through FLOAT64, where a key above 2^53 would lose its
    low bits and move a frame edge."""
    var nullable = column_has_nulls(key_col)
    # A float bound cannot overflow: NaN and the infinities absorb an offset.
    comptime if not wide.is_floating_point():
        _check_bounds[dt, wide](
            key_col, key, bounds, ends, nullable, nulls_first,
            frame.start_tag, frame.start_offset, desc,
        )
        _check_bounds[dt, wide](
            key_col, key, bounds, ends, nullable, nulls_first,
            frame.end_tag, frame.end_offset, desc,
        )
    var lo = _zeros(n)
    var hi = _zeros(n)
    for p in range(len(bounds)):
        var seg_start = bounds[p]
        var seg_end = ends[p]
        # The non-NULL rows are [nn_start, nn_end); the NULL group is the rest
        # of the partition, [seg_start, nn_start) or [nn_end, seg_end).
        var nn_start = seg_start
        var nn_end = seg_end
        if nullable:
            if nulls_first:
                nn_start = _non_null_start(key_col, seg_start, seg_end)
            else:
                nn_end = _non_null_end(key_col, seg_start, seg_end)
        var null_lo = seg_start if nulls_first else nn_end
        var null_hi = nn_start if nulls_first else seg_end
        var cur_lo = nn_start
        var cur_hi = nn_start
        for row in range(seg_start, seg_end):
            var new_lo: Int
            var new_hi: Int
            if frame.start_tag == FRAME_BOUND_UNBOUNDED_PRECEDING:
                new_lo = seg_start
            elif frame.start_tag == FRAME_BOUND_UNBOUNDED_FOLLOWING:
                new_lo = seg_end
            elif row < nn_start or row >= nn_end:
                new_lo = null_lo
            else:
                var b = _bound_value[dt, wide](
                    _key_at[dt, wide](key_col, row),
                    frame.start_tag, frame.start_offset, desc, key,
                )
                while cur_lo < nn_end and _before[wide](
                    _key_at[dt, wide](key_col, cur_lo), b, desc
                ):
                    cur_lo += 1
                new_lo = cur_lo

            if frame.end_tag == FRAME_BOUND_UNBOUNDED_FOLLOWING:
                new_hi = seg_end
            elif frame.end_tag == FRAME_BOUND_UNBOUNDED_PRECEDING:
                new_hi = seg_start
            elif row < nn_start or row >= nn_end:
                new_hi = null_hi
            else:
                var b2 = _bound_value[dt, wide](
                    _key_at[dt, wide](key_col, row),
                    frame.end_tag, frame.end_offset, desc, key,
                )
                # A row is inside the end bound while the bound does not come
                # before it.
                while cur_hi < nn_end and not _before[wide](
                    b2, _key_at[dt, wide](key_col, cur_hi), desc
                ):
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
    nulls_first: List[Bool],
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
    var key = String(order_keys[0])
    ref key_col = batch.column_at(batch.schema.column_index(key))
    var desc = False
    if len(descending) > 0:
        desc = descending[0]
    var nf = derived_nulls_first(desc)
    if len(nulls_first) > 0:
        nf = nulls_first[0]
    if key_col.arrow_type == ArrowType.INT64:
        return _range_value_fill[DType.int64, DType.int64](
            key_col, key, bounds, ends, n, frame, desc, nf
        )
    elif key_col.arrow_type == ArrowType.INT32:
        return _range_value_fill[DType.int32, DType.int64](
            key_col, key, bounds, ends, n, frame, desc, nf
        )
    elif key_col.arrow_type == ArrowType.FLOAT64:
        return _range_value_fill[DType.float64, DType.float64](
            key_col, key, bounds, ends, n, frame, desc, nf
        )
    raise Error(
        "partition_frame_index: a RANGE frame with an offset needs an INT64,"
        " INT32 or FLOAT64 ORDER BY key; got "
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
    nulls_first: List[Bool] = List[Bool](),
) raises -> FrameIdx:
    """Every row's frame, the units decision made once for the operator.

    `batch` is sorted by (partition keys ++ order keys) and `bounds` holds
    the partition starts (`partition_keys._detect_partition_boundaries`).
    `nulls_first` is the per-order-key NULL placement the batch was sorted
    under; empty derives it from `descending`.
    """
    var n = batch.num_rows()
    var ends = _segment_ends(bounds, n)
    if frame.units == FRAME_UNITS_RANGE:
        if _is_offset_bound(frame.start_tag) or _is_offset_bound(frame.end_tag):
            return _range_value_frame_index(
                batch, bounds, ends, order_keys, descending, frame, nulls_first
            )
        return _range_peer_frame_index(batch, bounds, ends, order_keys, frame)
    if frame.units != FRAME_UNITS_ROWS:
        raise Error(
            "partition_frame_index: unknown frame units "
            + String(Int(frame.units))
        )
    return _rows_frame_index(bounds, ends, n, frame)
