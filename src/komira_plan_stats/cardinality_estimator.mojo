# =============================================================================
# Cardinality estimator: the format-agnostic group-count primitives
# =============================================================================
#
# The helpers that turn a `StatsProvider` into plan statistics:
#
#   * `estimate_groups[T: StatsProvider]`: the GROUP BY group count from
#     per-column distinct-count signals, `None` when any signal is missing.
#   * `build_table_stats_from_provider[T: StatsProvider]`: a `TableStats`
#     from a provider's per-column distinct count, null count, min/max and
#     (when present) merged HyperLogLog registers.
#   * `merge_table_stats`: the cross-source union of several `TableStats`.
#
# The sketch itself is `komira_collections.hyperloglog.HyperLogLog`
# (precision 12, 4096 one-byte registers, about 1.6% standard error). The
# register lists a `StatsProvider` returns and `ColumnStats.hll_registers`
# holds are that sketch's registers, in index order, so the union here is
# that sketch's `merge` and the estimate is its `estimate`.
#
# Nothing here knows a file format: a provider for any source implements
# `StatsProvider`, and the format-specific estimation lives with that format.
# No pointer is used in this module.
# =============================================================================

from komira_arrow.schema import Schema
from komira_collections.hyperloglog import HLL_NUM_REGISTERS, HyperLogLog
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.stats_provider import StatsProvider
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
)


def sketch_from_registers(registers: List[UInt8]) -> Optional[HyperLogLog]:
    """The sketch whose registers are `registers`, in index order.

    Returns None unless `registers` holds exactly `HLL_NUM_REGISTERS`
    entries: a list of any other length is not a register set of this
    sketch, and the caller falls back to its no-sketch path.
    """
    if len(registers) != HLL_NUM_REGISTERS:
        return None
    var sketch = HyperLogLog()
    for i in range(HLL_NUM_REGISTERS):
        sketch.set_register(i, registers[i])
    return Optional[HyperLogLog](sketch^)


def registers_of(sketch: HyperLogLog) -> List[UInt8]:
    """The registers of `sketch`, in index order (the inverse of
    `sketch_from_registers`)."""
    var out = List[UInt8](capacity=HLL_NUM_REGISTERS)
    for i in range(HLL_NUM_REGISTERS):
        out.append(sketch.register(i))
    return out^

# -----------------------------------------------------------------------------
# estimate_groups: the GROUP BY group count via the StatsProvider trait
# -----------------------------------------------------------------------------
#
# Format-agnostic plan-time estimator: it reaches statistics only through the
# `StatsProvider` trait.
#
# Mojo monomorphizes `[T: StatsProvider]` at the user's compile
# time, so per-call overhead is identical to a direct method call on
# the concrete struct. NO trait-object / vtable cost.


def estimate_groups[T: StatsProvider](
    stats: T,
    key_names: List[String],
) -> Optional[Int]:
    """Compute estimated GROUP BY group count via the StatsProvider trait.

    Calls `column_ndv_estimate` for each group-by key column, which
    MERGES per-row-group HLL register state across row groups when the
    engine's HLL-register Statistics extension is present, or
    falls back to the scalar per-row-group SUM when registers are absent
    (e.g. files written by parquet-rs / DuckDB).
    Aggregates across keys multiplicatively (independence assumption);
    clamps to `total_row_count`.

    Returns None when:
      - any key column lacks a distinct-count signal (no merged HLL,
        no scalar SUM), OR
      - the source has zero row groups, OR
      - aggregation would produce a non-positive group count.

    A None return signals "stats missing -- fall back to the
    heuristic (or, runtime-side, the HLL sampler)".
    """
    if len(key_names) == 0:
        return Optional[Int](1)
    if stats.num_row_groups() == 0:
        return Optional[Int](None)
    var total_rows = stats.total_row_count()
    if total_rows < 1:
        return Optional[Int](None)

    # Per-key NDV. column_ndv_estimate uses HLL register merge
    # when the writer emitted register state per RG; otherwise it
    # falls back to the per-RG distinct_count SUM.
    var per_key_distinct = List[Int]()
    for k in range(len(key_names)):
        var dc_opt = stats.column_ndv_estimate(key_names[k])
        if not dc_opt:
            return Optional[Int](None)
        per_key_distinct.append(dc_opt.value())

    # Aggregate per-key. Multi-key: product (saturating-clamped).
    var groups: Int = 1
    var clamp_hit = False
    for k in range(len(per_key_distinct)):
        var dc = per_key_distinct[k]
        if dc <= 0:
            return Optional[Int](None)
        if groups > total_rows // dc + 1:
            clamp_hit = True
            break
        groups *= dc

    if clamp_hit or groups > total_rows:
        groups = total_rows
    if groups < 1:
        groups = 1
    return Optional[Int](groups)


