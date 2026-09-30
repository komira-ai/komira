# =============================================================================
# komira_crypto/aes_gcm.mojo — AES-128-GCM + AES-256-GCM (AWS-LC FFI delegation)
# =============================================================================
#
# AES-GCM delegates to AWS-LC's high-level EVP_AEAD path, the same shape as
# the SHA-256 compression primitive (`internal/asm/sha256_compress.mojo`).
#
# # Public surface
#
#   * AesGcm128(key: InlineArray[UInt8, 16])
#   * AesGcm128.seal_in_place(nonce, aad, plaintext_then_tag) raises
#   * AesGcm128.open_in_place(nonce, aad, ciphertext_then_tag) raises
#   * KEY_SIZE / NONCE_SIZE / TAG_SIZE / SEQUENCE_LIMIT aliases
# (Same for AesGcm256 with KEY_SIZE=32.)
#
# # Where the work happens
#
# All AES + GHASH cryptographic work is performed by AWS-LC's hand-tuned
# AArch64 `aes_hw_*` + `gcm_*_neon` (or x86 AES-NI + PCLMULQDQ) path,
# invoked via the FFI wrapper at `internal/asm/aes_gcm_ffi.mojo`. The
# wrapper exposes the `AesGcmCtx[KEY_SIZE]` opaque struct; AesGcm128 +
# AesGcm256 hold one such field and delegate seal/open to it. AWS-LC's
# `aes_hw_encrypt` applies the initial AddRoundKey(K0) that FIPS 197 §5.1
# requires; this file never touches the AES round body.
#
# # SEQUENCE_LIMIT
#
# `SEQUENCE_LIMIT = UInt64(1) << 24` per RFC 8446 §5.5 + [AEAD-LIMITS].
# A TLS record layer enforces it (asserting `_seq < A.SEQUENCE_LIMIT`
# before sealing); AesGcm128 / AesGcm256 only provide the correct alias.
#
# # Encapsulation invariants
#
#   * ZERO UnsafePointer in any public method signature.
#   * ZERO wildcard origins (Span[UInt8, _] is origin-inferred per call
#     site; NOT wildcard widening).
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO new ArcPointer sites.
#   * Secret-bearing state (AWS-LC's internal expanded key schedule +
#     GHASH H table) is zeroized by AWS-LC's `EVP_AEAD_CTX_free` (called
#     from `AesGcmCtx.__del__`). There is no Mojo-side secret material to
#     zeroize (all of it lives inside AWS-LC's opaque CTX).
# =============================================================================

from komira_crypto.traits import Aead
from komira_crypto.internal.asm.aes_gcm_ffi import AesGcmCtx


# -----------------------------------------------------------------------------
# AesGcm128 — AES-128-GCM conforming to `Aead` trait
# -----------------------------------------------------------------------------


