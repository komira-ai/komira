# =============================================================================
# Adaptive aggregation strategy selection (S1/S2/S3)
# =============================================================================
#
# PERF-CRITICAL: picks the right aggregation shape before any real work is
# done. Getting the wrong strategy on a workload costs 1.5-5x.
#
#   - S1 thread-local radix HT (default, cardinality <10M)
#   - S2 CAS global HT (cardinality >10M) — not implemented; see below
#   - S3 streaming sort (presorted input AND <10K groups, single worker)
#
# HLL cardinality sampling: 12-bit precision (4096 registers), samples first
# 3 batches (SAMPLE_BATCHES=3).
# =============================================================================

from std.math import log2

from komira_arrow.arrow_types import ArrowType


# -----------------------------------------------------------------------------
# Strategy tags
# -----------------------------------------------------------------------------

# Explicit sub-strategy for high-cardinality S1.
# STRATEGY_S1_RADIX (== S1_MINIMAP, value 1) is the default S1 Path 1 —
# per-worker FlatHashAggregator + MiniMap+Abandon (below the crossover).
# STRATEGY_S1_PARTITIONED (value 4) routes to Path 2 above the crossover
# (PartitionedFlatHashAggregator / PartitionedColumnarAggMap +
# partition-parallel steal_merge at combine).
#
# STRATEGY_S1_MINIMAP is a readability alias for STRATEGY_S1_RADIX — same
# value, different intent (the caller is explicitly asking for Path 1).
#
# Above the crossover, L2-resident per-partition sub-tables outperform
# MiniMap+Abandon.
comptime STRATEGY_S1_RADIX: UInt8 = 1
comptime STRATEGY_S1_MINIMAP: UInt8 = 1       # alias of STRATEGY_S1_RADIX
comptime STRATEGY_S2_CAS_GLOBAL: UInt8 = 2    # not implemented; see select_strategy
comptime STRATEGY_S3_STREAMING_SORT: UInt8 = 3
comptime STRATEGY_S1_PARTITIONED: UInt8 = 4


# -----------------------------------------------------------------------------
# Thresholds
# -----------------------------------------------------------------------------

# S1 ceiling: below this estimated cardinality we use per-worker radix HTs
# (MiniMap+Abandon, 64-way partition merge). Above: S2 (not implemented;
# routed to the partitioned S1 path).
comptime S1_MAX_CARDINALITY: Int = 10_000_000

# S3 cap: streaming sort only activates when presorted AND estimated groups
# fit in a single worker's hot HT.
comptime S3_SORTED_THRESHOLD: Int = 10_000

# S1-MiniMap -> S1-Partitioned crossover. Below this cardinality the
# per-worker MiniMap+Abandon path wins (small HTs, flush-into-partitioned
# store at the combine step). Above it, pre-partitioned per-worker
# aggregators win (L2-resident per-partition sub-tables on the consume
# hot path, cheap partition-parallel steal_merge at combine).
#
# Path 2 always uses NUM_PARTITIONS=64, so this threshold is just the route
# decision: "is partitioned worth it?". The value is empirical, measured
# against NDV estimates that merge HLL registers across row groups.
comptime S1_PARTITIONED_THRESHOLD: Int = 5_000_000

# HLL precision: number of bits used to index registers. Register count =
# 1 << precision. 12 bits → 4096 registers.
comptime HLL_PRECISION: Int = 12
comptime HLL_NUM_REGISTERS: Int = 4096     # 1 << HLL_PRECISION

# Number of input batches sampled before we freeze the strategy decision.
comptime SAMPLE_BATCHES: Int = 3


# -----------------------------------------------------------------------------
# HyperLogLog (12-bit / 4096-register) cardinality estimator
# -----------------------------------------------------------------------------
#
# Correctness reference: Flajolet et al. 2007. Register
# update:
#   1. Take high HLL_PRECISION bits of the mixed hash to index the register.
#   2. Count leading zeros in the remaining bits (+1); keep the max.
# Estimate:
#   E = alpha_m * m^2 / sum(1 / 2^M[i])   with small-range + large-range fixes.
#
# This struct is POD-like: plain array of UInt8 register values, no heap
# pointers (List owns the storage). Copyable and Movable so it can be cloned
# when the sampler finalizes and hands the estimate to the planner.


