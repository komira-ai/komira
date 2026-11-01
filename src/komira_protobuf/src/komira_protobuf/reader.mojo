# =============================================================================
# reader.mojo — Protocol Buffers wire DECODER.
# =============================================================================
#
# The general protobuf wire reader: the complete decoder surface, not scoped
# to any one message set — every proto3 wire type:
#
#   - varint            : base-128 LEB128 (int32/64, uint32/64, enum, bool)
#   - sint32 / sint64   : zigzag-decoded varint
#   - fixed32 / fixed64 : little-endian fixed-width (incl. float / double)
#   - length-delimited  : string, bytes, embedded messages
#   - packed-repeated   : a length-delimited block of concatenated varints
#                         (the future SIMD escalation site)
#
# Plus a general TAG-DRIVEN FIELD-DISPATCH loop helper (`PbFieldCursor`) so a
# decoder of an arbitrary message can walk fields without hand-threading
# positions. The ORC footer decoder (`komira_orc`) keeps its hand-rolled loops
# (they are on a hot path); new decoders use PbFieldCursor.
#
# Encapsulation: the public API exposes only typed values — small
# result structs, Int/Int64/UInt64/Float scalars, String, List, raised Error.
# No UnsafePointer crosses the module boundary; the reader walks a
# `Span[UInt8, _]` view with pure index arithmetic.
# =============================================================================

from std.memory import bitcast

from .wire_types import (
    PB_WIRE_VARINT,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_FIXED32,
    zigzag_decode,
    zigzag_decode32,
)


# =============================================================================
# Named-result structs — heterogeneous tuple returns are awkward on Mojo
# 1.0.0b1. Each reader returns a small result struct (value + new position) so
# position threading stays explicit and pointer-free.
# =============================================================================


@fieldwise_init
struct PbVarint(Copyable, Movable, ImplicitlyCopyable):
    """A decoded protobuf base-128 varint + the position after it."""

    var value: UInt64
    var new_pos: Int


@fieldwise_init
struct PbTag(Copyable, Movable, ImplicitlyCopyable):
    """A decoded protobuf field tag: field number + wire type + position."""

    var field_number: Int
    var wire_type: Int
    var new_pos: Int


@fieldwise_init
struct PbLenField(Copyable, Movable, ImplicitlyCopyable):
    """A length-delimited field: [payload_start, payload_end) + position."""

    var payload_start: Int
    var payload_end: Int
    var new_pos: Int


# =============================================================================
# Core primitive readers — varint / tag / length-delimited / skip.
# =============================================================================


def pb_read_varint(bytes: Span[UInt8, _], pos: Int) raises -> PbVarint:
    """Decode a protobuf base-128 varint starting at `pos`.

    Little-endian groups of 7 bits; the high bit of each byte is the
    continuation flag. Caps at 10 bytes (the max for a 64-bit varint).
    """
    return _pb_read_varint_upto(bytes, pos, len(bytes), "buffer end")


@always_inline
def _pb_read_varint_upto(
    bytes: Span[UInt8, _], pos: Int, limit: Int, limit_name: StaticString
) raises -> PbVarint:
    """Decode a varint at `pos` whose bytes all lie before `limit`
    (`limit <= len(bytes)`; callers guarantee it). A varint still continuing
    at `limit` is refused with "varint runs past <limit_name>"."""
    var p = pos
    var shift: UInt64 = 0
    var acc: UInt64 = 0
    var count = 0
    while True:
        if p >= limit:
            raise Error(
                String("ProtobufError.MALFORMED: varint runs past ")
                + String(limit_name)
            )
        var b = bytes[p]
        p += 1
        count += 1
        acc |= UInt64(Int(b & 0x7F)) << shift
        if (b & 0x80) == 0:
            break
        shift += 7
        if count >= 10:
            raise Error("ProtobufError.MALFORMED: varint exceeds 10 bytes")
    return PbVarint(acc, p)


