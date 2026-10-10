"""Avro name rules and the Latin-1 reading of a bytes/fixed default.

Names (Avro 1.11.1 specification, "Names"): the name part of a fullname, a
record field name and an enum symbol each match `[A-Za-z_][A-Za-z0-9_]*`. A
fullname and a namespace are dot-separated sequences of such names; the empty
string as a namespace means the null namespace. The parser refuses anything
else, which is also what lets Parsing Canonical Form copy names and symbols
into its JSON without escaping them.

Defaults (specification, "Complex Types", the field default table): the
default of a `bytes` or `fixed` field is a JSON string whose code points
U+0000..U+00FF are the byte values 0..255.
"""

comptime AVRO_NAME_PATTERN = "[A-Za-z_][A-Za-z0-9_]*"


def is_avro_name(s: String) -> Bool:
    """True when `s` matches `[A-Za-z_][A-Za-z0-9_]*`."""
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = b[i]
        var alpha = (c >= UInt8(ord("A")) and c <= UInt8(ord("Z"))) or (
            c >= UInt8(ord("a")) and c <= UInt8(ord("z"))
        )
        var ok = alpha or c == UInt8(ord("_"))
        if i > 0:
            ok = ok or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        if not ok:
            return False
    return True


def _invalid_name(what: String, value: String, part: String) -> Error:
    var msg = String("AvroSchemaError.INVALID_NAME: ") + what + " '" + value + "'"
    if part != value:
        msg += String(": component '") + part + "'"
    msg += String(" does not match ") + AVRO_NAME_PATTERN
    return Error(msg)


def check_avro_name(what: String, value: String) raises:
    """Refuse a record field name or enum symbol that is not an Avro name.

    `what` names the position in the error ("field name", "enum symbol")."""
    if not is_avro_name(value):
        raise _invalid_name(what, value, value)


def _check_dotted(what: String, value: String) raises:
    var parts = value.split(".")
    for i in range(len(parts)):
        var part = String(parts[i])
        if not is_avro_name(part):
            raise _invalid_name(what, value, part)


def check_avro_fullname(what: String, value: String) raises:
    """Refuse a record / enum / fixed `name` unless every dot-separated
    component is an Avro name. An empty name is refused."""
    _check_dotted(what, value)


def check_avro_namespace(what: String, value: String) raises:
    """Refuse a `namespace` unless it is empty (the null namespace) or every
    dot-separated component is an Avro name."""
    if value.byte_length() == 0:
        return
    _check_dotted(what, value)


def _code_point_label(cp: Int) -> String:
    var digits = String("0123456789ABCDEF").as_bytes()
    var out = String("U+")
    var width = 4
    if cp > 0xFFFF:
        width = 6 if cp > 0xFFFFF else 5
    for k in range(width - 1, -1, -1):
        out += chr(Int(digits[(cp >> (4 * k)) & 0xF]))
    return out^


def latin1_default_bytes(field: String, value: String) raises -> List[UInt8]:
    """Read a bytes/fixed default (a decoded JSON string, so well-formed
    UTF-8) as Latin-1: each code point U+0000..U+00FF becomes one byte.

    Raises `AvroSchemaError.INVALID_DEFAULT` naming the first code point
    above U+00FF."""
    var b = value.as_bytes()
    var n = len(b)
    var out = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        var c = Int(b[i])
        if c < 0x80:
            out.append(UInt8(c))
            i += 1
            continue
        if (c == 0xC2 or c == 0xC3) and i + 1 < n:
            # Two-byte sequences led by C2/C3 encode U+0080..U+00FF.
            out.append(UInt8(((c & 0x1F) << 6) | (Int(b[i + 1]) & 0x3F)))
            i += 2
            continue
        var cp: Int
        var extra: Int
        if c >= 0xF0:
            cp = c & 0x07
            extra = 3
        elif c >= 0xE0:
            cp = c & 0x0F
            extra = 2
        else:
            cp = c & 0x1F
            extra = 1
        for k in range(1, extra + 1):
            if i + k < n:
                cp = (cp << 6) | (Int(b[i + k]) & 0x3F)
        raise Error(
            String("AvroSchemaError.INVALID_DEFAULT: field '")
            + field
            + "' default contains "
            + _code_point_label(cp)
            + "; a bytes or fixed default holds only code points"
            " U+0000..U+00FF"
        )
    return out^
