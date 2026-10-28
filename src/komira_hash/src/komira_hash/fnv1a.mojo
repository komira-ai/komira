# =============================================================================
# fnv1a.mojo -- canonical byte-wise FNV-1a, 32 and 64 bit.
# =============================================================================
#
# For each byte: `h = (h ^ byte) * PRIME`, starting from the offset basis, with
# the multiply wrapping at the hash width. The empty input hashes to the offset
# basis. The constants are the published FNV parameters.
# =============================================================================

comptime FNV1A_32_OFFSET_BASIS: UInt32 = UInt32(2166136261)
comptime FNV1A_32_PRIME: UInt32 = UInt32(16777619)
comptime FNV1A_64_OFFSET_BASIS: UInt64 = UInt64(14695981039346656037)
comptime FNV1A_64_PRIME: UInt64 = UInt64(1099511628211)


def fnv1a_32(data: Span[UInt8, _]) -> UInt32:
    """FNV-1a 32-bit hash of `data`."""
    var h = FNV1A_32_OFFSET_BASIS
    for i in range(len(data)):
        h = (h ^ UInt32(data[i])) * FNV1A_32_PRIME
    return h


def fnv1a_64(data: Span[UInt8, _]) -> UInt64:
    """FNV-1a 64-bit hash of `data`."""
    var h = FNV1A_64_OFFSET_BASIS
    for i in range(len(data)):
        h = (h ^ UInt64(data[i])) * FNV1A_64_PRIME
    return h
