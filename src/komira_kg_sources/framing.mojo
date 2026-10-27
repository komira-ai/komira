# =============================================================================
# framing -- the byte layout helpers every stored object of this package uses.
# =============================================================================
#
# Every object this package writes is a short run of fields: a one-byte format
# version, strings and byte runs each led by a little-endian u32 length, and
# little-endian i64 integers. The readers take their input from storage, so they
# trust nothing in it:
#
#   * a length is checked against the bytes that remain by subtraction
#     (`remaining < count`), never by `offset + count`, which a hostile length
#     could wrap;
#   * nothing is allocated before the length it would be sized from has been
#     checked against the bytes actually present, so no allocation is larger
#     than the body already in memory;
#   * a string is refused over `FIELD_MAX_BYTES` and unless it is valid UTF-8;
#   * `expect_end` refuses bytes after the last field.
#
# The helpers carry no state; the caller owns the offset.
# =============================================================================

from komira_kg_format.utf8_check import bytes_are_utf8

comptime FIELD_MAX_BYTES: Int = 65536
"""The longest key, tag, identifier or prefix a stored object may hold, in
bytes."""

comptime U32_MAX: Int = 4294967295
"""The largest length a u32 field can carry."""


def check_text(what: String, value: String, allow_empty: Bool) raises:
    """Refuse a string that is empty (unless allowed), over `FIELD_MAX_BYTES`
    or holds a control byte (below 0x20, or 0x7F).

    Args:
        what: The field's name, for the error.
        value: The string to check.
        allow_empty: Whether the empty string is a valid value.

    Raises:
        If the string breaks one of the rules.
    """
    var b = value.as_bytes()
    if len(b) == 0:
        if allow_empty:
            return
        raise Error(what + " must not be empty")
    if len(b) > FIELD_MAX_BYTES:
        raise Error(
            what
            + " is "
            + String(len(b))
            + " bytes, over the limit of "
            + String(FIELD_MAX_BYTES)
        )
    for i in range(len(b)):
        if b[i] < UInt8(0x20) or b[i] == UInt8(0x7F):
            raise Error(what + " must not hold a control byte")


def check_prefix(what: String, value: String) raises:
    """Refuse a key prefix that is empty, over the length limit, holds a
    control byte, starts or ends with '/' or holds '//'. Slashes inside are
    allowed ("area/store").
    """
    check_text(what, value, False)
    var b = value.as_bytes()
    if b[0] == UInt8(0x2F) or b[len(b) - 1] == UInt8(0x2F):
        raise Error(what + " must not start or end with '/'")
    for i in range(len(b) - 1):
        if b[i] == UInt8(0x2F) and b[i + 1] == UInt8(0x2F):
            raise Error(what + " must not hold '//'")


def prefixes_nest(a: String, b: String) -> Bool:
    """True if the prefixes are equal or one lies under the other (`a` is `b`
    followed by '/' and more, or the reverse). Both are checked prefixes."""
    return _is_under(a, b) or _is_under(b, a)


def _is_under(inner: String, outer: String) -> Bool:
    var ib = inner.as_bytes()
    var ob = outer.as_bytes()
    if len(ib) < len(ob):
        return False
    for i in range(len(ob)):
        if ib[i] != ob[i]:
            return False
    return len(ib) == len(ob) or ib[len(ob)] == UInt8(0x2F)


def sort_strings(mut keys: List[String]):
    """Sort `keys` ascending by insertion. A listing from an object store is
    usually in key order already (one pass); the sort is there so the order
    never depends on the store."""
    var n = len(keys)
    for i in range(1, n):
        var j = i
        while j > 0 and keys[j - 1] > keys[j]:
            var tmp = keys[j - 1].copy()
            keys[j - 1] = keys[j].copy()
            keys[j] = tmp^
            j -= 1


def is_hash_name(s: String) -> Bool:
    """True if `s` is exactly 16 lowercase hex digits."""
    var b = s.as_bytes()
    if len(b) != 16:
        return False
    for i in range(16):
        var c = b[i]
        var digit = c >= UInt8(0x30) and c <= UInt8(0x39)
        var lower = c >= UInt8(0x61) and c <= UInt8(0x66)
        if not digit and not lower:
            return False
    return True


def name_without_suffix(location: String, dir_prefix: String, suffix: String) -> String:
    """The part of `location` between `dir_prefix` and `suffix`, or the empty
    string if `location` does not have that shape."""
    var lb = location.as_bytes()
    var pb = dir_prefix.as_bytes()
    var sb = suffix.as_bytes()
    if len(lb) < len(pb) + len(sb):
        return String("")
    for i in range(len(pb)):
        if lb[i] != pb[i]:
            return String("")
    var tail = len(lb) - len(sb)
    for i in range(len(sb)):
        if lb[tail + i] != sb[i]:
            return String("")
    var mid = List[UInt8](capacity=tail - len(pb))
    for i in range(len(pb), tail):
        mid.append(lb[i])
    # SAFETY: a run of bytes copied from a String that was valid UTF-8, between
    # two ASCII markers, so the cut falls on character boundaries.
    return String(unsafe_from_utf8=Span(mid))


