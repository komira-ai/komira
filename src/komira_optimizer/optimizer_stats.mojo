# =============================================================================
# Optimizer statistics -- cardinality + row width estimation
# =============================================================================
#
# `estimate_cardinality` is used by join reordering (`optimizer_reorder`)
# and eager aggregation (`optimizer_eager_agg`). `estimate_row_width` is the
# row-width half of a build-side cost model (smaller side = build side); no
# build-side selection rule is in this tree.
#
# This is a port of the v0.3 Rust cost model (cardinality and
# estimate_row_width).
#
# Cardinality is heuristic: scan nodes return either
# `ScanData.row_count` (if populated) or a hardcoded default.
#
# The cost model a build-side selection is designed to use is:
#     build_cost = cardinality * row_width
# matching DuckDB `build_probe_side_optimizer.cpp:119-153` and our v0.3
# Rust implementation.
# =============================================================================

from komira_arrow.schema import Schema
from komira_arrow.arrow_types import ArrowType
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
)
from komira_plan_stats.table_stats import TableStats
from .optimizer_filter_selectivity import compute_selectivity


# =============================================================================
# Constants (matching DuckDB / v0.3)
# =============================================================================

# Default row count when no scan statistics are available.
comptime DEFAULT_ROW_COUNT: Int = 1_000_000

# Default selectivity for a scan-level filter with no stats (50%).
comptime DEFAULT_SCAN_FILTER_SELECTIVITY_NUM: Int = 1
comptime DEFAULT_SCAN_FILTER_SELECTIVITY_DEN: Int = 2

# Default selectivity for a generic Filter with no stats (50%).
comptime DEFAULT_FILTER_SELECTIVITY_NUM: Int = 1
comptime DEFAULT_FILTER_SELECTIVITY_DEN: Int = 2

# HAVING clause selectivity (Filter above Aggregate). HAVING predicates
# typically filter out most groups (e.g. TPC-H Q18's
# `SUM(l_quantity) > 300`). We use 1%. Matches DuckDB HAVING behavior.
# Encoded as num/den since Optional[Int] avoids Float64 copies.
comptime HAVING_SELECTIVITY_NUM: Int = 1
comptime HAVING_SELECTIVITY_DEN: Int = 100

# Semi/Anti join output cardinality heuristic: ~30% of left.
comptime SEMI_ANTI_SELECTIVITY_NUM: Int = 3
comptime SEMI_ANTI_SELECTIVITY_DEN: Int = 10

# Aggregate output heuristic when no stats: 10% of input.
comptime AGG_REDUCTION_FACTOR: Int = 10


# =============================================================================
# Ceil-semantics post-filter cardinality helpers.
#
# DuckDB's InspectTableFilter uses ceil(card / NDV), not floor. Floor
# truncates non-integral post-filter cardinalities downward, which
# underestimates the row count for small fractions. With the clamp-to-1
# floor most cases give the same result; ceil matters at small
# selectivities where the difference between 0.5 -> 1 (floor + clamp)
# vs 0.5 -> 1 (ceil) is moot, but at 1.5 -> 1 (floor) vs 2 (ceil) the
# ceil answer is closer to DuckDB. Adopted at both PLAN_SCAN-with-filter
# and PLAN_FILTER sites for symmetry with the DuckDB-mirror.
# =============================================================================


@always_inline
def _apply_selectivity_ceil(card: Int, sel: Float64) -> Int:
    """Compute ceil(card * sel) clamped to >= 1.

    Floor-to-Int truncation (`Int(card * sel)`) under-counts when the
    product is non-integral. The ceil-correction lifts the floor by
    one when there is a fractional remainder, so it changes the result
    only for a non-integral product; the clamp-to-1 below catches the
    degenerate sel ~ 0 case so we
    never emit 0 rows.
    """
    if card < 1:
        return 1
    var raw = Float64(card) * sel
    var floored = Int(raw)
    if floored < 1:
        return 1
    # Ceil: lift by one if there is a positive fractional remainder.
    if Float64(floored) < raw:
        return floored + 1
    return floored


