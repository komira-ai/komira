# =============================================================================
# komira_db_postgres/wire/pg_binary.mojo — binary-format codecs for the closed 7-OID set
# =============================================================================
#
# The Postgres BINARY wire format
# (format code 1) for the closed OID set, matching pg's per-type `send` /
# `recv` functions exactly. The extended query protocol (Parse/Bind/Describe/
# Execute/Sync) binds params and reads results in this format so the typed DB
# layer gets exact-typed values with no text-parse ambiguity.
#
#   INT4   (OID 23)    int4send:   4-byte big-endian
#   INT8   (OID 20)    int8send:   8-byte big-endian
#   TEXT   (OID 25)    textsend:   raw UTF-8 bytes (no length prefix in the
#   VARCHAR(OID 1043)              value body — the Bind/DataRow frames carry
#                                  the Int32 length around the value)
#   UUID   (OID 2950)  uuid_send:  16 raw bytes
#   JSONB  (OID 3802)  jsonb_send: 1 version byte (0x01) + UTF-8 text
#   TIMESTAMPTZ (1184) timestamptz_send: 8-byte big-endian signed int,
#                                  MICROSECONDS since 2000-01-01 00:00:00 UTC
#                                  (the Postgres epoch — NOT the unix epoch).
#   TEXT[] (OID 1009)  array_send: the pg binary array header + elements
#                                  (see encode/decode_text_array below).
#
# Epoch offset (the fiddly one): pg's TIMESTAMPTZ counts microseconds from
# 2000-01-01, unix counts seconds from 1970-01-01. The gap is
#   946684800 seconds == 946684800000000 microseconds.
# So  pg_micros = unix_micros - 946684800000000  and the inverse adds it back.
#
# Encapsulation: every surface is List[UInt8] / Span / String / typed scalars
# / InlineArray. ZERO UnsafePointer crosses any boundary. All produced /
# consumed values are single-level Lists in Movable structs — never stored in
# a byte-backed slab, so there is no stale-pointer hazard on reuse.
# =============================================================================

from komira_db_postgres.wire.pgwire import (
    put_i32_be,
    put_i16_be,
    read_i16_be,
    read_i32_be,
    owned_utf8_string,
)

# NOTE: pg_binary is the LOWER layer (pg_types imports the encoders here for
# eager PgValue binary bodies), so it must NOT import from pg_types — that
# would be an import cycle. The single OID it needs (the TEXT element OID for
# the array header) is a local literal, kept in sync with pg_types.OID_TEXT.
comptime _OID_TEXT_ELEM: Int32 = 25  # == pg_types.OID_TEXT


# Microseconds between the unix epoch (1970-01-01) and the pg epoch
# (2000-01-01). 30 years incl. leap days 1972..2000 == 10957 days.
comptime PG_EPOCH_OFFSET_MICROS: Int64 = 946684800000000


# -----------------------------------------------------------------------------
# 64-bit big-endian helpers (pgwire.mojo only ships 16/32-bit).
# -----------------------------------------------------------------------------
def put_i64_be(mut buf: List[UInt8], v: Int64):
    var u = UInt64(v)
    buf.append(UInt8((u >> 56) & 0xFF))
    buf.append(UInt8((u >> 48) & 0xFF))
    buf.append(UInt8((u >> 40) & 0xFF))
    buf.append(UInt8((u >> 32) & 0xFF))
    buf.append(UInt8((u >> 24) & 0xFF))
    buf.append(UInt8((u >> 16) & 0xFF))
    buf.append(UInt8((u >> 8) & 0xFF))
    buf.append(UInt8(u & 0xFF))


def read_i64_be(buf: Span[UInt8, _], off: Int) -> Int64:
    var u = (
        (UInt64(Int(buf[off])) << 56)
        | (UInt64(Int(buf[off + 1])) << 48)
        | (UInt64(Int(buf[off + 2])) << 40)
        | (UInt64(Int(buf[off + 3])) << 32)
        | (UInt64(Int(buf[off + 4])) << 24)
        | (UInt64(Int(buf[off + 5])) << 16)
        | (UInt64(Int(buf[off + 6])) << 8)
        | UInt64(Int(buf[off + 7]))
    )
    return Int64(u)


