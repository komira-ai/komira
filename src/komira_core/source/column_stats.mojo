# =============================================================================
# ColumnStats — per-column statistics for InMemorySource
# =============================================================================
#
# One ColumnStats per column of an in-memory relation, holding:
# per column of an in-memory relation, holding:
#
#   - min / max          : PrecisionScalar lattice (Exact when the full column
#                          was scanned; Absent for non-orderable types).
#   - null_count         : Int — exact (we scan the validity buffers).
#   - distinct_count     : PrecisionScalar (Int payload). EXACT when the true
#                          NDV is small enough to track via an exact hash-set;
#                          INEXACT when it exceeds the threshold and we fall
#                          back to the HyperLogLog estimate.
#   - sum                : PrecisionScalar — numeric columns only; Absent
#                          otherwise.
#   - avg_size_bytes     : Float64 — for variable-length columns (String) it's
#                          the mean byte length; for fixed-width it's the
#                          dtype's element size.
#   - hll                : Optional[ArcPointer[HyperLogLog]] — register state
#                          for the high-cardinality NDV estimate. Arc-shared so
#                          cache entries that share the same InMemorySource
#                          share the sketch (no byte-copy on ColumnStats.copy()).
#   - bloom              : Optional[ArcPointer[BloomFilter]] — a *static* SBBF
#                          over the column's distinct values, for IN-list
#                          pushdown. Built only when the column is a plausible
#                          IN-list target (NDV <= BLOOM_NDV_CAP); None
#                          otherwise. Reuses komira_core.collections.bloom_filter.
#
# HyperLogLog: dense-register port of DuckDB's third_party/hyperloglog
# (Redis/antirez algorithm, Otmar Ertl improved estimator — arXiv:1702.01284).
# Params: p = 12  ⇒  m = 4096 registers  ⇒  standard error ≈ 1.04/sqrt(m) ≈
# 1.6%. Q = 64 - p = 52 (max leading-zero run + 1). Registers are full bytes
# (not 6-bit packed) for simplicity — 4 KiB per sketch. We use a fast 64-bit
# multiplicative mix for fixed-width values and FNV-1a over bytes for strings;
# the SAME 64-bit hash feeds both the HLL (low p bits ⇒ register index; the
# rest ⇒ leading-zero count) and the SBBF bloom (upper 32 bits ⇒ block,
# lower 32 ⇒ probe positions).
#
# ColumnStats is `Movable, Copyable, Deinitable` (the IR-variant
# value-type discipline). The Arc-shared sharing happens at the InMemorySource
# field level (`Optional[ArcPointer[List[ColumnStats]]]`), NOT inside
# ColumnStats — but `copy()` does refcount-bump the HLL/Bloom Arcs, so cloning
# a ColumnStats is cheap.
#
# NESTED-TYPE ColumnStats: a `kind` tag is reserved (PRIMITIVE only
# implemented; LIST / STRUCT child-stats propagation is not implemented).
# =============================================================================

from std.memory import ArcPointer
from std.math import sqrt
from std.sys import simd_width_of, size_of
from std.bit import count_trailing_zeros

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema
from komira_core.arrow.varlen_width_guard import (
    carries_offsets,
    offset_width_bytes_or_raise,
)
from komira_core.collections.bloom_filter import BloomFilter
from komira_core.collections.slab import Slab
from komira_core.plan.precision_scalar import PrecisionScalar
from komira_core.plan.scalar_value import ScalarValue


# =============================================================================
# Tuning constants
# =============================================================================

# HyperLogLog precision. p = 12  ⇒  m = 2^12 = 4096 registers, ~1.6% std error
# (matches DuckDB's HLL_P). Q = 64 - p = 52.
comptime HLL_P: Int = 12
comptime HLL_REGISTERS: Int = 1 << HLL_P          # 4096
comptime HLL_P_MASK: UInt64 = UInt64(HLL_REGISTERS - 1)
comptime HLL_Q: Int = 64 - HLL_P                  # 52
comptime HLL_ALPHA_INF: Float64 = 0.7213475204444817  # 0.5 / ln(2)

# Exact-NDV tracking threshold. While a column's observed distinct count is
# <= this, we track it exactly via a hash-set; above it, distinct_count
# becomes INEXACT (HLL estimate). 4096 mirrors the HLL register count.
comptime EXACT_NDV_THRESHOLD: Int = 4096

# Bloom filter is built only for columns whose estimated NDV is at or below
# this cap — i.e. plausible IN-list pushdown targets. 64 K distinct @ 1% FPP
# ≈ 96 KiB. Above the cap we leave bloom = None.
comptime BLOOM_NDV_CAP: Int = 64 * 1024
comptime BLOOM_FPP: Float64 = 0.01

# High-card early-exit tuning. After observing at least
# `HIGH_CARD_FIRST_CHECK` non-null values AND every `1 << CHECK_BITS` rows
# thereafter, sample the exact-set's `len(set) / n_values` ratio: if it
# exceeds `HIGH_CARD_RATIO_PERCENT%`, flip `exact_overflowed = True` early
# and free the set. This avoids the per-cell `Dict[UInt64,Bool]` probe on
# genuinely high-cardinality columns where it never converges to ≤
# `EXACT_NDV_THRESHOLD` (a 4096-entry Dict probe per row costs ~30 ns;
# freeing the dict at row 8192 saves every remaining probe).
#
# Tuning rationale: 8192-row first-check matches Mojo's typical
# `MORSEL_BATCH` granularity and is large enough for the ratio sample to
# be statistically meaningful (>1024 distinct values @ 50% ratio); checking
# every 8192 rows = `len(set)` polling overhead amortizes to <1 ns / row.
# Ratio threshold = 50% = pick "this column will overflow the 4096 cap
# before scan completes" iff distinct already > rows/2. Below that, we
# pay the dict probe out — fine, low-card columns finish overflow naturally
# at <= 4096 distinct values.
comptime HIGH_CARD_FIRST_CHECK: Int = 8192
comptime HIGH_CARD_CHECK_BITS: Int = 13  # 1 << 13 = 8192
comptime HIGH_CARD_CHECK_MASK: Int = (1 << HIGH_CARD_CHECK_BITS) - 1
comptime HIGH_CARD_MIN_DISTINCT: Int = 1024
comptime HIGH_CARD_RATIO_PERCENT: Int = 50

# Bloom-disable polling: once we've seen enough rows for the HLL estimate
# to be reliable, poll it every `1 << BLOOM_DISABLE_CHECK_BITS` rows; if
# the estimate exceeds `BLOOM_NDV_CAP`, the bloom would be discarded at
# finalize anyway, so we stop inserting now and save the SBBF write cost
# on the remaining rows. Polling cadence kept coarser than HIGH_CARD's
# (every 65 K rows vs 8 K) because the HLL.count() cost (4096-register
# histogram) is non-trivial.
comptime BLOOM_DISABLE_FIRST_CHECK: Int = 65536
comptime BLOOM_DISABLE_CHECK_BITS: Int = 16  # 1 << 16 = 65536
comptime BLOOM_DISABLE_CHECK_MASK: Int = (1 << BLOOM_DISABLE_CHECK_BITS) - 1