def build_table_stats_from_provider[T: StatsProvider](
    provider: T,
    schema: Schema,
) -> TableStats:
    """Build a `TableStats` for the join-reorder cost model from a
    `StatsProvider`'s per-column NDV / null_count.

    **NDV source must be `column_ndv_estimate`,
    NOT `column_distinct_count`.** A cost model that consumes
    `TableStats.column_distinct_count` reads the value stashed here under the
    `ColumnStats.distinct_count` field name. The legacy per-row-group SUM
    over-counts multi-RG keys (e.g. 6M rows / 6 RGs / true ~1M distinct gives
    SUM=5.68M, ratio=5.7x); the merged-HLL `column_ndv_estimate` returns an
    honest ~1M, so callers build scan statistics through THIS helper to thread
    the merged value through to the cost model.

    Public for test-visibility (`test_cardinality_estimator` exercises it
    with a synthetic provider).

    Args:
        provider: Any `StatsProvider` (for example a Parquet footer provider).
        schema: The SCAN schema whose column names define the
            `TableStats.column_names` parallel array.

    Returns:
        A `TableStats` with `STATS_SOURCE_PARQUET_METADATA` provenance.
        Each `ColumnStats.distinct_count` is the merged-HLL NDV when
        register state is present, else the legacy SUM (provider-side
        fallback in `column_ndv_estimate`).
    """
    var n_cols = schema.num_columns()
    var column_names = List[String]()
    var column_stats = List[ColumnStats]()
    # Parallel array recording whether each column's `distinct_count` came
    # from an HLL register merge (True) or from the SUM fallback (False);
    # `TableStats.column_distinct_count_from_hll` reads it back.
    var from_hll = List[Bool]()
    for c in range(n_cols):
        var name = schema.field_name(c)
        # column_ndv_estimate (HLL-merge) NOT
        # column_distinct_count (legacy SUM). The cost model reads the field
        # `ColumnStats.distinct_count`, so the field name is unchanged
        # but the value MUST be the merged NDV.
        var dc = provider.column_ndv_estimate(name)
        var nc = provider.column_null_count(name)
        # Query the provider's provenance bit.
        # This is True iff `column_ndv_estimate` will return the
        # register-merged HLL estimate (all RGs have well-formed
        # registers), False if it fell back to the per-RG SUM.
        var dc_from_hll = provider.column_ndv_estimate_from_hll(name)
        # When the HLL-merged path fired,
        # fetch the per-file merged register state so cross-source
        # merge (`merge_table_stats`) can compose another register-
        # wise MAX over multiple files. None on SUM-fallback (the
        # merge primitive falls back to per-file MAX-of-NDV there,
        # which is less precise but still safe).
        var hll_regs: Optional[List[UInt8]] = None
        if dc_from_hll:
            hll_regs = provider.column_merged_hll_registers(name)
        # The table-level `[min, max]` domain: the provider folds the
        # per-row-group min/max and returns None when any row group lacks a
        # decodable min/max (a partial fold could report a too-narrow
        # domain), so such columns keep None here.
        var mn: Optional[ScalarValue] = None
        var mx: Optional[ScalarValue] = None
        var mm_opt = provider.column_min_max(name)
        if mm_opt:
            ref mm = mm_opt.value()
            mn = Optional[ScalarValue](mm[0].copy())
            mx = Optional[ScalarValue](mm[1].copy())
        column_names.append(name)
        column_stats.append(
            ColumnStats(
                dc^,
                mn^,
                mx^,
                nc^,
                hll_regs^,
            )
        )
        from_hll.append(dc_from_hll)

    var total_rows = provider.total_row_count()
    return TableStats(
        total_rows,
        column_names^,
        column_stats^,
        STATS_SOURCE_PARQUET_METADATA,
        from_hll^,
    )


