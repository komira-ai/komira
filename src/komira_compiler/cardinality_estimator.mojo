# =============================================================================
# Cardinality Estimator — plan-time + sampler-ready group-count estimation
# =============================================================================
#
# Engine-local module. Two collaborating primitives:
#
#   1. `estimate_groups_from_parquet_metadata(metadata, key_names)` — Stage 1
#      (plan-time): attempts to derive the GROUP BY group count from per-
#      column `distinct_count` statistics in the Parquet footer. Sums the
#      per-row-group distinct counts (over-estimate, bounded by row count).
#
#   2. `HyperLogLog` — Stage 2 (runtime fallback): a 12-bit precision
#      (4096 registers) HLL sketch with ~1.6% standard error. Public
#      methods: `add(hash)`, `add_hashes(hashes)`, `estimate`. Used by
#      the unified MorselSink when Parquet stats are missing — the sink
#      samples the first ingested morsel and asks the sketch for its
#      cardinality estimate.
#
# # PERF-CRITICAL: this module is consulted ONCE per query at plan-compile
# time (Stage 1) and ONCE per AggSink at first-morsel time (Stage 2 — wired
# in W9.2). Returning stale or placeholder values causes `choose_strategy`
# downstream to mis-route between MiniMap+Abandon and (future) S2 CAS-global
# at >10M groups, the exact regime the 100M-group spike
# proved is load-bearing.
#
# # SAFETY: all heap state is encapsulated in `List[UInt8]` (the registers
# vector). No raw `UnsafePointer` crosses the public API. The
# `count_leading_zeros` intrinsic operates on `UInt64` values, not pointers.
#
# # Encapsulation rule: `HyperLogLog` exposes `add` / `add_hashes` /
# `estimate` / `merge`. Internal register access uses `List[UInt8]`'s
# bounds-checked API — no `_unsafe_ptr` shimming.
# =============================================================================

from std.bit import count_leading_zeros
from std.math import log

# the Parquet-CONCRETE estimation code
# (`estimate_groups_from_parquet_metadata`, `ParquetStatsCache`,
# `precompute_scan_stats`, `precompute_aggregate_estimates` + helpers) moved
# DOWN to `komira_parquet/parquet_cardinality.mojo` to break the
# `komira_compiler -> komira_parquet` feedback edge of the 26-pkg engine
# import-cycle SCC. This module keeps ONLY the format-agnostic primitives:
# `HyperLogLog`, `estimate_groups[T: StatsProvider]`,
# `build_table_stats_from_provider[T]`, `merge_table_stats`. No
# `FileMetaData` / `ParquetStatsProvider` import survives here.
from komira_core.arrow.schema import Schema
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.stats_provider import StatsProvider
from komira_core.plan.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
)


# -----------------------------------------------------------------------------
# HyperLogLog — 12-bit precision (4096 registers), ~1.6% standard error
# -----------------------------------------------------------------------------
#
# Registers are a `List[UInt8]`, keeping the encapsulation rule (no raw
# allocations crossing the API).
#
# Tradeoff vs. the 8-bit sampler in agg_hash.mojo: 4096 registers (4 KiB)
# vs. 256 (256 B). 16x more memory but ~4x lower std error (1.6% vs ~6.5%).
# The plan-time / first-morsel fallback path is NOT in a hot inner loop
# — it runs once per query. The accuracy gain matters at the
# 10M-group threshold where strategy selection flips between MiniMap and
# (future W9.2) GlobalConcurrent.
# -----------------------------------------------------------------------------


comptime HLL_PRECISION: Int = 12
comptime HLL_NUM_REGISTERS: Int = 4096  # 1 << HLL_PRECISION


