# =============================================================================
# ivp_bytes.mojo — the IVP low-level self-describing byte cursor.
# =============================================================================
#
# The primitive read/write cursor
# every IVP wire message (ticket, Expr tree, response envelope) is built on.
# The encoding is LEB128 varints + zigzag signed varints + little-endian fixed
# floats + varint-length-prefixed byte strings — the same shape protobuf uses,
# but WITHOUT field tags: an IVP message is a fixed positional record, so a
# decoder walks the exact field order the encoder wrote.
#
# WHY NOT protobuf field-tagged encoding: a ticket is a REMOTE-CLIENT-POSTED,
# UNTRUSTED byte blob. A positional record with a strict cursor that raises on
# ANY malformed byte (truncated varint, length running past the buffer end,
# trailing bytes) is far easier to validate fail-closed than a tag-skipping
# protobuf reader that silently tolerates unknown fields. The varint primitive
# itself is REUSED from komira_protobuf (pb_write_varint / pb_read_varint) —
# the one battle-tested LEB128 impl — so we do not fork the varint codec.
#
# Encapsulation: the writer is a `List[UInt8]` accumulator; the
# reader walks a `Span[UInt8]` view with pure index arithmetic. No UnsafePointer
# crosses this module boundary. Mojo 1.0.0b2 (def-only).
# =============================================================================

from std.memory import bitcast

from komira_protobuf import pb_write_varint, pb_read_varint


# A hard cap on any single length-prefixed byte string in an IVP message. A
# remote client cannot make the decoder allocate an arbitrarily large String
# from a small ticket: a declared length past this cap raises immediately,
# BEFORE any allocation. 16 MiB is generous for a column name / glob / literal
# and far below anything that could exhaust a worker.
comptime IVP_MAX_BYTESTRING_LEN: Int = 16 * 1024 * 1024


def _is_valid_utf8(b: Span[UInt8, _]) -> Bool:
    """RFC 3629 UTF-8 well-formedness: 1-byte ASCII, 2/3/4-byte sequences with
    valid continuation bytes, rejecting overlong encodings, surrogates
    (U+D800..U+DFFF), and > U+10FFFF. The choke point for every untrusted IVP
    string (column name / locator / literal / alias)."""
    var n = len(b)
    var i = 0
    while i < n:
        var c = Int(b[i])
        if c < 0x80:
            i = i + 1
            continue
        var need: Int
        var lo: Int  # min codepoint for the length (overlong rejection)
        var cp: Int
        if (c & 0xE0) == 0xC0:
            need = 1
            cp = c & 0x1F
            lo = 0x80
        elif (c & 0xF0) == 0xE0:
            need = 2
            cp = c & 0x0F
            lo = 0x800
        elif (c & 0xF8) == 0xF0:
            need = 3
            cp = c & 0x07
            lo = 0x10000
        else:
            return False  # invalid lead byte (0x80..0xBF or 0xF8..0xFF)
        if i + need >= n:
            return False  # truncated multibyte sequence
        var k = 1
        while k <= need:
            var cont = Int(b[i + k])
            if (cont & 0xC0) != 0x80:
                return False  # bad continuation byte
            cp = (cp << 6) | (cont & 0x3F)
            k = k + 1
        if cp < lo:
            return False  # overlong encoding
        if cp > 0x10FFFF:
            return False  # beyond Unicode
        if cp >= 0xD800 and cp <= 0xDFFF:
            return False  # UTF-16 surrogate half — illegal in UTF-8
        i = i + need + 1
    return True


struct IvpWriter(Movable):
    """Append-only IVP byte accumulator. Backed by an owned `List[UInt8]`."""

    var buf: List[UInt8]

    def __init__(out self):
        self.buf = List[UInt8]()

    def __init__(out self, capacity_hint: Int):
        self.buf = List[UInt8](capacity=capacity_hint)

    @always_inline
    def write_u8(mut self, v: UInt8):
        """Append one raw byte (tags, small enums, booleans)."""
        self.buf.append(v)

    @always_inline
    def write_bool(mut self, v: Bool):
        """Append a 0/1 byte."""
        self.buf.append(UInt8(1) if v else UInt8(0))

    @always_inline
    def write_uvarint(mut self, v: UInt64):
        """Append an unsigned LEB128 varint (counts, offsets, limits)."""
        pb_write_varint(self.buf, v)

    @always_inline
    def write_ivarint(mut self, v: Int64):
        """Append a signed value as a zigzag LEB128 varint (int literals)."""
        # zigzag: (n << 1) ^ (n >> 63) — maps small magnitudes (either sign)
        # to small varints.
        var zz = (UInt64(v) << 1) ^ UInt64(v >> 63)
        pb_write_varint(self.buf, zz)

    def write_f64(mut self, v: Float64):
        """Append a Float64 as 8 little-endian bytes (bit-exact, IEEE-754)."""
        var bits = bitcast[DType.uint64, 1](v)
        var i = 0
        while i < 8:
            self.buf.append(UInt8((bits >> UInt64(i * 8)) & 0xFF))
            i = i + 1

    def write_f32(mut self, v: Float32):
        """Append a Float32 as 4 little-endian bytes (bit-exact, IEEE-754)."""
        var bits = bitcast[DType.uint32, 1](v)
        var i = 0
        while i < 4:
            self.buf.append(UInt8((bits >> UInt32(i * 8)) & 0xFF))
            i = i + 1

    def write_string(mut self, s: String):
        """Append a UTF-8 string as varint(byte-len) + the bytes."""
        var b = s.as_bytes()
        var n = len(b)
        pb_write_varint(self.buf, UInt64(n))
        var i = 0
        while i < n:
            self.buf.append(b[i])
            i = i + 1

    def take_bytes(mut self) -> List[UInt8]:
        """Move the accumulated bytes out (leaves the writer with an empty
        buffer)."""
        var out = self.buf^
        self.buf = List[UInt8]()
        return out^


