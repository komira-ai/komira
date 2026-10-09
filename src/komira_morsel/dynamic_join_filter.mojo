# =============================================================================
# DynamicJoinFilter -- aggregate of the three v0.3 dynamic-filter tiers
# =============================================================================
#
# v0.3 spec source: komira-engine/src/morsel_join.rs:434-488 + 906-976.
#
# After the build hash table is finalized, up to three filter tiers are
# constructed and pushed to the probe pipeline:
#
#   - Tier 1: In-list filter -- for tiny build sides (<=128 distinct keys),
#     an explicit hash-set check. Cheapest per-row cost, zero false positives.
#   - Tier 2: Min/max range filter -- always generated. `key >= min AND
#     key <= max`. Already used for row-group pruning (Parquet stats);
#     extended here to per-batch filtering.
#   - Tier 3: Bloom filter -- probabilistic set membership test.
#     Constructed only when `total_rows > 0`. ~1% FPR.
#
# Phase 3.5 ports the Int64 single-key path. v0.3 also supports Int32
# / Float64 / Float32 / Utf8 plus multi-key (composite hash) builds;
# these follow when columnar dispatch needs them.
#
# Per the repository pointer rules:
#   - No UnsafePointer in public API.
#   - DynamicJoinFilter is Movable only (BloomFilter inside is non-copyable
#     because its data buffer is heap-allocated and cannot be cheaply
#     duplicated). Cross-segment sharing wraps in `ArcPointer[
#     DynamicJoinFilter]` (Phase 3.6) which the build-segment owner
#     constructs once and clones (refcount bump) per probe-segment worker.
#     The bloom filter inside is read-only after construction.
# =============================================================================

from komira_dynamic_filter.bloom_filter import BloomFilter
from komira_dynamic_filter.constant_filter import ConstantFilter
from komira_dynamic_filter.in_list_filter import InListFilter
from komira_dynamic_filter.range_filter import RangeFilter


# v0.3 source: morsel_join.rs:468 (BLOOM_FILTER_THRESHOLD).
# DuckDB applies no minimum threshold (builds a BF even for 1 row). For
# tiny builds (<=128 keys), the in-list filter is strictly better, but
# we still build a BF as a fallback for multi-key joins where in-list
# isn't supported. BF construction cost for 57 rows is ~1us.
comptime BLOOM_FILTER_THRESHOLD: Int = 0

# Upper bound on the build-row count for dynamic-filter pushdown. Above this,
# bloom selectivity on the probe side is unlikely to justify the per-row hash +
# bit-test cost: every row passes the bloom, and the late-materialization
# decode plus gather adds overhead against the full-decode fast path. DuckDB's
# runtime-filter pushdown also gates on build-side cardinality and selectivity;
# without a dynamic gate the bloom probe itself becomes the bottleneck on
# bloom-saturated joins. The cap is tuned to keep joins whose build side is
# large at parity with their pre-pushdown baselines while still firing where the
# build side is small (for example post-HAVING).
#
# TODO: wire `SelectivityTracker` into the source's bloom-mask path so the cap
# can be removed in favour of dynamic pause/resume.
comptime DYNAMIC_FILTER_BUILD_CAP: Int = 65_536


