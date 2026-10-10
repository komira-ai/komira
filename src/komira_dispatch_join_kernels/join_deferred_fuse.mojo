# =============================================================================
# join_deferred_fuse -- ROW-RANGE-MAJOR assembly: one index pass, N columns
# =============================================================================
#
# The deferred assembly forks (output column x row range) tiles, and it emits
# them COLUMN-MAJOR: every tile of column 0, then every tile of column 1, and so
# on. `_fill_deferred_value_range` therefore re-reads its column's slice of the
# match index once PER CONSUMING COLUMN, and two output columns that read the
# SAME index list get no reuse at all. This file owns the emission decision that
# removes that re-read, and the ARITHMETIC the byte ledger reports it with -- so
# the dispatch and the ledger cannot disagree about how many index passes ran.
#
# ★★ THE SAVING IS ONE INDEX PASS PER SIDE, NOT `columns - 1`. READ THIS BEFORE
# QUOTING A NUMBER FOR IT.
#
# An assembly consumes up to TWO distinct index arrays, never one: a PROBE-side
# output column is addressed by `ch.probe_idx` and a BUILD-side one by
# `ch.build_idx`. They are different arrays over different source columns, so no
# loop-order change can make a build-side column's read of `build_idx`
# disappear. The reachable ceiling is
#
#     saving = SUM over sides of (gathered_columns_on_that_side - 1) passes
#
# and on a high-cardinality join benchmark that is (2 - 1) + (1 - 1) = **ONE** pass:
# 4 output columns, the final-level join-key CSE aliases `b.key` onto `p.key`,
# leaving 2 probe-side gathers sharing `probe_idx` and 1 build-side gather of
# `build_idx`. With 100,009,017 matches that is
#
#     8 B x 100,009,017 = 800,072,136 B = 0.745 GiB   (index 8 bytes wide)
#     4 B x 100,009,017 = 400,036,068 B = 0.373 GiB   (index 4 bytes wide)
#
# ⛔ NOT 1.49 GiB. A model that prices this as "three reads become one" has
# assumed a single shared index array; it double-counts by exactly 2x, and the
# wrong answer is easy to miss because `2 x 800,072,136` is ALSO the exact size
# of a real neighbouring term (the probe+build index lists' original WRITE in
# `join_probe_op`), so it collides with a true number in the same ledger.
#
# ⚠ AND IT COMPOSES WITH THE 4-BYTE INDEX MULTIPLICATIVELY, NOT ADDITIVELY.
# That halves the WIDTH of every index element; this halves-ish the NUMBER of
# passes over them. Together that join's re-read goes 3 x 8 B -> 2 x 4 B per match, a 3x cut; each
# lever's own value depends on whether the other is armed, so a band for one
# must state the other's arm.
#
# WHAT IS FUSED, AND WHY THE PAIRING IS RESTRICTED
#
# A fused work item fills TWO output columns from ONE walk of the index. The two
# columns must agree on:
#   * the SIDE -- otherwise they read different index arrays and there is
#     nothing to share (this is the whole point above);
#   * the byte WIDTH -- the gather's hot loop is typed (`Scalar[int64]` /
#     `Scalar[int32]` stores), and the destination tiling is computed once for
#     the whole assembly from the widest column, so two columns of unequal width
#     would need either a per-row width branch or two tilings. Equal-width
#     pairing keeps the fused loop exactly as tight as the single-column one.
# Anything unpaired keeps today's single-column item, byte for byte.
#
# ⚠ PAIRWISE, NOT N-WISE, AND THE RESIDUAL IS STATED RATHER THAN HIDDEN. A group
# of G equal-width same-side columns costs `ceil(G / 2)` passes here where the
# theoretical floor is 1. For G = 2 -- that join's shape, and the shape of every
# two-column-per-side equi-join -- pairwise IS the floor, which is why it is
# what got built. G >= 3 leaves `ceil(G/2) - 1` passes on the table; closing it
# needs a kernel holding G destination pointers, which cannot be spelled with
# `ref` bindings in Mojo 1.0.0 and would trade the typed hot loop for an
# indirect one. Do not "generalize" this without measuring that trade.
# =============================================================================

