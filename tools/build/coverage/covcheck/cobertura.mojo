"""The Cobertura XML reader (the shape kcov writes, and the common core of
other writers').

What is read: each `<class filename=...>` and the `<line number= hits=>`
elements of its `<lines>`. A line with `branch="true"` carries
`condition-coverage="NN% (k/n)"`: n branches, of which k were taken (kept as
branches `<line>,c,0` .. `<line>,c,n-1`, the first k taken). Nothing else
carries data: every `*-rate`, `*-covered`, `*-valid`, `complexity`,
`timestamp` and `version` attribute is ignored (kcov writes
`branch-rate="1.0"` with no branch data at all), and so are `<source>`
elements (they are the absolute paths of the sandbox the tests ran in; a
class's `filename` is mapped as it is written, see paths.mojo). The
`<lines>` of a `<method>` repeat the class's and are not read.

The XML accepted: an optional `<?xml ...?>` declaration, `<!DOCTYPE ...>`,
comments, elements with attributes in any order quoted with `"` or `'`,
self-closing or with an end tag, the five predefined entities in attribute
values. Refused, naming the line: non-blank text outside the root element
(a UTF-8 byte order mark included), a tag never closed, an end tag that does
not match, an attribute without a quoted value, an attribute given twice in
one tag, an unknown entity (numeric character references included), CDATA
and any other `<!` markup, a DOCTYPE with an internal subset, a root
element that is not `<coverage>`, a second root element, a `<class>` inside
a `<class>`, a `<class>` without `filename`, a `<line>` without `number` or
`hits` or whose values are not decimal numbers, a `<line>` number of 0 or
above 10^9, a `branch` value other than `true`/`false`, a branch line
without a well-formed `condition-coverage`, and one claiming more than 4096
branches on a line.
"""

from covcheck.model import FileCov, merge_by_path
from covcheck.text import MAX_LINE, parse_count

# The most branches a `condition-coverage` may claim for one line (each is
# kept as a record, so an absurd count would exhaust memory).
comptime MAX_BRANCHES: Int = 4096


struct _Attr(Copyable, Movable):
    var name: String
    var value: String

    def __init__(out self, name: String, value: String):
        self.name = name
        self.value = value


def _line_of(b: List[UInt8], at: Int) -> Int:
    var n = 1
    for i in range(min(at, len(b))):
        if b[i] == UInt8(10):
            n += 1
    return n


def _fail(origin: String, b: List[UInt8], at: Int, why: String) raises:
    raise Error(origin + String(":") + String(_line_of(b, at)) + String(": ") + why)


def _is_space(c: UInt8) -> Bool:
    return c == UInt8(32) or c == UInt8(9) or c == UInt8(10) or c == UInt8(13)


def _is_name_end(c: UInt8) -> Bool:
    return _is_space(c) or c == UInt8(47) or c == UInt8(62) or c == UInt8(61)


def _at(b: List[UInt8], i: Int, pat: String) -> Bool:
    """Whether `b` holds `pat` at index `i`."""
    var p = pat.as_bytes()
    if i + len(p) > len(b):
        return False
    for k in range(len(p)):
        if b[i + k] != p[k]:
            return False
    return True


def _find(b: List[UInt8], start: Int, pat: String) -> Int:
    """The index of the first `pat` in `b` at or after `start`, or -1."""
    var p = pat.as_bytes()
    var n = len(b)
    var m = len(p)
    var i = start
    while i + m <= n:
        var ok = True
        for k in range(m):
            if b[i + k] != p[k]:
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1


def _text(b: List[UInt8], start: Int, end: Int) -> String:
    var sub = List[UInt8](capacity=max(end - start, 0))
    for i in range(start, end):
        sub.append(b[i])
    return String(from_utf8_lossy=sub)


def _unescape(origin: String, b: List[UInt8], start: Int, end: Int) raises -> String:
    """Bytes [start, end) of `b`, an attribute value, with its entities
    decoded."""
    var out = List[UInt8](capacity=end - start)
    var i = start
    while i < end:
        var c = b[i]
        if c == UInt8(60):
            _fail(origin, b, i, String("'<' in an attribute value"))
        if c != UInt8(38):
            out.append(c)
            i += 1
            continue
        var semi = -1
        for k in range(i + 1, min(end, i + 8)):
            if b[k] == UInt8(59):
                semi = k
                break
        if semi < 0:
            _fail(origin, b, i, String("an '&' that starts no entity"))
        var name = _text(b, i + 1, semi)
        if name == String("amp"):
            out.append(UInt8(38))
        elif name == String("lt"):
            out.append(UInt8(60))
        elif name == String("gt"):
            out.append(UInt8(62))
        elif name == String("quot"):
            out.append(UInt8(34))
        elif name == String("apos"):
            out.append(UInt8(39))
        else:
            _fail(origin, b, i, String("unknown entity '&") + name + String(";'"))
        i = semi + 1
    return String(from_utf8_lossy=out)


