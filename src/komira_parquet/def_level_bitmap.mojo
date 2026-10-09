# =============================================================================
# Definition levels to an Arrow validity bitmap
# =============================================================================
#
# A flat (non-nested) nullable column stores its definition levels in a V1
# data page as `[4-byte LE length][RLE/bit-pack hybrid bytes]` at bit width 1:
# level 0 is a null, level 1 a value. `decode_def_levels_to_bitmap` turns that
# section into an Arrow validity bitmap and the byte count the caller steps
# over to reach the values, with an all-valid fast path that allocates no
# level buffer.
# =============================================================================

from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion
from komira_buffer.byte_buffer import ByteBuffer

from .rle import RleDecoder, validate_level_section_length


# =============================================================================
# Definition level decode convenience
# =============================================================================


struct DefLevelResult(Movable):
    """Result of decoding definition levels: a validity bitmap and bytes consumed.

    Fields:
        bitmap: Arrow validity bitmap (bit=1 means valid, bit=0 means null).
        bytes_consumed: Number of bytes consumed from the input (including 4-byte prefix).
        all_valid: True when every def level == max_def_level (no nulls).
                   Callers can skip null-expansion when this is True.
    """

    var bitmap: Bitmap[HeapRegion]
    var bytes_consumed: Int
    var all_valid: Bool

    def __init__(
        out self, var bitmap: Bitmap[HeapRegion], bytes_consumed: Int, all_valid: Bool = False
    ):
        self.bitmap = bitmap^
        self.bytes_consumed = bytes_consumed
        self.all_valid = all_valid


# =============================================================================
# PERF-CRITICAL: All-valid def-level fast path
# =============================================================================
# Regression if removed: a large share of the decode time of nullable
#                         columns with no nulls
# Impact:                 Eliminates a per-page Int32 temp alloc + 2 scalar
#                         loops for nullable columns with zero nulls
# Other readers:          Detect a single RLE run of max_def_level, skip decode
# =============================================================================


@always_inline
def _is_all_valid_def_levels(
    encoded_data: Span[UInt8, _],
    num_values: Int,
) -> Bool:
    """Check if an RLE/bit-packed hybrid def-level stream (bit_width=1)
    encodes all values as 1 (valid) in a single block.

    Detects two patterns:
      1. Single RLE run: header low-bit=0, run_count >= num_values, value=0x01
      2. Single bit-packed group: header low-bit=1, num_groups*8 >= num_values,
         all packed bytes are 0xFF (every bit is 1)

    Pattern 1 is written by most writers. Pattern 2 is written by a writer
    that bit-packs an all-valid section in one group.

    This avoids allocating a per-page Int32 temp buffer and two
    scalar loops for the common case of nullable columns with zero nulls.
    """
    var avail = len(encoded_data)
    if avail < 2:
        return False

    # Copy encoded data into owned ByteBuffer for bounds-checked reads.
    var buf = List[UInt8](capacity=avail)
    for i in range(avail):
        buf.append(encoded_data[i])
    var reader = ByteBuffer(buf^)

    # Read the varint header via ByteBuffer.read_uleb128(). For typical
    # Parquet files the count fits in 1-2 bytes (up to ~8M values).
    try:
        var header = reader.read_uleb128()

        if header & 1 == 0:
            # --- Pattern 1: RLE run ---
            var run_count = header >> 1
            if run_count < num_values:
                return False
            if reader.is_empty():
                return False
            return Int(reader.read_byte()) == 1
        else:
            # --- Pattern 2: Bit-packed group ---
            var num_groups = header >> 1
            var values_in_run = num_groups * 8
            if values_in_run < num_values:
                return False
            # Check that all packed bytes are 0xFF.
            var num_packed_bytes = num_groups  # bit_width=1, so 1 byte per group
            if reader.remaining() < num_packed_bytes:
                return False
            # SAFETY: current_view() covers remaining() bytes and is
            # origin-tied to `reader`; we pull a pointer for the byte-scan
            # loop because ByteBuffer doesn't have a bulk-compare method,
            # and read_byte() per iteration would add overhead in a
            # PERF-CRITICAL path. pack_view keeps the borrow alive.
            var pack_view = reader.current_view()
            var pack_ptr = pack_view._unsafe_ptr()
            # Full bytes that must be 0xFF.
            var full_value_bytes = num_values >> 3
            for i in range(full_value_bytes):
                if Int((pack_ptr + i)[]) != 0xFF:
                    return False
            # If num_values is not a multiple of 8, the last byte must have
            # the low (num_values & 7) bits set.
            var remainder = num_values & 7
            if remainder > 0:
                var last_byte = Int((pack_ptr + full_value_bytes)[])
                var mask = (1 << remainder) - 1
                if (last_byte & mask) != mask:
                    return False
            return True
    except:
        return False  # Malformed -- fall back to full decode.


