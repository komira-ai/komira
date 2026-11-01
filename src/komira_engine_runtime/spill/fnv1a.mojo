# =============================================================================
# fnv1a.mojo -- FNV-1a-64 hash and the canonical schema fingerprint
# =============================================================================
#
# Canonical FNV-1a-64 shared by anything that needs a stable 64-bit identity
# for a spill layout: a partition's narrow fingerprint (entry stride alone) and
# a sink's full fingerprint (entry stride plus the sink-owned aggregate tag
# list) are comparable bit for bit because they fold the same prefix.
#
# Canonical fingerprint input:
#
#   bytes  0.. 7 : entry_stride (UInt64, little-endian)
#   bytes  8.. N : agg_tag_list_bytes (verbatim; caller-supplied context)
#
# The partition side passes an empty tag list; the sink side passes its own
# tag bytes. The 8-byte stride prefix is the same in both, so a stride mismatch
# is visible before any tag byte is read.
#
# FNV-1a-64 constants:
#
#   offset_basis = 0xcbf29ce484222325
#   prime        = 0x00000100000001b3
#
# Step: h_{i+1} = (h_i XOR byte_i) * prime  (mod 2^64; UInt64 overflow
# semantics match Mojo's UInt64 arithmetic exactly).
#
# Pure value-typed free functions: no pointer in any signature, inputs are
# `UInt64` / `UInt8` / `Span[UInt8, _]` / `List[UInt8]`.
# =============================================================================


# =============================================================================
# Constants
# =============================================================================
#
# FNV-1a-64 offset basis and prime. UInt64 ops fold the multiplications
# mod 2^64, so the hash matches every conformant FNV-1a-64 implementation
# byte for byte. `tests/test_fnv1a_and_async_wake.mojo` checks the published
# vectors against these constants.

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

    Schema-identity callers use `fnv1a_64_partition_fingerprint` below, which
    composes the `entry_stride_le_8B || agg_tag_list_bytes` input shape.

    Args:
        bytes: Input bytes. Empty input returns the offset basis
               (0xcbf29ce484222325) — canonical FNV-1a-64 semantic.

    Returns:
        64-bit hash, full UInt64 range.
    """
    return fnv1a_64_over_span(Span(bytes))


# =============================================================================
# fnv1a_64_over_span — Span variant
# =============================================================================
#
# The List form above delegates here. Callers that already hold a Span over
# the bytes use this form and avoid a List allocation.


def fnv1a_64_over_span(bytes: Span[UInt8, _]) -> UInt64:
    """FNV-1a-64 over a `Span[UInt8, _]`: the same hash as `fnv1a_64_over`
    over the same byte sequence, without materializing a List."""
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

    The 8 little-endian bytes of `entry_stride` come first, then the tag
    bytes verbatim. The partition-side narrow fingerprint passes an empty
    `agg_tag_list`; a sink-side full fingerprint passes its own tag bytes.
    Both fold the same 8-byte stride prefix first.

    Args:
        entry_stride: Bytes per row. Cast to UInt64 internally;
                      negative values are technically representable
                      but ill-formed (partition strides are positive
                      Int by domain).
        agg_tag_list: Agg-tag bytes (or empty for the narrow case). The byte content is
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
