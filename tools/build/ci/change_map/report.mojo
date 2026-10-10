"""The answer as text, as JSON and in kci's protocol."""

from buildtools.bytes import byte_at, hex_byte, join

from change_map.plan import KIND_AFFECTED, KIND_BROKEN, KIND_WIDENED, Verdict


def one_line(text: String) -> String:
    """`text` with every line break a space."""
    var out = String()
    var b = text.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == UInt8(10) or b[i] == UInt8(13):
            out += String(text[byte=start:i]) + String(" ")
            start = i + 1
    out += String(text[byte=start:])
    return out^


def json_string(s: String) -> String:
    var out = String('"')
    var start = 0
    for i in range(s.byte_length()):
        var c = byte_at(s, i)
        if c == 34 or c == 92 or c < 32:
            out += String(s[byte=start:i])
            start = i + 1
            if c == 34:
                out += String('\\"')
            elif c == 92:
                out += String("\\\\")
            elif c == 10:
                out += String("\\n")
            elif c == 13:
                out += String("\\r")
            elif c == 9:
                out += String("\\t")
            else:
                out += String("\\u00") + hex_byte(c)
    out += String(s[byte=start:])
    out += String('"')
    return out^


def _json_list(items: List[String]) -> String:
    var parts = List[String]()
    for i in range(len(items)):
        parts.append(json_string(items[i]))
    return String("[") + join(parts, String(",")) + String("]")


def render_targets(v: Verdict) -> String:
    """One label per line."""
    var out = String()
    for i in range(len(v.targets)):
        out += v.targets[i] + String("\n")
    return out^


def render_seconds(ms: Int) -> String:
    var frac = ms % 1000
    var pad = String("")
    if frac < 100:
        pad = String("0")
    if frac < 10:
        pad = String("00")
    return String(ms // 1000) + String(".") + pad + String(frac) + String("s")


def render_summary(v: Verdict, ms: Int) -> String:
    """The one stderr line: the verdict, the counts, the time."""
    var s = String("affected: ") + v.kind + String(": ") + String(len(v.targets)) + String(" target(s) from ")
    s += String(v.files) + String(" file(s), ") + String(v.seeds) + String(" seed(s), ") + render_seconds(ms)
    if v.reason.byte_length() > 0:
        s += String(" -- ") + v.reason
    return s^


def render_json(v: Verdict, ms: Int) -> String:
    var s = String('{"verdict":') + json_string(v.kind)
    s += String(',"reason":') + json_string(v.reason)
    s += String(',"widened":') + (String("true") if v.kind == String(KIND_WIDENED) else String("false"))
    s += String(',"files":') + String(v.files) + String(',"seeds":') + String(v.seeds)
    s += String(',"milliseconds":') + String(ms)
    s += String(',"warnings":') + _json_list(v.warnings)
    s += String(',"targets":') + _json_list(v.targets)
    s += String("}\n")
    return s^


def render_units_answer(v: Verdict, units: List[String]) -> String:
    """The answer in kci's grammar: `UNIT <name>` lines, then exactly one verdict line.
    A WIDENED or BROKEN answer names no unit (kci fails the check on BROKEN);
    a change that reaches none says `AFFECTED 0` and kci refuses it."""
    if v.kind == String(KIND_WIDENED):
        return String("WIDENED ") + one_line(v.reason) + String("\n")
    if v.kind == String(KIND_BROKEN):
        return String("BROKEN ") + one_line(v.reason) + String("\n")
    var s = String()
    for i in range(len(units)):
        s += String("UNIT ") + units[i] + String("\n")
    s += String(KIND_AFFECTED) + String(" ") + String(len(units)) + String("\n")
    return s^
