# =============================================================================
# fnv1a.mojo — FNV-1a-64 shared util (RFC v0.6 §10.10.3)
# =============================================================================
#
# RFC v0.6 §10.10.3 (P-1.D.1.a scope; an internal doc).
#
# # Role
#
# Canonical FNV-1a-64 implementation shared between:
#   * the `Spillable.schema_fingerprint() -> UInt64` trait method
#     (P-1.A/B widened from UInt32 to UInt64 in P-1.D.1.a Step 2),
#   * `FlatHashPartitionFlush.schema_fingerprint()` (P-1.D.0; folds
#     entry_stride alone — sink-side context fills in the agg-tag list),
#   * `flat_hash_agg_sink._compute_full_schema_fingerprint` (P-1.D.1.b;
#     folds entry_stride + the sink-owned agg-tag list to produce the
#     full canonical fingerprint that the on-disk header carries).
#
# Prior to v0.6 the codebase carried TWO hash functions for "schema
# identity": the THSPILL\x01 path (`spill_writer.fnv1a_tag_list_hash` —
# FNV-1a-64 over agg-tag bytes; widened to Int internally) and the
# THSPILL2 path (`FlatHashPartitionFlush.schema_fingerprint` — FNV-1a-32
# over stride-only). RFC v0.6 unifies on FNV-1a-64 over the canonical
# input `entry_stride_le_8B || agg_tag_list_bytes` so partition-side and
# sink-side fingerprints are comparable bit-for-bit.
#
# # Canonical input shape (RFC v0.6 §10.10.3)
#
#   bytes  0.. 7 : entry_stride (UInt64, little-endian)
#   bytes  8.. N : agg_tag_list_bytes (verbatim; sink-side context)
#
# The partition-side helper passes an EMPTY agg_tag_list (it doesn't own
# the sink's tag context); the sink-side helper passes its own
# `_acc_tags` bytes. The 8-byte entry_stride prefix is constant across
# both — so a partition's narrow fingerprint and the sink's full
# fingerprint share the same 8-byte prefix-fold and diverge only after.
# That is intentional: a stride-mismatched partition raises during
# `from_bytes` BEFORE the sink even reads the agg-tag list.
#
# # FNV-1a-64 constants (RFC 8 well-known)
#
#   offset_basis = 0xcbf29ce484222325
#   prime         = 0x00000100000001b3
#
# Step: h_{i+1} = (h_i XOR byte_i) * prime  (mod 2^64; UInt64 overflow
# semantics match Mojo's UInt64 arithmetic exactly).
#
# # Encapsulation rule
#
# Pure value-typed free functions. NO UnsafePointer in signatures; NO
# wildcard origins; inputs are `UInt64` / `UInt8` / `Span[UInt8, _]` /
# `List[UInt8]`. Internal arithmetic is plain UInt64 ops — no SIMD, no
# parallelize (called once per spill encode + once per restore decode;
# the cost is statistical noise against the THSPILL2 I/O wall).
# =============================================================================



# =============================================================================
# Constants
# =============================================================================
#
# FNV-1a-64 well-known constants (offset basis + prime). RFC 8 / FNV
# reference page. UInt64 ops fold the multiplications mod 2^64; the
# resulting hash matches every conformant FNV-1a-64 implementation
# byte-for-byte. The known-answer test vectors in
# `tests/engine/test_fnv1a.mojo` exercise the canonical "" and "a"
# values against these constants.

comptime FNV1A_64_OFFSET_BASIS: UInt64 = 0xCBF29CE484222325
comptime FNV1A_64_PRIME: UInt64 = 0x00000100000001B3


# =============================================================================
# fnv1a_64_combine — single-byte step
# =============================================================================


@always_inline
def fnv1a_64_combine(start: UInt64, byte: UInt8) -> UInt64:
    """FNV-1a-64 step: xor the input byte into the accumulator, then
    multiply by the prime.

    Args:
        start: Current accumulator value (offset_basis on the FIRST
               call; the previous step's return otherwise).
        byte:  Next byte of the canonical input.

    Returns:
        The post-multiplication accumulator value, ready to feed into
        the next step.
    """
    return (start ^ UInt64(Int(byte))) * FNV1A_64_PRIME


# =============================================================================
# fnv1a_64_over — fold an entire byte sequence
# =============================================================================