struct HyperLogLog(Copyable, Movable):
    """12-bit precision HLL estimator. Registers store max leading-zero+1."""

    var registers: List[UInt8]

    def __init__(out self):
        self.registers = List[UInt8]()
        for _ in range(HLL_NUM_REGISTERS):
            self.registers.append(UInt8(0))

    def add(mut self, hash: UInt64):
        """Register the observation `hash`. O(1)."""
        # High HLL_PRECISION bits index the register.
        var idx = Int(hash >> UInt64(64 - HLL_PRECISION))
        # Remaining 64 - HLL_PRECISION bits feed the leading-zero count.
        var w = hash << UInt64(HLL_PRECISION)
        # +1 so an all-zero window still produces rank >= 1; rank capped at
        # (64 - HLL_PRECISION) + 1 = 53 for precision=12.
        var rank: UInt8
        if w == UInt64(0):
            rank = UInt8(64 - HLL_PRECISION + 1)
        else:
            # Count leading zeros manually (the Mojo stdlib has no portable
            # CLZ intrinsic we can call from def context cleanly).
            var r: Int = 1
            var mask = UInt64(1) << UInt64(63)
            while (w & mask) == UInt64(0):
                r += 1
                mask = mask >> UInt64(1)
                if r > 64:
                    break  # cov: unreachable w != 0 has a set bit, so the loop exits with r <= 64
            rank = UInt8(r)
        if rank > self.registers[idx]:
            self.registers[idx] = rank

    def estimate(imm self) -> Int:
        """Return the estimated cardinality (approximate)."""
        # Harmonic mean of 2^M[i] plus alpha_m bias correction.
        # For m=4096 alpha ≈ 0.7213/(1+1.079/m) ≈ 0.72125.
        var m = Float64(HLL_NUM_REGISTERS)
        var sum_inv = Float64(0.0)
        var zero_registers = 0
        for i in range(HLL_NUM_REGISTERS):
            var r = Int(self.registers[i])
            if r == 0:
                zero_registers += 1
            sum_inv = sum_inv + (Float64(1.0) / Float64(Int(1) << r))
        var alpha = Float64(0.72125)
        var e = (alpha * m * m) / sum_inv

        # Small-range correction (bias for E <= 2.5*m when some registers=0).
        if e <= Float64(2.5) * m and zero_registers > 0:
            # Linear counting: m * ln(m / zero_registers).
            # Avoid log import; use Newton-style approximation via log2/ln2.
            var ratio = m / Float64(zero_registers)
            # ln(x) = log2(x) / log2(e); log2(e) = 1/ln(2) ≈ 1.4426950408
            var ln_ratio = log2(ratio) * Float64(0.6931471805599453)
            e = m * ln_ratio

        if e < Float64(0.0):
            return 0
        return Int(e)


# -----------------------------------------------------------------------------
# Strategy decision
# -----------------------------------------------------------------------------


struct StrategyDecision(Copyable, Movable):
    """Chosen strategy plus the sampled estimate that drove the decision."""

    var strategy: UInt8
    var estimated_cardinality: Int
    # True if the input plan advertises a sort order that is a prefix of the
    # group-by keys. Computed at plan time; we just record it here.
    var presorted: Bool

    def __init__(out self, strategy: UInt8, estimated_cardinality: Int, presorted: Bool):
        self.strategy = strategy
        self.estimated_cardinality = estimated_cardinality
        self.presorted = presorted


# -----------------------------------------------------------------------------
# Plan-time / runtime sort-order detection — current limitation:
#
# LogicalPlan does NOT carry a sort_order field, so the `presorted` bit on
# AggSinkData can only be set by the pipeline compiler when the input is an
# explicit ORDER BY upstream of GROUP BY. Parquet statistics-driven
# detection is not implemented.
#
# The engine's streaming S3 aggregate provides a runtime check
# (`is_batch_monotonic_non_decreasing_int64`) on the first morsel. The
# scheduler can call it and, if the first morsel is sorted + cardinality
# estimate is < threshold, commit to the S3 state; subsequent monotonicity
# violations would corrupt results silently. Escalation is the scheduler's
# responsibility, not this module's.
# -----------------------------------------------------------------------------


