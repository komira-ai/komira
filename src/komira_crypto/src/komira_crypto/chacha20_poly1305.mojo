# =============================================================================
# komira_crypto/chacha20_poly1305.mojo — ChaCha20-Poly1305 AEAD (AWS-LC FFI)
# =============================================================================
#
# ChaCha20-Poly1305 delegates to AWS-LC's high-level EVP_AEAD path, the
# same shape as AES-GCM (`internal/asm/aes_gcm_ffi.mojo` + `aes_gcm.mojo`).
#
# # Public surface
#
#   * ChaCha20Poly1305(key: InlineArray[UInt8, 32])
#   * ChaCha20Poly1305.seal_in_place(nonce, aad, plaintext_then_tag) raises
#   * ChaCha20Poly1305.open_in_place(nonce, aad, ciphertext_then_tag) raises
#   * KEY_SIZE / NONCE_SIZE / TAG_SIZE / SEQUENCE_LIMIT aliases
#
# # Where the work happens
#
# All cryptographic work (ChaCha20 stream encryption + Poly1305 MAC +
# AEAD framing per RFC 8439 §2.8) is performed by AWS-LC's hand-tuned
# `ChaCha20_ctr32_neon` + NEON Poly1305 (on AArch64) or
# `chacha20_poly1305_seal_avx2` (on x86-64 with AVX2), invoked via the
# FFI wrapper at `internal/asm/chacha20_poly1305_ffi.mojo`. The wrapper
# exposes the `ChaCha20Poly1305Ctx` opaque struct; this file's
# ChaCha20Poly1305 holds one such field and delegates seal/open to it.
#
# # SEQUENCE_LIMIT
#
# Per RFC 8446 §5.5 + [AEAD-LIMITS]: ChaCha20-Poly1305 is capped at
# 2^48 records per key (vs AES-GCM's 2^24) — ChaCha20 has a much larger
# sequence space without compromising the AEAD security bound, so the
# limit is set high for KeyUpdate hygiene only. A TLS record layer
# enforces this per record.
#
# # Encapsulation invariants
#
#   * ZERO UnsafePointer in any public method signature.
#   * ZERO wildcard origins (Span[UInt8, _] is origin-inferred per call
#     site; NOT wildcard widening).
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO new ArcPointer sites.
#   * Secret-bearing state (the 32-byte key inside AWS-LC's CTX) is
#     zeroized by AWS-LC's `EVP_AEAD_CTX_free` (called from
#     `ChaCha20Poly1305Ctx.__del__`). There is no Mojo-side secret
#     material to zeroize.
# =============================================================================

from komira_crypto.traits import Aead
from komira_crypto.internal.asm.chacha20_poly1305_ffi import (
    ChaCha20Poly1305Ctx,
)


# -----------------------------------------------------------------------------
# ChaCha20Poly1305 — Aead conformer per RFC 8439 §2.8 (FFI delegation)
# -----------------------------------------------------------------------------