# ColumnStats kind tag. PRIMITIVE implemented; LIST/STRUCT reserved.
comptime COLSTATS_KIND_PRIMITIVE: UInt8 = 0
comptime COLSTATS_KIND_LIST: UInt8 = 1
comptime COLSTATS_KIND_STRUCT: UInt8 = 2


# =============================================================================
# Hash helpers
# =============================================================================


@always_inline
def _mix64(x: UInt64) -> UInt64:
    """SplitMix64-style finalizer: a fast, well-distributed 64-bit mix for
    fixed-width integer / float-bit-pattern values. One multiply + xor-shift
    rounds — far cheaper than byte-wise FNV-1a for the per-cell hot loop, and
    good enough for both HLL register addressing and SBBF bloom probing."""
    var z = x + UInt64(0x9E3779B97F4A7C15)
    z = (z ^ (z >> 30)) * UInt64(0xBF58476D1CE4E5B9)
    z = (z ^ (z >> 27)) * UInt64(0x94D049BB133111EB)
    return z ^ (z >> 31)


@always_inline
def _mix64_simd[W: Int](x: SIMD[DType.uint64, W]) -> SIMD[DType.uint64, W]:
    """Lane-wise SplitMix64 finalizer — bit-identical to `_mix64` per lane.

    `_mix64` is a pure multiply / shift / xor chain with no data-dependent
    control flow, so it vectorizes cleanly: W adds, W shifts, W multiplies and
    W xors per stage become one SIMD op each. Used by the SIMD column-scan hot
    loop to hash W input values per iteration.
    """
    var z = x + SIMD[DType.uint64, W](0x9E3779B97F4A7C15)
    z = (z ^ (z >> 30)) * SIMD[DType.uint64, W](0xBF58476D1CE4E5B9)
    z = (z ^ (z >> 27)) * SIMD[DType.uint64, W](0x94D049BB133111EB)
    return z ^ (z >> 31)


# =============================================================================
# HyperLogLog (dense registers)
# =============================================================================


struct HyperLogLog(Movable):
    """Dense-register HyperLogLog cardinality sketch (p = 12, 4096 registers).

    Port of DuckDB's `third_party/hyperloglog` (Redis/antirez algorithm) with
    the Otmar Ertl improved estimator (arXiv:1702.01284). Registers are full
    bytes (not 6-bit packed) — 4 KiB per sketch, in a heap `Slab[UInt8]`.
    `Slab` is Movable-only, so this struct is Movable + an explicit `copy()`
    (NOT the `Copyable` trait); it lives behind an `ArcPointer` on ColumnStats
    so refcount-sharing — not byte-copy — is the cross-cache path anyway.

    API: `add(hash: UInt64)` — feed a pre-hashed value; `add_value(raw)` —
    mix-then-add for callers holding a raw value identity; `count() -> UInt64`
    — estimated distinct count; `merge(other)` — register-wise max merge.
    """

    var registers: Slab[UInt8]

    def __init__(out self):
        """Create an empty sketch (all 4096 registers zero)."""
        var sl = Slab[UInt8].create(HLL_REGISTERS)
        for _ in range(HLL_REGISTERS):
            sl.append(UInt8(0))
        self.registers = sl^

    def copy(self) -> Self:
        """Explicit deep copy of the register array."""
        var sl = Slab[UInt8].create(HLL_REGISTERS)
        for i in range(HLL_REGISTERS):
            sl.append(self.registers[i])
        var hll = HyperLogLog()
        hll.registers = sl^
        return hll^

    @always_inline
    def add(mut self, hash: UInt64):
        """Add a pre-hashed value. Low `p` bits select the register; the
        remaining `Q = 64 - p` bits are scanned for the leading-zero run
        (the terminating 1 is counted), capped at `Q + 1`. The register is
        bumped to the max of its current value and the run length."""
        var index = Int(hash & HLL_P_MASK)
        var rest = (hash >> UInt64(HLL_P)) | (UInt64(1) << UInt64(HLL_Q))
        var run: Int = 1
        var bit = UInt64(1)
        while (rest & bit) == UInt64(0):
            run += 1
            bit = bit << UInt64(1)
        if UInt8(run) > self.registers[index]:
            self.registers[index] = UInt8(run)

    @always_inline
    def add_value(mut self, raw: UInt64):
        """Mix `raw` (a value identity, e.g. an Int64 reinterpreted) then add."""
        self.add(_mix64(raw))

    @always_inline
    def add_bulk[W: Int](mut self, hashes: SIMD[DType.uint64, W]):
        """Add W pre-hashed values at once — register state is bit-identical to
        W successive `add()` calls (register-max is order-independent).

        SIMD-compute / scalar-scatter: the per-lane register index and
        rank computation vectorizes — register index is a single SIMD AND, the
        `rest` word is a SIMD shift + OR, and the leading-zero-run length is a
        SIMD `count_trailing_zeros` (LLVM lowers to `vpcttz` / a per-lane TZCNT)
        plus a SIMD add of 1. The scatter-max into the 4096-byte register slab
        is then a tight W-iteration scalar loop — Mojo exposes no SIMD scatter
        intrinsic with conflict resolution, and the index + rank compute (the
        bulk of the per-cell cost) already vectorized cleanly, so the scalar
        tail-scatter is the right shape.

        Note on `rest`: `(hash >> HLL_P) | (1 << HLL_Q)` always has bit `HLL_Q`
        set, so `count_trailing_zeros(rest)` is at most `HLL_Q` and the +1 gives
        a run length in `[1, HLL_Q + 1]` — no separate cap is needed (the scalar
        `add()` reaches the same bound by its terminating `1` bit), so the
        UInt8 cast never truncates.
        """
        var idx_vec = hashes & SIMD[DType.uint64, W](HLL_P_MASK)
        var rest_vec = (hashes >> SIMD[DType.uint64, W](UInt64(HLL_P))) | SIMD[
            DType.uint64, W
        ](UInt64(1) << UInt64(HLL_Q))
        var run_vec = count_trailing_zeros(rest_vec) + SIMD[DType.uint64, W](1)

        comptime for j in range(W):
            var ix = Int(idx_vec[j])
            var r = UInt8(run_vec[j])
            if r > self.registers[ix]:
                self.registers[ix] = r

    def merge(mut self, other: HyperLogLog):
        """Register-wise max merge of `other` into `self`."""
        for i in range(HLL_REGISTERS):
            if other.registers[i] > self.registers[i]:
                self.registers[i] = other.registers[i]

    def count(self) -> UInt64:
        """Estimated distinct count (Ertl estimator, arXiv:1702.01284).

        Build the register-value histogram, then
        `E = round(alpha_inf * m^2 / z)` where `z` mixes the histogram with
        the sigma/tau correction functions for the small / large extremes.
        """
        var m = Float64(HLL_REGISTERS)
        var reghisto = Slab[Int].create(HLL_Q + 2)
        for _ in range(HLL_Q + 2):
            reghisto.append(0)
        for i in range(HLL_REGISTERS):
            var v = Int(self.registers[i])
            if v > HLL_Q + 1:
                v = HLL_Q + 1
            reghisto[v] = reghisto[v] + 1

        var z = m * _hll_tau((m - Float64(reghisto[HLL_Q + 1])) / m)
        var j = HLL_Q
        while j >= 1:
            z += Float64(reghisto[j])
            z *= 0.5
            j -= 1
        z += m * _hll_sigma(Float64(reghisto[0]) / m)
        if z == 0.0:
            return UInt64(0)
        var e = HLL_ALPHA_INF * m * m / z
        if e < 0.0:
            return UInt64(0)
        return UInt64(e + 0.5)

    @staticmethod
    def relative_std_error() -> Float64:
        """Theoretical relative standard error: 1.04 / sqrt(m)."""
        return 1.04 / sqrt(Float64(HLL_REGISTERS))