def is_s3_eligible(
    estimated_cardinality: Int,
    presorted: Bool,
    num_workers: Int,
) -> Bool:
    """Convenience predicate — True iff all three S3 preconditions hold.

    (presorted, cardinality < S3_SORTED_THRESHOLD, single worker.)

    Useful for the scheduler / FlatHashAggSink dispatch path to decide
    whether to construct a StreamingS3AggState instead of the hash sink,
    without having to pattern-match on StrategyDecision.strategy.
    """
    return (
        presorted
        and estimated_cardinality < S3_SORTED_THRESHOLD
        and num_workers == 1
    )


def choose_strategy(
    estimated_cardinality: Int,
    presorted: Bool,
    num_workers: Int,
) -> StrategyDecision:
    """Pick an aggregation strategy.

    Precedence:
      1. S3 streaming sort — presorted AND estimate < S3_SORTED_THRESHOLD AND
         single-worker-safe (num_workers == 1 or the caller downgrades).
      2. S2 CAS global HT — estimate > S1_MAX_CARDINALITY (not implemented:
         we still choose S1 and the caller should log a perf warning).
      3. S1 — further split:
           3a. STRATEGY_S1_PARTITIONED when estimate >= S1_PARTITIONED_THRESHOLD
               (Path 2 per-worker partitioned aggregators + steal_merge).
           3b. STRATEGY_S1_MINIMAP otherwise (Path 1 MiniMap+Abandon).
         STRATEGY_S1_RADIX is an alias for S1_MINIMAP on the
         StrategyDecision; the sink's dispatch reads the tag and routes
         explicitly.
    """
    # S3 gate: strict `<` threshold; single worker only.
    if presorted and estimated_cardinality < S3_SORTED_THRESHOLD and num_workers == 1:
        return StrategyDecision(
            STRATEGY_S3_STREAMING_SORT, estimated_cardinality, presorted
        )

    # S2 gate: when estimate exceeds the S1 ceiling a CAS global HT would be
    # the S2 choice; it is not implemented, so S1 is kept. We route high-card estimates through the partitioned S1 path
    # because it handles >500K groups better than MiniMap.
    if estimated_cardinality > S1_MAX_CARDINALITY:
        return StrategyDecision(
            STRATEGY_S1_PARTITIONED, estimated_cardinality, presorted
        )

    # S1 sub-strategy pivot: Path 2 for large cardinalities,
    # Path 1 MiniMap+Abandon for small ones.
    if estimated_cardinality >= S1_PARTITIONED_THRESHOLD:
        return StrategyDecision(
            STRATEGY_S1_PARTITIONED, estimated_cardinality, presorted
        )

    return StrategyDecision(
        STRATEGY_S1_RADIX, estimated_cardinality, presorted
    )


# -----------------------------------------------------------------------------
# There is no runtime cardinality sampler: strategy is decided once at plan
# construction via `choose_strategy(estimated_groups, ...)` using
# Parquet-stats-derived cardinality estimates. The `HyperLogLog` primitive
# above serves plan-time estimation callers and unit tests of the HLL math.
# -----------------------------------------------------------------------------


# =============================================================================
# select_strategy + select_optimal_strategy_type_only
# =============================================================================
#
#   - select_strategy (hint, est, sorted), returning a StrategyDecision
#     (S1/S2/S3 axis). It maps hints onto the S1 split (S1_RADIX vs
#     S1_PARTITIONED) that `choose_strategy` uses.
#   - select_optimal_strategy_type_only — the type-only pass of key-strategy
#     selection (Bool/Int8/Int16/UInt8/UInt16 → PerfectHash unconditionally;
#     everything else → Columnar). A stats-driven pass for Int32+ keys is
#     not implemented.
# =============================================================================


# -----------------------------------------------------------------------------
# AggStrategyHint
# -----------------------------------------------------------------------------