# -----------------------------------------------------------------------------
# UUID hex <-> 16 bytes (binary form is the raw 16 bytes).
# -----------------------------------------------------------------------------
def _hex_nibble(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return c - UInt8(ord("A")) + UInt8(10)
    raise Error("pg_binary: invalid hex nibble in UUID")


def uuid_hex_to_bytes(s: String) raises -> Array[UInt8, 16]:
    """Canonical hyphenated UUID hex -> 16 raw bytes (the binary wire form)."""
    var b = s.as_bytes()
    var out = Array[UInt8, 16](fill=0)
    var oi = 0
    var i = 0
    var n = len(b)
    while i < n and oi < 16:
        if b[i] == UInt8(ord("-")):
            i += 1
            continue
        if i + 1 >= n:
            raise Error("pg_binary: truncated UUID hex")
        var hi = _hex_nibble(b[i])
        var lo = _hex_nibble(b[i + 1])
        out[oi] = (hi << 4) | lo
        oi += 1
        i += 2
    if oi != 16:
        raise Error("pg_binary: UUID did not yield 16 bytes")
    return out^


def _hex_char(nibble: UInt8) -> UInt8:
    if nibble < UInt8(10):
        return UInt8(ord("0")) + nibble
    return UInt8(ord("a")) + (nibble - UInt8(10))


def uuid_bytes_to_hex(b: Span[UInt8, _]) -> String:
    """16 raw bytes -> canonical hyphenated UUID hex (8-4-4-4-12)."""
    var out = String()
    for i in range(16):
        if i == 4 or i == 6 or i == 8 or i == 10:
            out += "-"
        var byte = b[i] if i < len(b) else UInt8(0)
        out += chr(Int(_hex_char((byte >> 4) & 0xF)))
        out += chr(Int(_hex_char(byte & 0xF)))
    return out^


# =============================================================================
# Binary ENCODE — value body bytes for a Bind param (NO Int32 length prefix;
# the Bind frame writes the length around the body).
# =============================================================================
def encode_int4_binary(v: Int32) -> List[UInt8]:
    var out = List[UInt8]()
    put_i32_be(out, v)
    return out^


def encode_int8_binary(v: Int64) -> List[UInt8]:
    var out = List[UInt8]()
    put_i64_be(out, v)
    return out^


def encode_text_binary(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def encode_uuid_binary(hex: String) raises -> List[UInt8]:
    var raw = uuid_hex_to_bytes(hex)
    var out = List[UInt8]()
    for i in range(16):
        out.append(raw[i])
    return out^


def encode_jsonb_binary(s: String) -> List[UInt8]:
    # jsonb_send: 1 version byte (currently 1) followed by the UTF-8 text.
    var out = List[UInt8]()
    out.append(UInt8(1))
    for b in s.as_bytes():
        out.append(b)
    return out^


def encode_timestamptz_binary(unix_micros: Int64) -> List[UInt8]:
    # The carrier value is microseconds since the UNIX epoch; convert to the
    # pg epoch (2000-01-01) before writing the 8-byte BE integer.
    var pg_micros = unix_micros - PG_EPOCH_OFFSET_MICROS
    var out = List[UInt8]()
    put_i64_be(out, pg_micros)
    return out^


def encode_text_array_binary(elements: List[String]) -> List[UInt8]:
    """Pg binary array_send for a 1-D text[] with NO NULL elements.

    Layout:
      Int32 ndim (1)
      Int32 hasnull flag (0)
      Int32 element OID (TEXT == 25)
      per dim: Int32 dim length, Int32 lower bound (1)
      per element: Int32 byte length, then the raw UTF-8 bytes.
    An empty array is ndim=0 with no dimension/element data.
    """
    var out = List[UInt8]()
    var n = len(elements)
    if n == 0:
        put_i32_be(out, 0)  # ndim
        put_i32_be(out, 0)  # hasnull
        put_i32_be(out, _OID_TEXT_ELEM)  # element OID
        return out^
    put_i32_be(out, 1)  # ndim
    put_i32_be(out, 0)  # hasnull
    put_i32_be(out, _OID_TEXT_ELEM)  # element OID
    put_i32_be(out, Int32(n))  # dim 0 length
    put_i32_be(out, 1)  # dim 0 lower bound (pg arrays are 1-based)
    for e in elements:
        var eb = e.as_bytes()
        put_i32_be(out, Int32(len(eb)))
        for b in eb:
            out.append(b)
    return out^


# =============================================================================
# Binary DECODE — value body bytes from a binary-format DataRow column.
# =============================================================================
def decode_int4_binary(b: Span[UInt8, _]) raises -> Int32:
    if len(b) < 4:
        raise Error("pg_binary: INT4 body shorter than 4 bytes")
    return read_i32_be(b, 0)


def decode_int8_binary(b: Span[UInt8, _]) raises -> Int64:
    if len(b) < 8:
        raise Error("pg_binary: INT8 body shorter than 8 bytes")
    return read_i64_be(b, 0)


def decode_text_binary(b: Span[UInt8, _]) -> String:
    var out = List[UInt8]()
    for byte in b:
        out.append(byte)
    return owned_utf8_string(out)


def decode_uuid_binary(b: Span[UInt8, _]) raises -> Array[UInt8, 16]:
    if len(b) < 16:
        raise Error("pg_binary: UUID body shorter than 16 bytes")
    var out = Array[UInt8, 16](fill=0)
    for i in range(16):
        out[i] = b[i]
    return out^


def decode_jsonb_binary(b: Span[UInt8, _]) raises -> String:
    # 1 version byte then UTF-8. Reject an unknown version so we never hand
    # back mis-framed bytes silently.
    if len(b) < 1:
        raise Error("pg_binary: JSONB body empty (missing version byte)")
    if b[0] != UInt8(1):
        raise Error(
            "pg_binary: unexpected JSONB version byte "
            + String(Int(b[0]))
            + " (expected 1)"
        )
    var out = List[UInt8]()
    for i in range(1, len(b)):
        out.append(b[i])
    return owned_utf8_string(out)


def decode_timestamptz_binary(b: Span[UInt8, _]) raises -> Int64:
    """8-byte BE µs-since-2000 -> µs-since-UNIX-epoch (adds the offset back)."""
    if len(b) < 8:
        raise Error("pg_binary: TIMESTAMPTZ body shorter than 8 bytes")
    var pg_micros = read_i64_be(b, 0)
    return pg_micros + PG_EPOCH_OFFSET_MICROS


def decode_text_array_binary(b: Span[UInt8, _]) raises -> List[String]:
    """Pg binary array_recv for a 1-D text[]. Returns the element strings.
    A NULL element raises (the closed-set contract is non-null text[]), and
    so does a body that ends before a declared element. An empty array
    (ndim 0) returns an empty list."""
    var out = List[String]()
    var n = len(b)
    if n < 12:
        raise Error("pg_binary: text[] header shorter than 12 bytes")
    var ndim = Int(read_i32_be(b, 0))
    # b[4:8] hasnull flag, b[8:12] element OID — not needed for decode shape.
    var off = 12
    if ndim == 0:
        return out^  # empty array
    if ndim != 1:
        raise Error(
            "pg_binary: text[] ndim=" + String(ndim) + " (only 1-D supported)"
        )
    if off + 8 > n:
        raise Error("pg_binary: text[] truncated dimension header")
    var dim_len = Int(read_i32_be(b, off))
    off += 8  # skip dim length (4) + lower bound (4)
    for e in range(dim_len):
        if off + 4 > n:
            raise Error("pg_binary: text[] truncated element length")
        var elen = Int(read_i32_be(b, off))
        off += 4
        if elen < 0:
            raise Error("pg_binary: text[] contains a NULL element")
        if elen > n - off:
            raise Error(
                "pg_binary: text[] truncated element "
                + String(e)
                + ": declares "
                + String(elen)
                + " bytes, "
                + String(n - off)
                + " present"
            )
        var eb = List[UInt8]()
        for i in range(off, off + elen):
            eb.append(b[i])
        off += elen
        out.append(owned_utf8_string(eb))
    return out^
