# =============================================================================
# text.mojo -- TEXT value escaping (RFC 6350 §3.4, RFC 5545 §3.3.11) and
# splitting of compound and list values on unescaped separators.
# =============================================================================
#
# Escaping: a backslash, comma and semicolon get a backslash before them; a
# line break (LF, CR or CRLF) is written as `\n`.
#
# Unescaping: `\n` and `\N` are a line feed; a backslash before any other
# character stands for that character (so `\\`, `\,`, `\;` and the `\:`
# some vCard 3.0 writers put in URLs all read back); a backslash at the end of
# the value is kept.
#
# A compound value (vCard N and ADR, iCalendar's lists) is split BEFORE it is
# unescaped: `split_unescaped` cuts at separators that no backslash escapes
# and returns the pieces still escaped, so `Doe\, Jr.` stays one value. Each
# piece is then unescaped on its own.
# =============================================================================


def escape_text(value: String) -> String:
    """`value` escaped as a TEXT value (file header)."""
    var b = value.as_bytes()
    var n = len(b)
    var out = String()
    var run = 0
    var i = 0
    while i < n:
        var c = b[i]
        var rep: String
        var skip = 1
        if c == 92:
            rep = "\\\\"
        elif c == 44:
            rep = "\\,"
        elif c == 59:
            rep = "\\;"
        elif c == 10:
            rep = "\\n"
        elif c == 13:
            rep = "\\n"
            if i + 1 < n and b[i + 1] == 10:
                skip = 2
        else:
            i += 1
            continue
        out += String(value[byte=run:i])
        out += rep
        i += skip
        run = i
    out += String(value[byte=run:n])
    return out^


def unescape_text(value: String) -> String:
    """`value` with TEXT escapes resolved (file header)."""
    var b = value.as_bytes()
    var n = len(b)
    var out = String()
    var run = 0
    var i = 0
    while i < n:
        if b[i] != 92 or i + 1 >= n:
            i += 1
            continue
        out += String(value[byte=run:i])
        var c = b[i + 1]
        if c == 110 or c == 78:
            out += "\n"
            run = i + 2
        else:
            # The escaped character is kept (it may start a multi-octet
            # sequence, which the next run copies whole).
            run = i + 1
        i += 2
    out += String(value[byte=run:n])
    return out^


def split_unescaped(value: String, separator: UInt8) -> List[String]:
    """`value` cut at every `separator` octet no backslash escapes; the pieces
    are still escaped. An empty value is one empty piece."""
    var b = value.as_bytes()
    var n = len(b)
    var out = List[String]()
    var start = 0
    var i = 0
    while i < n:
        var c = b[i]
        if c == 92:
            i += 2
            continue
        if c == separator:
            out.append(String(value[byte=start:i]))
            start = i + 1
        i += 1
    out.append(String(value[byte=start:n]))
    return out^