comptime AGG_HINT_ADAPTIVE: UInt8 = 0
comptime AGG_HINT_FORCE_THREAD_LOCAL: UInt8 = 1
comptime AGG_HINT_FORCE_GLOBAL_CONCURRENT: UInt8 = 2
comptime AGG_HINT_FORCE_SORT_BASED: UInt8 = 3


# -----------------------------------------------------------------------------
# AggStrategy carrier
# -----------------------------------------------------------------------------
#
# Mojo cannot express enum payloads. Sidecar pattern:
# `tag` selects which of the parallel struct fields are meaningful.

comptime AGG_STRATEGY_UNGROUPED: UInt8 = 0
comptime AGG_STRATEGY_COLUMNAR: UInt8 = 1
comptime AGG_STRATEGY_PERFECT_HASH: UInt8 = 2
comptime AGG_STRATEGY_PERFECT_HASH_COMPOSITE: UInt8 = 3


# -----------------------------------------------------------------------------
# KeyDomain
# -----------------------------------------------------------------------------

comptime KEY_DOMAIN_INT: UInt8 = 0
comptime KEY_DOMAIN_DICT: UInt8 = 1


struct KeyDomain(Copyable, Movable):
    """Per-key domain info for composite PerfectHash."""

    var tag: UInt8
    var min: Int
    var range: Int
    var dict_size: Int
    var stride: Int

    def __init__(
        out self,
        tag: UInt8,
        min: Int,
        range: Int,
        dict_size: Int,
        stride: Int,
    ):
        self.tag = tag
        self.min = min
        self.range = range
        self.dict_size = dict_size
        self.stride = stride

    @staticmethod
    def int_domain(min: Int, range: Int, stride: Int) -> KeyDomain:
        """Construct an Int-variant KeyDomain."""
        return KeyDomain(KEY_DOMAIN_INT, min, range, 0, stride)

    @staticmethod
    def dict_domain(dict_size: Int, stride: Int) -> KeyDomain:
        """Construct a Dict-variant KeyDomain."""
        return KeyDomain(KEY_DOMAIN_DICT, 0, 0, dict_size, stride)


struct AggStrategy(Movable):
    """Carrier struct for a payload-bearing AggStrategy enum.

    `tag` selects which fields are meaningful:
      AGG_STRATEGY_UNGROUPED:                no payload.
      AGG_STRATEGY_COLUMNAR:                 no payload.
      AGG_STRATEGY_PERFECT_HASH:             domain_size, key_offset.
      AGG_STRATEGY_PERFECT_HASH_COMPOSITE:   domain_size, keys.
    """

    var tag: UInt8
    var domain_size: Int
    var key_offset: Int
    var keys: List[KeyDomain]

    def __init__(
        out self,
        tag: UInt8,
        domain_size: Int,
        key_offset: Int,
        var keys: List[KeyDomain],
    ):
        self.tag = tag
        self.domain_size = domain_size
        self.key_offset = key_offset
        self.keys = keys^

    @staticmethod
    def ungrouped() -> AggStrategy:
        """Construct AggStrategy::Ungrouped."""
        return AggStrategy(AGG_STRATEGY_UNGROUPED, 0, 0, List[KeyDomain]())

    @staticmethod
    def columnar() -> AggStrategy:
        """Construct AggStrategy::Columnar."""
        return AggStrategy(AGG_STRATEGY_COLUMNAR, 0, 0, List[KeyDomain]())

    @staticmethod
    def perfect_hash(domain_size: Int, key_offset: Int) -> AggStrategy:
        """Construct AggStrategy::PerfectHash { domain_size, key_offset }."""
        return AggStrategy(
            AGG_STRATEGY_PERFECT_HASH, domain_size, key_offset, List[KeyDomain]()
        )

    @staticmethod
    def perfect_hash_composite(
        domain_size: Int, var keys: List[KeyDomain]
    ) -> AggStrategy:
        """Construct AggStrategy::PerfectHashComposite { domain_size, keys }."""
        return AggStrategy(
            AGG_STRATEGY_PERFECT_HASH_COMPOSITE, domain_size, 0, keys^
        )


