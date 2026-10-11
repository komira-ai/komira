# =============================================================================
# render_text — writing a query-supplied string into a render that is an
# IDENTITY.
# =============================================================================
#
# `Expr.write_to` / `ScalarValue.write_to` are EXPLAIN text, and they are also
# the input to `LogicalPlan.structural_hash`, the plan-compile cache key. A
# string the query supplies (a literal, an alias, a pattern, a regexp field, a
# struct-field name, a JSON path segment) is written between `"` quotes, and a
# raw write lets the string close its own quote and spell the rest of a
# different plan: `x IN ('a"), ScalarValue(utf8, "b')` rendered exactly like
# `x IN ('a', 'b')`, so the two shared one compiled plan (komira#960).
#
# The escape is `\` before `\` and `"` (and, for a JSON path segment, before
# `.`, the segment separator). It is one-to-one, and a string with none of
# those bytes renders byte-for-byte as before, so ordinary EXPLAIN text and
# every existing cache key are unchanged.
#
# All three escaped bytes are ASCII and never occur inside a multi-byte UTF-8
# sequence, so slicing at them keeps every slice valid UTF-8.
# =============================================================================


@always_inline
def _is_escaped(b: UInt8, escape_dot: Bool) -> Bool:
    return b == UInt8(0x5C) or b == UInt8(0x22) or (escape_dot and b == UInt8(0x2E))


def write_escaped[W: Writer](mut writer: W, s: String, escape_dot: Bool = False):
    """Write `s` with `\\` and `"` (and `.` when `escape_dot`) preceded by `\\`.

    The common case (no such byte) writes `s` unchanged with one scan and no
    allocation."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var clean = True
    for i in range(n):
        if _is_escaped(bytes[i], escape_dot):
            clean = False
            break
    if clean:
        writer.write(s)
        return
    var start = 0
    for i in range(n):
        if _is_escaped(bytes[i], escape_dot):
            writer.write(s[byte=start:i], "\\")
            start = i
    writer.write(s[byte=start:n])


def write_quoted[W: Writer](mut writer: W, s: String):
    """Write `"<s escaped>"`."""
    writer.write("\"")
    write_escaped(writer, s)
    writer.write("\"")


def write_hex[W: Writer](mut writer: W, s: String):
    """Write the bytes of `s` as `0x` + lowercase hex (`0x` alone when empty).
    A binary literal's VALUE, which its render must carry.

    One buffer reserved at its final size and filled from a nibble table, then
    one write: no allocation per byte."""
    comptime HEX = "0123456789abcdef"
    var bytes = s.as_bytes()
    var n = len(bytes)
    var out = String(capacity=2 + 2 * n)
    out += "0x"
    for i in range(n):
        var b = Int(bytes[i])
        out += HEX[byte = b >> 4]
        out += HEX[byte = b & 15]
    writer.write(out)