def merge_table_stats(stats_list: List[TableStats]) -> TableStats:
    """Cross-source HLL register-wise union merge.

    Combine multiple `TableStats` (one per Parquet source file) into a
    single `TableStats` whose per-column NDV reflects the UNION of
    distinct values across all sources, NOT the MAX-of-per-file-NDV
    or SUM-of-per-file-NDV.

    Why register-wise UNION (not MAX-of-NDV):
        MAX-of-NDV under-counts when source files have disjoint value
        sets (3 files each with 1000 distinct keys, disjoint = 3000
        true; MAX would say 1000).

        SUM-of-NDV over-counts when source files have OVERLAPPING value
        sets (3 files each with 1000 distinct keys, same set = 1000
        true; SUM would say 3000).

        Register-wise MAX of HLL register state IS the HLL union
        semantic. Two HLL sketches H1, H2 over sets S1, S2 produce a
        merged sketch whose NDV estimate = |S1 ∪ S2| ± std_error.
        DuckDB's `DistinctStatistics::Merge` does the same operation
        (see `src/common/types/hyperloglog.cpp:48`).

    Algorithm:
        Per output column (union of all input column names):
            1. Collect every input's `ColumnStats.hll_registers` for
               that column.
            2. If EVERY input has populated registers + matching length,
               register-wise MAX them all → merged sketch → recompute
               `distinct_count` from merged.estimate. Set
               `from_hll=True` for this column.
            3. If ANY input lacks registers, fall back to MAX-of-NDV
               over all inputs (low-confidence path). Set
               `from_hll=False`.
        `row_count` is summed across inputs (cross-source total).
        `source` is STATS_SOURCE_PARQUET_METADATA (preserves Tier-1
        dispatch eligibility for the merged stats).

    Args:
        stats_list: One TableStats per source file.

    Returns:
        Merged TableStats with cross-source NDVs.
    """
    if len(stats_list) == 0:
        # Empty input: return an empty TableStats.
        return TableStats(
            0, List[String](), List[ColumnStats](),
            STATS_SOURCE_PARQUET_METADATA,
        )
    if len(stats_list) == 1:
        # Single-source: pass-through (no merge needed).
        return stats_list[0].copy()

    # Union of column names across inputs (preserves first-seen order).
    var merged_names = List[String]()
    for i in range(len(stats_list)):
        ref ts = stats_list[i]
        for c in range(len(ts.column_names)):
            var present = False
            for j in range(len(merged_names)):
                if merged_names[j] == ts.column_names[c]:
                    present = True
                    break
            if not present:
                merged_names.append(ts.column_names[c])

    # Total row count across sources.
    var total_rows: Int = 0
    for i in range(len(stats_list)):
        total_rows += stats_list[i].row_count

    var merged_stats = List[ColumnStats]()
    var merged_from_hll = List[Bool]()
    for c in range(len(merged_names)):
        var name = merged_names[c]
        # Step 1: collect per-source register state + per-source NDV.
        var all_have_regs = True
        var saw_any = False
        var hll_merged = HyperLogLog()
        var max_ndv: Int = 0
        var any_dc = False
        var any_nc = False
        var total_nc: Int = 0

        for i in range(len(stats_list)):
            ref ts = stats_list[i]
            var idx = ts.find_column(name)
            if idx < 0:
                # Column missing from this source — treat as
                # "no contribution"; if no other source contributes
                # either, the merged column ends up with None NDV.
                continue
            ref cs = ts.column_stats[idx]
            if cs.distinct_count:
                any_dc = True
                var dc = cs.distinct_count.value()
                if dc > max_ndv:
                    max_ndv = dc
            if cs.null_count:
                any_nc = True
                total_nc += cs.null_count.value()

            # Register check: needs to be present, well-formed, AND
            # have flagged `from_hll=True` on this source (so we know
            # the merge path was load-bearing for this source's NDV).
            var source_from_hll = ts.column_distinct_count_from_hll(name)
            if not source_from_hll or not cs.hll_registers:
                all_have_regs = False
                continue
            var sketch = sketch_from_registers(cs.hll_registers.value())
            if not sketch:
                all_have_regs = False
                continue
            # Register-wise MAX: the sketch of the union of the sources.
            hll_merged.merge(sketch.value())
            saw_any = True

        # Step 2: choose merged NDV + from_hll bit.
        var merged_dc: Optional[Int] = None
        var merged_from_hll_bit = False
        if all_have_regs and saw_any:
            merged_dc = Optional[Int](hll_merged.estimate())
            merged_from_hll_bit = True
        elif any_dc:
            # SUM-fallback for inputs would over-count, but MAX-of-NDV
            # would under-count when value sets are disjoint. Without
            # register state we can't do better than MAX-of-NDV. This
            # is the documented low-confidence path; from_hll=False
            # signals the cost-model to apply discounting.
            merged_dc = Optional[Int](max_ndv)
            merged_from_hll_bit = False

        var merged_nc: Optional[Int] = None
        if any_nc:
            merged_nc = Optional[Int](total_nc)

        # Carry the merged registers when we used the HLL path, so a
        # further merge of this output composes another union.
        var out_regs: Optional[List[UInt8]] = None
        if all_have_regs and saw_any:
            out_regs = Optional[List[UInt8]](registers_of(hll_merged))

        merged_stats.append(
            ColumnStats(merged_dc^, None, None, merged_nc^, out_regs^)
        )
        merged_from_hll.append(merged_from_hll_bit)

    return TableStats(
        total_rows,
        merged_names^,
        merged_stats^,
        STATS_SOURCE_PARQUET_METADATA,
        merged_from_hll^,
    )
