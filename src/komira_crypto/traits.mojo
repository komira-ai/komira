# =============================================================================
# komira_crypto/traits.mojo — primary trait declarations
# =============================================================================
#
# Trait declarations for the three core abstractions of komira_crypto:
#   * Hash         — streaming hash function (Sha256 / Sha384 / Sha512)
#   * Aead         — authenticated encryption (AesGcm128/256 / ChaCha20Poly1305)
#   * KeySchedule  — TLS 1.3 key schedule (RFC 8446 §7.1)
#
# The trait surface lives in its own module so that conformers and their
# consumers can be written independently, with no circular dependency.
#
# Signature conventions:
#   * An explicit `[o: Origin[mut=True]]` parameter on mutable Span method
#     args (the bare `mut out: Span[UInt8, mut=True, _]` form does not
#     parse).
#   * `fork(self) -> Self` is declared on Hash (not just an implementation
#     convention) so a TLS transcript-hash flow can call it generically.
#   * `@always_inline` on the Aead seal/open trait methods. The annotation
#     must persist across a package boundary into the conformer impls, or
#     the monomorphization it exists for is lost.
#   * `SEQUENCE_LIMIT: UInt64` per-AEAD on the trait. RFC 8446 §5.5
#     + [AEAD-LIMITS]: AES-GCM 2^24, ChaCha20-Poly1305 capped at 2^48.
#
# Encapsulation invariants:
#   * No UnsafePointer in any signature.
#   * No wildcard origins — every Span has an explicit named Origin parameter
#     OR uses `_` (which infers a fresh concrete origin per call site;
#     this is NOT a wildcard widening).
#   * Trait conformers must be `Movable, Deinitable` (no Copyable —
#     copying secret material is a leak).
# =============================================================================

# -----------------------------------------------------------------------------
# Hash trait
# -----------------------------------------------------------------------------

trait Hash(Movable, Deinitable):
    """A streaming hash function.

Conformers:

  * Sha256  — OUTPUT_SIZE=32, BLOCK_SIZE=64

  * Sha384  — OUTPUT_SIZE=48, BLOCK_SIZE=128

  * Sha512  — OUTPUT_SIZE=64, BLOCK_SIZE=128


The block size and output size are comptime-known so callers can

stack-allocate output buffers (InlineArray[UInt8, H.OUTPUT_SIZE]) and

stage SIMD body work against the known constants.


Forkability: `fork(self) -> Self` clones the streaming state without

consuming it. A TLS transcript hash snapshots the running hash at

multiple transcript points without losing the ability to absorb more

messages.
    """

    comptime OUTPUT_SIZE: Int
    """Digest size in bytes. 32 for SHA-256, 48 for SHA-384, 64 for SHA-512."""

    comptime BLOCK_SIZE: Int
    """Compression block size in bytes. 64 for SHA-256, 128 for SHA-384/512."""

    def __init__(out self):
        """Construct an empty hash state."""
        ...

    def update(mut self, data: Span[UInt8, _]):
        """Absorb `data` into the streaming state.

        Span[UInt8, _] takes a fresh origin per call site (no wildcard
        widening). The caller's buffer must outlive this call.
        """
        ...

    def finalize_into[o: Origin[mut=True]](
        mut self,
        dst: Span[UInt8, o],
    ):
        """Emit the final digest into `dst`.

        `dst` MUST have length >= Self.OUTPUT_SIZE. Conformers may relax
        the contract and accept exactly OUTPUT_SIZE.

        An explicit `[o: Origin[mut=True]]` parameter is REQUIRED; the bare
        `mut dst: Span[UInt8, mut=True, _]` form does not parse.

        Param name is `dst` not `out`: `out` is a reserved arg-convention
        keyword on Mojo 1.0.0b1 (replaces 0.26.3's `inout self`).
        """
        ...

    def reset(mut self):
        """Reset the streaming state to empty (post-init state)."""
        ...

    def fork(self) -> Self:
        """Clone the streaming state.

        Required as a trait method (not just an implementation convention):
        a TLS transcript-hash flow calls it generically through the Hash
        trait surface.
        """
        ...


# -----------------------------------------------------------------------------
# Aead trait
# -----------------------------------------------------------------------------