# --- Ertl correction functions (mirror DuckDB hllSigma / hllTau) ---


def _hll_sigma(x_in: Float64) -> Float64:
    if x_in == 1.0:
        return 1e50  # +inf sentinel (matches DuckDB's INFINITY fallback)
    var x = x_in
    var y_acc = 1.0
    var z = x
    var z_prime = z + 1.0  # force first iteration
    while z_prime != z:
        x *= x
        z_prime = z
        z += x * y_acc
        y_acc += y_acc
    return z


def _hll_tau(x_in: Float64) -> Float64:
    if x_in == 0.0 or x_in == 1.0:
        return 0.0
    var x = x_in
    var y_acc = 1.0
    var z = 1.0 - x
    var z_prime = z + 1.0  # force first iteration
    while z_prime != z:
        x = sqrt(x)
        z_prime = z
        y_acc *= 0.5
        var t = 1.0 - x
        z -= t * t * y_acc
    return z / 3.0


# =============================================================================
# ColumnStats
# =============================================================================


struct ColumnStats(Movable, Copyable, Deinitable):
    """Per-column statistics for an in-memory relation. See module header.

    Construct via `compute_column_stats(batches, schema)` (the lazy-compute
    entry point) or the `null_only(...)` factory.
    """

    var kind: UInt8                       # COLSTATS_KIND_* (PRIMITIVE impl)
    var min: PrecisionScalar
    var max: PrecisionScalar
    var null_count: Int                   # exact
    var distinct_count: PrecisionScalar   # Int payload; Exact iff true NDV small
    var sum: PrecisionScalar              # numeric only; Absent otherwise
    var avg_size_bytes: Float64
    var hll: Optional[ArcPointer[HyperLogLog]]
    var bloom: Optional[ArcPointer[BloomFilter]]

    def __init__(
        out self,
        kind: UInt8,
        var min: PrecisionScalar,
        var max: PrecisionScalar,
        null_count: Int,
        var distinct_count: PrecisionScalar,
        var sum: PrecisionScalar,
        avg_size_bytes: Float64,
        var hll: Optional[ArcPointer[HyperLogLog]],
        var bloom: Optional[ArcPointer[BloomFilter]],
    ):
        self.kind = kind
        self.min = min^
        self.max = max^
        self.null_count = null_count
        self.distinct_count = distinct_count^
        self.sum = sum^
        self.avg_size_bytes = avg_size_bytes
        self.hll = hll^
        self.bloom = bloom^

    def copy(self) -> Self:
        """Explicit copy. PrecisionScalar fields deep-copy their inner
        ScalarValue; the HLL/Bloom Arcs are refcount-bumped (no byte-copy) —
        `Optional[ArcPointer[T]].copy()` is an Optional-of-Arc refcount bump.
        """
        var hll_copy = self.hll.copy()
        var bloom_copy = self.bloom.copy()
        return ColumnStats(
            self.kind,
            self.min.copy(),
            self.max.copy(),
            self.null_count,
            self.distinct_count.copy(),
            self.sum.copy(),
            self.avg_size_bytes,
            hll_copy^,
            bloom_copy^,
        )

    @staticmethod
    def null_only(null_count: Int, avg_size_bytes: Float64) -> ColumnStats:
        """Stats for a column whose type doesn't support min/max/sum/NDV.
        null_count is exact; everything else Absent."""
        var none_hll: Optional[ArcPointer[HyperLogLog]] = None
        var none_bloom: Optional[ArcPointer[BloomFilter]] = None
        return ColumnStats(
            COLSTATS_KIND_PRIMITIVE,
            PrecisionScalar.absent(),
            PrecisionScalar.absent(),
            null_count,
            PrecisionScalar.absent(),
            PrecisionScalar.absent(),
            avg_size_bytes,
            none_hll^,
            none_bloom^,
        )

    def fingerprint(self) -> UInt64:
        """Stable hash of the *summary* fields (min/max/null/NDV/sum/avg).

        Folds into the resolved-cache `stats_hash`. Does NOT
        include the HLL register state or bloom bits — those are derived
        from the same data the summary fields summarize.
        """
        var h = UInt64(0xCBF29CE484222325)
        comptime prime = UInt64(0x00000100000001B3)
        h = (h ^ UInt64(self.kind)) * prime
        h = (h ^ UInt64(self.null_count)) * prime
        h = (h ^ UInt64(self.min.tag)) * prime
        h = (h ^ UInt64(self.max.tag)) * prime
        h = (h ^ UInt64(self.distinct_count.tag)) * prime
        h = (h ^ UInt64(self.sum.tag)) * prime
        if self.distinct_count.is_present():
            h = (h ^ UInt64(self.distinct_count.value.value().int_val)) * prime
        h = (h ^ UInt64(Int(self.avg_size_bytes * 1000.0))) * prime
        return h


# =============================================================================
# Per-column accumulator (internal to compute_column_stats)
# =============================================================================


comptime _ACC_KIND_NONE: UInt8 = 0
comptime _ACC_KIND_INT: UInt8 = 1     # signed/unsigned int, date32, timestamp
comptime _ACC_KIND_FLOAT: UInt8 = 2
comptime _ACC_KIND_BOOL: UInt8 = 3
comptime _ACC_KIND_STRING: UInt8 = 4


