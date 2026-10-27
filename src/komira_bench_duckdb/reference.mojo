# Recorded reference answers: for each query, the signature of its result (and
# its ORDER BY keys), in a line-oriented text a package can compile in as a
# constant. With them a run is value-checked without any other engine.
#
# One record, one query:
#
#     query <id>
#     rows <n>
#     order <column>:<a|d>:<f|l>[,...]          optional: the ORDER BY keys
#     column <kind> <count> <nulls> <nans> <exact> <isum> <isumsq> <imin> <imax> <sum> <sumsq> <min> <max> <text-bytes> <x-hex-min> <x-hex-max>
#     ...                                        one line per column
#     end
#
# `kind` is 0 (no value), 1 (integers), 2 (doubles) or 3 (texts); `exact` is 1
# when the integer sum is exact, plus 2 when the sum of squares is. Blank lines and lines starting with `#`
# between records are ignored. A column that mixes numbers and texts has no
# recorded form.

from komira_crypto import hex_lower

from .cells import KIND_FLOAT, KIND_INT, KIND_NULL, KIND_TEXT
from .order import OrderKey
from .text import slice_bytes
from .signature import ColumnSignature, ResultSignature


struct ReferenceAnswer(Copyable, Movable):
    """The recorded answer of one query."""

    var id: String
    var signature: ResultSignature
    var order: List[OrderKey]

    def __init__(out self, var id: String):
        self.id = id^
        self.signature = ResultSignature()
        self.order = List[OrderKey]()


struct ReferenceSet(Copyable, Movable):
    """Recorded answers, looked up by query id."""

    var answers: List[ReferenceAnswer]

    def __init__(out self):
        self.answers = List[ReferenceAnswer]()

    def find(self, id: String) -> Int:
        """The index of the answer for `id`, or -1."""
        for i in range(len(self.answers)):
            if self.answers[i].id == id:
                return i
        return -1


def _hex_of(s: String) -> String:
    return String("x") + hex_lower(s.as_bytes())


def _nibble(c: UInt8) raises -> Int:
    if c >= UInt8(48) and c <= UInt8(57):
        return Int(c) - 48
    if c >= UInt8(97) and c <= UInt8(102):
        return Int(c) - 87
    raise Error("a hex digit is not 0-9a-f")


def _unhex(token: String) raises -> String:
    var b = token.as_bytes()
    if len(b) < 1 or b[0] != UInt8(120) or (len(b) - 1) % 2 != 0:
        raise Error(String("not a hex text: ") + token)
    var bytes = List[UInt8]()
    var i = 1
    while i < len(b):
        bytes.append(UInt8(_nibble(b[i]) * 16 + _nibble(b[i + 1])))
        i += 2
    return String(unsafe_from_utf8=Span[UInt8](bytes))


def _finite(v: Float64, what: String) raises:
    if v != v or v - v != Float64(0):
        raise Error(String("a recorded ") + what + String(" is not finite"))


def format_reference(ans: ReferenceAnswer) raises -> String:
    """The record of `ans`."""
    var out = String("query ") + ans.id + String("\nrows ") + String(ans.signature.rows) + String("\n")
    if len(ans.order) > 0:
        var parts = String("")
        for i in range(len(ans.order)):
            if i > 0:
                parts += String(",")
            var k = ans.order[i].copy()
            parts += String(k.column) + String(":") + String("d" if k.descending else "a")
            parts += String(":") + String("f" if k.nulls_first else "l")
        out += String("order ") + parts + String("\n")
    for c in range(len(ans.signature.columns)):
        var col = ans.signature.columns[c].copy()
        if col.mixed():
            raise Error(String("column ") + String(c) + String(" mixes numbers and texts"))
        _finite(col.sum, "sum")
        _finite(col.sumsq, "sum of squares")
        out += String("column ") + String(col.kind()) + String(" ") + String(col.count)
        out += String(" ") + String(col.nulls) + String(" ") + String(col.nans)
        out += String(" ") + String((1 if col.sum_exact else 0) + (2 if col.sumsq_exact else 0))
        out += String(" ") + String(col.isum) + String(" ") + String(col.isumsq)
        out += String(" ") + String(col.imin) + String(" ") + String(col.imax)
        out += String(" ") + String(col.sum) + String(" ") + String(col.sumsq)
        out += String(" ") + String(col.min_v) + String(" ") + String(col.max_v)
        out += String(" ") + String(col.text_bytes)
        out += String(" ") + _hex_of(col.text_min) + String(" ") + _hex_of(col.text_max)
        out += String("\n")
    out += String("end\n")
    return out^


