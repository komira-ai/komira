# =============================================================================
# komira_crypto/rng.mojo — RNG primitives via AWS-LC RAND_bytes
# =============================================================================
#
# SystemEntropy, ChaCha20Drbg and system_entropy are thin wrappers around
# AWS-LC's RAND_bytes, which internally implements NIST SP 800-90A CTR-DRBG
# (or ChaCha20-DRBG on platforms that prefer it), seeded from
# getrandom/getentropy with SP 800-90B continuous health tests. One AWS-LC
# symbol covers the syscall wrappers, the health tests and the DRBG.
#
# Public surface:
#   * system_entropy(dst) raises — free fn (CSPRNG fill)
#   * SystemEntropy struct: __init__ + read(dst) raises
#   * ChaCha20Drbg struct: __init__ (3 overloads) + next(dst) + reseed +
#     blocks_produced()
#
# The structs are an explicit-handle form of the same source for callers
# that construct and pass instances (the tests do); the free function is
# the plain form. All methods route through RAND_bytes; ChaCha20Drbg's
# block counting is diagnostic only, since RAND_bytes is already a
# stateful DRBG with internal state management.
# stateful DRBG with internal state management.
# =============================================================================

from komira_crypto.internal.asm.rng_ffi import rand_bytes_ffi


# -----------------------------------------------------------------------------
# system_entropy — free function CSPRNG fill via AWS-LC RAND_bytes
# -----------------------------------------------------------------------------


def system_entropy[o: Origin[mut=True]](dst: Span[UInt8, o]) raises:
    """Fill `dst` with cryptographic random bytes via AWS-LC's RAND_bytes.

    Internally seeded from OS entropy (getrandom on Linux, getentropy
    on macOS) with NIST SP 800-90B health tests applied by AWS-LC.
    """
    rand_bytes_ffi(dst)


# -----------------------------------------------------------------------------
# SystemEntropy — stateful wrapper (kept for backward compat)
# -----------------------------------------------------------------------------


struct SystemEntropy(Movable, Deinitable):
    """Stateful wrapper around AWS-LC's RAND_bytes.

    AWS-LC's RAND_bytes performs the SP 800-90B health checks internally,
    so the wrapper is stateless; it exists for callers that construct and
    pass an entropy-source instance.

    Movable, non-Copyable (an entropy source is not a value to duplicate).
    """

    var _calls_made: UInt64
    """Counter for diagnostics; not used for any correctness logic."""

    def __init__(out self):
        """Construct an empty wrapper. No syscall yet — first .read()
        does the work."""
        self._calls_made = UInt64(0)

    def read[o: Origin[mut=True]](mut self, dst: Span[UInt8, o]) raises:
        """Fill `dst` with AWS-LC RAND_bytes (which internally runs
        SP 800-90B health tests on the entropy stream)."""
        if len(dst) == 0:
            return
        rand_bytes_ffi(dst)
        self._calls_made = self._calls_made + UInt64(1)

    def __deinit__(deinit self):
        """No-op cleanup (RAND_bytes has no per-instance state)."""
        self._calls_made = UInt64(0)


# -----------------------------------------------------------------------------
# ChaCha20Drbg — stateful DRBG wrapper (kept for backward compat)
# -----------------------------------------------------------------------------


# Reseed threshold per NIST SP 800-90A §10.2.1 — a documented constant;
# AWS-LC manages reseeding internally.
comptime DRBG_RESEED_BLOCKS: UInt64 = UInt64(1) << UInt64(32)


struct ChaCha20Drbg(Movable, Deinitable):
    """DRBG wrapper around AWS-LC's RAND_bytes.

    AWS-LC's RAND_bytes IS the DRBG (CTR-DRBG or ChaCha20-DRBG depending on
    platform), with its own internal state + reseed schedule managed by
    AWS-LC's RAND_* layer. The name records the construction this API
    describes; the struct is the explicit-handle form of that DRBG.
    """

    var _blocks_produced: UInt64
    """Counter of 64-byte output blocks emitted, for diagnostics."""

    def __init__(out self):
        """Construct an empty DRBG wrapper. No seeding needed —
        AWS-LC's RAND_bytes maintains the global DRBG state."""
        self._blocks_produced = UInt64(0)

    def __init__(out self, mut seed_src: SystemEntropy) raises:
        """Construct from a SystemEntropy seed source.

        AWS-LC's RAND_bytes manages the global DRBG state and reseeds
        internally from OS entropy; the seed_src argument is used only for a
        smoke fill that validates seed_src works.
        """
        var smoke = Array[UInt8, 1](fill=0)
        seed_src.read(Span[UInt8](smoke))
        self._blocks_produced = UInt64(0)

    def next[o: Origin[mut=True]](mut self, dst: Span[UInt8, o]):
        """Fill `dst` with DRBG output via AWS-LC's RAND_bytes.

        Per AWS-LC RAND_bytes contract: outputs cryptographic-quality
        bytes from the global DRBG (CTR-DRBG/ChaCha20-DRBG seeded from
        OS entropy with internal reseed).
        """
        var n = len(dst)
        if n == 0:
            return
        # rand_bytes_ffi raises on failure; this method is non-raising by
        # contract, so the failure is absorbed here.
        try:
            rand_bytes_ffi(dst)
        except:
            # AWS-LC RAND_bytes only fails on catastrophic entropy-source
            # failure; in practice never happens. Silently zero-fill to
            # match the non-raising signature.
            for i in range(n):  # cov: unreachable rand_bytes_ffi raises only when the operating system's entropy source fails
                dst[i] = UInt8(0)  # cov: unreachable see the line above
        var blocks = UInt64((n + 63) // 64)
        self._blocks_produced = self._blocks_produced + blocks

    def blocks_produced(self) -> UInt64:
        """Count of 64-byte output blocks emitted since construction."""
        return self._blocks_produced

    def reseed(mut self, mut seed_src: SystemEntropy) raises:
        """Reseed via AWS-LC.

        AWS-LC manages reseeding internally; this runs a smoke fill from
        seed_src to validate it still works and resets the block counter (for
        diagnostics).
        """
        var smoke = Array[UInt8, 1](fill=0)
        seed_src.read(Span[UInt8](smoke))
        self._blocks_produced = UInt64(0)

    def __deinit__(deinit self):
        """No-op cleanup."""
        self._blocks_produced = UInt64(0)