struct HyperLogLog(Movable):
    """A HyperLogLog sketch for cardinality estimation.

    Uses 12-bit precision (4096 registers, ~1.6% standard error), the
    precision used for plan-time strategy selection.

    Memory: 4 KiB per sketch (4096 single-byte registers). The cost is
    paid once per query, not per row — so the precision/memory tradeoff
    favors accuracy here.

    Usage:
        var hll = HyperLogLog
        hll.add(my_hash)            # or hll.add_hashes(hashes)
        var n = hll.estimate      # returns Int

    # SAFETY: registers are stored in `List[UInt8]`, length-locked at
    # `HLL_NUM_REGISTERS`. All accesses go through `__getitem__` /
    # `__setitem__` (bounds-checked).
    """

    var registers: List[UInt8]

    def __init__(out self):
        """Creates an empty sketch with all 4096 registers zeroed."""
        self.registers = List[UInt8]()
        for _ in range(HLL_NUM_REGISTERS):
            self.registers.append(UInt8(0))

    @always_inline
    def add(mut self, hash: UInt64):
        """Add one hash value to the sketch.

        The top `HLL_PRECISION` bits of `hash` index a register; the
        remaining bits feed the leading-zeros count. Each register
        stores `max(observed_leading_zeros + 1)`.

        # PERF-CRITICAL: `count_leading_zeros` compiles to a single
        # CLZ / LZCNT instruction. The fast path is straight-line
        # arithmetic + one branch — no allocation, no hashing.
        """
        var register_idx = Int(hash >> UInt64((64 - HLL_PRECISION)))
        # Shift the precision-bits OUT, then OR a guard bit so a hash
        # whose remaining bits are all zero still contributes a finite
        # leading-zeros count rather than CLZ(0) which is undefined.
        var remaining = (hash << UInt64(HLL_PRECISION)) | (UInt64(1) << UInt64((HLL_PRECISION - 1)))
        var zeros = UInt8(count_leading_zeros(remaining)) + 1
        if zeros > self.registers[register_idx]:
            self.registers[register_idx] = zeros

    def add_hashes(mut self, hashes: List[UInt64]):
        """Add a batch of pre-computed hash values."""
        for i in range(len(hashes)):
            self.add(hashes[i])

    def estimate(self) -> Int:
        """Compute the cardinality estimate from the current registers.

        Implements the standard HLL estimator with linear-counting small-
        range correction (`raw_estimate <= 2.5 * m and zero_registers > 0`).
        Large-range correction is omitted for 64-bit hashes — the bias
        is negligible at our cardinality range.

        # PERF-CRITICAL: NOT-VECTORIZABLE inner loop (variable shift
        # amount per element + branch on `reg == 0`). N=4096 is small;
        # SIMD overhead would exceed benefit. Cost is ~10us, dominated
        # by the harmonic-sum loop.
        """
        var m = Float64(HLL_NUM_REGISTERS)
        var sum_val = Float64(0.0)
        var zero_registers = 0
        for i in range(HLL_NUM_REGISTERS):
            var reg = Int(self.registers[i])
            if reg == 0:
                sum_val += 1.0  # 2^0 = 1
                zero_registers += 1
            else:
                # Cap the shift at 62 to stay well inside Int64. At
                # `reg = 62`, contribution is 2^-62 ~= 2.2e-19 — far
                # below numerical noise.
                sum_val += 1.0 / Float64(1 << min(reg, 62))

        # alpha_m for m >= 128.
        var alpha_m = 0.7213 / (1.0 + 1.079 / m)
        var raw_estimate = alpha_m * m * m / sum_val

        # Small-range linear-counting correction.
        if raw_estimate <= 2.5 * m and zero_registers > 0:
            return Int(m * log(m / Float64(zero_registers)))
        return Int(raw_estimate)

    def merge(mut self, other: HyperLogLog):
        """Merge another sketch into this one (max per register).

        Useful for parallel sampling: each worker sketches its local
        sample, and the driver merges into one global sketch before
        calling `estimate`.
        """
        for i in range(HLL_NUM_REGISTERS):
            if other.registers[i] > self.registers[i]:
                self.registers[i] = other.registers[i]


# Local helper because std.math.min is generic and `min(Int, Int)` is fine,
# but we want to avoid a separate import in this hot path.
@always_inline
def min(a: Int, b: Int) -> Int:
    if a < b:
        return a
    return b


