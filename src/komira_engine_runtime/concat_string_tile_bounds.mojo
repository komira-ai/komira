# =============================================================================
# concat_string_tile_bounds — BYTE-balanced row bounds for STRING/BINARY tiles
# =============================================================================
#
# ★ WHY NOT EQUAL ROW RANGES. Cutting a column into equal ROW ranges is equal
# WORK for a fixed-width column — every row moves `width` bytes. For a
# STRING/BINARY column (the kind-3 tiles) it is not: a tile moves its rows'
# PAYLOAD plus one Int32 offset per row, and payload length is data. A skewed
# column (a run of long values among short ones) gives equal-row tiles very
# unequal costs, and a copy fan's wall is its LARGEST tile.
#
# ★ WHAT THIS DOES. Picks the tile bounds so every tile carries ~equal COST,
#     cost(R) = payload bytes before output row R  +  4 * R
# i.e. the bytes written below row R (payload + offsets). `cost` is monotone in
# R, so bound t is the smallest R with cost(R) >= t * total_cost / tiles: a
# forward walk over batches (O(num_batches)) plus one binary search over ONE
# batch's source offsets per bound (O(tiles * log rows)). Never O(rows).
#
# ★ WHY THE CONCAT STAYS BYTE-IDENTICAL. The bounds are non-decreasing, start
# at 0 and end at `total_rows`, so the tiles still PARTITION [0, total_rows) —
# the one property `_concat_string_column_into_range`'s disjointness contract
# rests on. WHERE the cuts fall changes which thread writes a byte, never which
# byte is written. Any partition is correct; this one is balanced.
#
# ⚠ THE BALANCE BOUND IS ONE ROW, NOT ZERO. A tile cannot split a row, so each
# tile's cost is within one row's cost (its payload + 4) of the target. Pinned
# by `test_concat_one_column_parallel.mojo` R7.
# =============================================================================

from std.collections.optional import Optional

from komira_arrow.schema import RecordBatch
from komira_collections.slab import Slab

comptime STRING_TILE_ROW_COST_BYTES: Int = 4
"""Bytes one output row costs beyond its payload: its Int32 offset slot."""


def _row_cost_at(
    imm input_slab: Slab[Optional[RecordBatch]],
    batch: Int,
    col: Int,
    local_row: Int,
    b_row_start: Int,
    b_byte_start: Int,
) raises -> Int:
    """cost(b_row_start + local_row) for a row boundary INSIDE batch `batch`
    (0 <= local_row <= rows). Reads ONE source offset through the safe typed
    accessor; the batch's own `_offset` (a sliced source) is honoured."""
    ref col_ref = input_slab[batch].value().column_at(col)
    if not col_ref._offsets:
        raise Error(
            "concat_string_tile_bounds: batch " + String(batch) + " column "
            + String(col) + " has rows but no offsets buffer"
        )
    var off = col_ref._offset
    ref offs = col_ref._offsets.value()
    var data_start = Int(offs.get_typed[Int32](off))
    var here = Int(offs.get_typed[Int32](off + local_row))
    return (
        b_byte_start
        + (here - data_start)
        + STRING_TILE_ROW_COST_BYTES * (b_row_start + local_row)
    )


def string_tile_row_bounds(
    imm input_slab: Slab[Optional[RecordBatch]],
    num_batches: Int,
    col: Int,
    imm batch_row_offset: List[Int],
    imm batch_byte_prefix: List[Int],
    total_rows: Int,
    tiles: Int,
) raises -> List[Int]:
    """`tiles + 1` non-decreasing row bounds for STRING/BINARY column `col`:
    `bounds[0] == 0`, `bounds[tiles] == total_rows`, and tile `t` is
    `[bounds[t], bounds[t+1])` carrying ~`total_cost / tiles` of
    payload-plus-offsets bytes. A zero-width tile (a single row costlier than a
    whole target) is legal and is skipped by the caller exactly as an empty
    equal-row tile always was.

    Args:
        input_slab: The concat's input batches (read-only; None / zero-row
            slots contribute nothing).
        num_batches: `len(input_slab)`.
        col: The STRING/BINARY column.
        batch_row_offset: Output row index of each batch's first row
            (`num_batches` entries) — the tiled driver's own prefix.
        batch_byte_prefix: Output byte offset of each batch's payload
            (`num_batches + 1` entries, last = column total) — exactly
            `_string_batch_byte_prefix`'s result.
        total_rows: Rows in the concatenated output.
        tiles: Tile count (>= 1).
    """
    var bounds = List[Int](capacity=tiles + 1)
    bounds.append(0)
    if tiles <= 1 or total_rows <= 0:
        bounds.append(total_rows)
        return bounds^

    var total_bytes = batch_byte_prefix[num_batches]
    var total_cost = total_bytes + STRING_TILE_ROW_COST_BYTES * total_rows

    var i = 0  # batch cursor, monotone across the targets
    for t in range(1, tiles):
        var target = (t * total_cost) // tiles
        var bound = total_rows
        while i < num_batches:
            if not input_slab[i]:
                i += 1
                continue
            var rows = input_slab[i].value().column_at(col)._length
            if rows == 0:
                i += 1
                continue
            var b_row = batch_row_offset[i]
            var b_byte = batch_byte_prefix[i]
            var end_cost = (
                batch_byte_prefix[i + 1]
                + STRING_TILE_ROW_COST_BYTES * (b_row + rows)
            )
            if end_cost < target:
                i += 1
                continue
            # Smallest local x in [0, rows] with cost(b_row + x) >= target.
            # cost(b_row + rows) == end_cost >= target, so `hi` is a valid
            # answer and the search is well-founded.
            var lo = 0
            var hi = rows
            while lo < hi:
                var mid = (lo + hi) // 2
                if _row_cost_at(input_slab, i, col, mid, b_row, b_byte) >= target:
                    hi = mid
                else:
                    lo = mid + 1
            bound = b_row + lo
            break
        # Monotone by construction (targets rise, the cursor never moves back);
        # clamped anyway so a malformed prefix can only produce an EMPTY tile,
        # never an overlapping one.
        if bound < bounds[len(bounds) - 1]:
            bound = bounds[len(bounds) - 1]
        if bound > total_rows:
            bound = total_rows
        bounds.append(bound)
    bounds.append(total_rows)
    return bounds^
