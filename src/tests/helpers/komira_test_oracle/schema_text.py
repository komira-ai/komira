"""The `<dataset>.schema` sidecar: a pyarrow schema as the schema line of the
canonical result text (komira_plan_harness: the entry in `type_text.mojo`,
the escapes in `escape.mojo`).

The line is one entry per column, separated by TAB and ended by LF:
`<name>:<type>`, then `?` when the column is nullable. `<type>` is
plan_vocabulary's ArrowType name without `ARROW_TYPE_`, in lower case, with
the parameters a flat type carries: `decimal128(<precision>,<scale>)`,
`timestamp_<unit>` and, with a time zone, `timestamp_<unit>(<zone>)`. Names
and zones are escaped as the harness's `escape_name` escapes them: a
backslash is `\\\\`, TAB `\\t`, LF `\\n`, CR `\\r`, any other control byte
and DEL `\\xHH`, each of `: , < > [ ] { } ( )` gets a backslash, and so does
a `#` that is the first character (so a schema line never reads as a comment
line).

Flat types only. The harness spells the whole nested type tree, but no
dataset here has a nested column, so a nested (or any other unlisted) type
is refused rather than spelt by code no dataset exercises. This module is
the only place the spelling lives: following a revision of the harness is an
edit to this file alone.
"""

import pyarrow as pa

# pyarrow type id -> the harness's spelling, for the types with no parameters.
_PLAIN = [
    (pa.types.is_boolean, "bool"),
    (pa.types.is_int8, "int8"),
    (pa.types.is_int16, "int16"),
    (pa.types.is_int32, "int32"),
    (pa.types.is_int64, "int64"),
    (pa.types.is_uint8, "uint8"),
    (pa.types.is_uint16, "uint16"),
    (pa.types.is_uint32, "uint32"),
    (pa.types.is_uint64, "uint64"),
    (pa.types.is_float32, "float32"),
    (pa.types.is_float64, "float64"),
    (pa.types.is_string, "string"),
    (pa.types.is_binary, "binary"),
    (pa.types.is_date32, "date32"),
]

_NAME_SPECIAL = {ord(c) for c in ":,<>[]{}()"}


def escape_name(name):
    """`name` as the harness's escape_name writes it (a Python str is always
    well-formed UTF-8, so no byte of it needs the not-UTF-8 escape)."""
    out = []
    for i, ch in enumerate(name):
        b = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif b < 32 or b == 127:
            out.append("\\x%02x" % b)
        elif b in _NAME_SPECIAL or (i == 0 and ch == "#"):
            out.append("\\" + ch)
        else:
            out.append(ch)
    return "".join(out)


def type_spelling(t):
    """The type part of one schema entry; raises on a type O1 does not spell."""
    for is_kind, spelt in _PLAIN:
        if is_kind(t):
            return spelt
    if pa.types.is_decimal128(t):
        return "decimal128(%d,%d)" % (t.precision, t.scale)
    if pa.types.is_timestamp(t):
        spelt = "timestamp_" + t.unit
        if t.tz:
            spelt += "(" + escape_name(t.tz) + ")"
        return spelt
    raise ValueError("schema_text: no flat spelling for type %s" % t)


def schema_line(schema):
    """The sidecar's text: the schema line, LF-terminated."""
    entries = []
    for field in schema:
        entry = escape_name(field.name) + ":" + type_spelling(field.type)
        if field.nullable:
            entry += "?"
        entries.append(entry)
    return "\t".join(entries) + "\n"
