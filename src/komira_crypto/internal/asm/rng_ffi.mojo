# =============================================================================
# komira_crypto/internal/asm/rng_ffi.mojo
# =============================================================================
#
# Cryptographic RNG via AWS-LC's RAND_bytes.
#
# Backs SystemEntropy + ChaCha20Drbg + system_entropy in rng.mojo.
#
# AWS-LC's RAND_bytes internally implements NIST SP 800-90A CTR-DRBG
# (or ChaCha20-DRBG on platforms that prefer it), seeded from
# getrandom(Linux) / getentropy(macOS) with NIST SP 800-90B continuous
# health tests (RCT/APT). One symbol covers the whole RNG stack.
#
# # Symbols used
#
#   * RAND_bytes(buf, len) -> Int  (returns 1 on success, 0 on failure)
#
# # C signature (from AWS-LC's include/openssl/rand.h)
#
#   int RAND_bytes(uint8_t *buf, size_t len);
#
# # Encapsulation discipline
#
#   * ZERO UnsafePointer in public sig (takes Span[UInt8, _]).
#   * ZERO wildcard origins on public surface.
#   * RAND_bytes is thread-safe in AWS-LC (internal locking).
#
# # ⚠ SECOND DECLARATION SITE — keep in sync
#
# The `komira_uuid` package declares this SAME `RAND_bytes` symbol with this
# SAME signature, for UUIDv7's random bits (`src/komira_uuid/entropy.mojo`).
# It is not a second RNG — both call this one AWS-LC implementation — but it
# IS a second declaration, and it exists so that `komira_uuid` does not import
# `komira_crypto`: every package that mints an id would otherwise have crypto
# upstream of it, and any crypto edit would invalidate all of their builds.
# Read that entropy module before changing anything here.
#
# If you change WHICH AWS-LC entrypoint this file calls (e.g. to a FIPS-mode
# `RAND_priv_bytes`), or its signature, change `komira_uuid`'s entropy
# module TOO. A silent divergence leaves UUIDv7 on the old entrypoint.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer


# -----------------------------------------------------------------------------
# The package's FFI origin (FFI-BOUNDARY).
#
# Mojo 1.0.0b2 removed the `UnsafePointer[T]()` null constructor and
# `Boolable`/`__bool__` (non-null-by-design; see
# the Mojo non-null-pointer proposal). A wildcard origin such as
# `MutExternalOrigin` is banned; this uses `StaticConstantOrigin`,
# a CONCRETE (non-wildcard) origin valid for the FFI ABI boundary whose
# lifetime is not expressible in Mojo's origin system. Opaque AWS-LC heap
# handles are passed BY VALUE to `external_call` and never written through
# Mojo-side, so an immutable static origin is sound. Data-buffer pointers
# (Span/InlineArray/scalar out-params) carry the same origin; the SAFETY
# contract is that the caller holds the buffer's real origin in scope across
# the synchronous external_call (AWS-LC retains no pointer past the call).
# -----------------------------------------------------------------------------
comptime _FFI_ORIGIN = ImmStaticOrigin
comptime _FfiHandle = UnsafePointer[NoneType, _FFI_ORIGIN]
comptime _FfiByte = UnsafePointer[UInt8, _FFI_ORIGIN]


@always_inline
def _ffi_null() -> _FfiHandle:
    """A raw NULL opaque-handle (stands in for the removed `UnsafePointer[T]()`
    null ctor) for pre-declared-then-reassigned handle locals and explicit
    C-NULL arguments.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer (the Mojo non-null-pointer proposal), and `None`
    # is the all-zero (NULL) bit pattern. We reinterpret an `Optional`-None
    # slot to obtain a raw NULL handle WITHOUT the removed null ctor and
    # WITHOUT the banned `unsafe_from_address=Int(0)`. Downstream sites
    # detect NULL via `Int(h) == 0` and AWS-LC free fns are NULL-safe.
    """
    var none: Optional[_FfiHandle] = None
    return UnsafePointer(to=none).bitcast[_FfiHandle]()[]



@always_inline
def _span_ptr_mut(s: Span[UInt8, _]) -> _FfiByte:
    """Coerce a `Span[UInt8, _]` to an FFI byte pointer (_FFI_ORIGIN)."""
    return (
        s.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )


def rand_bytes_ffi[o: Origin[mut=True]](dst: Span[UInt8, o]) raises:
    """Fill `dst` with cryptographic random bytes via AWS-LC's RAND_bytes.

    Internally implements NIST SP 800-90A DRBG seeded from OS entropy
    (getrandom on Linux, getentropy on macOS) with SP 800-90B health
    tests. Thread-safe (AWS-LC handles internal locking).

    Raises on RAND_bytes failure (extremely rare: only on
    catastrophic-entropy-source failure or fork-without-reseed
    detection — both of which are programmer errors at the process
    level, not transient).
    """
    if len(dst) == 0:
        return

    # SAFETY: RAND_bytes writes exactly len(dst) bytes to dst_ptr.
    # Buffer caller-owned for the synchronous call. AWS-LC is
    # thread-safe.
    var dst_ptr = _span_ptr_mut(dst)
    var rc = external_call[
        "komira_awslc_RAND_bytes",
        Int,
        _FfiByte,
        UInt,
    ](dst_ptr, UInt(len(dst)))
    if rc != 1:
        raise Error("rand_bytes_ffi: RAND_bytes failed (entropy source failure)")  # cov: unreachable RAND_bytes fails only when the operating system's entropy source fails