# =============================================================================
# ⭐ ROW-RANGE-MAJOR EMISSION IS UNCONDITIONAL
# =============================================================================
#
# There is no column-major arm and no switch. Fusing ADDS concurrent memory
# streams -- a fused task holds 2 destination write streams + 2 source read
# streams + 1 index read stream where a single-column task holds 1 + 1 + 1, so
# at 20 workers ~100 concurrent streams against ~60 -- and a DRAM page-open
# policy could lose more to that than the removed pass wins back. Measured
# together with the 4-byte index and `hbs_key_extract`'s build-key sharing
# (toggled TOGETHER, 20 workers, one binary against itself), the bundle cut a
# high-cardinality join's wall time 6.2% with DISJOINT ranges, and its
# memory-controller traffic 6.4%. The stream cost, if it exists, is smaller
# than the pass it removes.
#   ⚠ The BUNDLE is what was measured; there is no per-lever wall attribution.
#     This lever's own modelled saving there is 0.745 GiB, below the wall
#     detection floor at any rep count an operator will run.
#
# ARMING, in that same run: `fused_pairs` 0 -> 6 (one pair per assembly) and
# `idx_passes` 18 -> 12 (3 -> 2 per assembly). Those are GEOMETRY -- they prove
# the emission changed and say nothing about DRAM; the memory-controller number
# above is the traffic claim.
#
# ⛔ THE PAIRING RULE IS NOT A SWITCH. `_same_index_list` refuses to pair
# across the probe/build boundary, and the width equality refuses to pair
# unlike columns. Both are correctness conditions on the fused kernel, and the
# first is also the reason the saving is one pass per SIDE rather than
# `columns - 1`.
# =============================================================================


# =============================================================================
# The work item
# =============================================================================


@fieldwise_init
struct _DeferredWork(Copyable, Movable):
    """One assembly work item.

    `kind == 0` -> VALUE tile: fill output rows [row_start, row_end) of output
    column `col_idx` -- and, when `col_b >= 0`, of output column `col_b` as
    well, from the SAME walk of the shared index list.
    `kind == 2` -> VALIDITY + null count for the whole of output column
    `col_idx` (`row_end` carries `total_rows`; the item has no row range of its
    own, and `col_b` is always -1: a bitmap walk reads no index on any shape
    this route admits, so there is nothing for it to share).
    """
    var col_idx: Int32
    var col_b: Int32
    var kind: UInt8
    var row_start: Int
    var row_end: Int


@fieldwise_init
struct DeferredFusePlan(Copyable, Movable):
    """What the emission DECIDED, in numbers the byte ledger reads directly.

    ★ THE LEDGER MUST NOT RE-DERIVE THESE. `idx_passes` is the count of work
    items that will walk an index list end to end, and `idx_bytes_reread` is
    `idx_passes x (bytes of one index list)`. Computing that from the column
    count instead would be a second implementation of the pairing rule, free to
    drift from the first -- and the symptom of the drift would be a byte figure
    quoted in a write-up, not a red test.
    """

    var idx_passes: Int
    """Full passes over an index list the emitted value items will perform.
    Equals the gathered column count when no pair forms."""

    var fused_pairs: Int
    """Value items carrying TWO columns. 0 means the lever did not arm -- the
    firing observable, and the thing a vacuous A/B cannot distinguish from a
    lever that armed and did nothing."""


# =============================================================================
# The emission
# =============================================================================


@always_inline
def _same_index_list(a: Int, b: Int, probe_ncols: Int) -> Bool:
    """True iff output columns `a` and `b` are addressed by the same index list.

    Probe-side columns (`< probe_ncols`) read `probe_idx`; build-side columns
    read `build_idx`. This one predicate is the whole reason the saving is one
    pass per SIDE and not one per column.
    """
    return (a < probe_ncols) == (b < probe_ncols)