def pb_read_tag(bytes: Span[UInt8, _], pos: Int) raises -> PbTag:
    """Decode a protobuf field tag: `(field_number << 3) | wire_type`."""
    var v = pb_read_varint(bytes, pos)
    var key = v.value
    var wire_type = Int(key & 0x7)
    var field_number = Int(key >> 3)
    if field_number == 0:
        raise Error("ProtobufError.MALFORMED: field number 0 is illegal")
    return PbTag(field_number, wire_type, v.new_pos)


def pb_read_len_field(bytes: Span[UInt8, _], pos: Int) raises -> PbLenField:
    """Decode a length-delimited field header; return the payload span."""
    var v = pb_read_varint(bytes, pos)
    var payload_start = v.new_pos
    var payload_end = payload_start + Int(v.value)
    if payload_end > len(bytes) or payload_end < payload_start:
        raise Error(
            "ProtobufError.MALFORMED: length-delimited field runs past"
            " buffer end"
        )
    return PbLenField(payload_start, payload_end, payload_end)


def pb_skip_field(bytes: Span[UInt8, _], pos: Int, wire_type: Int) raises -> Int:
    """Skip a field of the given wire type; return the position after it.

    Used for unknown / not-yet-modeled fields so the parser stays
    forward-compatible — the proto3 skip-and-keep contract (an unknown field
    is skipped, never an error).
    """
    if wire_type == PB_WIRE_VARINT:
        var v = pb_read_varint(bytes, pos)
        return v.new_pos
    elif wire_type == PB_WIRE_FIXED64:
        if pos + 8 > len(bytes):
            raise Error("ProtobufError.MALFORMED: fixed64 past end")
        return pos + 8
    elif wire_type == PB_WIRE_LEN:
        var f = pb_read_len_field(bytes, pos)
        return f.payload_end
    elif wire_type == PB_WIRE_FIXED32:
        if pos + 4 > len(bytes):
            raise Error("ProtobufError.MALFORMED: fixed32 past end")
        return pos + 4
    raise Error(
        String("ProtobufError.MALFORMED: unknown wire type ")
        + String(wire_type)
    )


# =============================================================================
# Scalar readers — sint / fixed32 / fixed64 / float / double / bool.
# =============================================================================


@fieldwise_init
struct PbScalar32(Copyable, Movable, ImplicitlyCopyable):
    """A decoded fixed32 / float scalar + the position after it."""

    var value: UInt32
    var new_pos: Int


@fieldwise_init
struct PbScalar64(Copyable, Movable, ImplicitlyCopyable):
    """A decoded fixed64 / double scalar + the position after it."""

    var value: UInt64
    var new_pos: Int


def pb_read_sint64(bytes: Span[UInt8, _], pos: Int) raises -> Int64:
    """Decode a sint64: a zigzag-decoded varint.

    Returns the value only; a caller that needs the cursor threads `new_pos`
    via `pb_read_varint` directly.
    """
    var v = pb_read_varint(bytes, pos)
    return zigzag_decode(v.value)


def pb_read_sint32(bytes: Span[UInt8, _], pos: Int) raises -> Int32:
    """Decode a sint32: a zigzag-decoded varint."""
    var v = pb_read_varint(bytes, pos)
    return zigzag_decode32(UInt32(v.value & 0xFFFFFFFF))


def pb_read_fixed32(bytes: Span[UInt8, _], pos: Int) raises -> PbScalar32:
    """Decode a fixed32 (4 little-endian bytes) — fixed32 / sfixed32 / float."""
    if pos + 4 > len(bytes):
        raise Error("ProtobufError.MALFORMED: fixed32 past end")
    var acc: UInt32 = 0
    for k in range(4):
        acc |= UInt32(Int(bytes[pos + k])) << UInt32(8 * k)
    return PbScalar32(acc, pos + 4)


