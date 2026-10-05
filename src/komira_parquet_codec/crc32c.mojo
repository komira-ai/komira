# =============================================================================
# CRC-32C (Castagnoli) over a byte buffer
# =============================================================================
#
# CRC-32C uses the Castagnoli polynomial (0x1EDC6F41), which is different
# from the standard CRC-32 (ISO 3309, polynomial 0x04C11DB7). The Parquet
# page checksum (PageHeader.crc, Thrift field 4) is the STANDARD CRC-32, as
# in gzip and zlib, not this one: parquet.thrift says so in the field's doc.
# Do not use `crc32c` to write or check a Parquet page CRC.
#
# Implementation: the 256-entry table is computed at compile time and filled
# into a stack array on each call (1 KB, stays in L1 for the call).
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


def crc32c(data: Span[UInt8, _]) -> UInt32:
    """The CRC-32C (Castagnoli) checksum of `data`.

    Initializes the CRC to 0xFFFFFFFF and finalizes by XOR, so the CRC-32C of
    the nine bytes "123456789" is 0xE3069283 and of no bytes is 0. Processes
    4 bytes per loop iteration for instruction-level parallelism.

    This is NOT the Parquet page checksum, which is the standard CRC-32.
    """
    # PERF-CRITICAL: `comptime for` evaluates `_crc32c_table_entry` at
    # compile time; at run time the table is a stack fill of 256 constants.
    var table = Array[UInt32, 256](uninitialized=True)
    comptime for i in range(256):
        table[i] = _crc32c_table_entry(i)

    var crc = UInt32(0xFFFFFFFF)
    var length = len(data)

    # Process 4 bytes at a time for better ILP -- each iteration
    # does 4 dependent table lookups, but the overall loop count
    # is reduced by 4x, improving branch prediction.
    var i = 0
    var end4 = length - 3
    while i < end4:
        var idx0 = Int((crc ^ UInt32(data[i])) & 0xFF)
        crc = (crc >> 8) ^ table[idx0]
        var idx1 = Int((crc ^ UInt32(data[i + 1])) & 0xFF)
        crc = (crc >> 8) ^ table[idx1]
        var idx2 = Int((crc ^ UInt32(data[i + 2])) & 0xFF)
        crc = (crc >> 8) ^ table[idx2]
        var idx3 = Int((crc ^ UInt32(data[i + 3])) & 0xFF)
        crc = (crc >> 8) ^ table[idx3]
        i += 4

    # Handle remaining bytes.
    while i < length:
        var idx = Int((crc ^ UInt32(data[i])) & 0xFF)
        crc = (crc >> 8) ^ table[idx]
        i += 1

    return crc ^ UInt32(0xFFFFFFFF)
