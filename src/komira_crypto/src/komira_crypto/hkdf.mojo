# =============================================================================
# komira_crypto/hkdf.mojo — HKDF[H: Hash] per RFC 5869 + TLS 1.3 RFC 8446 §7.1
# =============================================================================
#
# RFC 5869 Extract + Expand delegate to AWS-LC's HKDF_extract +
# HKDF_expand. The TLS 1.3 wrappers (HKDF-Expand-Label + Derive-Secret)
# keep their HkdfLabel struct serialization in Mojo (the RFC 8446 §7.1
# byte layout is application-protocol-level; AWS-LC's HKDF doesn't expose
# a label form).
#
# Public surface:
#   * Hkdf[H: Hash].extract(salt, ikm) -> InlineArray
#   * Hkdf[H: Hash].expand(prk, info, dst)
#   * Hkdf[H: Hash].hkdf_expand_label(secret, label, context, dst)
#   * Hkdf[H: Hash].derive_secret(secret, label, messages, dst)
# =============================================================================

from komira_crypto.traits import Hash
from komira_crypto.internal.asm.hkdf_ffi import (
    hkdf_extract_ffi,
    hkdf_expand_ffi,
)


struct Hkdf[H: Hash](Movable, Deinitable):
    """RFC 5869 HKDF over any `H: Hash` conformer.

    Stateless namespace struct (instances never constructed). Backed
    by AWS-LC's HKDF_extract + HKDF_expand for the core RFC 5869
    primitives; TLS 1.3-specific wrappers in Mojo for the §7.1
    HKDFLabel byte-layout (AWS-LC has no equivalent symbol).
    """

    comptime OUTPUT_SIZE: Int = Self.H.OUTPUT_SIZE

    # -------------------------------------------------------------------------
    # HKDF-Extract — RFC 5869 §2.2
    # -------------------------------------------------------------------------

    @staticmethod
    def extract(
        salt: Span[UInt8, _],
        ikm: Span[UInt8, _],
    ) -> Array[UInt8, Self.H.OUTPUT_SIZE]:
        """HKDF-Extract(salt, IKM) via AWS-LC's HKDF_extract.

        RFC 5869 §2.2: PRK = HMAC-Hash(salt, IKM). Empty salt is
        substituted with HashLen bytes of zero (handled internally by
        AWS-LC).
        """
        return hkdf_extract_ffi[Self.H.OUTPUT_SIZE](salt, ikm)

    # -------------------------------------------------------------------------
    # HKDF-Expand — RFC 5869 §2.3
    # -------------------------------------------------------------------------

    @staticmethod
    def expand[o: Origin[mut=True]](
        prk: Span[UInt8, _],
        info: Span[UInt8, _],
        dst: Span[UInt8, o],
    ) raises:
        """HKDF-Expand(PRK, info, L) via AWS-LC's HKDF_expand.

        L = len(dst). Per RFC 5869 §2.3: L <= 255 * HashLen. Raises if
        L exceeds.
        """
        var l = len(dst)
        if l == 0:
            return
        if l > 255 * Self.H.OUTPUT_SIZE:
            raise Error(
                String("HKDF-Expand: requested length exceeds 255 * HashLen")
            )
        hkdf_expand_ffi[Self.H.OUTPUT_SIZE](prk, info, dst)

    # -------------------------------------------------------------------------
    # HKDF-Expand-Label — TLS 1.3 RFC 8446 §7.1
    # -------------------------------------------------------------------------

    @staticmethod
    def hkdf_expand_label[o: Origin[mut=True]](
        secret: Span[UInt8, _],
        label: String,
        context: Span[UInt8, _],
        dst: Span[UInt8, o],
    ) raises:
        """HKDF-Expand-Label(Secret, Label, Context, Length) per RFC 8446 §7.1.

        Builds the HKDFLabel struct (uint16 length || opaque label<7..255> ||
        opaque context<0..255>) with the "tls13 " label prefix, then calls
        HKDF-Expand. The label byte-layout is TLS-protocol-specific —
        kept in Mojo (AWS-LC's HKDF has no label form).
        """
        var label_bytes_view = label.as_bytes()
        var label_len = len(label_bytes_view)
        var context_len = len(context)
        var output_len = len(dst)

        if label_len == 0:
            raise Error(String("HKDF-Expand-Label: label cannot be empty"))
        if label_len > 249:
            raise Error(
                String("HKDF-Expand-Label: label exceeds 249 bytes (max after 'tls13 ' prefix)")
            )
        if context_len > 255:
            raise Error(String("HKDF-Expand-Label: context exceeds 255 bytes"))
        if output_len > 65535:
            raise Error(
                String("HKDF-Expand-Label: output length exceeds u16 limit")
            )

        # Build HKDFLabel byte sequence:
        #   uint16 length BE | label-len-byte | "tls13 " | label | context-len-byte | context
        var hkdf_label = List[UInt8](
            capacity=2 + 1 + 6 + label_len + 1 + context_len
        )

        # uint16 length (big-endian)
        hkdf_label.append(UInt8((output_len >> 8) & 0xFF))
        hkdf_label.append(UInt8(output_len & 0xFF))

        # opaque label<7..255> length prefix = 6 + label_len
        var tls13_label_len = 6 + label_len
        hkdf_label.append(UInt8(tls13_label_len))

        # "tls13 " prefix (6 bytes)
        hkdf_label.append(UInt8(0x74))  # 't'
        hkdf_label.append(UInt8(0x6C))  # 'l'
        hkdf_label.append(UInt8(0x73))  # 's'
        hkdf_label.append(UInt8(0x31))  # '1'
        hkdf_label.append(UInt8(0x33))  # '3'
        hkdf_label.append(UInt8(0x20))  # ' '

        # Label bytes.
        for i in range(label_len):
            hkdf_label.append(label_bytes_view[i])

        # opaque context<0..255> length prefix.
        hkdf_label.append(UInt8(context_len))

        # Context bytes.
        for i in range(context_len):
            hkdf_label.append(context[i])

        # HKDF-Expand(secret, HkdfLabel, len(dst)) -> dst.
        Self.expand(secret, Span[UInt8](hkdf_label), dst)

    # -------------------------------------------------------------------------
    # Derive-Secret — TLS 1.3 RFC 8446 §7.1
    # -------------------------------------------------------------------------

    @staticmethod
    def derive_secret[o: Origin[mut=True]](
        secret: Span[UInt8, _],
        label: String,
        messages: Span[UInt8, _],
        dst: Span[UInt8, o],
    ) raises:
        """Derive-Secret(Secret, Label, Messages) per RFC 8446 §7.1.

        Computes H(messages) (the transcript hash) and feeds it as
        the context input to HKDF-Expand-Label, emitting H.OUTPUT_SIZE
        bytes into dst.

        BOTH `Derive-Secret(_, "derived", "")`
        invocations in the TLS 1.3 key schedule (Early/Handshake and
        Handshake/Master) MUST work. When `messages` is empty,
        H("") is the well-defined empty-string digest.
        """
        if len(dst) < Self.H.OUTPUT_SIZE:
            raise Error(String("Derive-Secret: dst is smaller than Hash.length"))

        # 1. Compute Transcript-Hash(Messages) = H(Messages).
        var transcript_hash = Array[UInt8, Self.H.OUTPUT_SIZE](fill=0)
        var hasher = Self.H()
        hasher.update(messages)
        hasher.finalize_into(transcript_hash)

        # 2. HKDF-Expand-Label(secret, label, transcript_hash, Hash.length) -> dst.
        var dst_slice = dst[: Self.H.OUTPUT_SIZE]
        Self.hkdf_expand_label(
            secret,
            label,
            Span[UInt8](transcript_hash),
            dst_slice,
        )