trait Aead(Movable, Deinitable):
    """An authenticated-encryption-with-associated-data primitive.

    Conformers:
      * AesGcm128         — KEY_SIZE=16, NONCE_SIZE=12, TAG_SIZE=16,
                            SEQUENCE_LIMIT=2^24 (RFC 8446 §5.5)
      * AesGcm256         — KEY_SIZE=32, NONCE_SIZE=12, TAG_SIZE=16,
                            SEQUENCE_LIMIT=2^24
      * ChaCha20Poly1305  — KEY_SIZE=32, NONCE_SIZE=12, TAG_SIZE=16,
                            SEQUENCE_LIMIT=2^48 (KeyUpdate hygiene cap)

    KEY_SIZE / NONCE_SIZE / TAG_SIZE / SEQUENCE_LIMIT are comptime
    constants so a TLS record layer can stack-allocate the nonce
    buffer and assert sequence-counter bounds at compile time.

    The per-AEAD sequence limit is a HARD bound, not advisory. AES-GCM:
    ~2^24 records per RFC 8446 §5.5 + [AEAD-LIMITS] (2^32 would be 170x
    past the safety margin). ChaCha20-Poly1305: effectively unbounded; it
    is capped at 2^48 records for KeyUpdate hygiene. A record layer's
    `seal_record` asserts `_seq < SEQUENCE_LIMIT` and triggers KeyUpdate
    before exceeding.
    """

    comptime KEY_SIZE: Int
    """Symmetric key size in bytes."""

    comptime NONCE_SIZE: Int
    """Nonce size in bytes. Always 12 for TLS 1.3 AEADs (RFC 8446 §5.3)."""

    comptime TAG_SIZE: Int
    """Authentication tag size in bytes. Always 16 for TLS 1.3 AEADs."""

    comptime SEQUENCE_LIMIT: UInt64
    """Per-key record-count limit before KeyUpdate is REQUIRED.

    Per RFC 8446 §5.5 + [AEAD-LIMITS]. A record layer asserts it before
    incrementing `_seq`; on hit, the conformer raises
    SequenceLimitExceeded and the connection MUST initiate KeyUpdate.
    """

    def __init__(out self, key: Array[UInt8, Self.KEY_SIZE]):
        """Construct from a comptime-fixed-size key.

        InlineArray takes the key by value (stack-allocated); the
        conformer's body MUST zero the input on drop via
        `zeroize_inline_array[Self.KEY_SIZE]`.
        """
        ...

    @always_inline
    def seal_in_place[o: Origin[mut=True]](
        mut self,
        nonce: Array[UInt8, Self.NONCE_SIZE],
        aad: Span[UInt8, _],
        plaintext_then_tag: Span[UInt8, o],
    ) raises:
        """Encrypt-and-authenticate in place.

        `plaintext_then_tag` is a single contiguous buffer:
          [plaintext (len-TAG_SIZE bytes)][tag (TAG_SIZE bytes)]

        Pre-condition: the trailing TAG_SIZE bytes are uninitialized.
        Post-condition: plaintext region replaced with ciphertext; tag
        region filled with the authentication tag.

        This shape matches the TLS 1.3 record format byte-for-byte so the
        record-layer body is a thin tag-check around the AEAD call.

        An explicit `[o: Origin[mut=True]]` parameter is REQUIRED.

        `@always_inline` is load-bearing: a record layer calls these across
        a package boundary, and the annotation must persist into the
        conformer impls.
        """
        ...

    @always_inline
    def open_in_place[o: Origin[mut=True]](
        mut self,
        nonce: Array[UInt8, Self.NONCE_SIZE],
        aad: Span[UInt8, _],
        ciphertext_then_tag: Span[UInt8, o],
    ) raises:
        """Verify-and-decrypt in place.

        `ciphertext_then_tag` layout: [ciphertext][tag].

        Post-condition (success): ciphertext region replaced with plaintext;
        tag region is implementation-defined garbage (do NOT read).
        Post-condition (auth failure): RAISES; buffer contents are
        implementation-defined garbage (the AEAD layer guarantees no
        plaintext leaks on auth failure).

        Tag comparison MUST be constant-time (no early-exit on byte mismatch).
        """
        ...