struct AesGcm128(Aead, Movable, Deinitable):
    """AES-128-GCM streaming AEAD via AWS-LC FFI (NIST SP 800-38D).

    Conformer of the `Aead` trait (declared in `traits.mojo`).
    Delegates all cryptographic work to AWS-LC's hand-tuned EVP_AEAD
    AES-128-GCM path via the `AesGcmCtx[16]` opaque wrapper at
    `internal/asm/aes_gcm_ffi.mojo`.

    Field layout:
      _ctx: AesGcmCtx[16] — opaque wrapper around AWS-LC's EVP_AEAD_CTX.
            Holds the expanded AES-128 key schedule + GHASH H table
            inside AWS-LC's heap allocation. Zeroized on drop by
            EVP_AEAD_CTX_free.

    Usage:
        var k = InlineArray[UInt8, 16](fill=UInt8(0))
        # ... populate k ...
        var cipher = AesGcm128(k)
        var buf = ...  # [plaintext (N-16)][tag (16)]
        var nonce = InlineArray[UInt8, 12](fill=UInt8(0))
        cipher.seal_in_place(nonce, aad, buf)
        # ... transmit buf ...
        # Decrypt:
        cipher.open_in_place(nonce, aad, buf)  # raises on tag failure

    `SEQUENCE_LIMIT = 1 << 24` per RFC 8446 §5.5 + [AEAD-LIMITS]. A TLS
    record layer enforces this per record.

    Constant-time: AWS-LC's `aes_hw_*` path is constant-time by hardware
    contract (AArch64 `aese`/`aesmc` Crypto Extensions + x86 AES-NI).
    GHASH via `gcm_ghash_neon` (pmull64) is constant-time. Tag
    verification inside EVP_AEAD_CTX_open is constant-time.
    """

    comptime KEY_SIZE: Int = 16
    comptime NONCE_SIZE: Int = 12
    comptime TAG_SIZE: Int = 16
    comptime SEQUENCE_LIMIT: UInt64 = UInt64(1) << 24
    """RFC 8446 §5.5 / [AEAD-LIMITS]: ~16M records per key for AES-GCM
    with 16-byte tags. A TLS record layer asserts
    `_seq < SEQUENCE_LIMIT` before incrementing the sequence counter;
    on hit, the connection MUST initiate KeyUpdate."""

    var _ctx: AesGcmCtx[16]
    """Opaque AWS-LC EVP_AEAD_CTX wrapper. Owns the expanded key schedule
    + GHASH H table inside AWS-LC's heap allocation."""

    def __init__(out self, key: Array[UInt8, 16]):
        """Construct an AES-128-GCM cipher from a 128-bit key.

        Delegates to `AesGcmCtx[16](key_span)`. AWS-LC's
        `EVP_AEAD_CTX_new` expands the key schedule + computes the
        GHASH hash key H = AES_K(0^128) internally.

        Non-raising to match the `Aead` trait signature. AWS-LC's
        `EVP_AEAD_CTX_new` only returns NULL under OOM; AesGcmCtx
        debug_asserts on NULL (process-level invariant).
        """
        var key_span = Span[UInt8, origin_of(key)](key)
        self._ctx = AesGcmCtx[16](key_span)

    @always_inline
    def seal_in_place[o: Origin[mut=True]](
        mut self,
        nonce: Array[UInt8, 12],
        aad: Span[UInt8, _],
        plaintext_then_tag: Span[UInt8, o],
    ) raises:
        """Encrypt-and-authenticate in place per NIST SP 800-38D §7.1.

        `plaintext_then_tag` layout: [plaintext (N-16 bytes)][tag (16
        bytes uninitialized)]. Post-call: plaintext replaced with
        ciphertext; tag region filled with the 16-byte auth tag.

        Delegates to `AesGcmCtx[16].seal_in_place` which invokes
        AWS-LC's `EVP_AEAD_CTX_seal` (in-place via aliasing semantic).

        """
        self._ctx.seal_in_place(nonce, aad, plaintext_then_tag)

    @always_inline
    def open_in_place[o: Origin[mut=True]](
        mut self,
        nonce: Array[UInt8, 12],
        aad: Span[UInt8, _],
        ciphertext_then_tag: Span[UInt8, o],
    ) raises:
        """Verify-and-decrypt in place per NIST SP 800-38D §7.2.

        `ciphertext_then_tag` layout: [ciphertext (N-16 bytes)][tag (16
        bytes)]. Post-success: ciphertext replaced with plaintext.
        Post-failure: RAISES "authentication failure" — AWS-LC's
        `EVP_AEAD_CTX_open` performs verify-then-decrypt order per
        the AEAD contract (constant-time-compare tag; emit plaintext ONLY on
        auth success; zero output on failure).

        Delegates to `AesGcmCtx[16].open_in_place`.
        """
        self._ctx.open_in_place(nonce, aad, ciphertext_then_tag)

    # No __del__ — AesGcmCtx handles AWS-LC CTX cleanup via its own
    # __del__ which calls EVP_AEAD_CTX_free (zeroizes secret state +
    # frees the heap CTX).


# -----------------------------------------------------------------------------
# AesGcm256 — AES-256-GCM conforming to `Aead` trait
# -----------------------------------------------------------------------------


struct AesGcm256(Aead, Movable, Deinitable):
    """AES-256-GCM streaming AEAD via AWS-LC FFI (NIST SP 800-38D).

    Same shape as `AesGcm128` with 32-byte key and AES-256 key schedule.
    Delegates to `AesGcmCtx[32]` which routes through AWS-LC's
    `EVP_aead_aes_256_gcm` method.
    """

    comptime KEY_SIZE: Int = 32
    comptime NONCE_SIZE: Int = 12
    comptime TAG_SIZE: Int = 16
    comptime SEQUENCE_LIMIT: UInt64 = UInt64(1) << 24

    var _ctx: AesGcmCtx[32]

    def __init__(out self, key: Array[UInt8, 32]):
        """Construct an AES-256-GCM cipher from a 256-bit key.

        Same shape as `AesGcm128.__init__`; uses `EVP_aead_aes_256_gcm`
        method via `AesGcmCtx[32]`. Non-raising to match the `Aead`
        trait signature.
        """
        var key_span = Span[UInt8, origin_of(key)](key)
        self._ctx = AesGcmCtx[32](key_span)

    @always_inline
    def seal_in_place[o: Origin[mut=True]](
        mut self,
        nonce: Array[UInt8, 12],
        aad: Span[UInt8, _],
        plaintext_then_tag: Span[UInt8, o],
    ) raises:
        """Encrypt-and-authenticate in place (NIST SP 800-38D §7.1)."""
        self._ctx.seal_in_place(nonce, aad, plaintext_then_tag)

    @always_inline
    def open_in_place[o: Origin[mut=True]](
        mut self,
        nonce: Array[UInt8, 12],
        aad: Span[UInt8, _],
        ciphertext_then_tag: Span[UInt8, o],
    ) raises:
        """Verify-and-decrypt in place (NIST SP 800-38D §7.2)."""
        self._ctx.open_in_place(nonce, aad, ciphertext_then_tag)
