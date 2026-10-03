# =============================================================================
# komira_eval.xorshift64 — Per-worker XorShift64 RNG primitive.
# =============================================================================
#
# Why this primitive exists:
#
# Mojo 1.0.0b1's stdlib `random.seed()` is PROCESS-GLOBAL state — calling
# it from `parallelize` workers serializes their RNG streams and races on
# the global state. The AdaptiveFilter requires a per-worker RNG to pick random adjacent
# permutation swaps during the EXPLORATION phase. The canonical idiom is
# a per-worker `XorShift64` state held in a `Slab[FilterState]` (or
# similar per-worker container) indexed by worker_id.
#
# Algorithm: Marsaglia's classic 13/7/17 xorshift64. Period 2^64 - 1,
# fast (3 XOR + 3 shift per next), no allocation, fits in 8 bytes.
#
# Seed derivation: worker-id-derived deterministic seed so each worker
# gets a distinct stream:
#
#     seed = UInt64(worker_id + 1) * 0x100000001B3 + 0x9E3779B97F4A7C15
#
# `0x100000001B3` is the FNV-1a 64-bit multiplier; `0x9E3779B97F4A7C15`
# is the 64-bit golden-ratio offset. The product gives distinct streams
# for adjacent worker_ids.
#
# Encapsulation:
# - No UnsafePointer in any public signature.
# - The 8-byte `state` field is the entire heap footprint (POD).
# - Movable + Deinitable + ImplicitlyCopyable — fits in
#   any `Slab[T]` storage.
# =============================================================================


# Seed combiner constants — kept module-private (no `comptime` export needed).
# Module-level so the test file can re-derive expected seeds for a given
# worker_id without duplicating magic numbers.

# FNV-1a 64-bit prime multiplier.
comptime XORSHIFT64_SEED_MULTIPLIER: UInt64 = 0x100000001B3

# Knuth's 64-bit golden-ratio constant (also used as fallback when caller
# would otherwise seed with zero — pure xorshift on zero stays at zero).
comptime XORSHIFT64_GOLDEN_RATIO: UInt64 = 0x9E3779B97F4A7C15


@fieldwise_init
struct XorShift64(Movable, Deinitable, ImplicitlyCopyable):
    """A deterministic 64-bit xorshift PRNG (Marsaglia 13/7/17).

    Use this — NOT stdlib `random.seed()` — for any per-worker RNG state
    under `parallelize`. The stdlib RNG is process-global and races
    across workers.

    Fields:
        state: The 64-bit RNG state. Initialized via `from_seed` or
            `from_worker_id`; never set to zero (the all-zero state
            would lock the xorshift at zero forever; `from_seed`
            substitutes the golden-ratio constant in that case).

    Construction:
        - `XorShift64.from_seed(s)` — explicit seed; for tests.
        - `XorShift64.from_worker_id(wid)` — production: derives a
          worker-id-keyed seed via the FNV × golden-ratio combiner.

    Hot path:
        - `next_u64()` — returns next 64-bit value (3 XOR + 3 shift).
        - `next_in_range(n)` — returns next value in [0, n).

    Movability:
        - Movable, Deinitable, ImplicitlyCopyable. Fits in
          any `Slab[T]` storage. POD — no heap, no drop work.
    """

    var state: UInt64

    # --- Constructors -------------------------------------------------------

    @staticmethod
    def from_seed(s: UInt64) -> XorShift64:
        """Build a XorShift64 from an explicit 64-bit seed.

        Defensive against the zero-state lock: if `s == 0`, substitutes
        the golden-ratio constant `0x9E3779B97F4A7C15` so the stream
        progresses.

        Args:
            s: The 64-bit seed value.

        Returns:
            A XorShift64 ready for `next_u64` / `next_in_range`.
        """
        var v = s
        if v == UInt64(0):
            v = XORSHIFT64_GOLDEN_RATIO
        return XorShift64(state=v)

    @staticmethod
    def from_worker_id(worker_id: Int) -> XorShift64:
        """Build a XorShift64 keyed to a worker_id.

        The seed is derived from the canonical combiner formula:

            seed = UInt64(worker_id + 1) * FNV_PRIME + GOLDEN_RATIO

        For worker_id values 0..N-1 this produces distinct streams; the
        `+1` ensures worker_id = 0 doesn't degenerate to the FNV-prime-
        only stream.

        Args:
            worker_id: Non-negative worker index. The function accepts
                any Int — negative values are also valid (the wrap-
                around in UInt64 is deterministic) but the production
                convention is non-negative.

        Returns:
            A XorShift64 seeded for this worker.
        """
        var seed_val = (
            UInt64(worker_id + 1) * XORSHIFT64_SEED_MULTIPLIER
            + XORSHIFT64_GOLDEN_RATIO
        )
        return XorShift64.from_seed(seed_val)

    # --- Hot-path mutation --------------------------------------------------

    @always_inline
    def next_u64(mut self) -> UInt64:
        """Advance the state and return the next 64-bit value.

        Marsaglia's 13/7/17 xorshift64 step. Period 2^64 - 1.
        """
        var x = self.state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        self.state = x
        return x

    @always_inline
    def next_in_range(mut self, n: UInt64) -> UInt64:
        """Return the next value in [0, n).

        Note:
            Uses simple modulo — has slight bias for small `n` not a
            power of two. Acceptable for the AdaptiveFilter EXPLORATION
            picker (n is at most ~16 — the number of adjacent swaps in a
            small predicate permutation; bias is well below the noise
            floor of the perf measurement that drives the state machine).
            For unbiased range sampling, use a rejection-sampling wrapper.

        Args:
            n: Upper bound (exclusive). Must be > 0; callers MUST guard.

        Returns:
            A value in [0, n).
        """
        return self.next_u64() % n
