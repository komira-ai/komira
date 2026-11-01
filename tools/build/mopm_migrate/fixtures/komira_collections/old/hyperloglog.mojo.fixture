# =============================================================================
# HyperLogLog (HLL) cardinality sketch
# =============================================================================
#
# A fixed-precision HyperLogLog sketch (Flajolet, Fusy, Gandouet,
# Meunier): it estimates the number of distinct values in a stream in constant
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
#   - Estimator: Ertl's improved raw estimator (O. Ertl, "New cardinality
#     estimation algorithms for HyperLogLog sketches", arXiv:1702.01284,
#     Algorithm 6). It reads the register histogram, accounts for
#     empty registers and for registers at the maximum value q + 1 inside
#     the estimate itself, and so needs no switch to linear counting, no
#     threshold and no empirical bias table. Its error stays near the
#     standard error over the whole range, including n ~ 5/2 * m where the
#     original estimator (linear counting below 5/2 * m, raw HLL above)
#     overestimates by ~1.5% on average.
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

from std.math import sqrt


# -----------------------------------------------------------------------------
# Compile-time constants
# -----------------------------------------------------------------------------

# Precision (number of bits used for register indexing). m = 1 << p.
comptime HLL_PRECISION: Int = 12
comptime HLL_NUM_REGISTERS: Int = 1 << HLL_PRECISION  # 4096
comptime HLL_HASH_REM_BITS: Int = 64 - HLL_PRECISION  # 52


# The largest register value: rho of an all-zero tail, q + 1 in Ertl's
# notation (q = 64 - p).
comptime HLL_MAX_REGISTER: Int = HLL_HASH_REM_BITS + 1  # 53

# Ertl's alpha_inf = 1 / (2 ln 2), the limit of the HLL bias constant a_m
# as m grows. ln 2 is written to the precision a Float64 holds.
comptime _HLL_ALPHA_INF: Float64 = 1.0 / (2.0 * 0.6931471805599453)


# -----------------------------------------------------------------------------
# Hash mixing
# -----------------------------------------------------------------------------