def _attr(attrs: List[_Attr], name: String) -> Int:
    """The index of attribute `name`, or -1."""
    for i in range(len(attrs)):
        if attrs[i].name == name:
            return i
    return -1


def _number(origin: String, b: List[UInt8], at: Int, attrs: List[_Attr], name: String, tag: String) raises -> Int:
    var k = _attr(attrs, name)
    if k < 0:
        _fail(origin, b, at, String("<") + tag + String("> has no ") + name)
    var v = parse_count(attrs[k].value)
    if v < 0:
        _fail(origin, b, at, String("<") + tag + String("> ") + name + String("='") + attrs[k].value + String("' is not a decimal number"))
    return v


def _condition(origin: String, b: List[UInt8], at: Int, value: String) raises -> List[Int]:
    """`NN% (k/n)` as [k, n]."""
    var lp = value.find("(")
    var slash = value.find("/")
    var close = value.find(")")
    var pct = value.find("%")
    if pct <= 0 or lp < pct or slash < lp or close < slash or close != value.byte_length() - 1:
        _fail(origin, b, at, String("condition-coverage '") + value + String("' is not 'NN% (k/n)'"))
    var k = parse_count(String(value[byte = lp + 1 : slash]))
    var n = parse_count(String(value[byte = slash + 1 : close]))
    if k < 0 or n <= 0 or k > n:
        _fail(origin, b, at, String("condition-coverage '") + value + String("' is not 'NN% (k/n)' with 0 <= k <= n, n > 0"))
    if n > MAX_BRANCHES:
        _fail(origin, b, at, String("condition-coverage '") + value + String("' claims more than 4096 branches on one line"))
    var kn = List[Int]()
    kn.append(k)
    kn.append(n)
    return kn^


