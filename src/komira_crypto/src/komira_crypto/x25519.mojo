# =============================================================================
# komira_crypto/x25519.mojo — X25519 scalar multiplication (RFC 7748 §5)
# =============================================================================
#
# Public X25519 API. The implementation body delegates to AWS-LC's
# hand-tuned `X25519` symbol via `internal/asm/x25519_ffi.mojo`, so its
# performance is AWS-LC's.
#
# # Public API
#
#   fn x25519(scalar, u) -> InlineArray[UInt8, 32]
#   fn x25519_base_mult(scalar) -> InlineArray[UInt8, 32]
#
# Both are non-raising, which keeps a TLS handshake's key-share call sites
# free of error plumbing.
#
# # Small-order handling (RFC 7748 §6.1)
#
# RFC 7748 §6.1 specifies that implementations MAY check whether the
# shared secret is all-zero (the small-order rejection case) and SHOULD
# return failure if it is. AWS-LC's `X25519` returns `int 0` to signal
# this case; the public wrapper keeps the documented all-zero output
# contract by explicitly zeroing the output buffer when the FFI returns
# False (defensive — independent of whatever AWS-LC may have written).
#
# `tests/test_x25519_small_order.mojo` pins this behaviour.
#
# # Encapsulation discipline
#
#   * ZERO UnsafePointer in any public function signature.
#   * ZERO wildcard origins — `Span[UInt8, _]` is origin-inferred per
#     call site (NOT wildcard widening).
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * The FFI binding is in `internal/asm/x25519_ffi.mojo` (per the
#     `internal/asm/` carve-out convention; same shape as
#     `sha256_compress.mojo` + `aes_gcm_ffi.mojo` +
#     `chacha20_poly1305_ffi.mojo`).
# =============================================================================

from .internal.asm import x25519_scalarmult


# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------


def x25519(scalar: Span[UInt8, _], u: Span[UInt8, _]) -> Array[UInt8, 32]:
    """X25519 scalar multiplication per RFC 7748 §5.

    Args:
        scalar: 32-byte little-endian scalar (caller-owned; must be ≥32 bytes).
        u: 32-byte little-endian u-coordinate of input point.

    Returns:
        32-byte u-coordinate of k * P, where k is the clamped scalar.
        On small-order rejection (per RFC 7748 §6.1), returns all-zero
        bytes.

    The scalar clamping (`k &= ~7`, set bit 254, clear bit 255 per
    RFC 7748 §5) and the u-coordinate top-bit clearing are performed
    inside AWS-LC's `X25519` implementation.

    # Encapsulation
    Public API takes `Span[UInt8, _]` (origin-inferred). No UnsafePointer.
    No wildcard origins.

    # Constant-time
    AWS-LC's X25519 is constant-time per FIPS 140-3 design (used in
    AWS-LC's FIPS-validated module). The implementation uses a
    Montgomery ladder with mask-based conditional swaps + a fixed
    addition chain for modular inverse.

    # Performance
    Matches AWS-LC `X25519` byte-identically (this IS the AWS-LC
    implementation called via FFI). Per-call overhead vs a
    direct external_call: a few nanoseconds (Mojo's FFI dispatch +
    InlineArray init).
    """
    var out = Array[UInt8, 32](fill=UInt8(0))
    var ok = x25519_scalarmult(scalar, u, out)
    if not ok:
        # Defensive zeroize: ensure the documented all-zero output
        # contract holds on small-order rejection (RFC 7748 §6.1),
        # regardless of what AWS-LC may have written to the buffer
        # before signaling failure via the int 0 return.
        for i in range(32):
            out[i] = UInt8(0)
    return out^


def x25519_base_mult(scalar: Span[UInt8, _]) -> Array[UInt8, 32]:
    """X25519 scalar multiplication by the curve25519 base point (u=9).

    Used for keypair generation: `privkey = scalar` (random 32 bytes),
    `pubkey = x25519_base_mult(privkey)`.

    # Constant-time
    Same CT guarantees as `x25519`. The base point u=9 is a constant
    (publicly known) — no branch on it.
    """
    var base = Array[UInt8, 32](fill=UInt8(0))
    base[0] = UInt8(9)
    var base_span = Span[UInt8, origin_of(base)](base)
    return x25519(scalar, base_span)