# -----------------------------------------------------------------------------
# Stage 1: generic estimate_groups via StatsProvider trait
# -----------------------------------------------------------------------------
#
# Format-agnostic plan-time estimator. Same semantics as
# `estimate_groups_from_parquet_metadata` but reaches stats through the
# `StatsProvider` trait instead of a direct FileMetaData walk. This is
# the recommended call site for new code -- the legacy
# `estimate_groups_from_parquet_metadata` stays in place for backward
# compatibility.
#
# Mojo 0.26.3 monomorphizes `[T: StatsProvider]` at the user's compile
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

    # Per-key NDV. column_ndv_estimate uses HLL register merge (W9.1)
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
    NOT `column_distinct_count`.** The cost-model interface that consumes
    `TableStats.column_distinct_count` (in `optimizer_reorder` /
    `optimizer_dpccp`) reads the value stashed here under the
    `ColumnStats.distinct_count` field name. The legacy per-row-group SUM
    over-counts multi-RG keys (e.g. 6M rows / 6 RGs / true ~1M distinct gives
    SUM=5.68M, ratio=5.7x); the merged-HLL `column_ndv_estimate` returns an
    honest ~1M, and `_populate_scan_stats_for_scan` calls THIS helper to thread
    the merged value through to the cost model.

    Public for test-visibility (the synthetic-provider tests in
    `test_populate_scan_stats_uses_merged_ndv` exercise this directly).

    Args:
        provider: Any `StatsProvider` (typically `ParquetStatsProvider`).
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
    # Parallel array
    # recording whether each column's `distinct_count` came from HLL
    # register merge (True) or from the SUM fallback (False). Read
    # downstream by `DefaultColumnStatsProvider.distinct_count_for`
    # to set the `ColumnStatsValue.from_hll` flag.
    var from_hll = List[Bool]()
    for c in range(n_cols):
        var name = schema.field_name(c)
        # column_ndv_estimate (HLL-merge) NOT
        # column_distinct_count (legacy SUM). The cost-model surface
        # in optimizer_reorder._max_ndv_across_keys reads the field
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
        # KEYSTONE: fold the
        # per-column-chunk min/max across all row groups and stash it on the
        # ColumnStats so the plan carries the table-level `[min, max]` domain.
        # L2 (perfect-hash agg key-range) + range-selectivity read this off
        # `ScanData.table_stats` without re-walking the provider. Pre-this,
        # this helper hardcoded min/max to None ("not needed for the
        # join-reorder cost model") — only NDV/null_count flowed. The provider
        # returns None when any RG lacks decodable min/max (conservative: a
        # partial fold could report a too-narrow domain → mis-sized hash
        # table), so string/bool columns + stats-less files stay None (L2
        # declines to the generic path — correct).
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
            ref regs = cs.hll_registers.value()
            if len(regs) != HLL_NUM_REGISTERS:
                all_have_regs = False
                continue
            # Register-wise MAX into hll_merged.
            comptime W: Int = 16
            var dst_ptr = hll_merged.registers.unsafe_ptr()
            var src_ptr = regs.unsafe_ptr()
            for j in range(0, HLL_NUM_REGISTERS, W):
                # SAFETY: HLL_NUM_REGISTERS=4096 is W=16-divisible;
                # both buffers are exactly 4096 bytes (length-guarded
                # above). Encapsulated to this hot loop.
                var s = (dst_ptr + j).load[width=W]()
                var o = (src_ptr + j).load[width=W]()
                (dst_ptr + j).store(max(s, o))
            saw_any = True

        # Step 2: choose merged NDV + from_hll bit.
        var merged_dc: Optional[Int] = None
        var merged_from_hll_bit = False
        if all_have_regs and saw_any:
            merged_dc = Optional[Int](hll_merged.estimate())
            merged_from_hll_bit = True
            # Step 2.b: defensive — copy the merged registers into the
            # output ColumnStats so further merges compose correctly.
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

        # Carry the merged registers when we used the HLL path.
        var out_regs: Optional[List[UInt8]] = None
        if all_have_regs and saw_any:
            var regs_copy = List[UInt8]()
            for j in range(HLL_NUM_REGISTERS):
                regs_copy.append(hll_merged.registers[j])
            out_regs = Optional[List[UInt8]](regs_copy^)

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
