# =============================================================================
# komira_plan_harness/parse.mojo -- canonical text (an expected file) -> CanonText.
# =============================================================================
#
# Strict: anything canon would not write is refused with the line it is on,
# except comment lines (`#` and not a directive) between the header and the
# schema line, and float cells, which a hand file may write in the shorter
# forms float_text.mojo accepts. Those are normalized to the canonical
# `<decimal>|0x<bits>` (or bare `NaN`), so after parsing, two float cells with
# the same bits are the same text.
#
# Refused: a missing or other magic line; a missing, repeated or malformed
# `order:` / `float:` line; a key or float override naming no column (or a
# float override naming a column that is not a float); a raw CR; a row with
# the wrong number of cells; a scalar cell with an escape canon does not
# write (escape.check_scalar_cell); a nested cell that is not well formed or
# holds such an escape (escape.check_nested_cell; the check is structural, not
# typed: a nested value's leaves are compared as text, floats in them as bits,
# see render.mojo); a float leaf of a nested cell that is not canon's bits
# (nested_floats.mojo walks the cell along its type); a float cell
# float_text refuses.
# =============================================================================

from .canon_text import (
    CANON_MAGIC,
    ORDER_KEYS,
    ORDER_NONE,
    ORDER_TOTAL,
    CanonPolicy,
    CanonText,
)
from .escape import (
    check_nested_cell,
    check_scalar_cell,
    find_unescaped,
    split_unescaped,
)
from .float_text import FloatTolerance, parse_float_cell
from .nested_floats import NestedFloatType


def _lines(text: String) -> List[String]:
    var res = List[String]()
    var start = 0
    var n = text.byte_length()
    var bs = text.as_bytes()
    for i in range(n):
        if bs[i] == 10:
            res.append(String(text[byte=start:i]))
            start = i + 1
    if start < n:
        res.append(String(text[byte=start:n]))
    return res^


def _rest(line: String, prefix_len: Int) -> String:
    return String(line[byte = prefix_len : line.byte_length()])


def _float_width_of_spelling(type_part: String) -> Int:
    var t = type_part
    if t.endswith("?"):
        t = String(type_part[byte = 0 : type_part.byte_length() - 1])
    if t == "float16":
        return 16
    if t == "float32":
        return 32
    if t == "float64":
        return 64
    # A dictionary of floats compares as floats: dictionary<index,float64>.
    if t.startswith("dictionary<") and t.endswith(",float32>"):
        return 32
    if t.startswith("dictionary<") and t.endswith(",float64>"):
        return 64
    return 0


def _is_nested_spelling(type_part: String) -> Bool:
    return (
        type_part.startswith("list")
        or type_part.startswith("large_list")
        or type_part.startswith("fixed_size_list")
        or type_part.startswith("struct")
        or type_part.startswith("map")
        or type_part.startswith("union_")
    )


def _parse_order(mut policy: CanonPolicy, value: String) raises:
    if value == "total":
        policy.order = ORDER_TOTAL
        return
    if value == "none":
        policy.order = ORDER_NONE
        return
    if value.startswith("keys="):
        var keys = split_unescaped(_rest(value, 5), 44)  # ','
        for k in keys:
            if k.byte_length() == 0:
                raise Error("canon: 'order: " + value + "' names an empty key")
        policy.order = ORDER_KEYS
        policy.keys = keys^
        return
    raise Error(
        "canon: 'order: " + value + "' is not total, none or keys=<c1>,<c2>"
    )


