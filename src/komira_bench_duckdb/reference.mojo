# Recorded reference answers: for each query, the signature of its result (and
# its ORDER BY keys), in a line-oriented text a package can compile in as a
# constant. With them a run is value-checked without any other engine.
#
# One record, one query, after a `format 2` line (every record written by
# `format_reference` starts with one, and a text of several records may repeat
# it between records). A text that has records and no format line was written by
# an older layout, and one that names another format is of another layout:
# both are refused with that said, never read as the current layout.
#
#     format 2
#     query <id>
#     rows <n>
#     order <column>:<a|d>:<f|l>[,...]          optional: the ORDER BY keys
#     column <kind> <count> <nulls> <nans> <isum> <isumsq> <imin> <imax> <sum> <sumsq> <min> <max> <text-bytes> <text-hash> <x-hex-min> <x-hex-max> <dcount> <dsum> <dmin> <dmax> <dhash>
#     ...                                        one line per column
#     end
#
# `kind` is 0 (no value), 1 (integers), 2 (doubles), 3 (texts) or 4 (exact
# decimals); `isum` and `isumsq` are the integer sum and sum of squares modulo
# 2^64 (as a signed 64-bit number) and `text-hash` and `dhash` are the sums of
# the cell hashes, likewise. `dcount` is the number of exact decimals, `dsum`
# their exact sum and `dmin` and `dmax` the smallest and largest, as canonical
# decimal text (decimal_text.mojo); they are `0 0 0 0` for a column with none. A
# double that is not finite is written as `inf`, `-inf` or `nan`. Blank lines
# and lines starting with `#` between records are ignored. A column that mixes numbers and texts has no
# recorded form.

from std.math import inf, nan

from komira_crypto import hex_lower

from .cells import KIND_DECIMAL, KIND_FLOAT, KIND_INT, KIND_NULL, KIND_TEXT
from .decimal_text import ExactSum, canonical_decimal
from .order import OrderKey
from .text import slice_bytes
from .signature import ColumnSignature, ResultSignature


comptime REFERENCE_FORMAT: Int = 2
"""The layout this file writes and reads. 2 added the exact decimal kind and its
five fields to the column line; 1 had no format line."""


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


def _float_text(v: Float64) -> String:
    """A double as text that `_parse_float` reads back to the same value."""
    if v != v:
        return String("nan")
    if v - v != Float64(0):
        return String("inf") if v > Float64(0) else String("-inf")
    return String(v)


def _parse_float(token: String) raises -> Float64:
    if token == "nan":
        return nan[DType.float64]()
    if token == "inf":
        return inf[DType.float64]()
    if token == "-inf":
        return -inf[DType.float64]()
    return atof(token)


def format_reference(ans: ReferenceAnswer) raises -> String:
    """The record of `ans`."""
    var out = String("format ") + String(REFERENCE_FORMAT) + String("\nquery ") + ans.id + String("\nrows ") + String(ans.signature.rows) + String("\n")
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
            raise Error(String("column ") + String(c) + String(" mixes values that cannot be recorded (numbers and texts, or exact decimals and doubles)"))
        out += String("column ") + String(col.kind()) + String(" ") + String(col.count)
        out += String(" ") + String(col.nulls) + String(" ") + String(col.nans)
        out += String(" ") + String(col.isum) + String(" ") + String(col.isumsq)
        out += String(" ") + String(col.imin) + String(" ") + String(col.imax)
        out += String(" ") + _float_text(col.sum) + String(" ") + _float_text(col.sumsq)
        out += String(" ") + _float_text(col.min_v) + String(" ") + _float_text(col.max_v)
        out += String(" ") + String(col.text_bytes) + String(" ") + String(col.text_hash)
        out += String(" ") + _hex_of(col.text_min) + String(" ") + _hex_of(col.text_max)
        out += String(" ") + String(col.dcount) + String(" ") + col.dsum.text()
        out += String(" ") + col.dmin + String(" ") + col.dmax + String(" ") + String(col.dhash)
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
    if len(tokens) != 22:
        raise Error(String("a column line has 22 fields, got ") + String(len(tokens)))
    var col = ColumnSignature()
    var kind = atol(tokens[1])
    if kind < KIND_NULL or kind > KIND_DECIMAL:
        raise Error(String("unknown column kind ") + tokens[1])
    col.has_numeric = kind == KIND_INT or kind == KIND_FLOAT
    col.has_text = kind == KIND_TEXT
    col.has_decimal = kind == KIND_DECIMAL
    col.all_int = kind != KIND_FLOAT
    col.count = atol(tokens[2])
    col.nulls = atol(tokens[3])
    col.nans = atol(tokens[4])
    col.isum = Int64(atol(tokens[5]))
    col.isumsq = Int64(atol(tokens[6]))
    col.imin = Int64(atol(tokens[7]))
    col.imax = Int64(atol(tokens[8]))
    col.sum = _parse_float(tokens[9])
    col.sumsq = _parse_float(tokens[10])
    col.min_v = _parse_float(tokens[11])
    col.max_v = _parse_float(tokens[12])
    col.text_bytes = atol(tokens[13])
    col.text_hash = Int64(atol(tokens[14]))
    col.text_min = _unhex(tokens[15])
    col.text_max = _unhex(tokens[16])
    col.dcount = atol(tokens[17])
    if col.dcount < 0 or col.dcount > col.count or (col.dcount > 0) != (kind == KIND_DECIMAL):
        raise Error(String("a column of kind ") + tokens[1] + String(" cannot hold ") + tokens[17] + String(" decimals of ") + tokens[2])
    col.dsum = ExactSum()
    col.dsum.add(tokens[18])
    col.dmin = canonical_decimal(tokens[19])
    col.dmax = canonical_decimal(tokens[20])
    col.dhash = Int64(atol(tokens[21]))
    if col.dsum.text() != tokens[18]:
        raise Error(String("a decimal sum is not written canonically: ") + tokens[18])
    if col.dmin != tokens[19] or col.dmax != tokens[20]:
        raise Error(String("a decimal bound is not written canonically: ") + tokens[19] + String(" ") + tokens[20])
    return col^


def parse_references(text: String) raises -> ReferenceSet:
    """Every record in `text`. Raises on a malformed record or a repeated id."""
    var set = ReferenceSet()
    var rest = text
    var current = Optional[ReferenceAnswer](None)
    var have_rows = False
    var have_format = False
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
        if head == "format":
            if current or len(t) != 2:
                raise Error(String("bad format line: ") + line)
            if t[1] != String(REFERENCE_FORMAT):
                raise Error(
                    String("the reference answers are in format ") + t[1]
                    + String(", this reader reads format ") + String(REFERENCE_FORMAT)
                    + String(" only: record them again")
                )
            have_format = True
        elif head == "query":
            if not have_format:
                raise Error(
                    String("the reference answers have no format line: they were recorded in an older layout (format 1),")
                    + String(" this reader reads format ") + String(REFERENCE_FORMAT)
                    + String(" only: record them again")
                )
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