# -----------------------------------------------------------------------------
# select_strategy
# -----------------------------------------------------------------------------


def select_strategy(
    hint: UInt8,
    estimated_cardinality: Int,
    is_sorted: Bool,
) -> StrategyDecision:
    """Select an aggregation strategy from a hint and an estimate.

    Hint precedence:
      ForceThreadLocal      -> ResolvedStrategy::ThreadLocal       (S1)
      ForceGlobalConcurrent -> ResolvedStrategy::GlobalConcurrent  (S2)
      ForceSortBased        -> ResolvedStrategy::SortBased         (S3)
      Adaptive              -> rule-based:
        if is_sorted && est <= S3_SORTED_THRESHOLD     -> S3
        elif est > S1_THRESHOLD (10M)                  -> S2
        else                                           -> S1

    The S1 bucket is split by S1_PARTITIONED_THRESHOLD (see the strategy
    tags above).

    For S2: the CAS global path is not implemented; high-cardinality
    Adaptive routes to S1_PARTITIONED with a perf warning. Force hints
    bypass the deferral and return the requested tag verbatim.
    """
    if hint == AGG_HINT_FORCE_THREAD_LOCAL:
        if estimated_cardinality >= S1_PARTITIONED_THRESHOLD:
            return StrategyDecision(
                STRATEGY_S1_PARTITIONED, estimated_cardinality, is_sorted
            )
        return StrategyDecision(
            STRATEGY_S1_RADIX, estimated_cardinality, is_sorted
        )
    if hint == AGG_HINT_FORCE_GLOBAL_CONCURRENT:
        return StrategyDecision(
            STRATEGY_S2_CAS_GLOBAL, estimated_cardinality, is_sorted
        )
    if hint == AGG_HINT_FORCE_SORT_BASED:
        return StrategyDecision(
            STRATEGY_S3_STREAMING_SORT, estimated_cardinality, is_sorted
        )

    # Adaptive — `<=` for the S3 threshold.
    if is_sorted and estimated_cardinality <= S3_SORTED_THRESHOLD:
        return StrategyDecision(
            STRATEGY_S3_STREAMING_SORT, estimated_cardinality, is_sorted
        )
    if estimated_cardinality > S1_MAX_CARDINALITY:
        return StrategyDecision(
            STRATEGY_S1_PARTITIONED, estimated_cardinality, is_sorted
        )
    if estimated_cardinality >= S1_PARTITIONED_THRESHOLD:
        return StrategyDecision(
            STRATEGY_S1_PARTITIONED, estimated_cardinality, is_sorted
        )
    return StrategyDecision(
        STRATEGY_S1_RADIX, estimated_cardinality, is_sorted
    )


# -----------------------------------------------------------------------------
# select_optimal_strategy_type_only — the type-only strategy pass.
# -----------------------------------------------------------------------------


def select_optimal_strategy_type_only(
    key_types: List[ArrowType],
) -> AggStrategy:
    """Type-only key-strategy selection (no stats needed).

    Single-key with an inherently small type domain returns PerfectHash;
    multi-key or wider single-key returns Columnar. Caller invokes this at
    plan-compile time with the resolved group-by ArrowTypes.

    Stats-driven selection for Int32+ keys and the PerfectHashComposite
    path are not implemented here.
    """
    if len(key_types) == 0:
        return AggStrategy.ungrouped()

    if len(key_types) == 1:
        var dt = key_types[0]
        if dt == ArrowType.BOOL:
            return AggStrategy.perfect_hash(2, 0)
        if dt == ArrowType.INT8:
            return AggStrategy.perfect_hash(256, 128)
        if dt == ArrowType.UINT8:
            return AggStrategy.perfect_hash(256, 0)
        if dt == ArrowType.INT16:
            return AggStrategy.perfect_hash(65536, 32768)
        if dt == ArrowType.UINT16:
            return AggStrategy.perfect_hash(65536, 0)

    # Int32/Int64/UInt32/UInt64 would need stats; not implemented.
    return AggStrategy.columnar()
