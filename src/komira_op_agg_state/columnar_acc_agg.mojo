# =============================================================================
# Specialized Typed SoA Accumulators — PercentileAcc / CountDistinctAcc
# =============================================================================
#
# Split out of `columnar_acc_typed.mojo` (PE Phase 0d concern #3: 1000-line
# Mojo JIT hang threshold). These two accumulators have specialized semantics
# distinct from the numeric/utf8 reduce-on-update family:
#
#   - PercentileAcc BUFFERS values per-gid and runs quickselect at finalize
#     (NOT a reduction at update time).
#   - CountDistinctAcc BUFFERS values per-gid and runs sort+dedup at finalize.
#
# Both lack a SIMD `merge_aligned` fast path because the per-gid state is
# variable-length List[T]; merge is List concatenation, finalize does the
# real work. Co-locating them isolates the buffering/finalize family from
# the reduce-on-update structs in `columnar_acc_typed.mojo`.
#
# Reference sources (faithfully ported):
#   - `komira-engine/src/aggregate/columnar_accumulator.rs`
#       * PercentileF64ColumnarAcc + compute_percentile_f64 (~line 649-4264)
#       * CountDistinctI64ColumnarAcc sort+dedup at evaluate (~613-617, 2190)
#   - an internal doc §0, §2
#
# Movable-only (owns List[List[T]]). Do NOT add Copyable.
# =============================================================================