def decode_def_levels_to_bitmap(
    data: Span[UInt8, _],
    num_values: Int,
) raises -> DefLevelResult:
    """Decode definition levels into an Arrow validity bitmap.

    For flat schemas (non-nested): def_level 0 = null, 1 = valid.
    Input: 4-byte LE length prefix + RLE-encoded levels (bit_width=1).
    Output: Arrow-format Bitmap where bit=1 means valid.

    Args:
        data: The page bytes from the start of the definition level section.
        num_values: Number of definition levels to decode.

    Returns:
        DefLevelResult containing the bitmap and bytes consumed.

    Raises:
        Error if `num_values` is negative or past the Int32 range of a page's
        value count, or the length prefix is negative or longer than the
        bytes after it.
    """
    if num_values < 0 or num_values > 2147483647:
        raise Error(
            "decode_def_levels_to_bitmap: a page cannot hold "
            + String(num_values)
            + " definition levels"
        )
    var data_len = len(data)
    if data_len < 4 or num_values == 0:
        var empty_bm = Bitmap.create_all_valid(max(num_values, 0))
        return DefLevelResult(empty_bm^, min(4, data_len), all_valid=True)

    # Read 4-byte LE encoded length. We already checked data_len >= 4 above,
    # so this read is safe. Use pointer bitcast directly (ByteBuffer would add
    # try/except overhead for a guaranteed-safe 4-byte read).
    var encoded_len = Int(data.unsafe_ptr().bitcast[Int32]()[])

    # ROBUSTNESS GATE.
    #
    # `encoded_len` is a SIGNED Int32 read straight from the V1 data page
    # and is returned to the caller as `bytes_consumed = 4 + encoded_len`.
    # The caller does `values_ptr += bytes_consumed; values_len -=
    # bytes_consumed` — so an out-of-range value slides the VALUES pointer
    # up to 2 GB outside the page buffer and drives `values_len` negative,
    # after which no downstream comparison can save it and every decoder
    # (PLAIN memcpy, RLE, DELTA, BSS) reads from wild memory.
    #
    # The `avail = min(encoded_len, data_len - 4)` below clamps only
    # THIS function's own RLE read; it never constrains the value handed
    # back. Validate it here, once, at the point it is first read.
    #
    # `rle.decode_def_levels` and `rle.decode_levels` call the same
    # `rle.validate_level_section_length`, so there is ONE name to grep
    # for and the next decoder of a `[4-byte LE length][RLE]` section has
    # something to call instead of writing another copy.
    validate_level_section_length(encoded_len, data_len)

    var avail = min(encoded_len, data_len - 4)
    var encoded_data = data[4 : 4 + avail]

    # ---------------------------------------------------------------
    # PERF-CRITICAL: All-valid fast path — skip Int32 alloc + loops.
    # For nullable columns with zero nulls (the common case),
    # the RLE stream is a single repeated run of value=1.  We detect
    # this in O(1) and return an all-ones bitmap without allocating
    # the per-page Int32 temp buffer.
    # ---------------------------------------------------------------
    if _is_all_valid_def_levels(encoded_data, num_values):
        var all_bm = Bitmap.create_all_valid(num_values)
        return DefLevelResult(all_bm^, 4 + encoded_len, all_valid=True)

    # Slow path: Decode RLE levels into a temporary Int32 buffer.
    var levels = List[Int32](length=num_values, fill=0)
    var decoder = RleDecoder(encoded_data, 1)
    var decoded = decoder.decode_int32(num_values, Span(levels))

    # Convert to Bitmap: level 0 = null (bit=0), level 1 = valid (bit=1).
    var bm = Bitmap.create(num_values)
    var null_count = 0
    for i in range(num_values):
        if i < decoded and Int(levels[i]) != 0:
            bm.set(i)
        else:
            null_count += 1

    return DefLevelResult(bm^, 4 + encoded_len, all_valid=(null_count == 0))