def parse_canon(text: String) raises -> CanonText:
    """Parse canonical text (an expected file, or canon's own output)."""
    var lines = _lines(text)
    if len(lines) == 0 or lines[0] != CANON_MAGIC:
        raise Error("canon: the first line must be '" + String(CANON_MAGIC) + "'")
    for li in range(len(lines)):
        if lines[li].find("\r") >= 0:
            raise Error(
                "canon: line " + String(li + 1)
                + " holds a raw CR (a CR in a value is written \\r)"
            )
    var policy = CanonPolicy()
    var seen_order = False
    var seen_float = False
    var i = 1
    while i < len(lines) and lines[i].startswith("#"):
        ref line = lines[i]
        var where = String("canon: line ") + String(i + 1) + ": "
        if line.startswith("#!"):
            raise Error(where + "unknown directive '" + line + "'")
        if line.startswith("#  order: "):
            if seen_order:
                raise Error(where + "a second order line")
            _parse_order(policy, _rest(line, 10))
            seen_order = True
        elif line.startswith("#  float: "):
            if seen_float:
                raise Error(where + "a second float line")
            policy.tolerance = FloatTolerance.parse(_rest(line, 10))
            seen_float = True
        elif line.startswith("#  float["):
            var close = find_unescaped(line, 93, 9)  # ']'
            if close < 0 or not String(line[byte = close : line.byte_length()]).startswith("]: "):
                raise Error(where + "malformed float override '" + line + "'")
            var name = String(line[byte=9:close])
            for k in range(len(policy.override_names)):
                if policy.override_names[k] == name:
                    raise Error(where + "a second float override for " + name)
            policy.override_names.append(name)
            policy.override_tolerances.append(
                FloatTolerance.parse(_rest(line, close + 3))
            )
        elif line.startswith("#  order") or line.startswith("#  float"):
            raise Error(where + "malformed directive '" + line + "'")
        i += 1
    if not seen_order or not seen_float:
        raise Error("canon: the header needs both an order line and a float line")
    if i >= len(lines):
        raise Error("canon: no schema line")

    var res = CanonText(policy^)
    ref schema_line = lines[i]
    var nested = List[Bool]()
    var nested_types = List[NestedFloatType]()
    if schema_line.byte_length() > 0:
        for entry in schema_line.split("\t"):
            var e = String(entry)
            var colon = find_unescaped(e, 58)  # ':'
            if colon < 0:
                raise Error("canon: schema entry '" + e + "' has no ':'")
            var type_part = _rest(e, colon + 1)
            res.schema.append(e)
            res.names.append(String(e[byte=0:colon]))
            res.float_widths.append(_float_width_of_spelling(type_part))
            nested.append(_is_nested_spelling(type_part))
            nested_types.append(NestedFloatType(type_part))
    var ncols = len(res.schema)

    for k in res.policy.keys:
        var hits = 0
        for c in range(ncols):
            if res.names[c] == k:
                hits += 1
        if hits != 1:
            raise Error(
                "canon: order key '" + k + "' names " + String(hits)
                + " columns, not one"
            )
    for name in res.policy.override_names:
        var c = res.column_index(name)
        if c < 0 or res.float_widths[c] == 0:
            raise Error(
                "canon: float override '" + name + "' names no float column"
            )

    i += 1
    while i < len(lines):
        ref line = lines[i]
        var row = List[String](capacity=ncols)
        if ncols == 0:
            if line.byte_length() != 0:
                raise Error(
                    "canon: line " + String(i + 1)
                    + ": a row of a zero-column result must be empty"
                )
        else:
            for piece in line.split("\t"):
                row.append(String(piece))
            if len(row) != ncols:
                raise Error(
                    "canon: line " + String(i + 1) + " has " + String(len(row))
                    + " cells, the schema " + String(ncols)
                )
            for c in range(ncols):
                var w = res.float_widths[c]
                try:
                    if w > 0:
                        row[c] = parse_float_cell(row[c], w).canonical(w)
                    elif nested[c]:
                        check_nested_cell(row[c])
                        nested_types[c].check(row[c])
                    else:
                        check_scalar_cell(row[c])
                except e:
                    raise Error(
                        "line " + String(i + 1) + " column " + res.names[c]
                        + ": " + String(e)
                    )
        res.rows.append(row^)
        i += 1
    return res^
