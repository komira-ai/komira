# =============================================================================
# Arrow C Data Interface: dictionary index widths and decimal parameters.
# =============================================================================
#
# Two tables the C Data import and export in `c_data_stream.mojo` decide by,
# kept apart from that file's FFI. Nothing here touches a pointer: the import
# copies the producer's index bytes into an `OwnedAlignedBuffer` first, and
# everything below reads that buffer.
#
# DICTIONARY INDICES. "The index type MUST be an integer type, preferably
# signed" (CDataInterface.html, dictionary-encoded arrays): the parent format
# is one of `c s i l C S I L`, and the indices buffer holds `length` values of
# that width. A Column stores dictionary indices 4 bytes wide (INT32) or 8
# bytes wide (INT64) — `Column._dict_index_byte_width` — and nothing else, so
# import widens 8-, 16- and unsigned 32-bit indices to INT32 and keeps 64-bit
# ones as INT64. An unsigned index that does not fit the signed storage is
# refused on a valid row; under a null row the value is undefined and is
# stored as 0. Export emits the Field's index type, so it requires the
# Column's byte width to be that type's width.
#
# DECIMAL `d:P,S[,W]`. W is 128 (the default) or 256; precision is in
# [1, 38] or [1, 76]. Komira's decimals have 0 <= scale <= precision
# (`Field.decimal128` / `Field.decimal256`), so a negative scale or one above
# the precision is refused as unsupported rather than rewritten.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer


def _dict_index_width(index_t: ArrowType) -> Int:
    """Byte width of a declared dictionary index type, or 0 for a type that
    is not an integer (which the callers refuse with their own message)."""
    if index_t == ArrowType.INT8 or index_t == ArrowType.UINT8:
        return 1
    if index_t == ArrowType.INT16 or index_t == ArrowType.UINT16:
        return 2
    if index_t == ArrowType.INT32 or index_t == ArrowType.UINT32:
        return 4
    if index_t == ArrowType.INT64 or index_t == ArrowType.UINT64:
        return 8
    return 0


def _dict_storage_index_type(index_t: ArrowType) -> ArrowType:
    """The index type a Column stores `index_t` as: INT64 for the 64-bit
    types, INT32 for the rest."""
    if index_t == ArrowType.INT64 or index_t == ArrowType.UINT64:
        return ArrowType.INT64
    return ArrowType.INT32


def _dict_storage_width(storage_t: ArrowType) -> Int:
    """Byte width of a storage index type, or 0 when a Column cannot store
    indices of that type (anything but INT32 and INT64)."""
    if storage_t == ArrowType.INT32:
        return 4
    if storage_t == ArrowType.INT64:
        return 8
    return 0


@always_inline
def _row_is_valid(validity: Optional[Bitmap[HeapRegion]], row: Int) -> Bool:
    if not validity:
        return True
    return validity.value().test(row)


def _dict_indices_to_storage(
    var raw: OwnedAlignedBuffer,
    length: Int,
    index_t: ArrowType,
    validity: Optional[Bitmap[HeapRegion]],
) raises -> OwnedAlignedBuffer:
    """Convert `length` indices of the declared `index_t` in `raw` (exactly
    `length * _dict_index_width(index_t)` bytes, copied from the producer) to
    the Column's storage: INT32 and INT64 as they are, the narrower types and
    UINT32 widened to INT32, UINT64 kept 8 bytes wide.

    A value the storage cannot hold (an unsigned index above the signed
    maximum) is refused on a valid row and stored as 0 on a null row.
    """
    if index_t == ArrowType.INT32 or index_t == ArrowType.INT64:
        return raw^
    if index_t == ArrowType.UINT64:
        for i in range(length):
            var v = raw.read_u64_le_at(i * 8)
            if v > Int64.MAX.cast[DType.uint64]():
                if _row_is_valid(validity, i):
                    raise _does_not_fit(String(v), i, "INT64")
                raw.write_u64_le_at(i * 8, 0)
        return raw^
    var out = OwnedAlignedBuffer(max(length * 4, 1))
    out.set_length(Int64(length * 4))
    for i in range(length):
        var v: Int
        if index_t == ArrowType.INT8:
            v = Int(raw.read_u8_at(i))
            if v >= 0x80:  # two's complement: sign-extend
                v -= 0x100
        elif index_t == ArrowType.UINT8:
            v = Int(raw.read_u8_at(i))
        elif index_t == ArrowType.INT16:
            v = Int(raw.read_u16_le_at(i * 2))
            if v >= 0x8000:  # two's complement: sign-extend
                v -= 0x10000
        elif index_t == ArrowType.UINT16:
            v = Int(raw.read_u16_le_at(i * 2))
        else:  # UINT32
            v = Int(raw.read_u32_le_at(i * 4))
            if v > Int(Int32.MAX):
                if _row_is_valid(validity, i):
                    raise _does_not_fit(String(v), i, "INT32")
                v = 0
        out.write_i32_le_at(i * 4, Int32(v))
    return out^


