# =============================================================================
# StatsProvider -- format-agnostic plan-time statistics surface
# =============================================================================
#
# A trait that source-format crates (`komira_parquet`, `komira_json` /
# `komira_csv` / `komira_avro`) implement so that the
# compiler / planner / optimizer rules can reach format statistics
# WITHOUT ever importing concrete-format types like `FileMetaData`.
#
# Reaching directly into `parquet.metadata.FileMetaData` from the planner
# would force the Parquet file reader (and transitively
# `std.io.FileHandle`) into the `plan_compiler` recursive-dispatch
# monomorphization tree, which hangs on AOT link. By inverting the
# dependency -- planner depends on the trait, parquet implements the trait
# -- the `FileHandle` reach stays in the SDK / parquet pkg only.
#
# The surface is deliberately wider than `column_min_max`: planner rules
# need the parquet PHYSICAL TYPE (INT32 vs INT64) for sign-extension
# dispatch, PER-ROW-GROUP min/max walking, and per-column distinct counts
# (`cardinality_estimator`). The live perfect-hash aggregation route does
# NOT go through StatsProvider: it is selected in the engine off a cached
# footer probe.
#
# The trait stays policy-free (the perfect-hash 65536 ceiling is owned by
# the caller, not by the trait) so future stat
# providers don't have to know the optimizer's thresholds.
#
# Implementations may cache footer reads internally (the
# `ParquetStatsProvider` MUST do so to avoid N×M call amplification --
# see komira_parquet's `table_stats` footer cache).
#
# # PERF: trait dispatch is monomorphized at the user's compile time
# (Mojo has no vtable / dyn dispatch). Every callsite fans out
# to one concrete impl per source format used, so per-call overhead
# is identical to a direct method call on the concrete struct.
# =============================================================================

from .physical_type import PhysicalType
from .scalar_value import ScalarValue