def pb_read_fixed64(bytes: Span[UInt8, _], pos: Int) raises -> PbScalar64:
    """Decode a fixed64 (8 little-endian bytes) — fixed64 / sfixed64 / double."""
    if pos + 8 > len(bytes):
        raise Error("ProtobufError.MALFORMED: fixed64 past end")
    var acc: UInt64 = 0
    for k in range(8):
        acc |= UInt64(Int(bytes[pos + k])) << UInt64(8 * k)
    return PbScalar64(acc, pos + 8)


def pb_read_float(bytes: Span[UInt8, _], pos: Int) raises -> Float32:
    """Decode a fixed32 IEEE-754 single-precision float."""
    var s = pb_read_fixed32(bytes, pos)
    return bitcast[DType.float32, 1](s.value)


def pb_read_double(bytes: Span[UInt8, _], pos: Int) raises -> Float64:
    """Decode a fixed64 IEEE-754 double-precision float."""
    var s = pb_read_fixed64(bytes, pos)
    return bitcast[DType.float64, 1](s.value)


@always_inline
def _pb_check_span(
    bytes: Span[UInt8, _], start: Int, end: Int, what: StaticString
) raises:
    """Validate a `[start, end)` payload span against the buffer — ONCE, at
    entry, before a single byte is touched.

    ⚠ THIS IS NOT AN ASSERT AND MUST NOT BECOME ONE. `Span.__getitem__` is
    bounds-checked only at ASSERT=safe/all; we ship ASSERT=none. Measured
    at ASSERT=none with this check absent:
    `pb_read_bytes(buf, 0, 1 << 31)` over a 2-byte buffer SIGSEGV'd (rc=139),
    and `pb_read_string(buf, 0, 64)` silently returned 64 bytes of adjacent
    heap. Both are the module's PUBLIC API (re-exported from
    `komira_protobuf`) and both are reached from the ORC footer decoder
    (`komira_orc`) and the protobuf-binary serde backend (`komira_proto_codec`).
    """
    if start < 0 or end < start or end > len(bytes):
        raise Error(
            String("ProtobufError.MALFORMED: ")
            + String(what)
            + " span ["
            + String(start)
            + ", "
            + String(end)
            + ") is not inside the "
            + String(len(bytes))
            + "-byte buffer"
        )


def pb_read_string(bytes: Span[UInt8, _], start: Int, end: Int) raises -> String:
    """Materialize a length-delimited UTF-8 field span into a String.

    The payload bytes are reconstructed verbatim via `String(unsafe_from_utf8
    =Span)` — a per-byte `chr()` would mis-decode any multibyte UTF-8 sequence
    (treating each byte as its own codepoint). protobuf `string` fields are
    UTF-8, so the raw byte span is the String content.

    Raises if `[start, end)` is not inside `bytes` — see `_pb_check_span`.
    """
    _pb_check_span(bytes, start, end, "string")
    var buf = List[UInt8]()
    for i in range(start, end):
        buf.append(bytes[i])
    return String(unsafe_from_utf8=Span(buf))


def pb_read_bytes(
    bytes: Span[UInt8, _], start: Int, end: Int
) raises -> List[UInt8]:
    """Materialize a length-delimited `bytes` field span into an owned List.

    Raises if `[start, end)` is not inside `bytes` — see `_pb_check_span`.
    """
    _pb_check_span(bytes, start, end, "bytes")
    var out = List[UInt8]()
    for i in range(start, end):
        out.append(bytes[i])
    return out^


# =============================================================================
# Packed-repeated scalar readers — a length-delimited block of concatenated
# varints. Both packed and non-packed encodings are spec-legal for a repeated
# scalar; this reader handles the packed (LEN-wrapped) form.
#
# NOTE (perf): packed-repeated scalar decode is the future SIMD
# escalation site — a wide unpack of the varint block. Today it is a scalar
# loop; flagged so a future SIMD pass has a named target.
# =============================================================================


comptime _PACKED_BLOCK_END = "the end of its packed block"