def fnv1a_64_over(imm bytes: List[UInt8]) -> UInt64:
    """FNV-1a-64 over the entire byte sequence (offset basis seeded
    internally).

    Used by tests' known-answer vectors and as the building block for
    `fnv1a_64_partition_fingerprint`. Production schema-identity callers
    use the partition-fingerprint helper below — it composes the
    `entry_stride_le_8B || agg_tag_list_bytes` canonical input shape so
    callers don't have to.

    Args:
        bytes: Input bytes. Empty input returns the offset basis
               (0xcbf29ce484222325) — canonical FNV-1a-64 semantic.

    Returns:
        64-bit hash, full UInt64 range.
    """
    var h: UInt64 = FNV1A_64_OFFSET_BASIS
    for i in range(len(bytes)):
        h = fnv1a_64_combine(h, bytes[i])
    return h


# =============================================================================
# fnv1a_64_over_span — Span variant for sink-side callers
# =============================================================================
#
# The partition-side helper consumes a `List[UInt8]` (the sink's
# _acc_tags is List-backed). Tests that build canonical inputs from
# raw bytes prefer the List shape too. Sink-side helpers that hold a
# Span over already-allocated bytes use this overload to avoid a
# List allocation.


def fnv1a_64_over_span(bytes: Span[UInt8, _]) -> UInt64:
    """FNV-1a-64 over a `Span[UInt8, _]` — convenience for sink-side
    callers that already have a borrowed view over canonical-input
    bytes without needing to materialize them into a List.

    Semantically identical to `fnv1a_64_over` over the same byte
    sequence.
    """
    var h: UInt64 = FNV1A_64_OFFSET_BASIS
    for i in range(len(bytes)):
        h = fnv1a_64_combine(h, bytes[i])
    return h


# =============================================================================
# fnv1a_64_partition_fingerprint — canonical schema fingerprint
# =============================================================================


def fnv1a_64_partition_fingerprint(
    entry_stride: Int, imm agg_tag_list: List[UInt8]
) -> UInt64:
    """Canonical partition schema fingerprint:
       FNV-1a-64 over `entry_stride_le_8B || agg_tag_list_bytes`.

    The 8 little-endian bytes of `entry_stride` come FIRST; then the
    agg-tag bytes verbatim. This is the unified input that both the
    partition-side `schema_fingerprint()` and the sink-side restore-
    check use; their values are equal by construction when the schemas
    match.

    The partition-side narrow fingerprint passes an empty
    `agg_tag_list` (the partition doesn't own the sink's tag context).
    The sink-side full fingerprint passes the sink's `_acc_tags`
    bytes. Both fold the same 8-byte entry_stride prefix first so a
    stride mismatch is caught before any agg-tag-list reads.

    Args:
        entry_stride: Bytes per row (==
                      FlatHashAggregator._entry_stride at the
                      construction site). Cast to UInt64 internally;
                      negative values are technically representable
                      but ill-formed (partition strides are positive
                      Int by domain).
        agg_tag_list: Sink-side agg-tag bytes (or empty for the
                      partition-side narrow case). The byte content is
                      caller-owned — callers MUST ensure determinism
                      (e.g. by sorting the agg-tag list before feeding
                      it here) so re-runs against the same logical
                      schema yield the same fingerprint.

    Returns:
        64-bit canonical fingerprint, full UInt64 range.
    """
    var h: UInt64 = FNV1A_64_OFFSET_BASIS

    # Fold the 8 LE bytes of entry_stride first. UInt64 cast preserves
    # all 64 bits; for the sub-32-bit strides typical in production
    # (typed agg layouts top out near a few KB), the top bytes are
    # zero — but folding them all keeps the canonical input length
    # constant at exactly 8 prefix bytes regardless of stride
    # magnitude.
    var stride_u64 = UInt64(entry_stride)

    comptime for shift in range(0, 64, 8):
        var b = UInt8(Int((stride_u64 >> UInt64(shift)) & UInt64(0xFF)))
        h = fnv1a_64_combine(h, b)

    # Fold the agg-tag list bytes. Empty list (partition-side narrow
    # case) is a no-op; the returned fingerprint reflects entry_stride
    # alone.
    for i in range(len(agg_tag_list)):
        h = fnv1a_64_combine(h, agg_tag_list[i])

    return h