trait StatsProvider:
    """Format-agnostic plan-time statistics surface.

    Implemented by source-format crates. The compiler / planner accept
    an instance of `StatsProvider`, never a concrete `FileMetaData`
    (`cardinality_estimator` is the planner consumer); bakes in the
    DataFusion #2247 fix.

    All methods take immutable `self`. Implementations may cache
    footer reads internally.
    """

    def num_row_groups(self) -> Int:
        """Number of row groups in the source. >= 0; 0 means "no data"."""
        ...

    def total_row_count(self) -> Int:
        """Total row count across all row groups. >= 0."""
        ...

    def column_physical_type(self, name: String) -> Optional[PhysicalType]:
        """Physical type of column `name`, or None if the column is not
        present (or the source format doesn't carry physical types).

        For Parquet this is the leaf-column `Type` from
        `SchemaElement.type` (INT32 / INT64 / FLOAT / DOUBLE / etc.).
        """
        ...

    def column_rg_min_max(
        self, name: String, rg_idx: Int
    ) -> Optional[Tuple[ScalarValue, ScalarValue]]:
        """Per-row-group `(min, max)` for column `name`, or None if:
          - the column is missing in this row group, OR
          - the writer didn't emit min/max statistics, OR
          - `rg_idx` is out of range.

        ScalarValues are decoded into the column's physical type
        (sign-extended for INT32 stats; raw bits for FLOAT / DOUBLE).
        Implementations are responsible for the decode -- callers
        treat ScalarValue as opaque.
        """
        ...

    def column_min_max(
        self, name: String
    ) -> Optional[Tuple[ScalarValue, ScalarValue]]:
        """Table-level `(min, max)` for column `name`, folded across ALL
        row groups, or None if a global domain cannot be established.

        This is the whole-file sibling of `column_rg_min_max` (which is
        per-row-group): it walks every row group, decodes each RG's
        min/max into ScalarValues (physical-type decode; sign-extended
        for INT32, raw bits for FLOAT/DOUBLE), and folds them into a
        single global `[min, max]`.

        Returns None (conservatively — so a caller like the perfect-hash
        agg key-domain check declines to the generic path rather than
        computing a too-narrow domain) when ANY of:
          - the source has zero row groups, OR
          - the column is missing in some row group, OR
          - some row group lacks writer-emitted min/max statistics, OR
          - the column's physical type is not one the decoder supports
            (BYTE_ARRAY / BOOLEAN / INT96 → the cost model + perfect-hash
            don't consume string/bool ranges today).

        Requiring EVERY row group to carry decodable stats is the safe
        contract: a fold over only the row groups that happen to have
        stats could report a range narrower than the true column domain,
        which would mis-size a perfect-hash slot table. A well-formed
        Parquet file written by DuckDB / the Komira writer carries
        min/max on every numeric column-chunk, so this populates for the
        common case.

        Consumed at plan-compile time (once per column per scan) by
        `build_table_stats_from_provider`, which stashes the result on
        `ScanData.table_stats.column_stats[i].{min_value, max_value}`.
        """
        ...

    def column_distinct_count(self, name: String) -> Optional[Int]:
        """Aggregate distinct count for column `name` across all row
        groups. None when:
          - the column is missing, OR
          - any row group lacks a distinct_count writer-emitted stat.

        This is summed
        across row groups (an OVER-estimate, since the same logical
        key can appear in multiple row groups). Callers clamp to
        `total_row_count`.
        """
        ...

    def column_null_count(self, name: String) -> Optional[Int]:
        """Aggregate null count for column `name` across all row groups,
        or None when the writer didn't emit `null_count` for any row
        group. Returning 0 means "definitely no nulls"; None means
        "we don't know".
        """
        ...

    def column_ndv_estimate(self, name: String) -> Optional[Int]:
        """Distinct-value count from a Hyperloglog sketch (or equivalent
        cardinality estimator). This returns an `Int`
        rather than the sketch struct -- there is no
        `HllSketch` core type and the perfect-hash / cardinality
        consumers only need the NDV scalar.

        Returning None means "no sketch available"; callers fall
        through to `column_distinct_count` (writer-emitted) or to the
        runtime sampler.

        A sibling `column_hll_sketch -> Optional[HllSketch]` returning the
        merge-able sketch directly would need a core `HllSketch` type.
        """
        ...

    def column_ndv_estimate_from_hll(self, name: String) -> Bool:
        """True iff `column_ndv_estimate(name)` would return a
        register-merged HLL estimate (vs a SUM fallback).

        The cost-model needs to know whether the merged NDV came from
        HLL register-wise union (high confidence — DuckDB-parity) or
        from the per-RG distinct_count SUM fallback (low
        confidence — over-counts on cross-RG shared keys).

        Returns False when:
          - the column is missing, OR
          - any row group lacks `hll_registers`, OR
          - any row group's register blob is malformed (length !=
            HLL_NUM_REGISTERS), OR
          - the provider has no row groups.

        Returns True iff EVERY row group's Statistics carries a
        well-formed `hll_registers` field, in which case
        `column_ndv_estimate` returns the register-merged estimate.

        Implementations MUST keep this method O(num_row_groups) — it
        is queried at plan-compile time per column once per scan
        during `build_table_stats_from_provider`.
        """
        ...

    def column_merged_hll_registers(self, name: String) -> Optional[List[UInt8]]:
        """Return the within-file register-merged HLL state (register-wise
        MAX across all row groups) for column `name`, or None if the
        merged-HLL path is not available.

        Cross-source HLL merge: callers
        compose this across multiple TableStats (one per source file)
        to compute a cross-source merged NDV. Register-wise MAX is the
        correct HLL union semantic — concatenating two HLL sketches
        produces a sketch whose NDV estimate equals the union
        cardinality, not the sum (per HLL precision-12 ±1.6% std error).

        Returns None when `column_ndv_estimate_from_hll(name)` returns
        False (any RG missing/malformed). Returns Some(List[UInt8] of
        length HLL_NUM_REGISTERS=4096) on the happy path.

        Cost: O(num_row_groups * HLL_NUM_REGISTERS) byte ops. The
        cross-source merge primitive (in
        `cardinality_estimator.merge_table_stats`) walks per-source
        merged registers and combines them with another register-wise
        MAX pass — composes naturally with the per-source merge.
        """
        ...