def pb_read_packed_varints(
    bytes: Span[UInt8, _], start: Int, end: Int
) raises -> List[UInt64]:
    """Decode a packed-repeated varint block `[start, end)` into a List.

    Raises MALFORMED if a varint runs past `end` (see `_PACKED_BLOCK_END`).
    """
    _pb_check_span(bytes, start, end, "packed varint block")
    var out = List[UInt64]()
    var ip = start
    while ip < end:
        # Bounded by the block, not the buffer: a varint still continuing at
        # `end` would otherwise be completed by the bytes that follow it.
        var v = _pb_read_varint_upto(bytes, ip, end, _PACKED_BLOCK_END)
        out.append(v.value)
        ip = v.new_pos
    return out^


def pb_read_packed_sint64(
    bytes: Span[UInt8, _], start: Int, end: Int
) raises -> List[Int64]:
    """Decode a packed-repeated sint64 (zigzag) block `[start, end)`.

    Raises MALFORMED if a varint runs past `end`.
    """
    _pb_check_span(bytes, start, end, "packed sint64 block")
    var out = List[Int64]()
    var ip = start
    while ip < end:
        # Bounded by the block, not the buffer: a varint still continuing at
        # `end` would otherwise be completed by the bytes that follow it.
        var v = _pb_read_varint_upto(bytes, ip, end, _PACKED_BLOCK_END)
        out.append(zigzag_decode(v.value))
        ip = v.new_pos
    return out^


@always_inline
def _pb_check_packed_width(
    start: Int, end: Int, width: Int, what: StaticString
) raises:
    """Refuse a fixed-width packed block whose length is not a whole number
    of values: the trailing bytes would otherwise be dropped silently."""
    if (end - start) % width != 0:
        raise Error(
            String("ProtobufError.MALFORMED: ")
            + String(what)
            + " length "
            + String(end - start)
            + " is not a multiple of "
            + String(width)
        )


def pb_read_packed_fixed32(
    bytes: Span[UInt8, _], start: Int, end: Int
) raises -> List[UInt32]:
    """Decode a packed-repeated fixed32 block `[start, end)`.

    Raises MALFORMED if `end - start` is not a multiple of 4.
    """
    _pb_check_span(bytes, start, end, "packed fixed32 block")
    _pb_check_packed_width(start, end, 4, "packed fixed32 block")
    var out = List[UInt32]()
    var ip = start
    while ip < end:
        var s = pb_read_fixed32(bytes, ip)
        out.append(s.value)
        ip = s.new_pos
    return out^


def pb_read_packed_fixed64(
    bytes: Span[UInt8, _], start: Int, end: Int
) raises -> List[UInt64]:
    """Decode a packed-repeated fixed64 block `[start, end)`.

    Raises MALFORMED if `end - start` is not a multiple of 8.
    """
    _pb_check_span(bytes, start, end, "packed fixed64 block")
    _pb_check_packed_width(start, end, 8, "packed fixed64 block")
    var out = List[UInt64]()
    var ip = start
    while ip < end:
        var s = pb_read_fixed64(bytes, ip)
        out.append(s.value)
        ip = s.new_pos
    return out^


# =============================================================================
# PbFieldCursor — a general tag-driven field-dispatch loop.
#
# A decoder of an arbitrary protobuf message walks its records by repeatedly
# reading a tag and dispatching on `field_number`. PbFieldCursor encapsulates
# the position threading: `has_next()` / `next_tag()` advance past the tag,
# and per-wire-type accessors read the value and advance the cursor. This is
# the general decode loop that generated decoders and any new hand-written
# decoder use — the ORC footer decoder keeps its existing hand-rolled
# loops (they are on a hot path).
#
# Encapsulation: PbFieldCursor holds an immutable Span view + an Int position.
# No UnsafePointer field; the Span carries the origin. All accessors raise on
# a malformed wire, a wire-type mismatch, OR a read that would cross the
# cursor's own `[start, end)` window.
#
# ⚠ THAT LAST CLAUSE IS LOAD-BEARING. The free primitives above bound
# themselves against `len(bytes)` — the WHOLE buffer — so a sub-cursor minted
# by `read_message()` would have NO enforced end: measured at ASSERT=none, a
# sub-message declaring 2 bytes read a 20-byte string out of its parent's
# bytes and returned it as its own field value. `_bound` is what makes the
# claim true. ⚠ The ORC footer decoder's hand-rolled loops (`komira_orc`)
# have the SAME shape and do NOT yet have this gate.
# =============================================================================