# ---- writing ----------------------------------------------------------------


def put_u8(mut out: List[UInt8], v: Int):
    out.append(UInt8(v & 0xFF))


def put_u32(mut out: List[UInt8], v: Int):
    for k in range(4):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def put_i64(mut out: List[UInt8], v: Int64):
    var u = UInt64(Int(v))
    for k in range(8):
        out.append(UInt8(Int((u >> UInt64(8 * k)) & UInt64(0xFF))))


def put_text(mut out: List[UInt8], s: String, what: String) raises:
    """Write `s` as a u32 length and its bytes; refuse one over the limit."""
    var b = s.as_bytes()
    if len(b) > FIELD_MAX_BYTES:
        raise Error(
            what
            + " is "
            + String(len(b))
            + " bytes, over the limit of "
            + String(FIELD_MAX_BYTES)
        )
    put_u32(out, len(b))
    for i in range(len(b)):
        out.append(b[i])


def put_length(mut out: List[UInt8], n: Int, what: String) raises:
    """Write `n` as a u32; refuse one a u32 cannot hold, instead of writing its
    low 32 bits."""
    if n < 0 or n > U32_MAX:
        raise Error(
            what + " length " + String(n) + " does not fit in a u32"
        )
    put_u32(out, n)


def put_bytes(mut out: List[UInt8], b: List[UInt8], what: String) raises:
    """Write `b` as a u32 length and its bytes; refuse one a u32 cannot count."""
    put_length(out, len(b), what)
    for i in range(len(b)):
        out.append(b[i])


# ---- reading ----------------------------------------------------------------


def need(body: List[UInt8], off: Int, count: Int, who: String, what: String) raises:
    """Refuse unless `count` bytes remain at `off`. The comparison subtracts:
    `count` may come from the body, and `off + count` could wrap."""
    if count < 0 or off < 0 or off > len(body) or len(body) - off < count:
        var left = 0
        if off >= 0 and off <= len(body):
            left = len(body) - off
        raise Error(
            who
            + ": truncated "
            + what
            + " at offset "
            + String(off)
            + " ("
            + String(left)
            + " bytes remain)"
        )


def get_u8(body: List[UInt8], mut off: Int, who: String, what: String) raises -> Int:
    need(body, off, 1, who, what)
    var v = Int(body[off])
    off += 1
    return v


def get_u32(body: List[UInt8], mut off: Int, who: String, what: String) raises -> Int:
    need(body, off, 4, who, what)
    var v = (
        Int(body[off])
        | (Int(body[off + 1]) << 8)
        | (Int(body[off + 2]) << 16)
        | (Int(body[off + 3]) << 24)
    )
    off += 4
    return v


def get_i64(body: List[UInt8], mut off: Int, who: String, what: String) raises -> Int64:
    need(body, off, 8, who, what)
    var u = UInt64(0)
    for k in range(8):
        u = u | (UInt64(Int(body[off + k])) << UInt64(8 * k))
    off += 8
    return Int64(Int(u))


def get_bytes(
    body: List[UInt8], mut off: Int, who: String, what: String
) raises -> List[UInt8]:
    """A u32-length byte run. The length is checked against what remains
    before the run is allocated."""
    var n = get_u32(body, off, who, what + " length")
    need(body, off, n, who, what)
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(body[off + i])
    off += n
    return out^


def get_text(
    body: List[UInt8], mut off: Int, who: String, what: String
) raises -> String:
    """A u32-length string of at most `FIELD_MAX_BYTES`, valid UTF-8."""
    var n = get_u32(body, off, who, what + " length")
    if n > FIELD_MAX_BYTES:
        raise Error(
            who
            + ": the "
            + what
            + " claims "
            + String(n)
            + " bytes, over the limit of "
            + String(FIELD_MAX_BYTES)
        )
    need(body, off, n, who, what)
    var bytes = List[UInt8](capacity=n)
    for i in range(n):
        bytes.append(body[off + i])
    off += n
    if not bytes_are_utf8(Span(bytes)):
        raise Error(who + ": the " + what + " is not valid UTF-8")
    # SAFETY: checked well-formed just above.
    return String(unsafe_from_utf8=Span(bytes))


def expect_end(body: List[UInt8], off: Int, who: String) raises:
    """Refuse bytes after the last field."""
    if off != len(body):
        raise Error(
            who
            + ": "
            + String(len(body) - off)
            + " trailing bytes after the last field"
        )
