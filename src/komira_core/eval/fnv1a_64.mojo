# FNV-1a 64-bit hash over a borrowed byte span.
#
# Per the FNV reference (https://www.isthe.com/chongo/tech/comp/fnv/):
#   offset basis: 14695981039346656037 = 0xcbf29ce484222325
#   prime:        1099511628211        = 0x100000001b3
#
# The constants are public so every FNV-1a-64 fold over a different input
# shape (a string array's byte range, a term's bytes) shares one definition and
# stays byte-identical. The fold is xor-then-multiply, byte by byte.

comptime FNV1A_OFFSET_64: UInt64 = UInt64(0xCBF29CE484222325)
comptime FNV1A_PRIME_64: UInt64 = UInt64(0x100000001B3)


@always_inline
def fnv1a_64_over_bytes(bytes: Span[UInt8, _]) -> UInt64:
    """FNV-1a-64 over a borrowed byte span.

    Args:
        bytes: The borrowed byte span to hash. An empty span returns the FNV-1a
            offset basis (0xcbf29ce484222325), the canonical empty-input result.

    Returns:
        The FNV-1a-64 hash of `bytes`.
    """
    var h = FNV1A_OFFSET_64
    for i in range(len(bytes)):
        h = (h ^ UInt64(Int(bytes[i]))) * FNV1A_PRIME_64
    return h