struct PbFieldCursor[origin: Origin[mut=False]](Copyable, Movable):
    """A tag-driven cursor over a protobuf message buffer `[start, end)`."""

    var _bytes: Span[UInt8, Self.origin]
    var _pos: Int
    var _end: Int
    # The wire type of the tag most recently returned by `next_tag()` — the
    # per-value accessors validate against it.
    var _cur_wire: Int

    def __init__(
        out self, bytes: Span[UInt8, Self.origin], start: Int, end: Int
    ) raises:
        """Cursor over `bytes[start:end)`.

        ⚠ VALIDATES `[start, end)` HERE — ONCE, at the boundary where the
        window is established — so no per-read accessor has to re-derive it.
        Measured at ASSERT=none without this:
        `PbFieldCursor(Span(two_byte_buf), 0, 1 << 20).has_next()` returned
        True, handing every accessor below a window 2^20 bytes past the end of
        a 2-byte allocation.
        """
        if start < 0 or end < start or end > len(bytes):
            raise Error(
                "ProtobufError.MALFORMED: PbFieldCursor window ["
                + String(start)
                + ", "
                + String(end)
                + ") is not inside the "
                + String(len(bytes))
                + "-byte buffer"
            )
        self._bytes = bytes
        self._pos = start
        self._end = end
        self._cur_wire = -1

    @staticmethod
    def over(bytes: Span[UInt8, Self.origin]) raises -> PbFieldCursor[Self.origin]:
        """Cursor over the whole `bytes` buffer."""
        return PbFieldCursor[Self.origin](bytes, 0, len(bytes))

    @always_inline
    def has_next(self) -> Bool:
        """True if at least one more field tag remains."""
        return self._pos < self._end

    @always_inline
    def _bound(imm self, new_pos: Int, what: StaticString) raises:
        """Reject a read that ran past THIS cursor's `_end`.

        ⚠ THE MESSAGE-BOUNDARY GATE, AND IT IS LOAD-BEARING. Every free
        primitive below (`pb_read_varint` / `pb_read_len_field` /
        `pb_read_fixed*`) bounds itself against `len(bytes)` — the whole
        buffer — NOT against this cursor's window. A sub-cursor minted by
        `read_message()` therefore had no enforced end at all: measured
        without this gate, a sub-message declaring a 2-byte length read a 20-byte
        string straight out of its PARENT's bytes and returned it as its own
        field value. That is field confusion across a message boundary on the
        decoder every Flight / gRPC / ORC / serde message shares.

        ONE comparison per FIELD (not per byte) — the check is on the
        already-computed end position, so it costs nothing per value decoded.
        """
        if new_pos > self._end:
            raise Error(
                String("ProtobufError.MALFORMED: ")
                + String(what)
                + " runs past the end of its message (ends at "
                + String(new_pos)
                + ", message ends at "
                + String(self._end)
                + ")"
            )

    def next_tag(mut self) raises -> PbTag:
        """Read the next field tag and advance past it. The cursor now points
        at the field's value; call the matching per-wire-type accessor."""
        var tag = pb_read_tag(self._bytes, self._pos)
        self._bound(tag.new_pos, "field tag")
        self._pos = tag.new_pos
        self._cur_wire = tag.wire_type
        return tag

    def read_varint(mut self) raises -> UInt64:
        """Read a VARINT-wire value (int/uint/enum/bool) and advance."""
        if self._cur_wire != PB_WIRE_VARINT:
            raise Error("ProtobufError.WIRE_MISMATCH: expected VARINT")
        var v = pb_read_varint(self._bytes, self._pos)
        self._bound(v.new_pos, "varint field")
        self._pos = v.new_pos
        return v.value

    def read_bool(mut self) raises -> Bool:
        """Read a VARINT-wire bool and advance."""
        return self.read_varint() != 0

    def read_sint64(mut self) raises -> Int64:
        """Read a VARINT-wire zigzag sint64 and advance."""
        return zigzag_decode(self.read_varint())

    def read_sint32(mut self) raises -> Int32:
        """Read a VARINT-wire zigzag sint32 and advance."""
        return zigzag_decode32(UInt32(self.read_varint() & 0xFFFFFFFF))

    def read_fixed32(mut self) raises -> UInt32:
        """Read a FIXED32-wire value and advance."""
        if self._cur_wire != PB_WIRE_FIXED32:
            raise Error("ProtobufError.WIRE_MISMATCH: expected FIXED32")
        var s = pb_read_fixed32(self._bytes, self._pos)
        self._bound(s.new_pos, "fixed32 field")
        self._pos = s.new_pos
        return s.value

    def read_fixed64(mut self) raises -> UInt64:
        """Read a FIXED64-wire value and advance."""
        if self._cur_wire != PB_WIRE_FIXED64:
            raise Error("ProtobufError.WIRE_MISMATCH: expected FIXED64")
        var s = pb_read_fixed64(self._bytes, self._pos)
        self._bound(s.new_pos, "fixed64 field")
        self._pos = s.new_pos
        return s.value

    def read_float(mut self) raises -> Float32:
        """Read a FIXED32-wire IEEE-754 float and advance."""
        return bitcast[DType.float32, 1](self.read_fixed32())

    def read_double(mut self) raises -> Float64:
        """Read a FIXED64-wire IEEE-754 double and advance."""
        return bitcast[DType.float64, 1](self.read_fixed64())

    def read_len(mut self) raises -> PbLenField:
        """Read a LEN-wire length-delimited header and advance past the field.
        The returned `[payload_start, payload_end)` indexes into the buffer."""
        if self._cur_wire != PB_WIRE_LEN:
            raise Error("ProtobufError.WIRE_MISMATCH: expected LEN")
        var f = pb_read_len_field(self._bytes, self._pos)
        # `pb_read_len_field` only proved the payload is inside the BUFFER.
        # This is what proves it is inside THIS MESSAGE — the check whose
        # absence let a 2-byte sub-message return a 20-byte string.
        self._bound(f.payload_end, "length-delimited field")
        self._pos = f.new_pos
        return f

    def read_string(mut self) raises -> String:
        """Read a LEN-wire UTF-8 string and advance."""
        var f = self.read_len()
        return pb_read_string(self._bytes, f.payload_start, f.payload_end)

    def read_bytes(mut self) raises -> List[UInt8]:
        """Read a LEN-wire `bytes` field into an owned List and advance."""
        var f = self.read_len()
        return pb_read_bytes(self._bytes, f.payload_start, f.payload_end)

    def read_message(mut self) raises -> PbFieldCursor[Self.origin]:
        """Read a LEN-wire embedded message; return a sub-cursor over its
        payload. The parent cursor advances past the whole sub-message."""
        var f = self.read_len()
        return PbFieldCursor[Self.origin](
            self._bytes, f.payload_start, f.payload_end
        )

    def read_packed_varints(mut self) raises -> List[UInt64]:
        """Read a LEN-wire packed-repeated varint block and advance."""
        var f = self.read_len()
        return pb_read_packed_varints(
            self._bytes, f.payload_start, f.payload_end
        )

    def read_packed_sint64(mut self) raises -> List[Int64]:
        """Read a LEN-wire packed-repeated sint64 block and advance."""
        var f = self.read_len()
        return pb_read_packed_sint64(
            self._bytes, f.payload_start, f.payload_end
        )

    def skip(mut self) raises:
        """Skip the current field's value (unknown-field forward-compat)."""
        var np = pb_skip_field(self._bytes, self._pos, self._cur_wire)
        self._bound(np, "skipped field")
        self._pos = np
