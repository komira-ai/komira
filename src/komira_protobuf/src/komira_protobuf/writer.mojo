# =============================================================================
# writer.mojo — Protocol Buffers wire ENCODER (the inverse of reader.mojo).
# =============================================================================
#
# The general protobuf wire writer: the complete encoder surface, not scoped
# to any one message set — the symmetric flip of every reader.mojo decode
# primitive:
#
#   - varint            : base-128 LEB128
#   - sint32 / sint64   : zigzag-encoded varint
#   - fixed32 / fixed64 : little-endian fixed-width (incl. float / double)
#   - length-delimited  : string, bytes, embedded messages
#   - packed-repeated   : a length-delimited block of concatenated varints
#
# Every encoder appends to an owned `List[UInt8]`; sub-messages are encoded
# into a child buffer then length-prefixed into the parent. No UnsafePointer
# crosses any module boundary (owned List / String / Span only; pure index
# arithmetic).
# =============================================================================

from std.memory import bitcast

from .wire_types import (
    PB_WIRE_VARINT,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_FIXED32,
    zigzag_encode,
    zigzag_encode32,
)


# =============================================================================
# Core primitive writers — varint / tag / length-delimited.
# =============================================================================


def pb_write_varint(mut out: List[UInt8], value: UInt64):
    """Append `value` as a base-128 LEB128 varint (inverse of pb_read_varint).
    """
    var v = value
    while True:
        var b = UInt8(v & 0x7F)
        v >>= 7
        if v != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


@always_inline
def pb_write_tag(mut out: List[UInt8], field_number: Int, wire_type: Int):
    """Append a protobuf field tag = varint((field_number << 3) | wire_type)."""
    pb_write_varint(out, UInt64((field_number << 3) | wire_type))


@always_inline
def pb_write_varint_field(mut out: List[UInt8], field_number: Int, value: UInt64):
    """Append a complete varint field (tag + value)."""
    pb_write_tag(out, field_number, PB_WIRE_VARINT)
    pb_write_varint(out, value)


@always_inline
def pb_write_bool_field(mut out: List[UInt8], field_number: Int, value: Bool):
    """Append a complete bool field (a 0/1 varint)."""
    pb_write_varint_field(out, field_number, UInt64(1) if value else UInt64(0))


def pb_write_len_field(
    mut out: List[UInt8], field_number: Int, payload: Span[UInt8, _]
):
    """Append a complete length-delimited field (tag + varint(len) + payload).
    """
    pb_write_tag(out, field_number, PB_WIRE_LEN)
    pb_write_varint(out, UInt64(len(payload)))
    for i in range(len(payload)):
        out.append(payload[i])


# =============================================================================
# sint32 / sint64 — zigzag-encoded varint fields.
# =============================================================================


def pb_write_sint64_field(mut out: List[UInt8], field_number: Int, value: Int64):
    """Append a zigzag-encoded sint64 varint field."""
    pb_write_tag(out, field_number, PB_WIRE_VARINT)
    pb_write_varint(out, zigzag_encode(value))


def pb_write_sint32_field(mut out: List[UInt8], field_number: Int, value: Int32):
    """Append a zigzag-encoded sint32 varint field."""
    pb_write_tag(out, field_number, PB_WIRE_VARINT)
    pb_write_varint(out, UInt64(zigzag_encode32(value)))


# =============================================================================
# fixed32 / fixed64 — little-endian fixed-width fields (incl. float / double).
# =============================================================================


def pb_write_fixed64_field(
    mut out: List[UInt8], field_number: Int, bits: UInt64
):
    """Append a fixed64 field — 8 little-endian bytes of `bits`."""
    pb_write_tag(out, field_number, PB_WIRE_FIXED64)
    for k in range(8):
        out.append(UInt8((bits >> UInt64(8 * k)) & 0xFF))


def pb_write_fixed32_field(
    mut out: List[UInt8], field_number: Int, bits: UInt32
):
    """Append a fixed32 field — 4 little-endian bytes of `bits`."""
    pb_write_tag(out, field_number, PB_WIRE_FIXED32)
    for k in range(4):
        out.append(UInt8((bits >> UInt32(8 * k)) & 0xFF))


def pb_write_double_field(
    mut out: List[UInt8], field_number: Int, value: Float64
):
    """Append a fixed64 double field (little-endian IEEE-754 bits)."""
    pb_write_fixed64_field(out, field_number, bitcast[DType.uint64, 1](value))


def pb_write_float_field(
    mut out: List[UInt8], field_number: Int, value: Float32
):
    """Append a fixed32 float field (little-endian IEEE-754 bits)."""
    pb_write_fixed32_field(out, field_number, bitcast[DType.uint32, 1](value))


# =============================================================================
# Length-delimited payload writers — string / bytes / embedded message.
# =============================================================================


def pb_write_string_field(
    mut out: List[UInt8], field_number: Int, value: String
):
    """Append a length-delimited UTF-8 string field."""
    var bytes = value.as_bytes()
    pb_write_tag(out, field_number, PB_WIRE_LEN)
    pb_write_varint(out, UInt64(len(bytes)))
    for i in range(len(bytes)):
        out.append(bytes[i])


@always_inline
def pb_write_bytes_field(
    mut out: List[UInt8], field_number: Int, value: Span[UInt8, _]
):
    """Append a length-delimited `bytes` field."""
    pb_write_len_field(out, field_number, value)


def pb_write_message_field(
    mut out: List[UInt8], field_number: Int, message: List[UInt8]
):
    """Append a length-delimited embedded message field."""
    pb_write_len_field(out, field_number, Span(message))


# =============================================================================
# Packed-repeated scalar writers — a single length-delimited field whose
# payload is the concatenated varints / fixed-width values.
#
# NOTE (perf): packed-repeated scalar encode is the future SIMD
# escalation site — a wide pack of the value block. Today it is a scalar loop.
# =============================================================================


def pb_write_packed_varints(
    mut out: List[UInt8], field_number: Int, values: List[UInt64]
):
    """Append a packed-repeated varint field (one LEN field, concatenated
    varints). An empty `values` writes nothing — proto3 omits empty repeated."""
    if len(values) == 0:
        return
    var packed = List[UInt8]()
    for i in range(len(values)):
        pb_write_varint(packed, values[i])
    pb_write_len_field(out, field_number, Span(packed))


def pb_write_packed_sint64(
    mut out: List[UInt8], field_number: Int, values: List[Int64]
):
    """Append a packed-repeated sint64 (zigzag) field."""
    if len(values) == 0:
        return
    var packed = List[UInt8]()
    for i in range(len(values)):
        pb_write_varint(packed, zigzag_encode(values[i]))
    pb_write_len_field(out, field_number, Span(packed))


def pb_write_packed_fixed64(
    mut out: List[UInt8], field_number: Int, values: List[UInt64]
):
    """Append a packed-repeated fixed64 field."""
    if len(values) == 0:
        return
    var packed = List[UInt8]()
    for i in range(len(values)):
        var bits = values[i]
        for k in range(8):
            packed.append(UInt8((bits >> UInt64(8 * k)) & 0xFF))
    pb_write_len_field(out, field_number, Span(packed))


def pb_write_packed_fixed32(
    mut out: List[UInt8], field_number: Int, values: List[UInt32]
):
    """Append a packed-repeated fixed32 field."""
    if len(values) == 0:
        return
    var packed = List[UInt8]()
    for i in range(len(values)):
        var bits = values[i]
        for k in range(4):
            packed.append(UInt8((bits >> UInt32(8 * k)) & 0xFF))
    pb_write_len_field(out, field_number, Span(packed))
