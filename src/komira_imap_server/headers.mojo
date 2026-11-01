# Header blocks read as bytes, leniently. FETCH of a header section and
# SEARCH must work on mail that a strict parser would refuse (a header line
# without a colon, a multipart without a boundary), so they do not go through
# `komira_mail_message.parse_message`: this scanner never fails. It finds the
# end of the header block, the fields in it (name, unfolded value, the bytes
# as written), and filters them for `HEADER.FIELDS`.
#
# A line ends at an LF (a CR before it belongs to the line break). The header
# block ends at the first empty line, which is part of it; without one the
# whole input is header. A line that starts with a space or a tab continues
# the field before it. A line that is not a continuation and has no colon, or
# whose name holds a space, a control byte or a byte over 0x7E, is skipped:
# it is in the bytes of the header block but is not a field.

comptime _LF: UInt8 = 0x0A
comptime _CR: UInt8 = 0x0D
comptime _SP: UInt8 = 0x20
comptime _TAB: UInt8 = 0x09
comptime _COLON: UInt8 = 0x3A


def lower_byte(c: UInt8) -> UInt8:
    if c >= 0x41 and c <= 0x5A:
        return c + 32
    return c


def lower_bytes(s: Span[UInt8, _]) -> List[UInt8]:
    var out = List[UInt8](capacity=len(s))
    for i in range(len(s)):
        out.append(lower_byte(s[i]))
    return out^


def header_len(data: Span[UInt8, _]) -> Int:
    """The length of the header block of `data`, including the empty line that
    ends it; all of `data` when there is no empty line. This is the length of
    `BODY[HEADER]`, and the offset where `BODY[TEXT]` starts."""
    var n = len(data)
    var i = 0
    while i < n:
        var lf = i
        while lf < n and data[lf] != _LF:
            lf += 1
        var content_end = lf
        if lf > i and data[lf - 1] == _CR:
            content_end = lf - 1
        if content_end == i:
            return lf + 1 if lf < n else n
        i = lf + 1
    return n


struct HdrField(Copyable, Movable):
    """One header field: `name` in lower case, `value` unfolded and trimmed,
    and `start`..`end`, the bytes as written (folds and the final line break
    included)."""

    var name: List[UInt8]
    var value: List[UInt8]
    var start: Int
    var end: Int

    def __init__(
        out self,
        var name: List[UInt8],
        var value: List[UInt8],
        start: Int,
        end: Int,
    ):
        self.name = name^
        self.value = value^
        self.start = start
        self.end = end


def _name_ok(name: Span[UInt8, _]) -> Bool:
    if len(name) == 0:
        return False
    for i in range(len(name)):
        if name[i] <= 0x20 or name[i] > 0x7E:
            return False
    return True


def _trim(mut v: List[UInt8]):
    var lo = 0
    var hi = len(v)
    while lo < hi and (v[lo] == _SP or v[lo] == _TAB):
        lo += 1
    while hi > lo and (v[hi - 1] == _SP or v[hi - 1] == _TAB):
        hi -= 1
    if lo == 0 and hi == len(v):
        return
    var out = List[UInt8](capacity=hi - lo)
    for i in range(lo, hi):
        out.append(v[i])
    v = out^


def scan_fields(data: Span[UInt8, _]) -> List[HdrField]:
    """The fields of the header block at the start of `data`, in order."""
    var out = List[HdrField]()
    var n = len(data)
    var i = 0
    var cur = -1
    while i < n:
        var lf = i
        while lf < n and data[lf] != _LF:
            lf += 1
        var content_end = lf
        if lf > i and data[lf - 1] == _CR:
            content_end = lf - 1
        var next = lf + 1 if lf < n else n
        if content_end == i:
            break
        if data[i] == _SP or data[i] == _TAB:
            if cur >= 0:
                for k in range(i, content_end):
                    out[cur].value.append(data[k])
                out[cur].end = next
            i = next
            continue
        cur = -1
        var colon = i
        while colon < content_end and data[colon] != _COLON:
            colon += 1
        if colon == content_end:
            i = next
            continue
        var name_end = colon
        while name_end > i and (data[name_end - 1] == _SP or data[name_end - 1] == _TAB):
            name_end -= 1
        if not _name_ok(data[i:name_end]):
            i = next
            continue
        var value = List[UInt8]()
        for k in range(colon + 1, content_end):
            value.append(data[k])
        out.append(HdrField(lower_bytes(data[i:name_end]), value^, i, next))
        cur = len(out) - 1
        i = next
    for f in range(len(out)):
        _trim(out[f].value)
    return out^


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def find_field(fields: List[HdrField], name: String) -> Int:
    """The index of the first field named `name` (lower case), or -1."""
    var want = lower_bytes(name.as_bytes())
    for i in range(len(fields)):
        if _same(fields[i].name, want):
            return i
    return -1


def select_fields(
    data: Span[UInt8, _], names: List[String], invert: Bool
) -> List[UInt8]:
    """`BODY[HEADER.FIELDS (names)]` (or `.NOT` with `invert`): the lines of
    the header block of `data` whose field is (is not) one of `names`, as
    written, then the empty line. `names` are compared without regard to
    case."""
    var wanted = List[List[UInt8]]()
    for i in range(len(names)):
        wanted.append(lower_bytes(names[i].as_bytes()))
    var fields = scan_fields(data)
    var out = List[UInt8]()
    for f in range(len(fields)):
        var hit = False
        for w in range(len(wanted)):
            if _same(fields[f].name, wanted[w]):
                hit = True
                break
        if hit == invert:
            continue
        for k in range(fields[f].start, fields[f].end):
            out.append(data[k])
        if len(out) > 0 and out[len(out) - 1] != _LF:
            out.append(_CR)
            out.append(_LF)
    out.append(_CR)
    out.append(_LF)
    return out^