struct IvpReader(Movable):
    """Strict positional cursor over IVP bytes.

    Every read is bounds-checked and RAISES on any malformed / truncated /
    over-length input — the fail-closed contract the untrusted-ticket boundary
    depends on. OWNS its backing `List[UInt8]` (the `PbDecoder` pattern), so no
    borrowed-Span origin parameter propagates onto the recursive Expr decode
    signatures; the varint reader walks `Span(self.backing)` per call.
    """

    var backing: List[UInt8]
    var pos: Int

    def __init__(out self, var backing: List[UInt8]):
        self.backing = backing^
        self.pos = 0

    @staticmethod
    def from_span(data: Span[UInt8, _]) -> IvpReader:
        """Build a reader from a byte VIEW by copying it into an owned buffer
        (tickets are small; the ticket parse is not the hot data path)."""
        var buf = List[UInt8](capacity=len(data))
        for i in range(len(data)):
            buf.append(data[i])
        return IvpReader(buf^)

    @always_inline
    def remaining(self) -> Int:
        return len(self.backing) - self.pos

    @always_inline
    def at_end(self) -> Bool:
        return self.pos >= len(self.backing)

    def read_u8(mut self) raises -> UInt8:
        if self.pos >= len(self.backing):
            raise Error("ivp: truncated — expected a byte at end of buffer")
        var b = self.backing[self.pos]
        self.pos = self.pos + 1
        return b

    def read_bool(mut self) raises -> Bool:
        var b = self.read_u8()
        if b > UInt8(1):
            raise Error("ivp: malformed bool byte " + String(Int(b)))
        return b == UInt8(1)

    def read_uvarint(mut self) raises -> UInt64:
        var pv = pb_read_varint(Span(self.backing), self.pos)
        self.pos = pv.new_pos
        return pv.value

    def read_ivarint(mut self) raises -> Int64:
        var zz = self.read_uvarint()
        # inverse zigzag: (zz >> 1) ^ -(zz & 1)
        return Int64(zz >> 1) ^ (-(Int64(zz & 1)))

    def read_f64(mut self) raises -> Float64:
        if self.remaining() < 8:
            raise Error("ivp: truncated — expected 8 bytes for f64")
        var bits: UInt64 = 0
        var i = 0
        while i < 8:
            bits |= UInt64(Int(self.backing[self.pos + i])) << UInt64(i * 8)
            i = i + 1
        self.pos = self.pos + 8
        return bitcast[DType.float64, 1](bits)

    def read_f32(mut self) raises -> Float32:
        if self.remaining() < 4:
            raise Error("ivp: truncated — expected 4 bytes for f32")
        var bits: UInt32 = 0
        var i = 0
        while i < 4:
            bits |= UInt32(Int(self.backing[self.pos + i])) << UInt32(i * 8)
            i = i + 1
        self.pos = self.pos + 4
        return bitcast[DType.float32, 1](bits)

    def read_string(mut self) raises -> String:
        var n64 = self.read_uvarint()
        if n64 > UInt64(IVP_MAX_BYTESTRING_LEN):
            raise Error(
                "ivp: string length "
                + String(n64)
                + " exceeds cap "
                + String(IVP_MAX_BYTESTRING_LEN)
            )
        var n = Int(n64)
        if self.remaining() < n:
            raise Error(
                "ivp: truncated — declared string length "
                + String(n)
                + " runs past buffer end ("
                + String(self.remaining())
                + " left)"
            )
        var out = List[UInt8](capacity=n)
        var i = 0
        while i < n:
            out.append(self.backing[self.pos + i])
            i = i + 1
        self.pos = self.pos + n
        # Fail closed on malformed UTF-8: an IVP string is a column name /
        # locator / literal / alias — all UTF-8 by contract. `unsafe_from_utf8`
        # does NOT validate, so an untrusted ticket could smuggle invalid byte
        # sequences into a String; reject them here at the choke point.
        if not _is_valid_utf8(Span(out)):
            raise Error("ivp: string field is not valid UTF-8 (rejected)")
        return String(unsafe_from_utf8=Span(out))

    def expect_end(mut self) raises:
        """Assert the cursor consumed EXACTLY the whole buffer — trailing
        bytes are a malformed message (a padding / smuggling vector)."""
        if not self.at_end():
            raise Error(
                "ivp: "
                + String(self.remaining())
                + " trailing bytes after message end"
            )
