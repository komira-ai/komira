# =============================================================================
# TableStats — table-level + per-column statistics for a Scan node
# =============================================================================
#
# Carries the information that the cost model + cardinality estimator need
# to make strategy decisions (join build-side selection, AggSink pre-sizing,
# filter selectivity).
#
# # Critical: this module is PURE-DATA — it MUST NOT import from `parquet.*`
# or anywhere in the engine that pulls `std.io.FileHandle` into the call
# graph of `plan_compiler._compile_node`. Stats ride on `ScanData` to keep
# the Parquet metadata read in the SDK layer, where its FileHandle reach
# does NOT pollute plan_compiler's recursive-dispatch monomorphization tree
# (which hangs the compile). Anything that wants to *populate* a TableStats
# from Parquet metadata lives in the SDK.
#
# Shape:
#   - `ColumnStats { distinct_count, min_value, max_value, null_count }`
#   - `TableStats { row_count, column_stats, source }`
#   - `StatsSource { ParquetMetadata, FileSizeHeuristic, Unknown }`
#
# Storage choice: parallel `List[String]` + `List[ColumnStats]` instead of
# `Dict[String, ColumnStats]`. Plan-time consumers walk a small column set
# (<20 columns typical) so linear search is fine; this also keeps the
# Movable/Copyable trait surface trivial (ColumnStats is Copyable; Dict
# requires Hashable + Movable on values which is fine, but List[T] +
# List[String] mirrors the sort/topn `keys` / `descending`
# pattern and is easier to reason about under partial-move semantics).
# =============================================================================

from komira_plan_expr.scalar_value import ScalarValue


# =============================================================================
# StatsSource — provenance of the statistics
# =============================================================================
#
# Plan-time consumers want to know how much to trust the stats. Parquet
# footer stats are exact (within Parquet's own truncation rules); file-
# size heuristics are coarse; Unknown means "fall back to defaults".

comptime STATS_SOURCE_PARQUET_METADATA: UInt8 = 0
comptime STATS_SOURCE_FILE_SIZE_HEURISTIC: UInt8 = 1
comptime STATS_SOURCE_UNKNOWN: UInt8 = 2
# Distinguishes TableStats synthesized from a row-count fallback (no
# real per-column NDV signal) from genuine Parquet-footer-emitted
# stats. Used by `optimizer_dpccp._synth_row_count_table_stats` at the
# row_count-only fallback site.
comptime STATS_SOURCE_SYNTHETIC_ROW_COUNT: UInt8 = 3


# =============================================================================
# ColumnStats — per-column statistics
# =============================================================================


struct ColumnStats(Movable, Copyable):
    """Statistics for a single column, extracted from source metadata.

    All fields are Optional because
    Parquet writers do not always emit them — a missing field signals
    "unknown" to the cost model, not "zero".

    Fields:
        distinct_count: Distinct count from Parquet footer if available.
            None means "writer did not record it" — the runtime sampler
            (HLL) is the next-best signal.
        min_value: Minimum value (from column-chunk Statistics, decoded
            into a ScalarValue per the Arrow schema's logical type).
        max_value: Maximum value (same source as min).
        null_count: Number of null values across all row groups. None
            means "writer did not record it".
        hll_registers: Optional HLL register sketch (per-column NDV
            sketch, mergeable across row-groups) — DuckDB-parity NDV
            provenance flag.
            None means "no HLL signal available" (the column-level
            distinct_count may still be populated from non-HLL stats).
            Currently no writer populates this field; it is reserved
            for wiring through `komira_parquet.table_stats` and
            the Parquet footer collector. ColumnStatsProvider Tier 1
            inspects this field's presence as the load-bearing
            "is the NDV signal HLL-derived?" check.
    """

    var distinct_count: Optional[Int]
    var min_value: Optional[ScalarValue]
    var max_value: Optional[ScalarValue]
    var null_count: Optional[Int]
    var hll_registers: Optional[List[UInt8]]

    def __init__(
        out self,
        var distinct_count: Optional[Int] = None,
        var min_value: Optional[ScalarValue] = None,
        var max_value: Optional[ScalarValue] = None,
        var null_count: Optional[Int] = None,
        var hll_registers: Optional[List[UInt8]] = None,
    ):
        self.distinct_count = distinct_count^
        self.min_value = min_value^
        self.max_value = max_value^
        self.null_count = null_count^
        self.hll_registers = hll_registers^

    def copy(self) -> Self:
        """Explicit deep-copy. Required because Optional[ScalarValue]
        and Optional[Int] do not auto-copy under Mojo's narrow
        Copyable rules."""
        var dc: Optional[Int] = None
        if self.distinct_count:
            dc = Optional[Int](self.distinct_count.value())
        var mn: Optional[ScalarValue] = None
        if self.min_value:
            mn = Optional[ScalarValue](self.min_value.value().copy())
        var mx: Optional[ScalarValue] = None
        if self.max_value:
            mx = Optional[ScalarValue](self.max_value.value().copy())
        var nc: Optional[Int] = None
        if self.null_count:
            nc = Optional[Int](self.null_count.value())
        var hll: Optional[List[UInt8]] = None
        if self.hll_registers:
            ref src = self.hll_registers.value()
            var dst = List[UInt8]()
            for i in range(len(src)):
                dst.append(src[i])
            hll = Optional[List[UInt8]](dst^)
        return Self(dc^, mn^, mx^, nc^, hll^)

    @always_inline
    def hll_registers_for(self) -> Optional[List[UInt8]]:
        """Return a deep-copy of the HLL register sketch, or None if
        the field is unpopulated.

        Callers that want a borrow can read `self.hll_registers` directly
        in-module; this accessor exists as the public copy-out path so
        consumers do not depend on the field name (a typed `HllSketch`
        struct may replace `List[UInt8]`).
        """
        if not self.hll_registers:
            return None
        ref src = self.hll_registers.value()
        var dst = List[UInt8]()
        for i in range(len(src)):
            dst.append(src[i])
        return Optional[List[UInt8]](dst^)


