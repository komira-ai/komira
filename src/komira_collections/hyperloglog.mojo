# =============================================================================
# HyperLogLog (HLL) cardinality sketch
# =============================================================================
#
# A fixed-precision HyperLogLog sketch (Flajolet, Fusy, Gandouet, Meunier
# 2007): it estimates the number of distinct values in a stream in constant
# memory, and two sketches merge into the sketch of their union. The value
# is an approximate estimate (standard error ~1.6%, below). The Parquet spec
# defines `Statistics.distinct_count` (parquet.thrift field 4) as the count of
# distinct values without marking it approximate, so a writer that stores
# this estimate there is making that choice. A writer that wants SQL distinct
# semantics must also canonicalize -0.0/+0.0 and NaN before hashing (see
# `hll_hash_float64`).
#
# Design:
#   - Precision p = 12  ->  m = 4096 one-byte registers, 4 KiB of state.
#   - Standard error ~ 1.04 / sqrt(m) ~= 1.6%.
#   - 64-bit hashing throughout. The high p bits index the register, the
#     remaining (64 - p) bits feed the leading-zero count + 1 ("rho").
#   - Bias-corrected estimator: small-range (linear counting) when the
#     raw HLL estimate falls below 5/2 * m AND there are empty registers,
#     pure HLL elsewhere. Large-range correction is unnecessary for 64-bit
#     hashes (the original 32-bit large-range formula is wrong for u64).
#
# Hash function: a `splitmix64` finalizer. `add_hash` takes a pre-mixed
# UInt64 hash at face value, so callers can supply whatever upstream hash
# they prefer. The `add_int64`/`add_bytes`/... convenience methods mix
# their input themselves. Bytes are hashed via FNV-1a *then* funneled
# through the integer finalizer to fix FNV's poor upper-bit distribution.
# Every hash is deterministic: no seed, the same input gives the same hash
# on every machine, so sketches built in different processes merge.
#
# Encapsulation: every pointer use is internal to this module (the FNV-1a
# byte loop, the Float64 bit reinterpretation and the SIMD merge loop); the
# public API takes and returns only typed scalars, `List[UInt8]`,
# `List[UInt64]`, `String` and `HyperLogLog`.
# =============================================================================


# -----------------------------------------------------------------------------
# Compile-time constants
# -----------------------------------------------------------------------------

# Precision (number of bits used for register indexing). m = 1 << p.
comptime HLL_PRECISION: Int = 12
comptime HLL_NUM_REGISTERS: Int = 1 << HLL_PRECISION  # 4096
comptime HLL_HASH_REM_BITS: Int = 64 - HLL_PRECISION  # 52


@always_inline
def _alpha_m_squared() -> Float64:
    """The bias-correction factor a_m * m^2 from Flajolet et al.

    For p = 12 (m = 4096), a_m = 0.7213 / (1 + 1.079/m), so:
        a_m  = 0.7213 / (1 + 1.079/4096) = 0.72110997...
        a_m * m^2 = 0.72110997 * 4096^2 ~= 12098218.9
    Every operand is a compile-time constant, so the expression folds.
    """
    var alpha_m = 0.7213 / (1.0 + 1.079 / Float64(HLL_NUM_REGISTERS))
    return alpha_m * Float64(HLL_NUM_REGISTERS) * Float64(HLL_NUM_REGISTERS)


# -----------------------------------------------------------------------------
# Hash mixing
# -----------------------------------------------------------------------------