@always_inline
def _ceil_div(num: Int, den: Int) -> Int:
    """Integer ceil division (HAVING-style num/den). Clamped to >= 1."""
    if den <= 0:
        return 1
    var raw = (num + den - 1) // den
    if raw < 1:
        return 1
    return raw


# =============================================================================
# estimate_row_width -- per-column byte width + HT entry overhead
# =============================================================================

@always_inline
def estimate_row_width(schema: Schema) -> Int:
    """Estimate the average row width in bytes for a schema.

    For a build-side cost model (not in this tree): wider rows cost more memory in the
    hash table. Includes a per-column overhead byte (DuckDB
    COLUMN_COUNT_PENALTY) and a fixed hash table entry overhead
    (hash + ~3 HT entry pointers).

    Ported from v0.3, which
    itself follows DuckDB `build_probe_side_optimizer.cpp:119-153`.
    """
    var width: Int = 0
    var n = schema.num_columns()
    for i in range(n):
        var at = schema.field_arrow_type(i)
        var tid = at.type_id
        var col_width: Int
        if (
            tid == ArrowType.BOOL.type_id
            or tid == ArrowType.INT8.type_id
            or tid == ArrowType.UINT8.type_id
        ):
            col_width = 1
        elif tid == ArrowType.INT16.type_id or tid == ArrowType.UINT16.type_id:
            col_width = 2
        elif (
            tid == ArrowType.INT32.type_id
            or tid == ArrowType.UINT32.type_id
            or tid == ArrowType.FLOAT32.type_id
            or tid == ArrowType.DATE32.type_id
        ):
            col_width = 4
        elif (
            tid == ArrowType.INT64.type_id
            or tid == ArrowType.UINT64.type_id
            or tid == ArrowType.FLOAT64.type_id
            or tid == ArrowType.DATE64.type_id
            or tid == ArrowType.TIMESTAMP.type_id
            or tid == ArrowType.TIMESTAMP_S.type_id
            or tid == ArrowType.TIMESTAMP_MS.type_id
            or tid == ArrowType.TIMESTAMP_US.type_id
            or tid == ArrowType.TIMESTAMP_NS.type_id
        ):
            col_width = 8
        elif (
            tid == ArrowType.STRING.type_id
            or tid == ArrowType.BINARY.type_id
            or tid == ArrowType.LARGE_STRING.type_id
            or tid == ArrowType.LARGE_BINARY.type_id
        ):
            # Variable-length: pointer (8) + average string penalty (8).
            col_width = 16
        elif tid == ArrowType.DICTIONARY.type_id:
            # Dictionary index (typically Int32).
            col_width = 4
        else:
            col_width = 8
        # Per-column overhead: validity bitmap, alignment padding.
        width += col_width + 1
    # Hash table entry overhead: hash value (8) + ~3 HT entry pointers
    # (average due to NextPowerOfTwo(count*2) sizing) = 8 + 3*8 = 32.
    width += 32
    return width


# =============================================================================
# estimate_cardinality -- recursive row-count estimation
# =============================================================================