@always_inline
def _splitmix64(value: UInt64) -> UInt64:
    """splitmix64 finalizer — one-shot 64->64 bit mixer.

    Excellent avalanche, no dependencies. Same constants as the canonical
    SplitMix64 PRNG (Steele, Lea, Flood). Unlike a streaming hash,
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
    ingestion, `estimate()` returns a cardinality estimate from the
    register histogram (Ertl's improved raw estimator).

    Memory footprint: 4 KiB (one byte per register), allocated as a
    `List[UInt8]` for safe ownership and cheap copy-construction.
    """

    # Always exactly HLL_NUM_REGISTERS entries: created at that length and
    # never resized, which is what makes the SIMD loop in `merge` in bounds.
    # Read and write single registers through `register`/`set_register`.
    var _registers: List[UInt8]

    def __init__(out self):
        """Initialize an empty sketch (all registers = 0)."""
        self._registers = List[UInt8](capacity=HLL_NUM_REGISTERS)
        for _ in range(HLL_NUM_REGISTERS):
            self._registers.append(UInt8(0))

    @always_inline
    def register(self, idx: Int) -> UInt8:
        """The value of register `idx`, 0 <= idx < HLL_NUM_REGISTERS."""
        return self._registers[idx]

    @always_inline
    def set_register(mut self, idx: Int, value: UInt8):
        """Set register `idx` to `value`, 0 <= idx < HLL_NUM_REGISTERS.

        Overwrites rather than takes the maximum; `add_hash` and `merge`
        are the ingest paths. Any UInt8 is stored, but `estimate` treats a
        value above HLL_MAX_REGISTER (53) as 53.
        """
        self._registers[idx] = value

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
        if UInt8(rho) > self._registers[idx]:
            self._registers[idx] = UInt8(rho)

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
        debug_assert(
            len(self._registers) == HLL_NUM_REGISTERS
            and len(other._registers) == HLL_NUM_REGISTERS,
            "HyperLogLog.merge: a sketch does not hold HLL_NUM_REGISTERS registers",
        )
        var s_ptr = self._registers.unsafe_ptr()
        var o_ptr = other._registers.unsafe_ptr()
        for i in range(0, HLL_NUM_REGISTERS, W):
            # SAFETY: both sketches hold exactly HLL_NUM_REGISTERS (4096)
            # registers: `_registers` is created at that length and this
            # module never resizes it (asserted above in debug builds).
            # 4096 is divisible by W=16, so every load and store is in
            # bounds.
            var s = (s_ptr + i).load[width=W]()
            var o = (o_ptr + i).load[width=W]()
            (s_ptr + i).store(max(s, o))

    # -------------------------------------------------------------------------
    # Estimate
    # -------------------------------------------------------------------------

    def estimate(self) -> Int:
        """Estimate the number of distinct values added.

        Ertl's improved raw estimator (arXiv:1702.01284, Algorithm 6), over
        the histogram C[k] = number of registers holding k, k = 0 .. q + 1:

            z = m * tau(1 - C[q+1] / m)
            for k = q down to 1:  z = (z + C[k]) / 2
            z = z + m * sigma(C[0] / m)
            E = alpha_inf * m^2 / z

        Returns 0 for an empty sketch. A sketch whose every register is at
        q + 1 has an unbounded estimate, and a nearly saturated one an
        estimate above `Int.MAX`; both return `Int.MAX`. (Either takes
        thousands of hashes with all-zero or near-zero 52-bit tails, or
        `set_register`.)
        A register set above q + 1 through `set_register` counts as q + 1.
        """
        var m = HLL_NUM_REGISTERS
        var counts = InlineArray[Int, HLL_MAX_REGISTER + 1](fill=0)
        for i in range(m):
            counts[min(Int(self._registers[i]), HLL_MAX_REGISTER)] += 1

        if counts[0] == m:
            return 0
        if counts[HLL_MAX_REGISTER] == m:
            return Int.MAX

        var m_f = Float64(m)
        var z = m_f * _ertl_tau(1.0 - Float64(counts[HLL_MAX_REGISTER]) / m_f)
        for k in range(HLL_MAX_REGISTER - 1, 0, -1):
            z = 0.5 * (z + Float64(counts[k]))
        z += m_f * _ertl_sigma(Float64(counts[0]) / m_f)
        var e = _HLL_ALPHA_INF * m_f * m_f / z
        # 2^63 is the first Float64 that does not fit in Int.
        if e + 0.5 >= 9223372036854775808.0:
            return Int.MAX
        return Int(e + 0.5)


# -----------------------------------------------------------------------------
# Ertl's sigma and tau series
# -----------------------------------------------------------------------------


def _ertl_sigma(x_in: Float64) -> Float64:
    """sigma(x) = x + sum_{k>=1} x^(2^k) * 2^(k-1), for 0 <= x < 1.

    Ertl, arXiv:1702.01284, Algorithm 6: the series is summed until adding
    a term no longer changes the Float64 sum. The caller never passes
    x = 1 (an empty sketch returns before the estimate is formed).
    """
    var x = x_in
    var y = 1.0
    var z = x
    while True:
        x = x * x
        var z_prev = z
        z += x * y
        y += y
        if z == z_prev:
            return z


def _ertl_tau(x_in: Float64) -> Float64:
    """tau(x) = (1 - x - sum_{k>=1} (1 - x^(2^-k))^2 * 2^-k) / 3, 0 <= x <= 1.

    Ertl, arXiv:1702.01284, Algorithm 6, summed until the Float64 sum stops
    changing; tau(0) = tau(1) = 0.
    """
    if x_in == 0.0 or x_in == 1.0:
        return 0.0
    var x = x_in
    var y = 1.0
    var z = 1.0 - x
    while True:
        x = sqrt(x)
        var z_prev = z
        y *= 0.5
        var d = 1.0 - x
        z -= d * d * y
        if z == z_prev:
            return z / 3.0