def _does_not_fit(value: String, row: Int, storage: String) -> Error:
    return Error(
        "from_arrow_c_stream: dictionary index " + value + " at row "
        + String(row) + " does not fit the " + storage + " index storage"
    )


# --- decimal ---------------------------------------------------------------------


def _check_decimal_params(fmt: String, p: Int, s: Int, bit_width: Int) raises:
    """Refuse a decimal (precision, scale) Komira cannot represent as it is.

    `fmt` is the format string the values came from, for the message.
    """
    var max_p = 76 if bit_width == 256 else 38
    if p < 1 or p > max_p:
        raise Error(
            "from_arrow_c_stream: decimal format '" + fmt + "': precision "
            + String(p) + " is outside [1, " + String(max_p) + "] for a "
            + String(bit_width) + "-bit decimal"
        )
    if s < 0:
        raise Error(
            "UnsupportedArrowCABIType: decimal format '" + fmt + "': scale "
            + String(s) + " is negative; negative scales are not supported"
        )
    if s > p:
        raise Error(
            "UnsupportedArrowCABIType: decimal format '" + fmt + "': scale "
            + String(s) + " exceeds precision " + String(p)
            + "; such scales are not supported"
        )


def _parse_decimal_int(fmt: String, token: String) raises -> Int:
    """A decimal integer token: an optional '-' then 1 to 9 digits."""
    var b = token.as_bytes()
    var n = len(b)
    var i = 0
    var neg = False
    if n > 0 and b[0] == UInt8(ord("-")):
        neg = True
        i = 1
    if n - i < 1 or n - i > 9:
        raise _malformed_decimal(fmt)
    var v = 0
    while i < n:
        var c = Int(b[i])
        if c < 0x30 or c > 0x39:
            raise _malformed_decimal(fmt)
        v = v * 10 + (c - 0x30)
        i += 1
    return -v if neg else v


def _malformed_decimal(fmt: String) -> Error:
    return Error(
        "from_arrow_c_stream: malformed decimal format '" + fmt
        + "' (expected d:P,S or d:P,S,W)"
    )


def _parse_decimal_format(fmt: String) raises -> Tuple[Int, Int]:
    """Parse `d:P,S[,W]` into (precision, scale), refusing what it cannot
    represent: a malformed string, a bit width other than 128 or 256, a
    precision outside the width's range, a negative scale or a scale above
    the precision. Nothing is replaced by a default.
    """
    var b = fmt.as_bytes()
    if len(b) < 2 or b[0] != UInt8(ord("d")) or b[1] != UInt8(ord(":")):
        raise _malformed_decimal(fmt)
    var tail = String(fmt[byte=2 : fmt.byte_length()])
    var parts = tail.split(",")
    if len(parts) != 2 and len(parts) != 3:
        raise _malformed_decimal(fmt)
    var p = _parse_decimal_int(fmt, String(parts[0]))
    var s = _parse_decimal_int(fmt, String(parts[1]))
    if p < 0:
        raise _malformed_decimal(fmt)
    var w = 128
    if len(parts) == 3:
        w = _parse_decimal_int(fmt, String(parts[2]))
        if w != 128 and w != 256:
            raise Error(
                "UnsupportedArrowCABIType: decimal bitwidth '" + String(w)
                + "' (only 128 and 256 supported)"
            )
    _check_decimal_params(fmt, p, s, w)
    return (p, s)