struct _ColAccum(Movable):
    """Mutable single-column accumulator threaded through the batch loop."""

    var arrow_type: ArrowType
    var acc_kind: UInt8
    var seen_value: Bool
    var null_count: Int
    var total_len_bytes: Int            # sum of element byte sizes (for avg)
    var n_values: Int                   # non-null value count
    # numeric (int representation):
    var min_i: Int64
    var max_i: Int64
    var sum_i: Int64
    # numeric (float representation):
    var min_f: Float64
    var max_f: Float64
    var sum_f: Float64
    # string min/max:
    var min_s: String
    var max_s: String
    # NDV:
    var hll: HyperLogLog
    var exact_set: Dict[UInt64, Bool]
    var exact_overflowed: Bool
    # bloom (active while NDV plausibly small):
    var bloom: BloomFilter
    var bloom_active: Bool

    def __init__(out self, arrow_type: ArrowType, est_rows: Int):
        self.arrow_type = arrow_type
        if arrow_type == ArrowType.BOOL:
            self.acc_kind = _ACC_KIND_BOOL
        elif arrow_type == ArrowType.STRING or arrow_type == ArrowType.LARGE_STRING:
            self.acc_kind = _ACC_KIND_STRING
        elif arrow_type == ArrowType.FLOAT32 or arrow_type == ArrowType.FLOAT64:
            self.acc_kind = _ACC_KIND_FLOAT
        elif (
            arrow_type.is_integer()
            or arrow_type == ArrowType.DATE32
            or arrow_type == ArrowType.DATE64
            or arrow_type == ArrowType.TIMESTAMP
            or arrow_type == ArrowType.TIMESTAMP_S
            or arrow_type == ArrowType.TIMESTAMP_MS
            or arrow_type == ArrowType.TIMESTAMP_US
            or arrow_type == ArrowType.TIMESTAMP_NS
        ):
            self.acc_kind = _ACC_KIND_INT
        else:
            self.acc_kind = _ACC_KIND_NONE
        self.seen_value = False
        self.null_count = 0
        self.total_len_bytes = 0
        self.n_values = 0
        self.min_i = Int64.MAX
        self.max_i = Int64.MIN
        self.sum_i = 0
        self.min_f = Float64.MAX_FINITE
        self.max_f = Float64.MIN_FINITE
        self.sum_f = 0.0
        self.min_s = String("")
        self.max_s = String("")
        self.hll = HyperLogLog()
        self.exact_set = Dict[UInt64, Bool]()
        self.exact_overflowed = False
        var bloom_ndv = est_rows
        if bloom_ndv > BLOOM_NDV_CAP:
            bloom_ndv = BLOOM_NDV_CAP
        if bloom_ndv < 1:
            bloom_ndv = 1
        self.bloom = BloomFilter.with_ndv_fpp(bloom_ndv, BLOOM_FPP)
        self.bloom_active = True

    @always_inline
    def note_hash(mut self, h: UInt64):
        """Feed a value hash into the HLL, the exact set (until overflow),
        and the bloom (while active).

        High-cardinality early-exit: after every
        `1 << HIGH_CARD_CHECK_BITS` rows (starting at
        `HIGH_CARD_FIRST_CHECK`), sample the distinct/n_values ratio on
        the exact-set side. If it exceeds `HIGH_CARD_RATIO_PERCENT`, flip
        `exact_overflowed = True` early — the column is clearly going to
        blow past the 4096-distinct threshold anyway, and the per-cell
        Dict[UInt64,Bool] probe is pure overhead at that point. The HLL
        register update is cheap (one mul + xor-shift + one register
        write), so we keep feeding it.

        Bloom independence: bloom_active is NOT flipped here — bloom is
        useful at NDVs up to `BLOOM_NDV_CAP` (64K), which is well above
        `EXACT_NDV_THRESHOLD` (4K). We flip bloom_active off only when
        the HLL projects NDV > `BLOOM_NDV_CAP`, evaluated at the same
        sample check.
        """
        self.hll.add(h)
        if not self.exact_overflowed:
            self.exact_set[h] = True
            if len(self.exact_set) > EXACT_NDV_THRESHOLD:
                self.exact_overflowed = True
                self.exact_set = Dict[UInt64, Bool]()  # free it; HLL takes over
            elif (
                self.n_values >= HIGH_CARD_FIRST_CHECK
                and (self.n_values & HIGH_CARD_CHECK_MASK) == 0
            ):
                # Sample the distinct-rate. If we've already seen
                # HIGH_CARD_MIN_DISTINCT distinct values, AND the rate
                # (distinct / rows-seen) is above HIGH_CARD_RATIO_PERCENT,
                # the column will exceed EXACT_NDV_THRESHOLD before the
                # rest of the scan finishes. Skip the dict probe ahead.
                var distinct_so_far = len(self.exact_set)
                if (
                    distinct_so_far >= HIGH_CARD_MIN_DISTINCT
                    and distinct_so_far * 100
                    > self.n_values * HIGH_CARD_RATIO_PERCENT
                ):
                    self.exact_overflowed = True
                    self.exact_set = Dict[UInt64, Bool]()
        # Bloom decision: a separate, independent check. We disable the
        # bloom feed when (a) we've collected enough rows for a reliable
        # HLL estimate AND (b) that estimate already exceeds BLOOM_NDV_CAP
        # — in which case _finalize_accum will drop the bloom anyway, so
        # there's no point continuing to insert into it.
        if self.bloom_active:
            if (
                self.n_values >= BLOOM_DISABLE_FIRST_CHECK
                and (self.n_values & BLOOM_DISABLE_CHECK_MASK) == 0
            ):
                # HLL.count is O(m) = O(4096); cheap to poll at this cadence.
                var est = Int(self.hll.count())
                if est > BLOOM_NDV_CAP:
                    self.bloom_active = False
            if self.bloom_active:
                self.bloom.insert_hash(h)

    @always_inline
    def feed_hashes_simd_block[
        W: Int
    ](mut self, h_vec: SIMD[DType.uint64, W], n_values_before: Int):
        """Feed W pre-computed value hashes — bit-identical net state to W
        successive `note_hash()` calls (vectorized feed).

        The HLL register update is done in one `add_bulk[W]` (SIMD-compute /
        scalar-scatter); the exact-set and bloom sides are per-lane scalar loops
        — `Dict[UInt64, Bool]` insert and the SBBF block OR-back have no SIMD
        batch form (random scatter destinations). When the column has already
        overflowed the exact set AND disabled the bloom (the common
        high-cardinality steady state), both scalar loops are skipped entirely
        and the only per-cell cost is the vectorized hash + register update.

        Preconditions: `self.n_values` has ALREADY been advanced past this block
        (i.e. equals `n_values_before + W`) and `seen_value` is set.

        The exact-set sample check fires the same way as `note_hash`: in the
        scalar path it triggers at `n_values` ∈ {8192, 16384, ...}; here it
        triggers iff the block crosses one of those boundaries and the running
        `n_values` is at or past `HIGH_CARD_FIRST_CHECK`. The bloom-disable poll
        is the same boundary-cross test against `BLOOM_DISABLE_*`. (Both are
        cadence heuristics, not stat-determining: the exact-vs-inexact decision
        is driven by the natural `len(exact_set) > EXACT_NDV_THRESHOLD` check,
        which the per-lane loop below performs after the full block — and since
        an over-threshold set is discarded and replaced by the HLL estimate, the
        ≤ W-1 difference in *when* the overflow is observed is unobservable in
        the finalized stats.)
        """
        self.hll.add_bulk[W](h_vec)

        if not self.exact_overflowed:

            comptime for j in range(W):
                self.exact_set[h_vec[j]] = True
            if len(self.exact_set) > EXACT_NDV_THRESHOLD:
                self.exact_overflowed = True
                self.exact_set = Dict[UInt64, Bool]()
            else:
                # Boundary-cross sample check (mirrors note_hash's
                # `n_values & HIGH_CARD_CHECK_MASK == 0` per-row trigger).
                var crossed_check = (
                    self.n_values >= HIGH_CARD_FIRST_CHECK
                    and (n_values_before >> HIGH_CARD_CHECK_BITS)
                    != (self.n_values >> HIGH_CARD_CHECK_BITS)
                )
                if crossed_check:
                    var distinct_so_far = len(self.exact_set)
                    if (
                        distinct_so_far >= HIGH_CARD_MIN_DISTINCT
                        and distinct_so_far * 100
                        > self.n_values * HIGH_CARD_RATIO_PERCENT
                    ):
                        self.exact_overflowed = True
                        self.exact_set = Dict[UInt64, Bool]()

        if self.bloom_active:
            var crossed_disable = (
                self.n_values >= BLOOM_DISABLE_FIRST_CHECK
                and (n_values_before >> BLOOM_DISABLE_CHECK_BITS)
                != (self.n_values >> BLOOM_DISABLE_CHECK_BITS)
            )
            if crossed_disable:
                var est = Int(self.hll.count())
                if est > BLOOM_NDV_CAP:
                    self.bloom_active = False
            if self.bloom_active:

                comptime for j in range(W):
                    self.bloom.insert_hash(h_vec[j])

    @always_inline
    def note_int(mut self, v: Int64):
        self.seen_value = True
        self.n_values += 1
        if v < self.min_i:
            self.min_i = v
        if v > self.max_i:
            self.max_i = v
        self.sum_i += v
        self.note_hash(_mix64(UInt64(v)))

    @always_inline
    def note_float(mut self, v: Float64):
        self.seen_value = True
        self.n_values += 1
        if v < self.min_f:
            self.min_f = v
        if v > self.max_f:
            self.max_f = v
        self.sum_f += v
        # Hash the float by its IEEE-754 bit pattern.
        self.note_hash(_mix64(UInt64(v.to_bits())))

    @always_inline
    def note_bool(mut self, v: Bool):
        self.seen_value = True
        self.n_values += 1
        var iv: Int64 = 1 if v else 0
        if iv < self.min_i:
            self.min_i = iv
        if iv > self.max_i:
            self.max_i = iv
        self.note_hash(_mix64(UInt64(iv)))

    def note_string(mut self, s: String):
        self.n_values += 1
        var bs = s.as_bytes()
        var nbytes = len(bs)
        self.total_len_bytes += nbytes
        # FNV-1a over the UTF-8 bytes.
        var h = UInt64(0xCBF29CE484222325)
        comptime prime = UInt64(0x00000100000001B3)
        for i in range(nbytes):
            h = (h ^ UInt64(bs[i])) * prime
        self.note_hash(h)
        if not self.seen_value:
            self.seen_value = True
            self.min_s = s.copy()
            self.max_s = s.copy()
        else:
            if s < self.min_s:
                self.min_s = s.copy()
            if s > self.max_s:
                self.max_s = s.copy()


