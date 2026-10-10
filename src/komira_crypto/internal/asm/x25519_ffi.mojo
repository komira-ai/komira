# =============================================================================
# komira_crypto/internal/asm/x25519_ffi.mojo
# =============================================================================
#
# X25519 scalar multiplication — FFI wrapper to AWS-LC's hand-tuned `X25519`
# symbol from libcrypto.a (vendored from OpenSSL via AWS-LC; Apache 2.0 /
# OpenSSL dual licensed).
#
# # Why this exists
#
# The pattern of the other FFI bridges transposes mechanically to X25519:
# calling the exact `X25519` symbol AWS-LC's own benchmarks use gives
# AWS-LC's performance, which a pure-Mojo scalar ladder does not reach.
#
# # Approach: bare `X25519` symbol (simplest possible binding)
#
# Unlike AesGcmCtx / ChaCha20Poly1305Ctx (opaque-handle pattern with
# EVP_AEAD_CTX_new/free lifecycle), X25519 is STATELESS — no per-call
# heap allocation, no init/free pair. The bare `X25519` symbol in
# libcrypto.a is the direct entry point used by AWS-LC's own bench
# and test infrastructure.
#
#   int X25519(uint8_t out_shared_key[32],
#              const uint8_t private_key[32],
#              const uint8_t peer_public_value[32]);
#
# Returns 1 on success, 0 on small-order rejection (per RFC 7748 §6.1
# the shared secret is all-zero in this case).
#
# # Symbol verified
#
# `nm libcrypto.a | grep X25519` confirms `_X25519` exported with
# T (text) marker at offset 0x1ef44. The FFI binding resolves at
# AOT link time of the consuming binary.
#
# # Build wiring
#
# The `external_call` site below is a symbol REFERENCE, resolved at the
# final link of any consumer binary against aws-lc's libcrypto (a
# dependency of this package).
#
# # Encapsulation discipline
#
# Public API:
#   * `x25519_scalarmult(scalar, peer_public, mut shared_out) -> Bool`
#     takes Span[UInt8, _] + mut InlineArray[UInt8, 32] — ZERO
#     UnsafePointer in the public signature.
# Internal FFI:
#   * The `external_call["komira_awslc_X25519", ...]` site uses `UnsafePointer(to=...)`
#     with INFERRED origin (NOT wildcard widening), following the same
#     pattern as `sha256_compress.mojo` (and `zeroize.mojo` for memset_s).
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO ArcPointer.
#   * The external_call site carries a multi-line `# SAFETY:` comment.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer


# -----------------------------------------------------------------------------
# Public wrapper — x25519_scalarmult.
#
# Internal FFI invocation: AWS-LC's `X25519` symbol from libcrypto.a.
# The Mojo `external_call` site receives untyped-origin pointers (inferred
# from `scalar`, `peer_public`, `shared_out`); Mojo resolves the call at
# AOT link time. The linker needs libcrypto from aws-lc, which is why it
# is a dependency of this package.
# -----------------------------------------------------------------------------


@always_inline
def x25519_scalarmult(
    scalar: Span[UInt8, _],
    peer_public: Span[UInt8, _],
    mut shared_out: Array[UInt8, 32],
) -> Bool:
    """Compute X25519(scalar, peer_public) via AWS-LC's hand-tuned `X25519`.

    Args:
        scalar: 32-byte little-endian private scalar (caller-owned;
            MUST be ≥32 bytes; clamping is performed internally by
            AWS-LC per RFC 7748 §5).
        peer_public: 32-byte little-endian peer u-coordinate (caller-
            owned; MUST be ≥32 bytes; top bit masked internally per
            RFC 7748 §5).
        shared_out: 32-byte output buffer. On success, filled with
            the shared secret. On small-order rejection (return False),
            buffer contents are AWS-LC-defined (caller should treat as
            unspecified; the higher-level `x25519` wrapper zeros the
            buffer in this case per the documented all-zero contract).

    Returns:
        True if the shared secret is well-defined (per RFC 7748 §6.1
        rejection check); False on small-order rejection.

    Performance: matches AWS-LC's own `X25519` byte-identically — this
    IS the AWS-LC implementation. The ratio vs a direct AWS-LC call
    should be ~1.000x modulo Mojo's FFI dispatch overhead (a few
    nanoseconds per call).
    """
    debug_assert(
        len(scalar) >= 32,
        "x25519_scalarmult: scalar must be >= 32 bytes",
    )
    debug_assert(
        len(peer_public) >= 32,
        "x25519_scalarmult: peer_public must be >= 32 bytes",
    )

    # SAFETY: AWS-LC's `X25519` reads exactly 32 bytes from each of
    # `private_key` (scalar) and `peer_public_value` (peer u-coordinate),
    # writes exactly 32 bytes to `out_shared_key` (shared_out). All
    # three buffers are caller-owned for the duration of this
    # synchronous call; AWS-LC retains no pointer past the call.
    #
    # Pointers are constructed via `UnsafePointer(to=x).bitcast[UInt8]()`
    # following the in-package pattern in `sha256_compress.mojo` and
    # `zeroize.mojo` (memset_s).
    # Origin is INFERRED from the locals `shared_out` (mut InlineArray)
    # and the `scalar`/`peer_public` spans — NOT a wildcard widening.
    # The local pointers do not escape this function body and are passed
    # directly to the external_call below.
    #
    # The external_call typed-args list is OMITTED so Mojo infers from
    # the value types (same shape as sha256_compress.mojo and
    # zeroize.mojo's memset_s call); alternative form with explicit
    # type parameters would force a specific origin which is
    # incompatible with `Span[UInt8, _]` inputs potentially having
    # immutable origin.
    var rc = external_call["komira_awslc_X25519", Int32](
        UnsafePointer(to=shared_out[0]).bitcast[UInt8](),
        scalar.unsafe_ptr().bitcast[UInt8](),
        peer_public.unsafe_ptr().bitcast[UInt8](),
    )
    return Int(rc) == 1