def parse_cobertura(text: String, origin: String) raises -> List[FileCov]:
    """The files of the Cobertura report `text` (`origin` names it in
    errors), each path once."""
    var b = List[UInt8]()
    b.extend(Span(text.as_bytes()))
    var n = len(b)
    var stack = List[String]()
    var files = List[FileCov]()
    var current = FileCov(String(""))
    var in_class = False
    var saw_root = False
    var i = 0
    while i < n:
        if b[i] != UInt8(60):
            # Text is never read.
            if len(stack) == 0 and not _is_space(b[i]):
                _fail(origin, b, i, String("text outside the root element"))
            i += 1
            continue
        var start = i
        if _at(b, i, String("<?")):
            var e = _find(b, i + 2, String("?>"))
            if e < 0:
                _fail(origin, b, start, String("unterminated <?"))
            i = e + 2
            continue
        if _at(b, i, String("<!--")):
            var e = _find(b, i + 4, String("-->"))
            if e < 0:
                _fail(origin, b, start, String("unterminated comment"))
            i = e + 3
            continue
        if _at(b, i, String("<!DOCTYPE")):
            var e = _find(b, i, String(">"))
            if e < 0:
                _fail(origin, b, start, String("unterminated DOCTYPE"))
            var sub = _find(b, i, String("["))
            if sub >= 0 and sub < e:
                _fail(origin, b, start, String("a DOCTYPE with an internal subset"))
            i = e + 1
            continue
        if i + 1 < n and b[i + 1] == UInt8(33):
            _fail(origin, b, start, String("unsupported markup '<!' (CDATA is not read)"))
        if i + 1 < n and b[i + 1] == UInt8(47):
            # An end tag.
            var j = i + 2
            while j < n and not _is_name_end(b[j]):
                j += 1
            var name = _text(b, i + 2, j)
            while j < n and _is_space(b[j]):
                j += 1
            if j >= n or b[j] != UInt8(62):
                _fail(origin, b, start, String("unterminated end tag </") + name)
            if len(stack) == 0 or stack[len(stack) - 1] != name:
                var open_name = String("nothing") if len(stack) == 0 else String("<") + stack[len(stack) - 1] + String(">")
                _fail(origin, b, start, String("</") + name + String("> closes ") + open_name)
            _ = stack.pop()
            if name == String("class"):
                files.append(current.copy())
                in_class = False
            i = j + 1
            continue
        # A start tag.
        var j = i + 1
        while j < n and not _is_name_end(b[j]):
            j += 1
        var tag = _text(b, i + 1, j)
        if tag.byte_length() == 0:
            _fail(origin, b, start, String("a tag with no name"))
        var attrs = List[_Attr]()
        var self_closing = False
        while True:
            while j < n and _is_space(b[j]):
                j += 1
            if j >= n or b[j] == UInt8(60):
                _fail(origin, b, start, String("unterminated tag <") + tag)
            if b[j] == UInt8(62):
                j += 1
                break
            if b[j] == UInt8(47):
                if j + 1 < n and b[j + 1] == UInt8(62):
                    self_closing = True
                    j += 2
                    break
                _fail(origin, b, j, String("'/' not followed by '>' in <") + tag)
            var a0 = j
            while j < n and not _is_name_end(b[j]):
                j += 1
            var aname = _text(b, a0, j)
            if aname.byte_length() == 0:
                _fail(origin, b, j, String("malformed attribute in <") + tag)
            while j < n and _is_space(b[j]):
                j += 1
            if j >= n or b[j] != UInt8(61):
                _fail(origin, b, a0, String("attribute ") + aname + String(" of <") + tag + String("> has no value"))
            j += 1
            while j < n and _is_space(b[j]):
                j += 1
            if j >= n or (b[j] != UInt8(34) and b[j] != UInt8(39)):
                _fail(origin, b, a0, String("attribute ") + aname + String(" of <") + tag + String("> is not quoted"))
            var q = b[j]
            var v0 = j + 1
            var v1 = v0
            while v1 < n and b[v1] != q:
                v1 += 1
            if v1 >= n:
                _fail(origin, b, a0, String("unterminated value of ") + aname + String(" in <") + tag)
            if _attr(attrs, aname) >= 0:
                _fail(origin, b, a0, String("attribute ") + aname + String(" of <") + tag + String("> is given twice"))
            attrs.append(_Attr(aname, _unescape(origin, b, v0, v1)))
            j = v1 + 1
        if len(stack) == 0:
            if saw_root:
                _fail(origin, b, start, String("a second root element <") + tag + String(">"))
            if tag != String("coverage"):
                _fail(origin, b, start, String("the root element is <") + tag + String(">, not <coverage>"))
            saw_root = True
        var parent = String("") if len(stack) == 0 else stack[len(stack) - 1]
        var grandparent = String("") if len(stack) < 2 else stack[len(stack) - 2]
        if tag == String("class"):
            if in_class:
                _fail(origin, b, start, String("<class> inside <class>"))
            var k = _attr(attrs, String("filename"))
            if k < 0 or attrs[k].value.byte_length() == 0:
                _fail(origin, b, start, String("<class> has no filename"))
            current = FileCov(attrs[k].value)
            in_class = True
            if self_closing:
                files.append(current.copy())
                in_class = False
        elif tag == String("line") and parent == String("lines") and grandparent == String("class"):
            var number = _number(origin, b, start, attrs, String("number"), tag)
            if number == 0:
                _fail(origin, b, start, String("<line> number 0 (lines start at 1)"))
            if number > MAX_LINE:
                _fail(origin, b, start, String("<line> number ") + String(number) + String(" is above 10^9"))
            current.add_line(number, _number(origin, b, start, attrs, String("hits"), tag))
            var kb = _attr(attrs, String("branch"))
            if kb >= 0:
                var bv = attrs[kb].value
                if bv == String("true"):
                    var kc = _attr(attrs, String("condition-coverage"))
                    if kc < 0:
                        _fail(origin, b, start, String("a branch line has no condition-coverage"))
                    var kn = _condition(origin, b, start, attrs[kc].value)
                    for x in range(kn[1]):
                        current.add_branch(String(number) + String(",c,") + String(x), 1 if x < kn[0] else 0)
                elif bv != String("false"):
                    _fail(origin, b, start, String("<line> branch='") + bv + String("' is not true or false"))
        if not self_closing:
            stack.append(tag)
        i = j
    if not saw_root:
        _fail(origin, b, n, String("no <coverage> element"))
    if len(stack) > 0:
        _fail(origin, b, n, String("<") + stack[len(stack) - 1] + String("> is never closed"))
    return merge_by_path(files^)