# =============================================================================
# Finalization
# =============================================================================


def _finalize_accum(mut acc: _ColAccum) -> ColumnStats:
    """Build the ColumnStats from a fully-populated accumulator."""
    # null_count is exact regardless.
    var null_count = acc.null_count

    # avg_size_bytes.
    var avg_size: Float64
    if acc.acc_kind == _ACC_KIND_STRING:
        avg_size = (Float64(acc.total_len_bytes) / Float64(acc.n_values)) if acc.n_values > 0 else 0.0
    else:
        avg_size = Float64(_fixed_width_bytes(acc.arrow_type))

    # No values at all (all-null or empty) ⇒ min/max/sum Absent, NDV exact 0.
    if not acc.seen_value:
        var zero_ndv = PrecisionScalar.exact(ScalarValue.from_int(0))
        var none_hll: Optional[ArcPointer[HyperLogLog]] = None
        var none_bloom: Optional[ArcPointer[BloomFilter]] = None
        return ColumnStats(
            COLSTATS_KIND_PRIMITIVE,
            PrecisionScalar.absent(),
            PrecisionScalar.absent(),
            null_count,
            zero_ndv^,
            PrecisionScalar.absent(),
            avg_size,
            none_hll^,
            none_bloom^,
        )

    # min / max / sum.
    var min_ps: PrecisionScalar
    var max_ps: PrecisionScalar
    var sum_ps: PrecisionScalar
    if acc.acc_kind == _ACC_KIND_INT or acc.acc_kind == _ACC_KIND_BOOL:
        min_ps = PrecisionScalar.exact(ScalarValue.from_int64(acc.min_i))
        max_ps = PrecisionScalar.exact(ScalarValue.from_int64(acc.max_i))
        if acc.acc_kind == _ACC_KIND_INT:
            sum_ps = PrecisionScalar.exact(ScalarValue.from_int64(acc.sum_i))
        else:
            sum_ps = PrecisionScalar.absent()  # sum over booleans not meaningful
    elif acc.acc_kind == _ACC_KIND_FLOAT:
        min_ps = PrecisionScalar.exact(ScalarValue.from_float(acc.min_f))
        max_ps = PrecisionScalar.exact(ScalarValue.from_float(acc.max_f))
        sum_ps = PrecisionScalar.exact(ScalarValue.from_float(acc.sum_f))
    elif acc.acc_kind == _ACC_KIND_STRING:
        min_ps = PrecisionScalar.exact(ScalarValue.from_string(acc.min_s.copy()))
        max_ps = PrecisionScalar.exact(ScalarValue.from_string(acc.max_s.copy()))
        sum_ps = PrecisionScalar.absent()
    else:
        min_ps = PrecisionScalar.absent()
        max_ps = PrecisionScalar.absent()
        sum_ps = PrecisionScalar.absent()

    # distinct_count + HLL/Bloom Arc.
    var ndv_ps: PrecisionScalar
    var hll_arc: Optional[ArcPointer[HyperLogLog]]
    var bloom_arc: Optional[ArcPointer[BloomFilter]]
    if not acc.exact_overflowed:
        # Exact NDV from the small set.
        var exact_n = len(acc.exact_set)
        ndv_ps = PrecisionScalar.exact(ScalarValue.from_int(exact_n))
        # Still keep the HLL Arc (cheap, harmless) and the bloom (it's small).
        hll_arc = Optional(ArcPointer[HyperLogLog](acc.hll.copy()))
        bloom_arc = Optional(ArcPointer[BloomFilter](acc.bloom.copy()))
    else:
        var est = Int(acc.hll.count())
        ndv_ps = PrecisionScalar.inexact(ScalarValue.from_int(est))
        hll_arc = Optional(ArcPointer[HyperLogLog](acc.hll.copy()))
        # Discard the bloom if the column turned out high-cardinality.
        if est > BLOOM_NDV_CAP:
            bloom_arc = None
        else:
            bloom_arc = Optional(ArcPointer[BloomFilter](acc.bloom.copy()))

    return ColumnStats(
        COLSTATS_KIND_PRIMITIVE,
        min_ps^,
        max_ps^,
        null_count,
        ndv_ps^,
        sum_ps^,
        avg_size,
        hll_arc^,
        bloom_arc^,
    )


