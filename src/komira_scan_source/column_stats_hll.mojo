# =============================================================================
# column_stats_hll: the value hashes and the HyperLogLog sketch behind
# ColumnStats' NDV estimate (see column_stats.mojo)
# =============================================================================
#
# HyperLogLog: dense-register port of DuckDB's third_party/hyperloglog
# (Redis/antirez algorithm, Otmar Ertl improved estimator, arXiv:1702.01284).
# Params: p = 12, so m = 4096 registers and the standard error is about
# 1.04/sqrt(m), 1.6%. Q = 64 - p = 52 (max leading-zero run + 1). Registers
# are full bytes (not 6-bit packed), 4 KiB per sketch. A fast 64-bit
# multiplicative mix hashes fixed-width values and FNV-1a hashes string
# bytes; the SAME 64-bit hash feeds both the HLL (low p bits: register index;
# the rest: leading-zero count) and the SBBF bloom (upper 32 bits: block,
# lower 32: probe positions).
# =============================================================================

from std.math import sqrt
from std.bit import count_trailing_zeros

from komira_collections.slab import Slab


# HyperLogLog precision. p = 12  ⇒  m = 2^12 = 4096 registers, ~1.6% std error
# (matches DuckDB's HLL_P). Q = 64 - p = 52.
comptime HLL_P: Int = 12
comptime HLL_REGISTERS: Int = 1 << HLL_P          # 4096
comptime HLL_P_MASK: UInt64 = UInt64(HLL_REGISTERS - 1)
comptime HLL_Q: Int = 64 - HLL_P                  # 52
comptime HLL_ALPHA_INF: Float64 = 0.7213475204444817  # 0.5 / ln(2)

# The largest estimate `HyperLogLog.count` returns: Int64.MAX, so the count
# converts to an `Int` NDV without wrapping. A saturated sketch (every
# register at Q + 1) has no finite Ertl estimate and returns this.
comptime HLL_COUNT_CAP: UInt64 = UInt64(9223372036854775807)

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

        Every register at Q + 1 (a saturated sketch) makes z exactly 0 and
        the estimate unbounded; that, and any estimate at or above
        `HLL_COUNT_CAP`, returns `HLL_COUNT_CAP`.
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
            return HLL_COUNT_CAP
        var e = HLL_ALPHA_INF * m * m / z
        if e < 0.0:
            return UInt64(0)
        # Float64(HLL_COUNT_CAP) rounds to 2^63; below it, `e + 0.5` stays
        # below 2^63 (the float spacing there is 1024), so the cast is exact.
        if e >= Float64(HLL_COUNT_CAP):
            return HLL_COUNT_CAP
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
