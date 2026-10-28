# =============================================================================
# wire -- little-endian integers and length-prefixed strings for the delta
#   bodies and the fingerprint set.
# =============================================================================
#
# The bodies of `delta_body` and `source_fingerprint` are read from object
# storage, so every read here checks its bounds first. A read that would run
# past the end of the input, a negative length and a string that is not UTF-8
# are errors that name the caller (`who`), never a partial value. The length
# check subtracts instead of adding: `off + n` on an untrusted `n` can wrap.
# =============================================================================

from .utf8_check import bytes_are_utf8


@always_inline
def put_i64_le(mut out: List[UInt8], v: Int64):
    """Append `v` as eight little-endian bytes."""
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8(Int((u >> UInt64(8 * i)) & UInt64(0xFF))))


def put_str(mut out: List[UInt8], s: String):
    """Append `s` as an i64 byte length and its UTF-8 bytes."""
    var b = s.as_bytes()
    put_i64_le(out, Int64(len(b)))
    for j in range(len(b)):
        out.append(b[j])


@always_inline
def get_i64_le(bytes: List[UInt8], off: Int, who: String) raises -> Int64:
    """The little-endian i64 at `off`; an error naming `who` if fewer than
    eight bytes remain there."""
    if off < 0 or off > len(bytes) - 8:
        raise Error(who + ": truncated i64 at " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


def get_str(
    bytes: List[UInt8], mut off: Int, who: String, what: String
) raises -> String:
    """Read a length-prefixed UTF-8 string at `off` and advance past it.

    Args:
        bytes: The body being decoded.
        off: Where the length starts; advanced past the string.
        who: The caller's name, for the error.
        what: What the string is, for the error.
    """
    var n = Int(get_i64_le(bytes, off, who))
    off += 8
    if n < 0:
        raise Error(who + ": negative length " + String(n) + " for " + what)
    if n > len(bytes) - off:
        raise Error(who + ": truncated " + what)
    var buf = List[UInt8](capacity=n)
    for i in range(n):
        buf.append(bytes[off + i])
    off += n
    if not bytes_are_utf8(Span(buf)):
        raise Error(who + ": " + what + " is not valid UTF-8")
    return String(unsafe_from_utf8=Span(buf))
