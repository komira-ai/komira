# =============================================================================
# Snappy varint (LEB128) decode
# =============================================================================
#
# Snappy's preamble is a single varint holding the uncompressed length.
# 7 payload bits per byte, high bit = continuation. Max output is 2^32-1 →
# up to 5 bytes.
#
# Reference: google/snappy snappy-stubs-internal.h
# (Varint::Parse32WithLimit); format_description.txt section 1.
#
# Encapsulation: package-private; the signature takes `ByteView[_]` (not raw
# wildcard pointers). This module never crosses a pointer boundary — all
# reads route through ByteView's bounds-checked `read_u8_at`.
# =============================================================================

from komira_buffer.byte_view import ByteView


# Up to 5 bytes for a 32-bit unsigned value (32 / 7 rounded up).
comptime varint_max_len: Int = 5


@always_inline
def _varint_decode32(
    data: ByteView[_],
) raises -> Tuple[UInt32, Int]:
    """Decode a Snappy varint from `data[0..data.len())`.

    Returns `(value, bytes_consumed)`.

    Raises on:
      - empty input
      - truncated varint (continuation bit on final byte)
      - overflow past 32 bits (bit 33+ set)

    Reference: Varint::Parse32WithLimit.
    """
    var data_len = data.len()
    if data_len == 0:
        raise Error("snappy: empty input, cannot read varint length prefix")

    var result: UInt32 = 0
    var shift: UInt32 = 0
    var pos = 0

    while pos < data_len:
        if shift >= 32:
            raise Error("snappy: varint length overflows 32 bits")
        var byte = data.read_u8_at(pos)
        pos += 1
        # Cast to UInt32 so the shift doesn't overflow a UInt8.
        var val: UInt32 = UInt32(byte) & 0x7F
        # snappy.cc:1204 LeftShiftOverflows: at shift=28, only 4 bits of room
        # remain in the 32-bit result. Any value > 0xF with shift=28 overflows.
        if shift == 28 and val > 0xF:
            raise Error("snappy: varint length overflows 32 bits")
        result = result | (val << shift)
        if (UInt32(byte) & 0x80) == 0:
            return (result, pos)
        shift += 7

    raise Error("snappy: truncated varint (missing continuation byte)")
