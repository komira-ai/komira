# =============================================================================
# komira_objectstore_gcs/crc32c.mojo — CRC-32C (Castagnoli), the checksum
# Cloud Storage states for every object and accepts for every write chunk.
# =============================================================================
#
# google.storage.v2 carries a CRC-32C in `ChecksummedData.crc32c` (one chunk)
# and `ObjectChecksums.crc32c` (the whole object): a write whose stated value
# does not match what the service computed fails, and a reader of a whole
# object compares the stated value with what it received. The polynomial is
# Castagnoli's, reflected (0x82F63B78), with the usual all-ones initial value
# and final inversion (RFC 3720 §B.4; `crc32c("123456789") == 0xE3069283`).
#
# Table-driven, one byte at a time: portable, no intrinsic and no pointer.
# `crc32c_extend(crc32c(a), b) == crc32c(a + b)`, so a payload sent in
# chunks is summed once, chunk by chunk.
# =============================================================================

comptime _CRC32C_POLY: UInt32 = 0x82F63B78
comptime _ALL_ONES: UInt32 = 0xFFFFFFFF


def _crc32c_table() -> List[UInt32]:
    var table = List[UInt32](capacity=256)
    for i in range(256):
        var c = UInt32(i)
        for _ in range(8):
            if (c & UInt32(1)) != UInt32(0):
                c = (c >> UInt32(1)) ^ _CRC32C_POLY
            else:
                c = c >> UInt32(1)
        table.append(c)
    return table^


def crc32c_extend(crc: UInt32, data: Span[UInt8, _]) -> UInt32:
    """The CRC-32C of the bytes `crc` summed followed by `data` (`crc = 0`:
    of `data` alone)."""
    var table = _crc32c_table()
    var c = crc ^ _ALL_ONES
    for i in range(len(data)):
        c = table[Int((c ^ UInt32(data[i])) & UInt32(0xFF))] ^ (c >> UInt32(8))
    return c ^ _ALL_ONES


def crc32c(data: Span[UInt8, _]) -> UInt32:
    """The CRC-32C of `data`."""
    return crc32c_extend(UInt32(0), data)
