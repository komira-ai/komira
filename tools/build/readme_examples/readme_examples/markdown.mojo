"""What a Markdown file holds as code, and its links. Pure: no I/O.

Fences follow CommonMark: a run of three or more backticks or tildes opens a
fenced block, and only a run of the SAME character, at least as long, with
nothing but spaces after it, closes it. So a ```` fence may quote ```, and a
~~~ block may quote a ``` line. A backtick fence's info string may not hold a
backtick (that line is not a fence). A block left open runs to the end of the
document. Container blocks are not modelled: a fence is recognised at any
indentation, because a fence inside a list item is indented.

`buildtools.doc_links` (tools/build/inspect) reads code through this module,
so the link check and the README examples agree on what is code.
"""

from .text import byte_at, indent_of, is_space, strip, substr, suffix


@fieldwise_init
struct Fence(Copyable, Movable):
    """One fenced code block. Line numbers are 0-based indexes into the
    document's lines."""

    var open_line: Int
    # The closing fence's line, or -1 when the document ends first.
    var close_line: Int
    # Whitespace bytes before the opening fence.
    var indent: Int
    # 96 for backticks, 126 for tildes.
    var char: Int
    var length: Int
    # The info string, without surrounding whitespace.
    var info: String


def _fence_run(line: String, start: Int) -> Int:
    """The length of the run of `line[start]` from `start`."""
    var n = line.byte_length()
    var c = byte_at(line, start)
    var k = start
    while k < n and byte_at(line, k) == c:
        k += 1
    return k - start


def opening_fence(line: String, mut fence: Fence) -> Bool:
    """Whether `line` opens a fenced block; fills indent, char, length and
    info of `fence`."""
    var i = indent_of(line)
    var n = line.byte_length()
    if i >= n:
        return False
    var c = byte_at(line, i)
    if c != 96 and c != 126:
        return False
    var run = _fence_run(line, i)
    if run < 3:
        return False
    var info = strip(suffix(line, i + run))
    if c == 96 and info.find("`") >= 0:
        return False
    fence.indent = i
    fence.char = c
    fence.length = run
    fence.info = info
    return True


def closes(line: String, fence: Fence) -> Bool:
    """Whether `line` closes `fence`."""
    var i = indent_of(line)
    var n = line.byte_length()
    if i >= n or byte_at(line, i) != fence.char:
        return False
    var run = _fence_run(line, i)
    if run < fence.length:
        return False
    for k in range(i + run, n):
        if not is_space(byte_at(line, k)):
            return False
    return True


def fences(lines: List[String]) -> List[Fence]:
    """Every fenced block, in document order."""
    var out = List[Fence]()
    var i = 0
    var n = len(lines)
    while i < n:
        var f = Fence(i, -1, 0, 0, 0, String(""))
        if not opening_fence(lines[i], f):
            i += 1
            continue
        var j = i + 1
        while j < n and not closes(lines[j], f):
            j += 1
        if j < n:
            f.close_line = j
        out.append(f^)
        i = j + 1
    return out^


def code_mask(lines: List[String]) -> List[Bool]:
    """For each line: True when it is a fence line or inside a fenced block."""
    var mask = List[Bool](length=len(lines), fill=False)
    var fs = fences(lines)
    for k in range(len(fs)):
        var last = fs[k].close_line if fs[k].close_line >= 0 else len(lines) - 1
        for i in range(fs[k].open_line, last + 1):
            mask[i] = True
    return mask^


# ---- links ------------------------------------------------------------------


def mask_code_spans(line: String) -> String:
    """Inline code spans become two backticks."""
    var out = String()
    var n = line.byte_length()
    var i = 0
    var start = 0
    while i < n:
        if byte_at(line, i) == 96:
            var j = i + 1
            while j < n and byte_at(line, j) != 96:
                j += 1
            if j < n:
                out += substr(line, start, i) + "``"
                i = j + 1
                start = i
                continue
            break
        i += 1
    out += suffix(line, start)
    return out^


def _inline_at(line: String, p: Int, mut target: String) -> Int:
    """Matches `!?[text](<?target>? "title"?)` at p; returns the end or -1."""
    var n = line.byte_length()
    var i = p
    if i < n and byte_at(line, i) == 33:
        var r = _inline_at(line, p + 1, target)
        if r >= 0:
            return r
        return -1
    if i >= n or byte_at(line, i) != 91:
        return -1
    i += 1
    while i < n:
        var c = byte_at(line, i)
        if c == 93:
            break
        if c == 91:
            var j = i + 1
            while j < n and byte_at(line, j) != 93:
                j += 1
            if j >= n:
                return -1
            i = j + 1
            continue
        i += 1
    if i >= n or byte_at(line, i) != 93:
        return -1
    i += 1
    if i >= n or byte_at(line, i) != 40:
        return -1
    i += 1
    while i < n and is_space(byte_at(line, i)):
        i += 1
    if i < n and byte_at(line, i) == 60:
        var alt = String()
        var r = _inline_rest(line, i + 1, alt)
        if r >= 0:
            target = alt
            return r
    return _inline_rest(line, i, target)