# =============================================================================
# THE ADMISSION POLICY -- one named predicate, so no caller re-derives it
# =============================================================================
#
# CB20-DEAD-DYNFILTER. `build_int64_from_list` has SIX production
# call sites. Five spelled their own `build_n <= DYNAMIC_FILTER_BUILD_CAP` guard
# (`materialize_join.mojo` :1470 / :1651 / :1725 / :2120, `optimizer_scan_dedup
# .mojo` :674). The sixth -- `HashBuildSink._finalize_dynamic_filter_from_keys`
# -- did not, so cb20's 18,295,832-key build paid a full element-by-element
# `List[Int64]` copy (146 MB) to construct a filter that NO consumer can apply.
# Naming the policy once is what stops the seventh caller from repeating it.
#
# WHY `n > CAP` MEANS "NO FILTER AT ALL", not "a range-only filter".
# ------------------------------------------------------------------
# Above the cap the in-list / bloom / constant tiers are deliberately skipped
# (they do not amortize at that cardinality). Q13-OUTER-JOIN-COMPLETENESS-V0.4
# Phase A shipped a RANGE-ONLY `DynamicJoinFilter` for that case as
# a "producer foundation", explicitly deferring the matching consumer-side gate
# to a Phase B that never landed. Every consumer of the range tier was
# re-enumerated and every one is unreachable for such an object:
#
#   * `range_ref()`          -- ONE caller, `parquet_source.mojo:3239`, and it
#                               sits INSIDE `if apply_tier12:` where
#                               `apply_tier12 = df.has_in_list()` (:3222).
#                               Above cap `has_in_list()` is False.
#   * `in_list_ref()`        -- same branch (`parquet_source.mojo:3273`).
#   * `has_bloom()`          -- `parquet_source.mojo:3302` gates the bloom mask;
#                               above cap `_has_bloom` is False.
#   * `has_range()`,
#     `range_min_int64()`,
#     `range_max_int64()`    -- ZERO production callers.
#   * `might_contain_int64()`-- the aggregate DOES consult the range tier, but
#                               its only caller is
#                               `dyn_filter_apply.apply_dyn_filter_int64`,
#                               which itself has ZERO callers repo-wide.
#
# So a range-only filter removed no rows. It was not even inert: installing one
# sets `has_dyn_filter` in the parquet source, which forces the late-materialise
# path and disables four decode fast paths (`parquet_source.mojo:2659, 2701,
# 2729, 2864, 2943, 3026`). It cost a 146 MB copy to make the probe slower.
#
# The above-cap arm is therefore DELETED and this predicate restores the
# pre-Phase-A contract, now stated positively: a returned `DynamicJoinFilter`
# always has at least one tier a consumer will actually APPLY. If a future
# Phase B wires a standalone `apply_range = df.has_range()` gate at the
# consumer, re-admit above-cap builds HERE and the six producers inherit it.
@always_inline
def dynamic_filter_admits_build(n: Int) -> Bool:
    """True iff a build of `n` INT64 keys should produce a DynamicJoinFilter.

    False for `n == 0` (v0.3:912-914 -- no useful filter from zero rows) and
    for `n > DYNAMIC_FILTER_BUILD_CAP` (every tier that survives the cap is
    unapplied by every consumer -- see the block comment above).

    Callers MUST consult this BEFORE materialising the key list: the whole
    point is to skip the copy, not to discard its result afterwards.
    """
    return n > 0 and n <= DYNAMIC_FILTER_BUILD_CAP


# =============================================================================
# DynamicJoinFilter (Int64 specialization for Phase 3.5)
# =============================================================================