def _fixed_width_bytes(at: ArrowType) -> Int:
    """Element byte size for a fixed-width arrow type; 0 if variable-length."""
    if at == ArrowType.INT8 or at == ArrowType.UINT8 or at == ArrowType.BOOL:
        return 1
    if at == ArrowType.INT16 or at == ArrowType.UINT16:
        return 2
    if (
        at == ArrowType.INT32
        or at == ArrowType.UINT32
        or at == ArrowType.FLOAT32
        or at == ArrowType.DATE32
    ):
        return 4
    if (
        at == ArrowType.INT64
        or at == ArrowType.UINT64
        or at == ArrowType.FLOAT64
        or at == ArrowType.TIMESTAMP
        or at == ArrowType.TIMESTAMP_S
        or at == ArrowType.TIMESTAMP_MS
        or at == ArrowType.TIMESTAMP_US
        or at == ArrowType.TIMESTAMP_NS
    ):
        return 8
    if at == ArrowType.DECIMAL128:
        return 16
    return 0


# =============================================================================
# compute_column_stats — the lazy-compute entry point
# =============================================================================


def compute_column_stats(
    batches: Slab[RecordBatch], schema: Schema
) raises -> List[ColumnStats]:
    """Single pass over `batches`, producing one ColumnStats per column.

    Per-column dispatch on the schema's arrow type:
      - signed/unsigned int, date32, timestamp[*] : min/max/sum (as Int64),
        null_count, NDV, bloom (if low-card), avg_size = dtype size.
      - float32/64                                : min/max/sum (as Float64).
      - boolean                                   : min/max as 0/1, NDV (≤2),
        avg_size = 1.
      - string / large_string                     : min/max (lexicographic),
        null_count, NDV over byte hashes, avg_size = mean byte length.
      - everything else (binary, dictionary, ...) : null_count only; min/max/
        sum/NDV Absent.

    Args:
        batches: The relation's RecordBatches (read-only; not consumed).
        schema: The structural schema.

    Returns:
        A `List[ColumnStats]` of length `schema.num_columns()`.
    """
    var ncols = schema.num_columns()
    var est_rows = 0
    for i in range(len(batches)):
        est_rows += batches[i]._num_rows

    # `Slab` (Movable container) — `_ColAccum` is Movable-only (heap fields),
    # so a `List` (which requires `T: Copyable`) won't hold it.
    var accums = Slab[_ColAccum].create(max(ncols, 1))
    for c in range(ncols):
        accums.append(_ColAccum(schema.field_arrow_type(c), est_rows))

    for bi in range(len(batches)):
        ref batch = batches[bi]
        var nrows = batch._num_rows
        if nrows == 0:
            continue
        for c in range(ncols):
            var ak = accums[c].acc_kind
            var at = accums[c].arrow_type
            if ak == _ACC_KIND_INT:
                _scan_int_column(accums[c], batch.column_at(c), at, nrows)
            elif ak == _ACC_KIND_FLOAT:
                _scan_float_column(accums[c], batch.column_at(c), at, nrows)
            elif ak == _ACC_KIND_BOOL:
                _scan_bool_column(accums[c], batch.column_at(c), nrows)
            elif ak == _ACC_KIND_STRING:
                _scan_string_column(accums[c], batch.column_at(c), nrows)
            else:
                var ncol_nulls = batch.column_at(c).null_count()
                accums[c].null_count += ncol_nulls
                accums[c].n_values += (nrows - ncol_nulls)

    var out = List[ColumnStats]()
    for c in range(ncols):
        out.append(_finalize_accum(accums[c]))
    return out^


# --- per-(column, batch) scanners. `col` is the type-erased Column (borrowed
#     ref — `Column` is Movable-only so it cannot be passed by value). ---
#
# ZERO-COPY: the scanners read directly from `col._data` /
# `col._validity` / `col._offsets` (MmapAlignedBuffer.get_typed for primitives,
# Bitmap.test for validity, MmapAlignedBuffer.read_u8_at for raw bytes). They
# never invoke `as_primitive` / `as_string` / `as_boolean`, which would COPY
# the buffers into a freshly-allocated typed array (hundreds of MB of memcpy
# for a wide multi-million-row table). The single-underscore prefix on
# Column's internal fields is the module-internal convention — other
# perf-critical kernels (partition scan, perfect-hash aggregation, top-N
# rank helpers) also read these fields directly.


@always_inline
def _col_is_null(col: Column, i: Int) -> Bool:
    """Null check on a Column slot (offset-aware, non-raising). No validity
    bitmap means no nulls (Arrow's fast path)."""
    if not col._validity:
        return False
    # SAFETY: validity bitmap is index-by-element-position; col._offset
    # is the slot offset for sliced columns.
    return not col._validity.value().test(col._offset + i)


def _scan_primitive_int_zero_copy[dtype: DType](
    mut acc: _ColAccum, col: Column, nrows: Int
):
    """Scan an integer-valued column directly from `col._data` — no copy.

    The no-validity path (the common case for stats columns) goes through the
    SIMD kernel `_scan_int_simd_no_validity` — W values per iteration, lane-wise
    min/max/sum + lane-wise `_mix64` hash + bulk HLL register update.
    The validity path stays scalar (per-row Bitmap.test gating) and feeds via
    `acc.note_int`.
    """
    var has_validity = col._validity.__bool__()
    var off = col._offset
    if not has_validity:
        _scan_int_simd_no_validity[dtype](acc, col, nrows)
    else:
        ref vbm = col._validity.value()
        for i in range(nrows):
            if not vbm.test(off + i):
                acc.null_count += 1
            else:
                acc.note_int(
                    Int64(Int(col._data.get_typed[Scalar[dtype]](off + i)))
                )