struct ChaCha20Poly1305(Aead, Movable, Deinitable):
    """ChaCha20-Poly1305 AEAD (RFC 8439 §2.8) via AWS-LC FFI delegation.

    Conformer of the `Aead` trait (declared in `traits.mojo`).
    Delegates all cryptographic work to AWS-LC's hand-tuned EVP_AEAD
    ChaCha20-Poly1305 path via the `ChaCha20Poly1305Ctx` opaque
    wrapper at `internal/asm/chacha20_poly1305_ffi.mojo`.

    Field layout:
      _ctx: ChaCha20Poly1305Ctx — opaque wrapper around AWS-LC's
            EVP_AEAD_CTX. Holds the 32-byte key + any precomputed
            Poly1305-init state inside AWS-LC's heap allocation.
            Zeroized on drop by EVP_AEAD_CTX_free.

    Usage:
        var k = InlineArray[UInt8, 32](fill=UInt8(0))
        # ... populate k ...
        var cipher = ChaCha20Poly1305(k)
        var buf = ...  # [plaintext (N-16)][tag (16)]
        var nonce = InlineArray[UInt8, 12](fill=UInt8(0))
        cipher.seal_in_place(nonce, aad, buf)
        # ... transmit buf ...
        # Decrypt:
        cipher.open_in_place(nonce, aad, buf)  # raises on tag failure

    `SEQUENCE_LIMIT = 1 << 48` per RFC 8446 §5.5 + [AEAD-LIMITS]. A TLS
    record layer enforces this per record.

    Constant-time: AWS-LC's `ChaCha20_ctr32_neon` is constant-time by
    construction (no LUTs; pure arithmetic + bit ops on SIMD registers).
    NEON Poly1305 is constant-time (Bernstein's `poly1305-donna`-style
    constant-time modular reduction). Tag verification inside
    EVP_AEAD_CTX_open is constant-time (memcmp_neq returning early on
    inequality is the documented exception, but for the auth-fail
    code path the timing leak is the same regardless of which bit
    differs first — accepted by this AEAD's threat model).

    # Non-Copyable
    Copying secret key material is a leak. The struct is Movable
    (for trait conformance / container storage) but never Copyable.
    """

    comptime KEY_SIZE: Int = 32
    comptime NONCE_SIZE: Int = 12
    comptime TAG_SIZE: Int = 16
    comptime SEQUENCE_LIMIT: UInt64 = UInt64(1) << 48
    """RFC 8446 §5.5 + [AEAD-LIMITS]: ~2^48 records
    per key for ChaCha20-Poly1305 (much higher than AES-GCM's 2^24
    because ChaCha20's stream-cipher security bound doesn't shrink
    with sequence). A TLS record layer enforces it; this alias is
    informational."""

    var _ctx: ChaCha20Poly1305Ctx
    """Opaque AWS-LC EVP_AEAD_CTX wrapper. Owns the 32-byte key +
    any precomputed Poly1305-init state inside AWS-LC's heap
    allocation. Zeroized on drop by EVP_AEAD_CTX_free."""

    def __init__(out self, key: Array[UInt8, 32]):
        """Construct a ChaCha20-Poly1305 cipher from a 256-bit key.

        Delegates to `ChaCha20Poly1305Ctx(key_span)`. AWS-LC's
        `EVP_AEAD_CTX_new` copies the key into the CTX + may
        precompute internal state.

        Non-raising to match the `Aead` trait signature. AWS-LC's
        `EVP_AEAD_CTX_new` only returns NULL under OOM;
        ChaCha20Poly1305Ctx debug_asserts on NULL (process-level
        invariant).
        """
        var key_span = Span[UInt8, origin_of(key)](key)
        self._ctx = ChaCha20Poly1305Ctx(key_span)

    @always_inline
    def seal_in_place[
        o: Origin[mut=True]
    ](
        mut self,
        nonce: Array[UInt8, 12],
        aad: Span[UInt8, _],
        plaintext_then_tag: Span[UInt8, o],
    ) raises:
        """Encrypt-and-authenticate in place per RFC 8439 §2.8.

        `plaintext_then_tag` layout: [plaintext (N-16 bytes)][tag (16
        bytes uninitialized)]. Post-call: plaintext replaced with
        ciphertext; tag region filled with the 16-byte Poly1305 tag.

        Delegates to `ChaCha20Poly1305Ctx.seal_in_place` which invokes
        AWS-LC's `EVP_AEAD_CTX_seal` (in-place via aliasing semantic).

        """
        self._ctx.seal_in_place(nonce, aad, plaintext_then_tag)

    @always_inline
    def open_in_place[
        o: Origin[mut=True]
    ](
        mut self,
        nonce: Array[UInt8, 12],
        aad: Span[UInt8, _],
        ciphertext_then_tag: Span[UInt8, o],
    ) raises:
        """Verify-and-decrypt in place per RFC 8439 §2.8.

        `ciphertext_then_tag` layout: [ciphertext (N-16 bytes)][tag (16
        bytes)]. Post-success: ciphertext replaced with plaintext.
        Post-failure: RAISES "authentication failure" — AWS-LC's
        `EVP_AEAD_CTX_open` performs verify-then-decrypt order per
        the AEAD contract (constant-time-compare tag; emit plaintext ONLY on
        auth success; zero output on failure).

        Delegates to `ChaCha20Poly1305Ctx.open_in_place`.
        """
        self._ctx.open_in_place(nonce, aad, ciphertext_then_tag)

    # No __del__ — ChaCha20Poly1305Ctx handles AWS-LC CTX cleanup via
    # its own __del__ which calls EVP_AEAD_CTX_free (zeroizes the
    # secret-bearing state + frees the heap CTX).