struct DynamicJoinFilter(Movable):
    """Aggregate of the v0.3 three dynamic-filter tiers (in-list / range /
    bloom), plus the Phase 2.A ConstantFilter tier (single-distinct-value
    fast path).

    Constructed from build-side INT64 keys after the hash join's combine()
    completes. Pushed to the probe-side scan source for per-batch filtering.

    Cascade ordering (cheapest first):
        Tier 0 -- ConstantFilter (1 scalar compare; fires when distinct==1).
        Tier 1 -- InListFilter   (1 hash lookup; fires when distinct<=128).
        Tier 2 -- RangeFilter    (2 compares; always present).
        Tier 3 -- BloomFilter    (hash + bit-test; present when total_rows>0).

    Mutual exclusivity: when ConstantFilter is active (`distinct == 1`),
    the InListFilter tier is SKIPPED at construction time (a 1-element
    in-list is strictly more expensive than scalar equality). The range
    tier is degenerate (min == max) but kept inert; the cascade short-
    circuits at the constant tier above it.

    Fields:
        _constant: Optional[ConstantFilter] -- present when distinct
            count == 1. NEW in Phase 2.A.
        _in_list: Optional[InListFilter] -- present when 1 < distinct <= 128.
            Skipped when ConstantFilter is active (mutually exclusive).
        _range: RangeFilter -- always present for non-empty build.
        _bloom: BloomFilter -- always present when total_rows > 0.
        _has_bloom: explicit flag (BloomFilter has no zero-state we can
            test cheaply; use this to gate `might_contain_int64` Tier 3).
    """

    var _constant: Optional[ConstantFilter]
    var _in_list: Optional[InListFilter]
    var _range: RangeFilter
    var _bloom: BloomFilter
    var _has_bloom: Bool

    def __init__(
        out self,
        var constant: Optional[ConstantFilter],
        var in_list: Optional[InListFilter],
        var range_filter: RangeFilter,
        var bloom: BloomFilter,
        has_bloom: Bool,
    ):
        self._constant = constant^
        self._in_list = in_list^
        self._range = range_filter^
        self._bloom = bloom^
        self._has_bloom = has_bloom

    @staticmethod
    def build_int64_from_list(
        keys: List[Int64],
        cap: Int = DYNAMIC_FILTER_BUILD_CAP,
    ) -> Optional[DynamicJoinFilter]:
        """Build a DynamicJoinFilter from a build-side INT64 key list.

        v0.3 source: morsel_join.rs:906-976 (build_dynamic_filter), Int64
        path. Computes:
          1. Range (always — required for tier 2).
          2. In-list (only when <=128 distinct keys — tier 1).
          3. Bloom (when total_rows > 0 — tier 3).

        `cap` (FUSE1-SK, 2026-09-25): the admission ceiling, DEFAULTING to
        `DYNAMIC_FILTER_BUILD_CAP` so every existing caller is unchanged. The
        cap predates the per-worker bloom `SelectivityTracker` the parquet
        source now consults before applying the bloom tier (see the Phase 3.6
        note above it), so a caller that has its own reason to want the bloom
        over a larger build may raise it; the single-key stream route does,
        and says why at `FUSED_SINGLE_STREAM_MAX_BUILD_ROWS`.

        Returns:
            Some(DynamicJoinFilter) when 1 <= len(keys) <= `cap` (by default
            `dynamic_filter_admits_build(len(keys))`). None otherwise.

            A returned filter ALWAYS carries at least one tier a consumer
            applies. There is no "built but never consulted" return value; see
            the admission-policy block above `dynamic_filter_admits_build`.
        """
        var n = len(keys)
        # CB20-DEAD-DYNFILTER: one gate, both refusals.
        #   n == 0    -- v0.3:912-914 early return, no useful filter.
        #   n > CAP   -- the RANGE-ONLY object this used to build here had no
        #                reachable consumer (Q13 Phase A's "Phase B" never
        #                landed). Deleted, not silently returned.
        # This is a NO-OP for every production caller: all six now pre-gate on
        # the same cap before materialising their key list, so no production
        # path reaches this refusal with n > CAP. It is the backstop, not the
        # gate -- the gate has to be at the caller or the copy is already paid.
        if n == 0 or n > cap:
            return None

        # Tier 2: range (always built — O(n) single-pass min/max, cheap
        # at any cardinality).
        var range_opt = RangeFilter.try_from_int64(keys)
        if not range_opt:
            # Defensive: try_from_int64 returns None only on empty; n > 0
            # so this is unreachable, but guard for robustness.
            return None
        var range_filter = range_opt.take()

        # An earlier revision built a RangeFilter-ONLY DynamicJoinFilter here
        # when `n > CAP`, as a producer foundation for a consumer-side step
        # (`apply_range = df.has_range()`) that was never written. DELETED:
        # the object it produced had no reachable
        # consumer, and installing one made the probe scan SLOWER by forcing
        # `has_dyn_filter` late-materialisation. The refusal now happens up
        # front in `dynamic_filter_admits_build`, before the caller pays for
        # the key list. Full call-site enumeration is in the block comment
        # above that predicate; the falsifier is
        # `tests/engine/test_dynamic_filter_range_only_above_cap.mojo`.

        # Tier 1: in-list (<=128 distinct).
        var in_list = InListFilter.try_from_int64(keys)

        # Phase 2.A: ConstantFilter (tier 0) detection. When the build
        # side reduces to exactly ONE distinct value, the cheapest probe
        # is `probe_key == constant` (one scalar compare). Detect via
        # `InListFilter.size() == 1` (already deduplicated). When active,
        # the InListFilter tier is SKIPPED (mutually exclusive — a
        # 1-element in-list is strictly more expensive than the scalar
        # equality compare we use instead).
        #
        # DuckDB precedent:
        #   * `duckdb/src/include/duckdb/planner/filter/
        #     constant_filter.hpp` — TableFilter variant for
        #     `column = constant`.
        #   * `duckdb/src/execution/operator/join/
        #     physical_hash_join.cpp` — LegacyConstantFilter emission
        #     in the dynamic-filter pushdown when build distinct == 1.
        var constant_opt = Optional[ConstantFilter](None)
        if in_list and in_list.value().size() == 1:
            # The single distinct value equals both min and max of the
            # range tier (degenerate range). Pull it from the already-
            # built range filter to avoid a redundant pass over `keys`.
            var the_value = range_filter.min_int64()
            constant_opt = Optional(
                ConstantFilter(the_value, has_null=False)
            )
            # Mutually exclusive: drop the in-list tier (the constant
            # tier is strictly cheaper and produces the same answer).
            in_list = None

        # Tier 3: bloom filter.
        # v0.3:953-969 constructs over hashes; Mojo's BloomFilter
        # exposes `insert_int64(value)` which is the equivalent (FNV-1a
        # hash inline). FPP=0.01 matches v0.3's 7-hash 10-bit-per-element
        # parameters within the Parquet SBBF spec.
        var has_bloom = n > BLOOM_FILTER_THRESHOLD
        var bloom: BloomFilter
        if has_bloom:
            bloom = BloomFilter.with_ndv_fpp(n, 0.01)
            for i in range(n):
                bloom.insert_int64(keys[i])
        else:
            # Allocate a tiny placeholder so the struct field is always
            # initialized (Mojo doesn't allow uninitialized struct fields).
            bloom = BloomFilter.with_ndv_fpp(1, 0.01)

        return DynamicJoinFilter(
            constant_opt^, in_list^, range_filter^, bloom^, has_bloom
        )

    # -------------------------------------------------------------------------
    # Tier-presence accessors (used by callers that build per-tier filter
    # stages and consult selectivity trackers).
    # -------------------------------------------------------------------------

    @always_inline
    def has_constant(self) -> Bool:
        """Phase 2.A: True when the build side reduced to exactly one
        distinct key and the ConstantFilter tier is active. When True,
        the InListFilter tier is guaranteed inactive (mutually exclusive).
        """
        return self._constant.__bool__()

    @always_inline
    def constant_value_int64(self) -> Int64:
        """Phase 2.A: the single distinct build-side value. Caller MUST
        check `has_constant()` first; returns 0 sentinel when inactive.
        """
        if self._constant:
            return self._constant.value().value_int64()
        return Int64(0)

    @always_inline
    def has_in_list(self) -> Bool:
        return self._in_list.__bool__()

    @always_inline
    def in_list_size(self) -> Int:
        if self._in_list:
            return self._in_list.value().size()
        return 0

    @always_inline
    def has_range(self) -> Bool:
        # Range is always built when any DynamicJoinFilter exists.
        return True

    @always_inline
    def range_min_int64(self) -> Int64:
        return self._range.min_int64()

    @always_inline
    def range_max_int64(self) -> Int64:
        return self._range.max_int64()

    @always_inline
    def has_bloom(self) -> Bool:
        return self._has_bloom

    # -------------------------------------------------------------------------
    # Tier accessors for downstream wiring (probe-side mask helpers).
    # Returns refs into self so callers don't trigger a Copyable copy of
    # the full bloom filter.
    # -------------------------------------------------------------------------

    def bloom_ref(self) -> ref [self._bloom] BloomFilter:
        return self._bloom

    def in_list_ref(self) -> ref [self._in_list] Optional[InListFilter]:
        return self._in_list

    def range_ref(self) -> ref [self._range] RangeFilter:
        return self._range

    # -------------------------------------------------------------------------
    # Aggregate `might_contain_int64` -- AND of all active tiers.
    #
    # Cascade ordering (cheapest first):
    #   Tier 0 (Phase 2.A): ConstantFilter -- 1 scalar compare; when
    #       active, returns the exact answer (zero FPR) and skips all
    #       other tiers.
    #   Tier 1: InListFilter -- 1 hash lookup; zero FPR -> exact answer
    #       when active.
    #   Tier 2: RangeFilter  -- 2 compares; always present (degenerate
    #       when distinct==1 but inert because Tier 0 short-circuits).
    #   Tier 3: BloomFilter  -- hash + bit-test; probabilistic.
    #
    # v0.3 doesn't aggregate this way (it dispatches via FilterStage on the
    # columnar path), but for unit tests and a default fallback this
    # composition is the contract.
    # -------------------------------------------------------------------------

    @always_inline
    def might_contain_int64(self, value: Int64) -> Bool:
        # Tier 0 (Phase 2.A) — ConstantFilter is the cheapest (1 compare)
        # and produces an exact answer. When active, all other tiers are
        # skipped.
        if self._constant:
            return self._constant.value().matches_int64(value)
        # Tier 2 (range) — applied before Tier 1 because the 2-compare
        # bounds check is the v0.3 columnar dispatch order
        # (`FilterStage::Range` precedes `FilterStage::InList`).
        if not self._range.contains_int64(value):
            return False
        # Tier 1 (in-list) — zero false positives -> exact answer when
        # active.
        if self._in_list:
            return self._in_list.value().contains_int64(value)
        # Tier 3 (bloom) — probabilistic fallback.
        if self._has_bloom:
            return self._bloom.might_contain_int64(value)
        return True