@always_inline
def _splitmix64(value: UInt64) -> UInt64:
    """splitmix64 finalizer — one-shot 64->64 bit mixer.

    Excellent avalanche, no dependencies. Same constants as the canonical
    SplitMix64 PRNG (Steele, Lea, Flood 2014). Unlike a streaming hash,
    this is intended as a finalizer step on a value that already has
    moderate entropy in some of its bits.
    """
    var x = value + UInt64(0x9E3779B97F4A7C15)
    x = (x ^ (x >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B5)
    x = (x ^ (x >> UInt64(27))) * UInt64(0x94D049BB133111EB)
    x = x ^ (x >> UInt64(31))
    return x


@always_inline
def hll_hash_int64(value: Int64) -> UInt64:
    """Hash an Int64 for HLL ingestion.

    Bit-pattern reinterpretation of the i64 as a u64, then splitmix64.
    Negative values do not get any special treatment — only their bit
    patterns matter. Determinism: same input always produces the same
    output across processes / machines (no random seed).
    """
    return _splitmix64(UInt64(value))


@always_inline
def hll_hash_uint64(value: UInt64) -> UInt64:
    """Hash a UInt64 for HLL ingestion."""
    return _splitmix64(value)


@always_inline
def hll_hash_float64(value: Float64) -> UInt64:
    """Hash a Float64 for HLL ingestion via its IEEE-754 bit pattern.

    Caller is responsible for canonicalizing NaN if NaN-distinction is
    not desired (NaNs are NOT collapsed here — every NaN bit pattern
    counts as a distinct value, and -0.0 and +0.0 count as two values).
    """
    var buf = value
    # SAFETY: `buf` is a stack-local Float64; pointer is origin-tied and
    # used only for a single bitcast load before the function returns.
    var bits = UnsafePointer(to=buf).bitcast[UInt64]()[]
    return _splitmix64(bits)


@always_inline
def _fnv1a_64(data: UnsafePointer[UInt8, _], length: Int) -> UInt64:
    """FNV-1a-64 over a byte range.

    Used as a streaming step before the splitmix64 finalizer below;
    the two-stage pipeline (FNV mix -> splitmix64 finalize) corrects for
    FNV's poor upper-bit distribution and is sufficient for HLL.
    """
    var h = UInt64(0xCBF29CE484222325)
    comptime fnv_prime = UInt64(0x00000100000001B3)
    for i in range(length):
        h = h ^ UInt64((data + i)[])
        h = h * fnv_prime
    return h


@always_inline
def hll_hash_bytes(data: List[UInt8]) -> UInt64:
    """Hash a byte sequence for HLL ingestion (FNV-1a then splitmix64).

    SAFETY: `data` is a List held by the caller; `data.unsafe_ptr()` is
    valid for the lifetime of the call. The pointer is used only inside
    `_fnv1a_64` and not stored.
    """
    var h = _fnv1a_64(data.unsafe_ptr(), len(data))
    return _splitmix64(h)


@always_inline
def hll_hash_string(value: String) -> UInt64:
    """Hash a String for HLL ingestion."""
    var bytes = value.as_bytes()
    var h = _fnv1a_64(bytes.unsafe_ptr(), len(bytes))
    return _splitmix64(h)


# -----------------------------------------------------------------------------
# Internal: count leading zeros in the register-tail bits
# -----------------------------------------------------------------------------


@always_inline
def _leading_zero_count_plus_one_in_tail(tail: UInt64) -> Int:
    """Compute rho(w) — position of the leading 1-bit in the (64-p)-bit
    tail, with rho(0) = 64 - p + 1.

    `tail` MUST already have the high p bits set to zero (caller responsibility).
    """
    if tail == UInt64(0):
        return HLL_HASH_REM_BITS + 1

    # Find leading-zero count of the 64-bit tail starting from its
    # highest meaningful bit (which is bit `HLL_HASH_REM_BITS - 1`).
    # We could call clz; this scalar loop is fine for a per-add cost
    # of ~52 iterations worst case but typically <= 4 (geometric distribution).
    var t = tail
    var rho = 1
    var probe = UInt64(1) << UInt64(HLL_HASH_REM_BITS - 1)
    while (t & probe) == UInt64(0):
        rho += 1
        probe = probe >> UInt64(1)
        if probe == UInt64(0):
            # Shouldn't reach here given the early-out above, but keep
            # the loop bounded.
            break
    return rho


# -----------------------------------------------------------------------------
# HyperLogLog — main struct
# -----------------------------------------------------------------------------


struct HyperLogLog(Movable, Copyable):
    """A precision-12 HyperLogLog cardinality sketch.

    State: 4096 register bytes. Each register holds the largest rho
    observed for any hash that mapped to that register's index. After
    ingestion, `estimate()` returns a cardinality estimate corrected for
    small-range bias via linear counting.

    Memory footprint: 4 KiB (one byte per register), allocated as a
    `List[UInt8]` for safe ownership and cheap copy-construction.
    """

    var registers: List[UInt8]

    def __init__(out self):
        """Initialize an empty sketch (all registers = 0)."""
        self.registers = List[UInt8](capacity=HLL_NUM_REGISTERS)
        for _ in range(HLL_NUM_REGISTERS):
            self.registers.append(UInt8(0))

    # -------------------------------------------------------------------------
    # Ingest helpers
    # -------------------------------------------------------------------------

    @always_inline
    def add_hash(mut self, hash: UInt64):
        """Add a pre-mixed 64-bit hash to the sketch.

        Caller MUST supply a well-mixed hash (e.g. via `hll_hash_int64`,
        `hll_hash_uint64`, `hll_hash_float64`, or `hll_hash_bytes`). We
        do NOT re-mix here — the caller's hash is taken at face value.
        """
        # Top HLL_PRECISION bits index the register.
        var idx = Int(hash >> UInt64(HLL_HASH_REM_BITS))
        # Bottom HLL_HASH_REM_BITS bits are the rho input.
        var tail_mask = (UInt64(1) << UInt64(HLL_HASH_REM_BITS)) - UInt64(1)
        var tail = hash & tail_mask
        var rho = _leading_zero_count_plus_one_in_tail(tail)
        if UInt8(rho) > self.registers[idx]:
            self.registers[idx] = UInt8(rho)

    def add_int64(mut self, value: Int64):
        """Convenience: hash an Int64 and add it."""
        self.add_hash(hll_hash_int64(value))

    def add_uint64(mut self, value: UInt64):
        """Convenience: hash a UInt64 and add it."""
        self.add_hash(hll_hash_uint64(value))

    def add_float64(mut self, value: Float64):
        """Convenience: hash a Float64 and add it."""
        self.add_hash(hll_hash_float64(value))

    def add_bytes(mut self, data: List[UInt8]):
        """Convenience: hash a byte sequence and add it."""
        self.add_hash(hll_hash_bytes(data))

    def add_hashes(mut self, hashes: List[UInt64]):
        """Batch-add a list of pre-mixed hashes."""
        for i in range(len(hashes)):
            self.add_hash(hashes[i])

    def merge(mut self, other: HyperLogLog):
        """Merge another HLL sketch into this one (register-wise max).

        A planner merges one sketch per column chunk to estimate a
        column's distinct count, so a file with C columns and R row
        groups costs C * R merges at plan time. The register-wise max is
        a SIMD loop over 16 bytes per iteration (4096 / 16 = 256
        iterations) rather than 4096 scalar compares.
        """
        comptime W: Int = 16
        var s_ptr = self.registers.unsafe_ptr()
        var o_ptr = other.registers.unsafe_ptr()
        for i in range(0, HLL_NUM_REGISTERS, W):
            # SAFETY: precondition: both sketches hold exactly
            # HLL_NUM_REGISTERS (4096) registers, and nothing resizes
            # `registers`. 4096 is divisible by W=16, so under that
            # precondition every load and store is in bounds.
            var s = (s_ptr + i).load[width=W]()
            var o = (o_ptr + i).load[width=W]()
            (s_ptr + i).store(max(s, o))

    # -------------------------------------------------------------------------
    # Estimate
    # -------------------------------------------------------------------------

    def estimate(self) -> Int:
        """Compute the bias-corrected cardinality estimate.

        Returns 0 if all registers are empty (no values added). Otherwise
        applies the standard HLL estimator with linear-counting small-range
        correction. No large-range correction is needed for 64-bit hashes.
        """
        var m = HLL_NUM_REGISTERS
        var num_empty = 0
        var sum_inv = Float64(0.0)
        # E = a_m * m^2 / sum_i(2^-M_i)
        for i in range(m):
            var r = self.registers[i]
            if r == UInt8(0):
                num_empty += 1
                # 2^-0 = 1.0
                sum_inv += 1.0
            else:
                # 2^-r
                sum_inv += _pow2_neg(Int(r))

        if sum_inv <= 0.0:
            # Pathological — should never happen since each register
            # contributes >= 2^-255. Defensive zero.
            return 0

        var raw_e = _alpha_m_squared() / sum_inv

        # Small-range correction (linear counting) when raw estimate is
        # small and we have empty registers. Threshold: 5/2 * m.
        var small_range_threshold = 2.5 * Float64(m)
        if raw_e <= small_range_threshold and num_empty > 0:
            # E* = m * ln(m / V)  where V = number of empty registers
            var v_f = Float64(num_empty)
            var m_f = Float64(m)
            var corrected = m_f * _ln(m_f / v_f)
            return Int(corrected + 0.5)

        # Pure HLL (no large-range correction needed for 64-bit hashes).
        return Int(raw_e + 0.5)


# -----------------------------------------------------------------------------
# Float helpers
# -----------------------------------------------------------------------------


@always_inline
def _pow2_neg(exp: Int) -> Float64:
    """Compute 2^-exp for exp in [1, 64].

    For exp <= 62 the denominator 2^exp fits in a UInt64; for exp > 62
    it halves a Float64 exp times.
    """
    if exp <= 0:
        return 1.0
    if exp <= 62:
        var denom = UInt64(1) << UInt64(exp)
        return 1.0 / Float64(denom)
    var v = 1.0
    for _ in range(exp):
        v *= 0.5
    return v


@always_inline
def _ln(x: Float64) -> Float64:
    """Natural log for x > 0, via `std.math.log`."""
    from std.math import log
    return log(x)