def plan_deferred_work_items(
    imm alias_out: List[Int],
    imm col_width: List[Int],
    probe_ncols: Int,
    total_rows: Int,
    tiles: Int,
    mut work_items: List[_DeferredWork],
) raises -> DeferredFusePlan:
    """Append the assembly's work items to `work_items`; report what it decided.

    A column with `alias_out[c] >= 0` is a join-key CSE share: it allocates no
    buffer, dispatches no tile and reads no index, so it appears in NO item and
    contributes to NO term. That is the CSE's whole saving and both the dispatch
    and the ledger have to show it, or an A/B of the CSE reads as a null.

    ⚠ AN UNPAIRED COLUMN GETS THE COLUMN-MAJOR SEQUENCE, ITEM FOR ITEM --
    including the ordering rule that a column's VALIDITY item is emitted
    immediately before that column's value tiles (validity is the longest
    single item of the two kinds, a whole-column bitmap walk, and a straggler
    costs least when it starts earliest; the tiled concat orders the same way).
    A pair preserves that rule per column, so the only difference from the
    column-major sequence is which columns share a tile.
    """
    var num_cols = len(alias_out)
    var passes = 0
    var pairs = 0

    # Walk the columns in output order and give each unclaimed gathered column
    # the next unclaimed gathered column that shares its index list AND its
    # width. Output order is preserved for the FIRST member of every pair.
    #
    # ⚠ AN UNPAIRED COLUMN IS NOT A SPECIAL CASE -- IT IS `partner == -1`, AND
    # THAT IS WHY THE COLUMN-MAJOR ARM COULD BE DELETED RATHER THAN KEPT AS A
    # FALLBACK. A column with no eligible partner emits exactly the item the
    # retired arm emitted for it, byte for byte, through the same
    # `_append_value_tiles` call; the old arm was the case where EVERY column
    # took that path. So the shapes it used to serve -- an odd column count, a
    # side with one gathered column (that join's build side, after the CSE),
    # a width mismatch -- are all still served, by this loop, unchanged.
    var claimed = List[Bool](capacity=num_cols)
    for _ in range(num_cols):
        claimed.append(False)

    for c in range(num_cols):
        if alias_out[c] >= 0 or claimed[c]:
            continue
        var partner = -1
        for e in range(c + 1, num_cols):
            if alias_out[e] >= 0 or claimed[e]:
                continue
            if (
                _same_index_list(c, e, probe_ncols)
                and col_width[c] == col_width[e]
            ):
                partner = e
                break
        claimed[c] = True
        passes += 1
        work_items.append(
            _DeferredWork(Int32(c), Int32(-1), UInt8(2), 0, total_rows)
        )
        if partner >= 0:
            claimed[partner] = True
            pairs += 1
            # The partner's VALIDITY is still its own whole-column item: a
            # bitmap is owned whole-column by ONE task precisely so no two
            # threads share a bitmap byte, and fusing two bitmap walks would
            # buy nothing (they read no index) while widening that ownership.
            work_items.append(
                _DeferredWork(
                    Int32(partner), Int32(-1), UInt8(2), 0, total_rows
                )
            )
        _append_value_tiles(work_items, c, partner, total_rows, tiles)

    return DeferredFusePlan(passes, pairs)


def _append_value_tiles(
    mut work_items: List[_DeferredWork],
    col_a: Int,
    col_b: Int,
    total_rows: Int,
    tiles: Int,
) raises:
    """The row-range split, for a single column (`col_b < 0`) or a fused pair.

    ⚠ ONE IMPLEMENTATION, WHICH IS LOAD-BEARING FOR THE DISJOINTNESS ARGUMENT
    THE DRIVER STATES. A fused item's destination byte slices are exactly the
    union of the two single-column items' because the tile boundaries are this
    one piece of arithmetic in both cases -- not two implementations kept in
    agreement by review. That mattered when the two emissions were selectable
    arms and it still matters now that only the pairing varies.
    """
    for t in range(tiles):
        var rs = (t * total_rows) // tiles
        var re = ((t + 1) * total_rows) // tiles
        if t == tiles - 1:
            re = total_rows
        if re <= rs:
            continue
        work_items.append(
            _DeferredWork(Int32(col_a), Int32(col_b), UInt8(0), rs, re)
        )
