# =============================================================================
# komira_crypto/cert/asn1.mojo — ASN.1 DER decoder (X.690 + RFC 5280)
# =============================================================================
#
# Implements an ASN.1 DER
# Tag-Length-Value (TLV) parser plus per-primitive value decoders sufficient
# for X.509 cert parsing per RFC 5280 §4 + X.690 BER/DER §8.
#
# # API shape
#
# Callers consume two surfaces:
#
#   1. The TLV walker — `der_parse_tlv(buf, pos)` returns a `DerTlv` record
#      (tag, value_pos, value_len, end_pos). Re-slicing the value bytes is
#      the caller's responsibility (`buf[tlv.value_pos : tlv.value_pos +
#      tlv.value_len]`). This avoids the Mojo 1.0.0b1 "no memory origin in
#      origin specifier" issue when returning sub-Spans across fn calls.
#
#   2. The per-primitive decoders — `der_parse_boolean(value)`,
#      `der_parse_integer_to_int64(value)`, etc. — operate on the value
#      Span and produce typed Mojo values (Bool / Int64 / List[UInt8] /
#      String / List[UInt32] for OID / DerTime).
#
# # Encapsulation invariants
#
#   * ZERO UnsafePointer in any public function signature.
#   * ZERO wildcard origins — `Span[UInt8, _]` is origin-inferred per call
#     site, NOT wildcard widening.
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * All DerTag / DerTlv / DerTime are POD structs (Copyable + Movable +
#     Deinitable). No heap ownership of byte buffers; sub-slice
#     re-construction is on the caller.
#
# # Error policy
#
# All malformed input raises with a descriptive Error string. The X.509
# parser layer (`x509.mojo`) catches and re-raises with cert-specific
# context. Pure 0-byte buffer, truncated length, length-overflow,
# unsupported tag — all raise rather than crash.
#
# # X.509-relevant subset (NOT full ASN.1)
#
# This decoder covers only the universal-class primitive tags + the
# constructed types (SEQUENCE, SET) + context-specific tags (the [0]..[3]
# EXPLICIT / IMPLICIT tags X.509 uses for version, issuerUniqueID,
# subjectUniqueID, extensions). Long-form tag-number encoding (>= 31)
# is parsed but unused at the cert level. CHOICE, REAL, ENUMERATED,
# T61String, VisibleString, GraphicString, GeneralString, etc. are NOT
# implemented — encountering one raises.
# =============================================================================


# -----------------------------------------------------------------------------
# Tag-class constants (X.690 §8.1.2.2)
# -----------------------------------------------------------------------------

comptime ASN1_CLASS_UNIVERSAL = UInt8(0)
comptime ASN1_CLASS_APPLICATION = UInt8(1)
comptime ASN1_CLASS_CONTEXT = UInt8(2)
comptime ASN1_CLASS_PRIVATE = UInt8(3)


# -----------------------------------------------------------------------------
# Universal-class tag numbers (X.690 §8 + ITU-T X.680 §47, X.509-relevant subset)
# -----------------------------------------------------------------------------

comptime ASN1_TAG_BOOLEAN = UInt32(1)            # 0x01
comptime ASN1_TAG_INTEGER = UInt32(2)            # 0x02
comptime ASN1_TAG_BIT_STRING = UInt32(3)         # 0x03
comptime ASN1_TAG_OCTET_STRING = UInt32(4)       # 0x04
comptime ASN1_TAG_NULL = UInt32(5)               # 0x05
comptime ASN1_TAG_OID = UInt32(6)                # 0x06
comptime ASN1_TAG_UTF8_STRING = UInt32(12)       # 0x0C
comptime ASN1_TAG_SEQUENCE = UInt32(16)          # 0x10 (always constructed)
comptime ASN1_TAG_SET = UInt32(17)               # 0x11 (always constructed)
comptime ASN1_TAG_PRINTABLE_STRING = UInt32(19)  # 0x13
comptime ASN1_TAG_IA5_STRING = UInt32(22)        # 0x16
comptime ASN1_TAG_UTC_TIME = UInt32(23)          # 0x17
comptime ASN1_TAG_GENERALIZED_TIME = UInt32(24)  # 0x18


# -----------------------------------------------------------------------------
# Core POD types
# -----------------------------------------------------------------------------


struct DerTag(
    TrivialRegisterPassable,
    Copyable,
    ImplicitlyCopyable,
    Movable,
    Deinitable,
):
    """An ASN.1 tag (X.690 §8.1.2).

    `class_` is one of `ASN1_CLASS_{UNIVERSAL, APPLICATION, CONTEXT, PRIVATE}`.
    `constructed` is True for constructed encodings (SEQUENCE, SET, etc.).
    `tag_number` is the tag number — for universal-class tags this is the
    primitive type identifier (INTEGER=2, OCTET STRING=4, etc.); for
    context-specific tags it's the bracketed `[N]` index.
    """
    var class_: UInt8
    var constructed: Bool
    var tag_number: UInt32

    def __init__(out self, class_: UInt8, constructed: Bool, tag_number: UInt32):
        self.class_ = class_
        self.constructed = constructed
        self.tag_number = tag_number


struct DerTlv(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """A parsed Tag-Length-Value record.

    `tag`         the parsed tag.
    `value_pos`   absolute byte offset where the value bytes start.
    `value_len`   length of the value bytes.
    `end_pos`     absolute byte offset just past the value (next-TLV pos).

    The caller re-slices `buf[value_pos : value_pos + value_len]` to get a
    `Span` over the value bytes. This shape is forced by Mojo 1.0.0b1's
    "no memory origin in origin specifier" issue when a function tries to
    return a sub-Span derived from a parameter Span.
    """
    var tag: DerTag
    var value_pos: Int
    var value_len: Int
    var end_pos: Int

    def __init__(out self, tag: DerTag, value_pos: Int, value_len: Int, end_pos: Int):
        self.tag = tag
        self.value_pos = value_pos
        self.value_len = value_len
        self.end_pos = end_pos


struct DerTime(
    TrivialRegisterPassable,
    Copyable,
    ImplicitlyCopyable,
    Movable,
    Deinitable,
):
    """A parsed UTCTime / GeneralizedTime broken into (year, month, day,
    hour, minute, second). Year is 4-digit (UTCTime's 2-digit form is
    expanded per RFC 5280 §4.1.2.5.1 — yy in [00, 49] -> 20yy, yy in
    [50, 99] -> 19yy)."""
    var year: UInt16
    var month: UInt8
    var day: UInt8
    var hour: UInt8
    var minute: UInt8
    var second: UInt8

    def __init__(
        out self,
        year: UInt16,
        month: UInt8,
        day: UInt8,
        hour: UInt8,
        minute: UInt8,
        second: UInt8,
    ):
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second


# Helper bundles for multi-return without Tuple-constructor trip.


struct _TagParseResult(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    var tag: DerTag
    var next_pos: Int

    def __init__(out self, tag: DerTag, next_pos: Int):
        self.tag = tag
        self.next_pos = next_pos


struct _LengthParseResult(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    var length: Int
    var next_pos: Int

    def __init__(out self, length: Int, next_pos: Int):
        self.length = length
        self.next_pos = next_pos


struct _BitStringResult(Movable, Deinitable):
    var bytes: List[UInt8]
    var unused_bits: UInt8

    def __init__(out self, var bytes: List[UInt8], unused_bits: UInt8):
        self.bytes = bytes^
        self.unused_bits = unused_bits


# -----------------------------------------------------------------------------
# TLV parsers
# -----------------------------------------------------------------------------


def der_parse_tag(buf: Span[UInt8, _], pos: Int) raises -> _TagParseResult:
    """Parse a single ASN.1 tag starting at `buf[pos]`.

    Supports long-form (>=31) multi-byte tag numbers per X.690 §8.1.2.4.
    """
    if pos < 0 or pos >= len(buf):
        raise Error("der_parse_tag: pos out of range")
    var b0 = buf[pos]
    var class_ = (b0 >> 6) & UInt8(0x03)
    var constructed = ((b0 >> 5) & UInt8(0x01)) == UInt8(1)
    var low5 = UInt32(Int(b0 & UInt8(0x1F)))
    if low5 < UInt32(31):
        # Short-form tag (the common case).
        var tag = DerTag(class_, constructed, low5)
        return _TagParseResult(tag, pos + 1)
    # Long-form: read 7-bit groups until high bit clears. Cap at 4 bytes
    # (UInt32) — anything longer is malformed for X.509 purposes.
    var tag_num = UInt32(0)
    var off = pos + 1
    for _ in range(4):
        if off >= len(buf):
            raise Error("der_parse_tag: truncated long-form tag")
        var bb = buf[off]
        # Each continuation byte contributes 7 bits.
        # Overflow check: tag_num << 7 must fit in UInt32.
        if (tag_num >> UInt32(25)) != UInt32(0):
            raise Error("der_parse_tag: tag-number overflow (>2^32)")  # cov: unreachable at most four 7-bit groups are read, so tag_num has at most 21 bits before the last shift
        tag_num = (tag_num << UInt32(7)) | UInt32(Int(bb & UInt8(0x7F)))
        off += 1
        if (bb & UInt8(0x80)) == UInt8(0):
            var tag = DerTag(class_, constructed, tag_num)
            return _TagParseResult(tag, off)
    # Ran 4 bytes without terminator; reject.
    raise Error("der_parse_tag: long-form tag exceeds 4 bytes")


def der_parse_length(buf: Span[UInt8, _], pos: Int) raises -> _LengthParseResult:
    """Parse an ASN.1 DER length encoding at `buf[pos]`.

    Short-form: single byte < 0x80, value is the length directly.
    Long-form: byte b0 = 0x80 | n_len_bytes. Followed by n_len_bytes
    big-endian length bytes. Reject indefinite-length (0x80 alone) per
    DER (only BER allows).
    """
    if pos < 0 or pos >= len(buf):
        raise Error("der_parse_length: pos out of range")
    var b0 = buf[pos]
    if (b0 & UInt8(0x80)) == UInt8(0):
        # Short form
        return _LengthParseResult(Int(b0), pos + 1)
    # Long form
    var nbytes = Int(b0 & UInt8(0x7F))
    if nbytes == 0:
        # Indefinite length — illegal in DER (RFC 6025 §8.1.3.6 implicit;
        # X.690 §10.1 explicit DER prohibition).
        raise Error("der_parse_length: indefinite-length encoding not allowed in DER")
    if nbytes > 4:
        # Lengths > 2^32-1 are nonsensical for any real cert.
        raise Error("der_parse_length: length-of-length exceeds 4 bytes")
    if pos + 1 + nbytes > len(buf):
        raise Error("der_parse_length: truncated long-form length")
    var length = Int(0)
    for i in range(nbytes):
        length = (length << 8) | Int(buf[pos + 1 + i])
    if length < 0:
        # UInt32 -> Int conversion shouldn't go negative on a 64-bit Int
        # but defensive-check anyway.
        raise Error("der_parse_length: length overflow")  # cov: unreachable at most four length bytes: the length is below 2^32 and fits a 64-bit Int
    return _LengthParseResult(length, pos + 1 + nbytes)


def der_parse_tlv(buf: Span[UInt8, _], pos: Int) raises -> DerTlv:
    """Parse one full TLV: tag + length + value boundaries.

    Returns a DerTlv with `(tag, value_pos, value_len, end_pos)`. The caller
    re-slices `buf[value_pos : value_pos + value_len]` to access the value
    bytes.
    """
    var tag_res = der_parse_tag(buf, pos)
    var len_res = der_parse_length(buf, tag_res.next_pos)
    var value_pos = len_res.next_pos
    var value_len = len_res.length
    var end_pos = value_pos + value_len
    if end_pos > len(buf):
        raise Error("der_parse_tlv: value length exceeds buffer remainder")
    if end_pos < value_pos:
        # Defensive: cannot happen with bounded length on 64-bit Int but
        # cover the overflow edge.
        raise Error("der_parse_tlv: length-pos overflow")  # cov: unreachable value_len is at least 0, so end_pos is never below value_pos
    return DerTlv(tag_res.tag, value_pos, value_len, end_pos)


# -----------------------------------------------------------------------------
# Universal-tag primitive value parsers
# -----------------------------------------------------------------------------


def der_parse_boolean(value: Span[UInt8, _]) raises -> Bool:
    """ASN.1 BOOLEAN per X.690 §11.1 (DER-strict).

    DER mandates: 0x00 == FALSE, 0xFF == TRUE; any other non-zero byte
    is non-canonical (BER would accept, DER does not). We accept any
    non-zero byte as TRUE for robustness against slightly-off
    encodings, but raise on length != 1.
    """
    if len(value) != 1:
        raise Error("der_parse_boolean: value length must be 1")
    if value[0] == UInt8(0):
        return False
    return True


def der_parse_null(value: Span[UInt8, _]) raises -> None:
    """ASN.1 NULL — length must be 0."""
    if len(value) != 0:
        raise Error("der_parse_null: value length must be 0")


def der_parse_integer_to_int64(value: Span[UInt8, _]) raises -> Int64:
    """ASN.1 INTEGER decoded into Int64. Big-endian two's-complement.

    Raises if the value would overflow Int64 (i.e. > 8 bytes after stripping
    a single leading 0x00 sign-byte). For larger integers (RSA modulus,
    cert serial number), use `der_parse_integer_to_bytes`.
    """
    if len(value) == 0:
        raise Error("der_parse_integer_to_int64: empty value")
    # Determine sign from MSB of the first byte.
    var is_negative = (value[0] & UInt8(0x80)) != UInt8(0)
    # 9-byte case is legal ONLY if the leading byte is 0x00 (sign pad for
    # a positive integer whose MSB would otherwise look negative). Any
    # other 9+ byte case overflows Int64.
    var start = 0
    if len(value) >= 9:
        if value[0] == UInt8(0) and len(value) == 9:
            start = 1
        else:
            raise Error("der_parse_integer_to_int64: value > Int64 range")
    var n = len(value) - start
    # Sign-extend by initializing as -1 if negative.
    var acc: Int64
    if is_negative and start == 0:
        acc = Int64(-1)
    else:
        acc = Int64(0)
    for i in range(n):
        acc = (acc << Int64(8)) | Int64(Int(value[start + i]))
    return acc


def der_parse_integer_to_bytes(value: Span[UInt8, _]) raises -> List[UInt8]:
    """ASN.1 INTEGER decoded into a List[UInt8] big-endian byte sequence.

    Use this for large integers (RSA modulus, cert serial number) that
    don't fit in Int64. The single leading 0x00 sign-pad byte (present
    when the integer is positive but its MSB is set) is STRIPPED — the
    caller gets the canonical positive-magnitude bytes.
    """
    if len(value) == 0:
        raise Error("der_parse_integer_to_bytes: empty value")
    var start = 0
    # Strip ONE leading 0x00 sign-pad if present and the next byte has MSB set.
    if len(value) >= 2 and value[0] == UInt8(0) and (value[1] & UInt8(0x80)) != UInt8(0):
        start = 1
    var out = List[UInt8]()
    for i in range(start, len(value)):
        out.append(value[i])
    return out^


def der_parse_octet_string(value: Span[UInt8, _]) -> List[UInt8]:
    """ASN.1 OCTET STRING — direct byte-for-byte copy."""
    var out = List[UInt8]()
    for i in range(len(value)):
        out.append(value[i])
    return out^


def der_parse_bit_string(value: Span[UInt8, _]) raises -> _BitStringResult:
    """ASN.1 BIT STRING per X.690 §11.2.

    First byte is the "unused trailing bits" count (0..7). The remaining
    bytes are the bit data, big-endian, with the last byte's low
    `unused_bits` bits unused.

    Returns `_BitStringResult { bytes, unused_bits }`. For X.509
    subjectPublicKey + signatureValue these BIT STRINGs are byte-aligned
    (unused_bits = 0) and the caller treats `bytes` as a plain byte
    sequence.
    """
    if len(value) == 0:
        raise Error("der_parse_bit_string: empty value")
    var unused_bits = value[0]
    if unused_bits > UInt8(7):
        raise Error("der_parse_bit_string: unused_bits > 7")
    if len(value) == 1 and unused_bits != UInt8(0):
        # An empty bit-string must have unused_bits = 0.
        raise Error("der_parse_bit_string: empty bit-data with non-zero unused_bits")
    var out = List[UInt8]()
    for i in range(1, len(value)):
        out.append(value[i])
    return _BitStringResult(out^, unused_bits)


def der_parse_utf8_string(value: Span[UInt8, _]) -> String:
    """ASN.1 UTF8String. The Mojo `String` consumer accepts the raw bytes.

    NOTE: we do NOT validate UTF-8 conformance here — that's the caller's
    job. Production cert chains are virtually always ASCII-only in DN
    fields, so an invalid-UTF-8 byte stream would either bubble up as a
    rendering issue or get caught by a higher-level validator.
    """
    var out = String()
    for i in range(len(value)):
        out += chr(Int(value[i]))
    return out^


def der_parse_printable_string(value: Span[UInt8, _]) raises -> String:
    """ASN.1 PrintableString (X.680 §41.4): A-Z, a-z, 0-9, space, and
    `'()+,-./:=?`. We validate but produce a plain Mojo String."""
    var out = String()
    for i in range(len(value)):
        var c = value[i]
        var ok = (
            (c >= UInt8(0x41) and c <= UInt8(0x5A))  # A-Z
            or (c >= UInt8(0x61) and c <= UInt8(0x7A))  # a-z
            or (c >= UInt8(0x30) and c <= UInt8(0x39))  # 0-9
            or c == UInt8(0x20)  # space
            or c == UInt8(0x27)  # '
            or c == UInt8(0x28)  # (
            or c == UInt8(0x29)  # )
            or c == UInt8(0x2B)  # +
            or c == UInt8(0x2C)  # ,
            or c == UInt8(0x2D)  # -
            or c == UInt8(0x2E)  # .
            or c == UInt8(0x2F)  # /
            or c == UInt8(0x3A)  # :
            or c == UInt8(0x3D)  # =
            or c == UInt8(0x3F)  # ?
        )
        if not ok:
            raise Error("der_parse_printable_string: invalid character")
        out += chr(Int(c))
    return out^


def der_parse_ia5_string(value: Span[UInt8, _]) raises -> String:
    """ASN.1 IA5String (X.680 §41.5): 7-bit ASCII (0x00..0x7F)."""
    var out = String()
    for i in range(len(value)):
        var c = value[i]
        if c > UInt8(0x7F):
            raise Error("der_parse_ia5_string: byte > 0x7F (not IA5)")
        out += chr(Int(c))
    return out^


def der_parse_oid(value: Span[UInt8, _]) raises -> List[UInt32]:
    """ASN.1 OBJECT IDENTIFIER per X.690 §8.19.

    Decoding:
      - First sub-identifier byte encodes the first TWO arcs:
        arc0 = first_byte // 40, arc1 = first_byte % 40
        (Special case: if first_byte >= 80, arc0 = 2 and arc1 = first_byte - 80.)
      - Subsequent sub-identifiers are base-128 with the high bit set on
        all but the last byte of the group.

    Returns the list of UInt32 arc components. Overflow on a single arc
    > 2^32 - 1 raises.
    """
    if len(value) == 0:
        raise Error("der_parse_oid: empty value")
    var out = List[UInt32]()
    # First byte -> arc0 + arc1.
    var b0 = value[0]
    var first = Int(b0)
    var arc0: UInt32
    var arc1: UInt32
    if first < 80:
        arc0 = UInt32(first // 40)
        arc1 = UInt32(first % 40)
    else:
        arc0 = UInt32(2)
        arc1 = UInt32(first - 80)
    out.append(arc0)
    out.append(arc1)
    # Walk the remaining bytes, accumulating high-bit-continuation groups.
    var acc = UInt32(0)
    var have_acc = False
    for i in range(1, len(value)):
        var b = value[i]
        # Overflow check: acc << 7 must fit in UInt32.
        if (acc >> UInt32(25)) != UInt32(0):
            raise Error("der_parse_oid: arc overflow (>2^32)")
        acc = (acc << UInt32(7)) | UInt32(Int(b & UInt8(0x7F)))
        have_acc = True
        if (b & UInt8(0x80)) == UInt8(0):
            out.append(acc)
            acc = UInt32(0)
            have_acc = False
    if have_acc:
        # Last byte had high-bit set with no terminator.
        raise Error("der_parse_oid: truncated sub-identifier (no terminating byte)")
    return out^


def der_oid_eq(a: List[UInt32], b: List[UInt32]) -> Bool:
    """Comparison helper for OID lists."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


# -----------------------------------------------------------------------------
# Time parsers (X.690 §11.7 + RFC 5280 §4.1.2.5)
# -----------------------------------------------------------------------------


@always_inline
def _ascii_digit(c: UInt8) raises -> UInt8:
    if c < UInt8(0x30) or c > UInt8(0x39):
        raise Error("expected ASCII digit")
    return c - UInt8(0x30)


def _parse_2digit(value: Span[UInt8, _], off: Int) raises -> UInt8:
    var d0 = _ascii_digit(value[off])
    var d1 = _ascii_digit(value[off + 1])
    return d0 * UInt8(10) + d1


def _parse_4digit(value: Span[UInt8, _], off: Int) raises -> UInt16:
    var d0 = UInt16(Int(_ascii_digit(value[off])))
    var d1 = UInt16(Int(_ascii_digit(value[off + 1])))
    var d2 = UInt16(Int(_ascii_digit(value[off + 2])))
    var d3 = UInt16(Int(_ascii_digit(value[off + 3])))
    return d0 * UInt16(1000) + d1 * UInt16(100) + d2 * UInt16(10) + d3


def der_parse_utc_time(value: Span[UInt8, _]) raises -> DerTime:
    """ASN.1 UTCTime per X.690 §11.7 + RFC 5280 §4.1.2.5.1.

    Canonical DER form: `YYMMDDhhmmssZ` (13 ASCII bytes).
    RFC 5280 says UTC century interpretation: YY in [00,49] -> 20YY,
    YY in [50,99] -> 19YY.
    """
    if len(value) != 13:
        raise Error("der_parse_utc_time: length must be 13 (YYMMDDhhmmssZ)")
    if value[12] != UInt8(0x5A):  # 'Z'
        raise Error("der_parse_utc_time: must end with 'Z'")
    var yy = _parse_2digit(value, 0)
    var year: UInt16
    if yy < UInt8(50):
        year = UInt16(2000) + UInt16(Int(yy))
    else:
        year = UInt16(1900) + UInt16(Int(yy))
    var month = _parse_2digit(value, 2)
    var day = _parse_2digit(value, 4)
    var hour = _parse_2digit(value, 6)
    var minute = _parse_2digit(value, 8)
    var second = _parse_2digit(value, 10)
    # Sanity-check field ranges.
    if month < UInt8(1) or month > UInt8(12):
        raise Error("der_parse_utc_time: month out of range")
    if day < UInt8(1) or day > UInt8(31):
        raise Error("der_parse_utc_time: day out of range")
    if hour > UInt8(23):
        raise Error("der_parse_utc_time: hour out of range")
    if minute > UInt8(59):
        raise Error("der_parse_utc_time: minute out of range")
    if second > UInt8(60):  # leap second tolerated
        raise Error("der_parse_utc_time: second out of range")
    return DerTime(year, month, day, hour, minute, second)


# -----------------------------------------------------------------------------
# Constructed-type iteration (SEQUENCE / SET / EXPLICIT context tags)
# -----------------------------------------------------------------------------
#
# A constructed TLV's value bytes are a packed sequence of child TLVs. To
# iterate, the caller calls `der_parse_tlv(buf, pos)` repeatedly, advancing
# `pos = tlv.end_pos` between iterations. The `_seq_end` parameter caps
# iteration at the parent's value boundary.
#
# For X.509 patterns like `[3] EXPLICIT Extensions` (context-class
# constructed wrapper around a SEQUENCE of Extension), the caller:
#
#   1. der_parse_tlv at top-level finds the [3] wrapper.
#   2. Re-parses inside: der_parse_tlv(buf, wrapper.value_pos) finds the
#      inner SEQUENCE.
#   3. Iterates the inner SEQUENCE's children for the Extension TLVs.
#
# IMPLICIT context tags replace the universal tag class+number on the
# encoding wire. The X.509 `[1] IMPLICIT UniqueIdentifier` decodes as a
# bit-string-shaped value but with tag class=context, number=1.


def der_iter_count(buf: Span[UInt8, _], start_pos: Int, end_pos: Int) raises -> Int:
    """Count the number of immediate-child TLVs inside a constructed-value
    span `buf[start_pos : end_pos]`. Used by callers that need to size
    a destination List before iterating to fill it.

    Raises on malformed input.
    """
    if start_pos < 0 or end_pos < start_pos or end_pos > len(buf):
        raise Error("der_iter_count: invalid range")
    var count = 0
    var pos = start_pos
    while pos < end_pos:
        var tlv = der_parse_tlv(buf, pos)
        if tlv.end_pos > end_pos:
            raise Error("der_iter_count: child TLV exceeds parent boundary")
        count += 1
        pos = tlv.end_pos
    return count


def der_expect_tag(
    buf: Span[UInt8, _], pos: Int, expected_class: UInt8, expected_tag: UInt32
) raises -> DerTlv:
    """Parse a TLV and assert its tag class + tag_number match expected.

    Used by structured parsers (X.509 TBSCertificate field walker) to fail
    fast on shape mismatches. The `constructed` bit is NOT checked here —
    callers that care assert separately.
    """
    var tlv = der_parse_tlv(buf, pos)
    if tlv.tag.class_ != expected_class or tlv.tag.tag_number != expected_tag:
        raise Error("der_expect_tag: unexpected tag")
    return tlv


def der_parse_generalized_time(value: Span[UInt8, _]) raises -> DerTime:
    """ASN.1 GeneralizedTime per X.690 §11.7 + RFC 5280 §4.1.2.5.2.

    Canonical DER form: `YYYYMMDDhhmmssZ` (15 ASCII bytes). RFC 5280
    forbids fractional seconds in cert validity.
    """
    if len(value) != 15:
        raise Error("der_parse_generalized_time: length must be 15 (YYYYMMDDhhmmssZ)")
    if value[14] != UInt8(0x5A):  # 'Z'
        raise Error("der_parse_generalized_time: must end with 'Z'")
    var year = _parse_4digit(value, 0)
    var month = _parse_2digit(value, 4)
    var day = _parse_2digit(value, 6)
    var hour = _parse_2digit(value, 8)
    var minute = _parse_2digit(value, 10)
    var second = _parse_2digit(value, 12)
    if month < UInt8(1) or month > UInt8(12):
        raise Error("der_parse_generalized_time: month out of range")
    if day < UInt8(1) or day > UInt8(31):
        raise Error("der_parse_generalized_time: day out of range")
    if hour > UInt8(23):
        raise Error("der_parse_generalized_time: hour out of range")
    if minute > UInt8(59):
        raise Error("der_parse_generalized_time: minute out of range")
    if second > UInt8(60):
        raise Error("der_parse_generalized_time: second out of range")
    return DerTime(year, month, day, hour, minute, second)