# -----------------------------------------------------------------------------
# KeySchedule trait — TLS 1.3 key schedule (RFC 8446 §7.1)
# -----------------------------------------------------------------------------
#
# The KeySchedule structure stores the early/handshake/master secrets and
# their derivatives (client_hs/server_hs/client_ap/server_ap traffic secrets).
# Implementations are parametric on `H: Hash` — the hash's OUTPUT_SIZE
# determines secret-buffer size.
#
# Method bodies on a conformer call HKDF + HKDF-Expand-Label internally;
# the trait surface only constrains the "what TLS 1.3 expects to call on a
# key schedule" public API.
#
# Per RFC 8446 §7.1 the schedule has:
#   1. derive_early_secret(psk)
#   2. derive_handshake_secret(ecdhe)
#   3. derive_master_secret()
#   4. derive_client_hs_traffic_secret(transcript_hash)
#   5. derive_server_hs_traffic_secret(transcript_hash)
#   6. derive_client_ap_traffic_secret(transcript_hash)
#   7. derive_server_ap_traffic_secret(transcript_hash)
#   8. derive_exporter_master_secret(transcript_hash)
#   9. derive_resumption_master_secret(transcript_hash)
#
# Each method takes Span[UInt8, _] inputs and either mutates internal
# secret state (1-3) or writes a derived secret into an out buffer (4-9).
#
# Zero-on-drop: KeySchedule's `__del__` MUST call zeroize_inline_array
# on every secret field.
# -----------------------------------------------------------------------------

trait KeySchedule(Movable, Deinitable):
    """TLS 1.3 key schedule (RFC 8446 §7.1).

    A conformer (e.g. `KeyScheduleImpl[H: Hash]`) is comptime-parametric
    on the negotiated hash (Sha256 / Sha384), stack-allocates secret
    buffers as `InlineArray[UInt8, H.OUTPUT_SIZE]`, and instantiates HKDF
    + HKDF-Expand-Label internally.

    Output buffers (derive_*_traffic_secret + derive_*_master_secret):
    callers pass an out-Span sized to H.OUTPUT_SIZE bytes; the conformer
    raises BufferTooSmall on under-sized inputs.

    Every conformer's __del__ MUST zero every secret field
    via `zeroize_inline_array[H.OUTPUT_SIZE]` for each tracked secret.
    """

    comptime OUTPUT_SIZE: Int
    """The hash's OUTPUT_SIZE — secret buffers are this many bytes."""

    # -------------------------------------------------------------------------
    # Stage 1-3: stateful derivation of the three master secrets.
    # Each consumes the previous stage's internal secret state.
    # -------------------------------------------------------------------------

    def derive_early_secret(mut self, psk: Span[UInt8, _]):
        """Stage 1: Early-Secret = HKDF-Extract(0, PSK).

        If no PSK (most TLS 1.3 handshakes), pass an empty Span. The
        conformer substitutes 0^OUTPUT_SIZE per RFC 8446 §7.1.
        """
        ...

    def derive_handshake_secret(mut self, ecdhe: Span[UInt8, _]):
        """Stage 2: Handshake-Secret = HKDF-Extract(
                       Derive-Secret(Early-Secret, "derived", ""),
                       ECDHE).

        The second `Derive-Secret(_, "derived", "")` between Early/Handshake
        AND Handshake/Master stages MUST both be applied; omitting either is
        a known key-schedule bug.
        """
        ...

    def derive_master_secret(mut self):
        """Stage 3: Master-Secret = HKDF-Extract(
                       Derive-Secret(Handshake-Secret, "derived", ""),
                       0^OUTPUT_SIZE).
        """
        ...

    # -------------------------------------------------------------------------
    # Stage 4-9: per-direction / exporter / resumption traffic secrets.
    # Each takes a transcript-hash input and writes the derived secret out.
    # -------------------------------------------------------------------------

    def derive_client_hs_traffic_secret[o: Origin[mut=True]](
        self,
        transcript_hash: Span[UInt8, _],
        dst: Span[UInt8, o],
    ):
        """`client_handshake_traffic_secret` = Derive-Secret(
              Handshake-Secret, "c hs traffic", ClientHello..ServerHello)."""
        ...

    def derive_server_hs_traffic_secret[o: Origin[mut=True]](
        self,
        transcript_hash: Span[UInt8, _],
        dst: Span[UInt8, o],
    ):
        """`server_handshake_traffic_secret` = Derive-Secret(
              Handshake-Secret, "s hs traffic", ClientHello..ServerHello)."""
        ...

    def derive_client_ap_traffic_secret[o: Origin[mut=True]](
        self,
        transcript_hash: Span[UInt8, _],
        dst: Span[UInt8, o],
    ):
        """`client_application_traffic_secret_0` = Derive-Secret(
              Master-Secret, "c ap traffic", ClientHello..server Finished).
        """
        ...

    def derive_server_ap_traffic_secret[o: Origin[mut=True]](
        self,
        transcript_hash: Span[UInt8, _],
        dst: Span[UInt8, o],
    ):
        """`server_application_traffic_secret_0` = Derive-Secret(
              Master-Secret, "s ap traffic", ClientHello..server Finished).
        """
        ...