# =============================================================================
# TableStats — table-level statistics
# =============================================================================


struct TableStats(Movable, Copyable):
    """Table-level statistics for a Scan node.

    Per-column stats are stored
    as parallel `List[String]` (column names) + `List[ColumnStats]`
    instead of `Dict[String, ColumnStats]`. Plan-time consumers walk
    the small column set (typically <20 columns) so linear search is
    not a bottleneck; this matches the sort/topn `keys` /
    `descending` parallel-list pattern and keeps trait constraints
    minimal.

    Fields:
        row_count: Total row count across all row groups.
        column_names: Parallel with column_stats; column[i].
        column_stats: Per-column stats, indexed parallel to column_names.
        source: Where these stats came from (Parquet, file-size, unknown).

    Lookup helpers `find_column` / `column_distinct_count` are
    @always_inline because they are on the plan-compile hot path
    (called once per group-by key per aggregate node).
    """

    var row_count: Int
    var column_names: List[String]
    var column_stats: List[ColumnStats]
    var source: UInt8
    # `from_hll` provenance: parallel array,
    # one entry per column, True iff `column_stats[i].distinct_count`
    # came from the HLL-merged path (writer-emitted register state
    # across all row groups), False if it came from the per-RG
    # `distinct_count` SUM fallback (parquet-rs / DuckDB writers).
    # Empty list (len 0) means "no provenance recorded" — treated as
    # False at consumer time (cost-model-safe under-estimation).
    # See `column_distinct_count_from_hll` for the lookup helper.
    var from_hll: List[Bool]

    def __init__(
        out self,
        row_count: Int,
        var column_names: List[String],
        var column_stats: List[ColumnStats],
        source: UInt8 = STATS_SOURCE_UNKNOWN,
        var from_hll: List[Bool] = List[Bool](),
    ):
        self.row_count = row_count
        self.column_names = column_names^
        self.column_stats = column_stats^
        self.source = source
        self.from_hll = from_hll^

    def copy(self) -> Self:
        """Explicit deep-copy."""
        var names_copy = List[String]()
        for i in range(len(self.column_names)):
            names_copy.append(self.column_names[i])
        var stats_copy = List[ColumnStats]()
        for i in range(len(self.column_stats)):
            stats_copy.append(self.column_stats[i].copy())
        var from_hll_copy = List[Bool]()
        for i in range(len(self.from_hll)):
            from_hll_copy.append(self.from_hll[i])
        return Self(
            self.row_count, names_copy^, stats_copy^, self.source, from_hll_copy^
        )

    @always_inline
    def find_column(self, name: String) -> Int:
        """Linear search for a column by name. Returns -1 if not found.

        # PERF: O(n) but n is the schema width (<20 typical). The
        # alternative — Dict[String, Int] — costs more in init/copy
        # overhead than the search costs at lookup time given typical
        # schema widths.
        """
        for i in range(len(self.column_names)):
            if self.column_names[i] == name:
                return i
        return -1

    @always_inline
    def column_distinct_count(self, name: String) -> Optional[Int]:
        """Return the per-column distinct_count, or None if missing.

        Convenience wrapper used by the engine-side cardinality
        estimator. Returns None when the column is unknown OR when
        the writer did not emit `distinct_count` for that column.
        """
        var idx = self.find_column(name)
        if idx < 0:
            return None
        ref cs = self.column_stats[idx]
        if not cs.distinct_count:
            return None
        return Optional[Int](cs.distinct_count.value())

    @always_inline
    def column_distinct_count_from_hll(self, name: String) -> Bool:
        """True iff `column_distinct_count(name)` came from HLL register
        merge (not SUM fallback).

        The cost-model's `DefaultColumnStatsProvider` reads this to
        set the `ColumnStatsValue.from_hll` flag — distinguishes
        high-confidence HLL-merged NDV from low-confidence SUM-
        fallback.

        Returns False when:
          - the column is unknown, OR
          - `from_hll` is populated for this column AND the recorded
            flag is False.

        Returns True when:
          - the column is known AND
          - `from_hll` was provided by the producer
            AND records True for this column, OR
          - `from_hll` is EMPTY (a producer or test-fixture constructor
            that records no provenance; the Tier-1 contract applies —
            assume HLL-backed for STATS_SOURCE_PARQUET_METADATA).

        The empty-list default is critical: a producer that builds a
        `STATS_SOURCE_PARQUET_METADATA`-tagged TableStats without
        populating `from_hll` still gets the Tier-1 dispatch contract,
        "Parquet-metadata signal => high-confidence". The
        field is informational refinement, not a downgrade.
        Producers that want explicit provenance (e.g.
        `build_table_stats_from_provider`) populate
        the parallel array and get per-column discrimination.
        """
        var idx = self.find_column(name)
        if idx < 0:
            return False
        if len(self.from_hll) == 0:
            # Unspecified: assume Tier-1 contract (HLL-backed), for test
            # fixtures and producers that record no provenance.
            return True
        if idx >= len(self.from_hll):
            # Defensive: mismatched parallel-array length. Treat as
            # unspecified → assume Tier-1 (preserves cost-model
            # parity with the empty-list path).
            return True
        return self.from_hll[idx]