# =============================================================================
# CLUSTER-Z TODO: scheduled migration per an internal doc
# =============================================================================
# Each remaining MutExternalOrigin in this file is either (a) a load-bearing
# interior pointer awaiting redesign onto a tight origin, or (b) a temporary
# shim into a primitive that will be removed in Cluster Z (e.g. Slab /
# Slab / Slab / AtomicSlab _mut_ptr / _unsafe_base_ptr helpers
# preserved for migration source callers).
#
# Remediation: replace each wildcard with one of
#   * a typed `ref [origin] T` return / parameter,
#   * a private `UnsafePointer[T, concrete_origin]` field + `# SAFETY:`
#     comment (inside a single struct only),
#   * a byte-view (`ByteView` / `ByteViewMut`) + typed scalar reads/writes.
#
# See an internal doc §5 for canonical API shapes
# and an internal doc §8 for the Cluster Z schedule.
# The baseline at scripts/mut_external_origin_allowlist.txt is
# monotonic-shrinking; do NOT add new wildcard sites to this file.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_collections.slab import Slab
from komira_op_agg_state.accumulator_trait import Accumulator
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# PERF-CRITICAL: PercentileAcc — exact percentile via quickselect
# =============================================================================
# Ports `PercentileF64ColumnarAcc` + `compute_percentile_f64` from
# columnar_accumulator.rs:649-4264.
#
# Algorithm (v0.3 faithful):
#   1. Per gid: List[Float64] of raw values (push on update).
#   2. finalize per group:
#        k    = floor(q * (n - 1))
#        frac = q * (n - 1) - k
#        select_nth(k)                       # Hoare partition (not full sort)
#        lower = values[k]
#        if frac == 0 or k+1 >= n: return lower
#        upper = min(values[k+1..])          # LINEAR SCAN, NOT values[k+1]
#        return lower * (1-frac) + upper * frac
#
# Key correctness point (design §2): after `select_nth(k)`, values[k+1..] is
# UNSORTED but all >= values[k]. The (k+1)th order statistic is the MIN of
# that suffix — NOT the value sitting at index k+1. A literal `values[k+1]`
# implementation returns wrong results for every non-integer quantile.
#
# Null / NaN semantics:
#   - All-null group => SQL NULL (signaled via Optional in finalize).
#   - NaN rows are EXCLUDED in update_batch. ⚠ DuckDB does NOT do this; see
#     the measurement at the `if v == v` line in `update_batch`.
#   - If group has only NaN rows => SQL NULL. (DuckDB returns the NaN.)
#
# Regression if removed: PERCENTILE/MEDIAN falls back to full-sort O(N log N)
# vs quickselect O(N) expected. Design §10 expected ~3-5x on long groups.
# =============================================================================
struct PercentileAcc(Accumulator):
    """Exact percentile. Stores raw values per gid; quickselect at finalize."""

    var values: List[List[Float64]]
    var seen: List[Bool]
    var q: Float64

    def __init__(out self, q: Float64):
        self.values = List[List[Float64]]()
        self.seen = List[Bool]()
        self.q = q

    @staticmethod
    def new(q: Float64) -> Self:
        return Self(q)

    def ensure_capacity(mut self, num_groups: Int):
        while len(self.values) < num_groups:
            self.values.append(List[Float64]())
            self.seen.append(False)

    def update_batch[
        origin_g: Origin, origin_v: Origin
    ](
        mut self,
        gids: Span[UInt32, origin_g],
        values_ptr: Span[Float64, origin_v],
        num_rows: Int,
    ) raises:
        for i in range(num_rows):
            var g = Int(gids[i])
            if g >= len(self.values):
                raise Error("PercentileAcc.update_batch: gid out of range")
            var v = values_ptr[i]
            # NaN EXCLUSION. We can't import isnan cleanly at Phase 0a; use
            # the self-inequality property (v != v iff v is NaN).
            #
            # ⚠ KNOWN DIVERGENCE. This said "matches DuckDB + design §2".
            # DuckDB does NOT exclude NaN from an order statistic — it orders
            # it LAST and includes it in the count. Measured on DuckDB v1.5.3,
            # 2026-09-11: median{1,2,3,4,nan,nan} = 3.5 (exclusion gives 2.5)
            # and median{1,2,3,nan,nan} = 3.0 (exclusion gives 2.0).
            # Two other medians in this tree already do it the DuckDB way:
            # `komira_eval/hash_agg_op_dt.mojo:1213` `_finalize_nan_last` and
            # `agg_extended_grouped.mojo:135` `_ext_median_inplace`.
            # Tracked by an internal doc (step 5).
            # ⭐ THAT STEP NOW HAS AN ANSWER, AND IT IS "DELETE THIS GUARD":
            # an internal doc
            # decides ONE policy -- NaN LAST and COUNTED -- for every order
            # statistic, DuckDB's. ⛔ THE EDIT IS DEFERRED TO THE `AGG_PERCENTILE` SLICE
            # ON PURPOSE, not forgotten: this exclusion is ASSERTED by
            # `tests/test_percentile_dispatch.mojo` T2 (twice -- the mixed-NaN
            # answer AND the all-NaN `seen[gid] == False` -> None arm), so
            # removing it is a deliberate semantic change that wants a
            # door-level parity test, and nothing user-facing reaches this
            # kernel until the tag exists. The exact edit is written out in
            # that ADR §4 so it is not re-derived.
            if v == v:
                self.values[g].append(v)
                self.seen[g] = True

    # Phase 0e.2: explicit-semantic alias for update_batch. PercentileAcc is the
    # only accumulator in the SoA family that BUFFERS values per-gid rather than
    # reducing them — quickselect runs at finalize, not at update time. Naming
    # the entry point `append_batch` at the dispatch boundary (AccumulatorEnum)
    # makes the contract loud at every call site so future authors don't try to
    # treat it like SUM/COUNT/MIN/MAX. The implementation IS the existing
    # update_batch — kept in one place to avoid drift.
    def append_batch[
        origin_g: Origin, origin_v: Origin
    ](
        mut self,
        gids: Span[UInt32, origin_g],
        values_ptr: Span[Float64, origin_v],
        num_rows: Int,
    ) raises:
        self.update_batch(gids, values_ptr, num_rows)

    def merge_at(mut self, dst_gid: Int, imm src: Self, src_gid: Int) raises:
        # Per-gid merge = concatenate raw values. v0.3 does extend_from_slice.
        if dst_gid >= len(self.values):
            raise Error("PercentileAcc.merge_at: dst_gid out of range")
        if src_gid >= len(src.values):
            raise Error("PercentileAcc.merge_at: src_gid out of range")
        if not src.seen[src_gid]:
            return
        ref src_vec = src.values[src_gid]
        for i in range(len(src_vec)):
            self.values[dst_gid].append(src_vec[i])
        self.seen[dst_gid] = True

    # ----- Quickselect + interpolation helpers -------------------------------

    def _select_nth(mut self, mut data: List[Float64], k: Int):
        # Hoare partition with median-of-three pivot + depth-limited fallback
        # to simple insertion sort beyond a small slice. Mojo has no
        # stdlib `select_nth_unstable_by`, so we inline an introselect-lite.
        #
        # PERF-CRITICAL: this is called once per group at finalize. O(N) expected.
        var lo = 0
        var hi = len(data) - 1
        while lo < hi:
            # Median-of-three pivot selection.
            var mid = (lo + hi) // 2
            if data[lo] > data[mid]:
                var tmp = data[lo]
                data[lo] = data[mid]
                data[mid] = tmp
            if data[lo] > data[hi]:
                var tmp = data[lo]
                data[lo] = data[hi]
                data[hi] = tmp
            if data[mid] > data[hi]:
                var tmp = data[mid]
                data[mid] = data[hi]
                data[hi] = tmp
            var pivot = data[mid]
            # Hoare two-pointer partition.
            var i = lo
            var j = hi
            while i <= j:
                while data[i] < pivot:
                    i = i + 1
                while data[j] > pivot:
                    j = j - 1
                if i <= j:
                    var tmp = data[i]
                    data[i] = data[j]
                    data[j] = tmp
                    i = i + 1
                    j = j - 1
            # Recurse on the side containing k.
            if k <= j:
                hi = j
            elif k >= i:
                lo = i
            else:
                break

    def _finalize_one(mut self, gid: Int) -> Optional[Float64]:
        # Port of compute_percentile_f64 (columnar_accumulator.rs:4251-4264).
        if gid >= len(self.values):
            return Optional[Float64](None)
        if not self.seen[gid]:
            return Optional[Float64](None)
        ref src = self.values[gid]
        var n = len(src)
        if n == 0:
            return Optional[Float64](None)
        # Copy to a local list because select_nth permutes in place and we
        # don't want to destroy the raw values (merge_at may still be pending
        # in more complex call sequences; harmless idempotence).
        var data = List[Float64]()
        for i in range(n):
            data.append(src[i])
        var pos = self.q * Float64(n - 1)
        var k_float = pos  # cast via int truncation
        var k = Int(k_float)  # floor for non-negative q*(n-1)
        var frac = pos - Float64(k)
        self._select_nth(data, k)
        var lower = data[k]
        if frac == Float64(0.0) or k + 1 >= n:
            return Optional[Float64](lower)
        # SIMD-friendly linear scan of upper slice for min (design §2, §6.4).
        var upper = data[k + 1]
        for i in range(k + 2, n):
            if data[i] < upper:
                upper = data[i]
        return Optional[Float64](lower * (Float64(1.0) - frac) + upper * frac)

    def finalize(mut self) -> List[Optional[Float64]]:
        var out = List[Optional[Float64]]()
        for g in range(len(self.values)):
            out.append(self._finalize_one(g))
        return out^

    def num_groups(self) -> Int:
        return len(self.values)

    # --- Accumulator trait conformance (Phase Acc-trait) ----------------------

    def update_batch[og: Origin, oc: Origin](
        mut self,
        gids: Span[Int, og],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises:
        """Trait-conforming: extract Float64 ptr from Column[HeapRegion], delegate."""
        # SAFETY: the pointers are formed from the borrowed spans and live only for
        # this call; the untracked origin and the nominal mutable cast keep the body's
        # pointer type unchanged (the kernels only read both buffers).
        var gids_ptr = (
            gids.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        var col_data_ptr = (
            col_data.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        var data_ptr = col_data_ptr.bitcast[Float64]()
        var off = col_offset
        for i in range(n):
            var g = gids_ptr[i]
            if g >= len(self.values):
                raise Error("PercentileAcc.update_batch: gid out of range")
            var v = (data_ptr + off + i)[]
            if v == v:  # NaN exclusion
                self.values[g].append(v)
                self.seen[g] = True

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        var arr = PrimitiveArray[DType.float64].allocate(len(self.values))
        for g in range(len(self.values)):
            var opt = self._finalize_one(g)
            if opt:
                arr.set(g, opt.value())
            # else: stays 0.0 (zero-initialized)
        return Column.from_primitive[DType.float64](arr)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        return self.finalize_to_column()


# =============================================================================
# PERF-CRITICAL: CountDistinctAcc — COUNT(DISTINCT col) via sort+dedup
# =============================================================================
# Port of `CountDistinctI64ColumnarAcc` (columnar_accumulator.rs:613-617, 2190).
# Strategy: per-gid `List[Int64]` collects raw values on update; at finalize
# we sort_unstable + dedup, and count = len(deduped).
#
# v0.3 uses sort+dedup at evaluate time (not per-insert hashing). Motivation:
#   - O(N log N) per group at finalize, amortized
#   - Zero allocation in the hot append path (amortized List append)
#   - Merge is free: just extend the raw buffer, dedup runs once at evaluate.
#
# Memory: O(groups * distinct_values_per_group * 8). For high-cardinality
# distinct values, HLL-based approx is the fallback (out of scope Phase 0a).
#
# Regression if removed: CB-04 COUNT(DISTINCT int) falls back to hash-per-
# insert.
# =============================================================================
struct CountDistinctAcc(Accumulator):
    """SoA COUNT(DISTINCT Int64) column: raw values per gid, dedup at finalize.

    ⛔ ZERO PRODUCTION CALLERS AS OF 2026-09-01, AND `is_null`-BLIND. Its
    only reachable surface is `AccumulatorArena.alloc_count_distinct` /
    `get_count_distinct`, which nothing outside tests calls. Board
    AGG-CD-NULL () fixed the four LIVE COUNT(DISTINCT) accumulate
    loops and deliberately left this one alone: a null skip in dead code is
    coverage that is not there, and the next audit would read it as handled.

    ⚠ WIRING IT BACK IN NEEDS A VALIDITY INPUT, WHICH `update_batch` DOES
    NOT HAVE. Both overloads take a values pointer and a row count and
    nothing else, so there is no bit to consult — the same MISSING INPUT
    (not a missed branch) that let the defect survive four implementations.
    `komira_agg_api.agg_column_ptrs.ValidityLanes` is the channel to thread.
    """

    var buffers: List[List[Int64]]

    def __init__(out self):
        self.buffers = List[List[Int64]]()

    @staticmethod
    def new() -> Self:
        return Self()

    def ensure_capacity(mut self, num_groups: Int):
        while len(self.buffers) < num_groups:
            self.buffers.append(List[Int64]())

    def update_batch[
        origin_g: Origin, origin_v: Origin
    ](
        mut self,
        gids: Span[UInt32, origin_g],
        values: Span[Int64, origin_v],
        num_rows: Int,
    ) raises:
        for i in range(num_rows):
            var g = Int(gids[i])
            if g >= len(self.buffers):
                raise Error("CountDistinctAcc.update_batch: gid out of range")
            self.buffers[g].append(values[i])

    def merge_at(mut self, dst_gid: Int, imm src: Self, src_gid: Int) raises:
        if dst_gid >= len(self.buffers):
            raise Error("CountDistinctAcc.merge_at: dst_gid out of range")
        if src_gid >= len(src.buffers):
            raise Error("CountDistinctAcc.merge_at: src_gid out of range")
        ref src_vec = src.buffers[src_gid]
        for i in range(len(src_vec)):
            self.buffers[dst_gid].append(src_vec[i])

    # ----- sort+dedup helper -------------------------------------------------

    def _sort_inplace(mut self, mut data: List[Int64]):
        # Insertion sort — acceptable Phase 0a because per-gid buffers are
        # usually small (<1k distinct values) and quickselect-style sort is
        # out of scope for correctness. Phase 0c/beyond will switch to a
        # proper pdqsort once we port one into Mojo.
        #
        # PERF-CRITICAL NOTE: if a group accumulates >10k distinct values,
        # this O(N^2) path WILL regress. v0.3 uses Rust stdlib's pdqsort
        # via sort_unstable(). Port-of-sort is a follow-up task.
        var n = len(data)
        for i in range(1, n):
            var key = data[i]
            var j = i - 1
            while j >= 0 and data[j] > key:
                data[j + 1] = data[j]
                j = j - 1
            data[j + 1] = key

    def _dedup_count(self, imm data: List[Int64]) -> Int64:
        # Assumes data is already sorted. Matches Rust Vec::dedup semantics.
        var n = len(data)
        if n == 0:
            return Int64(0)
        var distinct = Int64(1)
        for i in range(1, n):
            if data[i] != data[i - 1]:
                distinct = distinct + Int64(1)
        return distinct

    def finalize(mut self) -> List[Int64]:
        var out = List[Int64]()
        for g in range(len(self.buffers)):
            # Take-by-value so we can sort; don't destroy the raw buffer in
            # case of replay (Phase 0a conservative).
            var copy = List[Int64]()
            ref src = self.buffers[g]
            for i in range(len(src)):
                copy.append(src[i])
            self._sort_inplace(copy)
            out.append(self._dedup_count(copy))
        return out^

    def num_groups(self) -> Int:
        return len(self.buffers)

    # --- Accumulator trait conformance (Phase Acc-trait) ----------------------

    def update_batch[og: Origin, oc: Origin](
        mut self,
        gids: Span[Int, og],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises:
        """Trait-conforming: extract Int64 ptr from Column[HeapRegion], delegate."""
        # SAFETY: the pointers are formed from the borrowed spans and live only for
        # this call; the untracked origin and the nominal mutable cast keep the body's
        # pointer type unchanged (the kernels only read both buffers).
        var gids_ptr = (
            gids.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        var col_data_ptr = (
            col_data.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        var data_ptr = col_data_ptr.bitcast[Int64]()
        var off = col_offset
        for i in range(n):
            var g = gids_ptr[i]
            if g >= len(self.buffers):
                raise Error("CountDistinctAcc.update_batch: gid out of range")
            self.buffers[g].append((data_ptr + off + i)[])

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        var result = self.finalize()
        var arr = PrimitiveArray[DType.int64].allocate(len(result))
        for i in range(len(result)):
            arr.set(i, result[i])
        return Column.from_primitive[DType.int64](arr)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        return self.finalize_to_column()