def _scan_int_simd_no_validity[dtype: DType](
    mut acc: _ColAccum, col: Column, nrows: Int
):
    """SIMD column scan for a null-free integer column (vectorized feed).

    Per W-lane iteration (W = native int64 lane count, 4 on AVX2 / 8 on
    AVX-512):
      - load W `dtype` values from `col._data` and widen to `SIMD[int64, W]`;
      - lane-wise min / max / sum reduction (branchless `select`) —
        the SIMD accumulators are seeded from the running `acc.min_i/max_i` and
        reduced back after the loop;
      - lane-wise `_mix64` hash on the int64 bit-pattern, then a single
        `HyperLogLog.add_bulk[W]` (SIMD index/rank compute, scalar scatter-max)
        and `_ColAccum.feed_hashes_simd_block[W]` for the exact-set / bloom side
        (per-lane scalar — those have no SIMD batch form — but skipped wholesale
        once the column has overflowed the exact set and disabled the bloom).
    The `nrows % W` tail is handled by the scalar `acc.note_int` path so the
    feed-order semantics match exactly.

    Bit-identical net state to W successive `note_int` calls: the lane-wise hash
    is the same algebraic form as `_mix64` (verified by a property test),
    register-max is order-independent, and
    min/max/sum are commutative reductions.
    """
    if nrows == 0:
        return
    var off = col._offset
    acc.seen_value = True

    comptime W: Int = simd_width_of[DType.int64]()
    comptime ELEM_BYTES: Int = size_of[Scalar[dtype]]()
    var simd_end = (nrows // W) * W

    # SIMD min/max/sum accumulators, seeded from the running accumulator state.
    var min_vec = SIMD[DType.int64, W](acc.min_i)
    var max_vec = SIMD[DType.int64, W](acc.max_i)
    var sum_vec = SIMD[DType.int64, W](0)

    var i = 0
    while i < simd_end:
        # Load W lanes of `dtype` (byte offset = element-index * elem size),
        # widen to int64 (sign-extends signed lanes, zero-extends unsigned).
        var raw = col._data.load_simd[dtype, W]((off + i) * ELEM_BYTES)
        var v64 = raw.cast[DType.int64]()

        min_vec = (v64.lt(min_vec)).select(v64, min_vec)
        max_vec = (v64.gt(max_vec)).select(v64, max_vec)
        sum_vec += v64

        # Hash the int64 bit-pattern (matches scalar `_mix64(UInt64(v))`).
        var h_vec = _mix64_simd[W](v64.cast[DType.uint64]())

        var n_before = acc.n_values
        acc.n_values += W
        acc.feed_hashes_simd_block[W](h_vec, n_before)
        i += W

    # Fold the SIMD accumulators back into the scalar accumulator.
    acc.min_i = min_vec.reduce_min()
    acc.max_i = max_vec.reduce_max()
    acc.sum_i += sum_vec.reduce_add()

    # Scalar tail (< W rows) — use the row-at-a-time path for exact parity.
    while i < nrows:
        acc.note_int(Int64(Int(col._data.get_typed[Scalar[dtype]](off + i))))
        i += 1


def _scan_primitive_float_zero_copy[dtype: DType](
    mut acc: _ColAccum, col: Column, nrows: Int
):
    """Scan a float-valued column directly from `col._data` — no copy.
    Promotes each non-null value to Float64 and feeds the accumulator.
    """
    var has_validity = col._validity.__bool__()
    var off = col._offset
    if not has_validity:
        for i in range(nrows):
            acc.note_float(
                Float64(col._data.get_typed[Scalar[dtype]](off + i))
            )
    else:
        ref vbm = col._validity.value()
        for i in range(nrows):
            if not vbm.test(off + i):
                acc.null_count += 1
            else:
                acc.note_float(
                    Float64(col._data.get_typed[Scalar[dtype]](off + i))
                )


def _scan_int_column(mut acc: _ColAccum, col: Column, at: ArrowType, nrows: Int) raises:
    if at == ArrowType.INT8:
        _scan_primitive_int_zero_copy[DType.int8](acc, col, nrows)
    elif at == ArrowType.INT16:
        _scan_primitive_int_zero_copy[DType.int16](acc, col, nrows)
    elif at == ArrowType.INT32 or at == ArrowType.DATE32:
        _scan_primitive_int_zero_copy[DType.int32](acc, col, nrows)
    elif (
        at == ArrowType.INT64
        or at == ArrowType.TIMESTAMP
        or at == ArrowType.TIMESTAMP_S
        or at == ArrowType.TIMESTAMP_MS
        or at == ArrowType.TIMESTAMP_US
        or at == ArrowType.TIMESTAMP_NS
    ):
        _scan_primitive_int_zero_copy[DType.int64](acc, col, nrows)
    elif at == ArrowType.UINT8:
        _scan_primitive_int_zero_copy[DType.uint8](acc, col, nrows)
    elif at == ArrowType.UINT16:
        _scan_primitive_int_zero_copy[DType.uint16](acc, col, nrows)
    elif at == ArrowType.UINT32:
        _scan_primitive_int_zero_copy[DType.uint32](acc, col, nrows)
    elif at == ArrowType.UINT64:
        # UInt64 values exceeding Int64.MAX wrap on promotion; acceptable for
        # stats (typical OLAP columns are well within range).
        _scan_primitive_int_zero_copy[DType.uint64](acc, col, nrows)
    else:
        acc.null_count += col.null_count()
        acc.n_values += (nrows - col.null_count())


def _scan_float_column(mut acc: _ColAccum, col: Column, at: ArrowType, nrows: Int) raises:
    if at == ArrowType.FLOAT32:
        _scan_primitive_float_zero_copy[DType.float32](acc, col, nrows)
    elif at == ArrowType.FLOAT64:
        _scan_primitive_float_zero_copy[DType.float64](acc, col, nrows)
    else:  # FLOAT16 — not handled; count nulls only.
        acc.null_count += col.null_count()
        acc.n_values += (nrows - col.null_count())


def _scan_bool_column(mut acc: _ColAccum, col: Column, nrows: Int) raises:
    """Scan a boolean column zero-copy: read packed bits from `col._data`
    (a Bitmap stored as bytes) and validity from `col._validity`. No
    BooleanArray copy."""
    # The Column's `_data` for BOOL stores the packed value bits (one bit
    # per element); validity is the standard separate bitmap. Both share
    # the same byte-offset access pattern.
    var has_validity = col._validity.__bool__()
    var off = col._offset
    for i in range(nrows):
        if has_validity:
            ref vbm = col._validity.value()
            if not vbm.test(off + i):
                acc.null_count += 1
                continue
        # Read the value bit directly from col._data. Same encoding as
        # Bitmap.test: byte = (off + i) >> 3, bit = (off + i) & 7.
        var pos = off + i
        var byte_idx = pos >> 3
        var bit_idx = pos & 7
        var b = col._data.read_u8_at(byte_idx)
        var v = ((b >> UInt8(bit_idx)) & UInt8(1)) == UInt8(1)
        acc.note_bool(v)


def _scan_string_column(mut acc: _ColAccum, col: Column, nrows: Int) raises:
    """Scan a string column zero-copy, dispatching on the offsets width.

    `_ColAccum.__init__` tags BOTH STRING and LARGE_STRING as
    `_ACC_KIND_STRING`, and the two layouts differ in offsets width (Int32 vs
    Int64). `get_typed` is ELEMENT-indexed, so reading an Int64 buffer with
    `get_typed[Int32]` would return low32(O[k/2]) for even k and
    high32(O[k/2]) for odd k — wrong min/max/NDV/avg_size feeding the
    OPTIMIZER, and from row index 2 onward a NEGATIVE `nbytes` that reaches
    `List[UInt8](capacity=nbytes + 1)` in `_string_from_col`. The width is
    therefore dispatched on.

    ⚠ THE SCHEMA FIELD AND THE COLUMN CAN DISAGREE, AND THIS FUNCTION IS
    REACHED BY THE DISAGREEMENT. `acc_kind` was decided from
    `schema.field_arrow_type(c)` (`compute_column_stats`), while the width
    below must come from `col.arrow_type` — it is the COLUMN's buffer that is
    about to be strided, and only the column knows how wide its entries are.
    A DICTIONARY column under a declared STRING / LARGE_STRING field lands
    here with a NON-NULL `_offsets` (its dict-VALUE offsets), so the early-out
    above does not catch it, and `carries_offsets(DICTIONARY)` is False.

    That case takes the degraded arm below and MUST NOT RAISE. This path runs
    inside `InMemorySource.get_column_stats` during OPTIMIZATION: raising
    fails the whole query. The degraded arm is byte-for-byte what
    `compute_column_stats` does for a column whose type it has no scanner
    for — exact null/value counts, no min/max, NDV exact 0 (via
    `seen_value == False`) — which is also precisely the stats this same
    DICTIONARY column receives when its schema field is honest about being a
    DICTIONARY. So the disagreement costs the same as agreement, instead of
    costing garbage.
    """
    if not col._offsets:
        # No offsets buffer => no values to scan.
        return
    if not carries_offsets(col.arrow_type):
        # Degraded arm — see the docstring. Mirrors the `else` arm of
        # `compute_column_stats`'s per-column dispatch exactly.
        var ncol_nulls = col.null_count()
        acc.null_count += ncol_nulls
        acc.n_values += (nrows - ncol_nulls)
        return
    var ow = offset_width_bytes_or_raise(
        "column_stats(_scan_string_column)", col.arrow_type
    )
    if ow == 8:
        _scan_string_column_w[DType.int64](acc, col, nrows)
    else:
        _scan_string_column_w[DType.int32](acc, col, nrows)


def _scan_string_column_w[
    OffsetType: DType
](mut acc: _ColAccum, col: Column, nrows: Int) raises:
    """Width-parameterized body of `_scan_string_column`. ONE body serves the
    Int32 (STRING) and Int64 (LARGE_STRING) offset layouts.

    The min/max strings still need owned `String` values (PrecisionScalar
    holds a ScalarValue with owned bytes), so a String IS constructed when
    a new min or max is discovered — but only for those branches, not for
    every row (a string column with N distinct values produces O(N)
    String allocations for min/max tracking, vs O(nrows) for the
    `as_string` path).
    """
    var has_validity = col._validity.__bool__()
    var off = col._offset
    ref offsets_buf = col._offsets.value()
    for i in range(nrows):
        if has_validity:
            ref vbm = col._validity.value()
            if not vbm.test(off + i):
                acc.null_count += 1
                continue
        # Offset range for string at logical index `off + i`.
        var start = Int(offsets_buf.get_typed[Scalar[OffsetType]](off + i))
        var end = Int(offsets_buf.get_typed[Scalar[OffsetType]](off + i + 1))
        var nbytes = end - start
        acc.n_values += 1
        acc.total_len_bytes += nbytes
        # FNV-1a directly over col._data bytes — no per-row materialization.
        var h = UInt64(0xCBF29CE484222325)
        comptime prime = UInt64(0x00000100000001B3)
        for b in range(nbytes):
            var byte = col._data.read_u8_at(start + b)
            h = (h ^ UInt64(byte)) * prime
        acc.note_hash(h)
        # Min/max tracking still needs an owned String, but only on
        # discovery of a new extreme (O(distinct) allocations, not
        # O(nrows)).
        if not acc.seen_value:
            acc.seen_value = True
            var s_init = _string_from_col(col, start, nbytes)
            acc.min_s = s_init.copy()
            acc.max_s = s_init^
        else:
            # Materialize only when we need to actually compare: defer
            # the String construction until the byte-compare proves a new
            # extreme. Lexicographic byte-compare of (start, nbytes) vs
            # (existing min/max) is sufficient.
            var cmp_min = _str_byte_cmp(col, start, nbytes, acc.min_s)
            if cmp_min < 0:
                acc.min_s = _string_from_col(col, start, nbytes)
            var cmp_max = _str_byte_cmp(col, start, nbytes, acc.max_s)
            if cmp_max > 0:
                acc.max_s = _string_from_col(col, start, nbytes)


@always_inline
def _string_from_col(col: Column, start: Int, nbytes: Int) -> String:
    """Materialize an owned String from `col._data[start..start+nbytes]`.

    Reuses the same null-terminated-scratch idiom as `StringArray.get`,
    but reads from `col._data` directly (one byte-copy, then String ctor).
    """
    if nbytes == 0:
        return String("")
    var scratch = List[UInt8](capacity=nbytes + 1)
    for b in range(nbytes):
        scratch.append(col._data.read_u8_at(start + b))
    scratch.append(UInt8(0))
    # SAFETY: scratch is alive through the ctor; null-terminated UTF-8.
    return String(unsafe_from_utf8_ptr=scratch.unsafe_ptr())


@always_inline
def _str_byte_cmp(col: Column, start: Int, nbytes: Int, ref s: String) -> Int:
    """Lexicographic byte-compare of `col._data[start..start+nbytes]` vs
    the bytes of `s`. Returns negative / zero / positive (memcmp shape)."""
    var sb = s.as_bytes()
    var slen = len(sb)
    var n = nbytes if nbytes < slen else slen
    for k in range(n):
        var a = col._data.read_u8_at(start + k)
        var b = sb[k]
        if a != b:
            return Int(a) - Int(b)
    return nbytes - slen
