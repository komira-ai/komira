# =============================================================================
# CRC-32C (Castagnoli) over a byte buffer
# =============================================================================
#
# CRC-32C uses the Castagnoli polynomial (0x1EDC6F41), which is different
# from the standard CRC-32 (ISO 3309, polynomial 0x04C11DB7). The Parquet
# page checksum (PageHeader.crc, Thrift field 4) is the STANDARD CRC-32, as
# in gzip and zlib, not this one: parquet.thrift says so in the field's doc.
#
# Implementation: the 256-entry table is computed at compile time and filled
# into a stack array on each call (1 KB, stays in L1 for the call).
#
# SAFETY: Uses UnsafePointer for raw byte-level access to the buffer.
# =============================================================================


# CRC-32C reflected polynomial (Castagnoli).
comptime _CRC32C_POLY: UInt32 = 0x82F63B78


@always_inline
def _crc32c_table_entry(byte_val: Int) -> UInt32:
    """Compute one CRC-32C table entry for the given byte value.

    Each entry is the CRC of a single byte through 8 rounds of
    polynomial division.
    """
    var crc = UInt32(byte_val)
    for _ in range(8):
        if crc & 1 != 0:
            crc = (crc >> 1) ^ _CRC32C_POLY
        else:
            crc = crc >> 1
    return crc


def _compute_crc32c(data: UnsafePointer[UInt8, _], length: Int) -> UInt32:
    """Compute the CRC-32C checksum of a byte buffer.

    Builds the 256-entry lookup table on the stack, then processes
    bytes 4 at a time for better instruction-level parallelism.
    Initializes CRC to 0xFFFFFFFF and finalizes by XOR.

    Args:
        data: Pointer to the bytes to checksum.
        length: Number of bytes.

    Returns:
        CRC-32C checksum as a UInt32.
    """
    # PERF-CRITICAL: `comptime for` evaluates `_crc32c_table_entry` at
    # compile time; at run time the table is a stack fill of 256 constants.
    var table = Array[UInt32, 256](uninitialized=True)
    comptime for i in range(256):
        table[i] = _crc32c_table_entry(i)

    var crc = UInt32(0xFFFFFFFF)

    # Process 4 bytes at a time for better ILP -- each iteration
    # does 4 dependent table lookups, but the overall loop count
    # is reduced by 4x, improving branch prediction.
    var i = 0
    var end4 = length - 3
    while i < end4:
        var idx0 = Int((crc ^ UInt32((data + i)[])) & 0xFF)
        crc = (crc >> 8) ^ table[idx0]
        var idx1 = Int((crc ^ UInt32((data + i + 1)[])) & 0xFF)
        crc = (crc >> 8) ^ table[idx1]
        var idx2 = Int((crc ^ UInt32((data + i + 2)[])) & 0xFF)
        crc = (crc >> 8) ^ table[idx2]
        var idx3 = Int((crc ^ UInt32((data + i + 3)[])) & 0xFF)
        crc = (crc >> 8) ^ table[idx3]
        i += 4

    # Handle remaining bytes.
    while i < length:
        var idx = Int((crc ^ UInt32((data + i)[])) & 0xFF)
        crc = (crc >> 8) ^ table[idx]
        i += 1

    return crc ^ UInt32(0xFFFFFFFF)


def compute_crc32c_list(data: List[UInt8]) -> UInt32:
    """Compute the CRC-32C checksum of a List[UInt8].

    Convenience wrapper that extracts the raw pointer from the list.

    Args:
        data: The byte list to checksum.

    Returns:
        CRC-32C checksum as a UInt32.
    """
    if len(data) == 0:
        return UInt32(0xFFFFFFFF) ^ UInt32(0xFFFFFFFF)  # CRC of empty = 0
    # SAFETY: `_compute_crc32c` accepts `UnsafePointer[UInt8, _]` (origin-
    # generic), so we can pass `data.unsafe_ptr()` directly -- no wildcard
    # widening is needed. `data` remains live across the call because it
    # is `owned` by the caller (List[UInt8] is Movable), and the pointer
    # is consumed synchronously inside `_compute_crc32c`.
    var result = _compute_crc32c(data.unsafe_ptr(), len(data))
    # keepalive: ensure data is not destroyed before _compute_crc32c returns
    _ = data
    return result