def _tokens(line: String) -> List[String]:
    var out = List[String]()
    var rest = line
    while True:
        var sp = rest.find(String(" "))
        if sp < 0:
            if rest.byte_length() > 0:
                out.append(rest)
            return out^
        if sp > 0:
            out.append(String(rest[byte=0:sp]))
        rest = slice_bytes(rest, sp + 1, rest.byte_length())


def _parse_order(spec: String) raises -> List[OrderKey]:
    var keys = List[OrderKey]()
    var rest = spec
    while rest.byte_length() > 0:
        var comma = rest.find(String(","))
        var item = rest
        if comma >= 0:
            item = String(rest[byte=0:comma])
            rest = slice_bytes(rest, comma + 1, rest.byte_length())
        else:
            rest = String("")
        var a = item.find(String(":"))
        if a < 0:
            raise Error(String("bad order key: ") + item)
        var tail = String(item[byte = a + 1 : item.byte_length()])
        var b = tail.find(String(":"))
        if b < 0:
            raise Error(String("bad order key: ") + item)
        var dir = String(tail[byte=0:b])
        var nulls = String(tail[byte = b + 1 : tail.byte_length()])
        if (dir != "a" and dir != "d") or (nulls != "f" and nulls != "l"):
            raise Error(String("bad order key: ") + item)
        keys.append(OrderKey(atol(String(item[byte=0:a])), dir == "d", nulls == "f"))
    return keys^


def _parse_column(tokens: List[String]) raises -> ColumnSignature:
    if len(tokens) != 17:
        raise Error(String("a column line has 17 fields, got ") + String(len(tokens)))
    var col = ColumnSignature()
    var kind = atol(tokens[1])
    if kind < KIND_NULL or kind > KIND_TEXT:
        raise Error(String("unknown column kind ") + tokens[1])
    col.has_numeric = kind == KIND_INT or kind == KIND_FLOAT
    col.has_text = kind == KIND_TEXT
    col.all_int = kind != KIND_FLOAT
    col.count = atol(tokens[2])
    col.nulls = atol(tokens[3])
    col.nans = atol(tokens[4])
    var exact = atol(tokens[5])
    col.sum_exact = exact % 2 == 1
    col.sumsq_exact = exact >= 2
    col.isum = Int64(atol(tokens[6]))
    col.isumsq = Int64(atol(tokens[7]))
    col.imin = Int64(atol(tokens[8]))
    col.imax = Int64(atol(tokens[9]))
    col.sum = atof(tokens[10])
    col.sumsq = atof(tokens[11])
    col.min_v = atof(tokens[12])
    col.max_v = atof(tokens[13])
    col.text_bytes = atol(tokens[14])
    col.text_min = _unhex(tokens[15])
    col.text_max = _unhex(tokens[16])
    return col^


def parse_references(text: String) raises -> ReferenceSet:
    """Every record in `text`. Raises on a malformed record or a repeated id."""
    var set = ReferenceSet()
    var rest = text
    var current = Optional[ReferenceAnswer](None)
    var have_rows = False
    while rest.byte_length() > 0:
        var nl = rest.find(String("\n"))
        var line = rest
        if nl >= 0:
            line = String(rest[byte=0:nl])
            rest = slice_bytes(rest, nl + 1, rest.byte_length())
        else:
            rest = String("")
        var t = _tokens(line)
        if len(t) == 0 or t[0].startswith(String("#")):
            continue
        var head = t[0]
        if head == "query":
            if current:
                raise Error("a query record starts before the last one ends")
            if len(t) != 2:
                raise Error(String("bad query line: ") + line)
            if set.find(t[1]) >= 0:
                raise Error(String("query recorded twice: ") + t[1])
            current = Optional[ReferenceAnswer](ReferenceAnswer(t[1]))
            have_rows = False
        elif not current:
            raise Error(String("a line outside a record: ") + line)
        elif head == "rows":
            if len(t) != 2:
                raise Error(String("bad rows line: ") + line)
            current.value().signature.rows = atol(t[1])
            have_rows = True
        elif head == "order":
            if len(t) != 2:
                raise Error(String("bad order line: ") + line)
            current.value().order = _parse_order(t[1])
        elif head == "column":
            current.value().signature.columns.append(_parse_column(t))
        elif head == "end":
            if not have_rows:
                raise Error(String("record ") + current.value().id + String(" has no rows line"))
            set.answers.append(current.take())
        else:
            raise Error(String("unknown line: ") + line)
    if current:
        raise Error(String("record ") + current.value().id + String(" has no end line"))
    return set^