def _inline_rest(line: String, p: Int, mut target: String) -> Int:
    var n = line.byte_length()
    var i = p
    var start = i
    while i < n:
        var c = byte_at(line, i)
        if c == 41 or c == 62 or is_space(c):
            break
        i += 1
    if i == start:
        return -1
    var t = substr(line, start, i)
    if i < n and byte_at(line, i) == 62:
        i += 1
    # An optional title: whitespace, then "...".
    var j = i
    while j < n and is_space(byte_at(line, j)):
        j += 1
    if j > i and j < n and byte_at(line, j) == 34:
        var k = j + 1
        while k < n and byte_at(line, k) != 34:
            k += 1
        if k < n:
            var m = k + 1
            while m < n and is_space(byte_at(line, m)):
                m += 1
            if m < n and byte_at(line, m) == 41:
                target = t
                return m + 1
    while i < n and is_space(byte_at(line, i)):
        i += 1
    if i < n and byte_at(line, i) == 41:
        target = t
        return i + 1
    return -1


def inline_targets(line: String) -> List[String]:
    """The target of every inline link and image on `line`."""
    var out = List[String]()
    var n = line.byte_length()
    var p = 0
    while p < n:
        var t = String()
        var r = _inline_at(line, p, t)
        if r >= 0:
            out.append(t)
            p = r
        else:
            p += 1
    return out^


def refdef_target(line: String, mut target: String) -> Bool:
    """`[id]: target` at the start of a line (up to three spaces before)."""
    var n = line.byte_length()
    var i = 0
    while i < 3 and i < n and is_space(byte_at(line, i)):
        i += 1
    if i >= n or byte_at(line, i) != 91:
        return False
    var j = i + 1
    while j < n and byte_at(line, j) != 93:
        j += 1
    if j >= n or j == i + 1 or j + 1 >= n or byte_at(line, j + 1) != 58:
        return False
    var k = j + 2
    while k < n and is_space(byte_at(line, k)):
        k += 1
    var start = k
    while k < n and not is_space(byte_at(line, k)):
        k += 1
    if k == start:
        return False
    var t = substr(line, start, k)
    if t.startswith("<") and t.byte_length() > 1:
        t = suffix(t, 1)
    if t.endswith(">") and t.byte_length() > 1:
        t = substr(t, 0, t.byte_length() - 1)
    target = t
    return True


def is_external(t: String) -> Bool:
    """A URL with a scheme, or a scheme-relative `//host` one."""
    if t.startswith("//"):
        return True
    var n = t.byte_length()
    if n == 0:
        return False
    var c = byte_at(t, 0)
    if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122)):
        return False
    for i in range(1, n):
        var d = byte_at(t, i)
        if d == 58:
            return True
        if not (
            (d >= 65 and d <= 90)
            or (d >= 97 and d <= 122)
            or (d >= 48 and d <= 57)
            or d == 43
            or d == 46
            or d == 45
        ):
            return False
    return False


@fieldwise_init
struct Link(Copyable, Movable):
    # 0-based index of the line holding the link.
    var line: Int
    var target: String


def _html_comment_mask(lines: List[String], code: List[Bool]) -> List[Bool]:
    """For each line: True when it is in an HTML block that opens with
    `<!--` (CommonMark type 2), from that line to the first holding `-->`.
    Such a block is raw HTML, never Markdown: it holds no link."""
    var mask = List[Bool](length=len(lines), fill=False)
    var i = 0
    while i < len(lines):
        if code[i] or not strip(lines[i]).startswith("<!--"):
            i += 1
            continue
        var j = i
        while j < len(lines) and suffix(lines[j], 0 if j > i else lines[j].find("<!--") + 4).find("-->") < 0:
            mask[j] = True
            j += 1
        if j < len(lines):
            mask[j] = True
        i = j + 1
    return mask^


def relative_links(lines: List[String]) -> List[Link]:
    """Every link outside code (fenced blocks and code spans) and outside an
    HTML comment block (a README's mojo-hidden lines) whose target has no
    scheme: a path, a path with a `#fragment`, or a bare `#fragment`."""
    var out = List[Link]()
    var mask = code_mask(lines)
    var comments = _html_comment_mask(lines, mask)
    for li in range(len(lines)):
        if mask[li] or comments[li]:
            continue
        var line = mask_code_spans(lines[li])
        var targets = inline_targets(line)
        var rd = String()
        if refdef_target(line, rd):
            targets.append(rd)
        for ti in range(len(targets)):
            if not is_external(targets[ti]):
                out.append(Link(li, targets[ti]))
    return out^
