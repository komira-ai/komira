# =============================================================================
# komira_uuid/entropy.mojo — CSPRNG fill for UUIDv7's random bits
# =============================================================================
#
# UUIDv7 needs `rand_a` (12 bits) + `rand_b` (62 bits) drawn from a
# cryptographically secure RNG (RFC 9562 §6.9 — "unguessable" bits SHOULD
# come from a CSPRNG). This file is this package's own source of
# those bytes.
#
# # Why this file exists
#
# The same CSPRNG is exposed by `komira_crypto.rng.system_entropy`, but
# importing `komira_crypto` here would put the whole crypto library upstream
# of every package that mints an ID: an edit to any crypto source would
# invalidate all of them. Declaring the one C symbol locally keeps this package
# a small leaf. (The clock is different: `komira_clock` is a dependency-free
# leaf of its own, so the wall clock comes from there.)
#
# # What is and is NOT duplicated
#
# NOTHING cryptographic is reimplemented here. The CSPRNG is AWS-LC's
# `RAND_bytes` — a single implementation, linked once from aws-lc's
# `libcrypto` and shared by this file and by `komira_crypto`. What is
# duplicated is the C-ABI *declaration*, exactly as a C header is re-included
# in every translation unit that calls it. The entropy source, its NIST
# SP 800-90A DRBG construction, its SP 800-90B continuous health tests, and its
# fork-safety all live in AWS-LC and are untouched by this file. There is no
# second RNG.
#
# ⚠ KEEP IN SYNC with `komira_crypto/internal/asm/rng_ffi.mojo`. The two
# declarations MUST name the same symbol with the same signature. If AWS-LC's
# RNG entrypoint is ever changed there (e.g. to a FIPS-mode
# `RAND_priv_bytes`), change it HERE TOO — a silent divergence would leave
# UUIDv7 on the old entrypoint. This package's test carries the behavioural
# guards — `test_entropy_is_live_csprng` (two draws must be non-zero and
# distinct) and `test_generated_uuids_have_varying_random_bits` (those bytes
# must actually reach a UUID). No-op'ing the `external_call` below turns that
# test RED.
#
# # Link surface
#
# Any binary that links this package links aws-lc's `libcrypto` (this
# library's `deps` carries it). Re-declaring an extern symbol in a second
# package is routine: the symbol resolves to the one definition at link time.
#
# # Encapsulation discipline
#
# The `external_call` and the raw byte pointer stay INSIDE this file. The
# public symbol `system_entropy` takes a `Span[UInt8, o]` with a CONCRETE
# mutable origin and returns nothing — no `UnsafePointer` crosses the module
# boundary, and no wildcard origin appears on the public surface.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer


# -----------------------------------------------------------------------------
# Canonical FFI-boundary origin.
#
# `StaticConstantOrigin` is a CONCRETE (non-wildcard) origin used for the C-ABI
# boundary, whose real lifetime is not expressible in Mojo's origin system.
# This mirrors `komira_crypto/internal/asm/rng_ffi.mojo` exactly. The SAFETY
# contract is that the caller holds the buffer's real origin in scope across
# the synchronous `external_call`; AWS-LC retains no pointer past the call.
# -----------------------------------------------------------------------------
comptime _FFI_ORIGIN = ImmStaticOrigin
comptime _FfiByte = UnsafePointer[UInt8, _FFI_ORIGIN]


@always_inline
def _span_ptr_mut(s: Span[UInt8, _]) -> _FfiByte:
    """Coerce a `Span[UInt8, _]` to an FFI byte pointer (_FFI_ORIGIN)."""
    return (
        s.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )


def system_entropy[o: Origin[mut=True]](dst: Span[UInt8, o]) raises:
    """Fill `dst` with cryptographic random bytes via AWS-LC's `RAND_bytes`.

    Byte-for-byte the same entropy source as
    `komira_crypto.rng.system_entropy` —
    AWS-LC's `RAND_bytes` implements a NIST SP 800-90A DRBG seeded from OS
    entropy (`getrandom` on Linux, `getentropy` on macOS) with SP 800-90B
    continuous health tests applied internally. Thread-safe (AWS-LC does its
    own locking).

    Raises on `RAND_bytes` failure (extremely rare: catastrophic
    entropy-source failure or fork-without-reseed detection — both process-level
    programmer errors, not transient). Never silently returns weak bytes.
    """
    if len(dst) == 0:
        return

    # SAFETY: RAND_bytes writes exactly len(dst) bytes to dst_ptr. The buffer
    # is caller-owned for the duration of the synchronous call, and AWS-LC
    # retains no reference to it. AWS-LC is thread-safe.
    var dst_ptr = _span_ptr_mut(dst)
    var rc = external_call[
        "komira_awslc_RAND_bytes",
        Int,
        _FfiByte,
        UInt,
    ](dst_ptr, UInt(len(dst)))
    if rc != 1:
        raise Error("system_entropy: RAND_bytes failed (entropy source failure)")