def estimate_cardinality(plan: LogicalPlan) -> Int:
    """Estimate the number of output rows produced by `plan`.

    Simplified port of v0.3 `estimate_cardinality`. Scans use
    `ScanData.row_count` and fall back to `DEFAULT_ROW_COUNT` when
    `row_count` is None.

    Used by join reordering and eager aggregation. Must return >= 1 to
    avoid divide-by-zero and degenerate cost comparisons.
    """
    var tag = plan.tag

    if tag == PLAN_SCAN:
        var base: Int
        ref sdata = plan._scan.value()[]
        if sdata.row_count:
            base = sdata.row_count.value()
        else:
            base = DEFAULT_ROW_COUNT
        # Scan-level filter: predicate-aware selectivity.
        # When the scan carries a pushed-down filter, dispatch to
        # `compute_selectivity` with the scan's table_stats (Parquet NDV
        # available when present). Matches DuckDB's
        # `LogicalGet::EstimateCardinality` post-filter narrowing.
        if sdata.filter:
            var sel = compute_selectivity(
                sdata.filter.value(),
                sdata.table_stats,
            )
            # ceil(card * sel) clamped to >= 1 (DuckDB
            # InspectTableFilter semantics). Floor truncation
            # under-counts at small fractional products.
            base = _apply_selectivity_ceil(base, sel)
        if base < 1:
            base = 1
        return base

    elif tag == PLAN_FILTER:
        ref fdata = plan._filter.value()[]
        var child_card = estimate_cardinality(fdata.child[])
        # HAVING clause: Filter above Aggregate. These predicates reference
        # aggregate outputs (counts, sums), and they typically filter most
        # groups. 1% selectivity matches DuckDB.
        if fdata.child[].tag == PLAN_AGGREGATE:
            # ceil((card * NUM) / DEN) clamped to >= 1.
            # Floor under-counts surviving HAVING groups; ceil matches
            # DuckDB's filter cardinality estimator.
            var having_card = _ceil_div(
                child_card * HAVING_SELECTIVITY_NUM,
                HAVING_SELECTIVITY_DEN,
            )
            return having_card
        # Generic filter: predicate-aware selectivity.
        # We do NOT have per-column NDV at a non-scan Filter (the child
        # might be a join / project / aggregate output), so we pass
        # `None` for table_stats — the helper falls back to DuckDB's
        # per-op constants without the NDV-based equality refinement.
        var sel = compute_selectivity(
            fdata.predicate,
            Optional[TableStats](),
        )
        # ceil(card * sel) clamped to >= 1.
        var filter_card = _apply_selectivity_ceil(child_card, sel)
        return filter_card

    elif tag == PLAN_PROJECT:
        # 1:1 -- project does not change row count.
        return estimate_cardinality(plan._project.value()[].child[])

    elif tag == PLAN_AGGREGATE:
        var child_card = estimate_cardinality(plan._aggregate.value()[].child[])
        # Scalar aggregate (no group-by) always produces one row.
        if len(plan._aggregate.value()[].group_by) == 0:
            return 1
        # Heuristic: 10% of input.
        var grouped = child_card // AGG_REDUCTION_FACTOR
        if grouped < 1:
            grouped = 1
        return grouped

    elif tag == PLAN_JOIN:
        var left_card = estimate_cardinality(plan._join.value()[].left[])
        var right_card = estimate_cardinality(plan._join.value()[].right[])
        var jt = plan._join.value()[].join_type

        if jt == JOIN_SEMI or jt == JOIN_ANTI:
            # Output bounded by left side, scaled by selectivity.
            var sa = (
                left_card * SEMI_ANTI_SELECTIVITY_NUM // SEMI_ANTI_SELECTIVITY_DEN
            )
            if sa < 1:
                sa = 1
            return sa

        if jt == JOIN_CROSS:
            # Cartesian product (clamp to avoid overflow in heuristic use).
            var prod = left_card * right_card
            if prod < 1:
                prod = 1
            return prod

        # INNER / LEFT / RIGHT / FULL equi-joins: (|L| * |R|) / max(|L|, |R|)
        # which simplifies to max(|L|, |R|) -- conservative estimate since
        # distinct counts are unknown. This matches the common case where
        # one side is a fact table (many rows) joining a dimension table
        # (few rows): output is bounded by the fact table size.
        var mx = left_card
        if right_card > mx:
            mx = right_card
        if mx < 1:
            mx = 1
        return mx

    elif tag == PLAN_SORT:
        # Sort preserves row count.
        return estimate_cardinality(plan._sort.value()[].child[])

    elif tag == PLAN_LIMIT:
        var child_card = estimate_cardinality(plan._limit.value()[].child[])
        var n = plan._limit.value()[].n
        if n < child_card:
            return n
        return child_card

    elif tag == PLAN_DISTINCT:
        # Conservative upper bound: child cardinality.
        return estimate_cardinality(plan._distinct.value()[].child[])

    elif tag == PLAN_TOPN:
        var child_card = estimate_cardinality(plan._topn.value()[].child[])
        var n = plan._topn.value()[].n
        if n < child_card:
            return n
        return child_card

    # Fallback for unknown tags.
    return DEFAULT_ROW_COUNT
