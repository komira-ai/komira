# =============================================================================
# src/kci_ci_check/workflow_reader.mojo -- a FAIL-CLOSED reader of a STRICT
#   SUBSET of YAML, into a tree of maps, lists and scalars.
# =============================================================================
#
# This is not a YAML parser. It accepts a subset of YAML small enough that
# every value it reads is exactly the value YAML (and so GitHub) reads, and
# says CANNOT TELL (raises, the message prefixed `cannot tell: line N:`) for
# every line outside it. A construct outside the subset is never read, never
# guessed at, and never a pass. docs/ci.md, "The workflow subset kci reads",
# states the same subset for a workflow's author.
#
# THE SUBSET (anything not listed is refused):
#
#   lines     printable ASCII and LF only; a full-line comment may also hold
#             other UTF-8, except a YAML 1.1 line break (U+0085, U+2028,
#             U+2029) and a byte order mark. No TAB anywhere, no CR, no other
#             control character.
#   comments  a line whose first non-space character is `#`; after a value,
#             ` #` (a space, then `#`) to the line's end.
#   mappings  block mappings by indentation: `key: value` or `key:`. A key is
#             plain, of the characters [A-Za-z0-9_.-], followed by `:` and a
#             space or the line's end. Keys of one mapping differ ignoring
#             case. A key the rules read (`_RULE_KEYS`) is written in lower
#             case.
#   lists     block lists by indentation: `- value`, `- key: value` (a list
#             item that is a mapping, its further keys at the column after
#             `- `), or `-` with the item on the lines below; exactly one
#             space after the dash. A list may sit at its key's indentation.
#   scalars   on ONE line: plain (not starting with an indicator, holding no
#             `: ` and not ending in `:`); single-quoted with no `'` inside
#             (so no `''`); double-quoted with no `"` and no backslash inside.
#             Nothing but a comment after a quoted scalar's close. A value
#             never continues on the next line.
#   flow      `[]`, `[a, b]` of plain items of [A-Za-z0-9_./-] only, and `{}`.
#   block     a literal block scalar `|` (clip chomping, no indentation
#             indicator), only as the value of a `run:` key, read exactly:
#             its lines dedented by the first line's indentation, a final
#             newline, trailing blank lines dropped. No line of spaces only.
#
# REFUSED, among others: folded `>` and every chomping or indentation
# indicator; a block scalar under any key but `run`; a scalar over two
# lines; `''` and any escape; anchors, aliases and tags; merge keys `<<`;
# complex keys `?`; quoted keys; flow mappings other than `{}`; a quoted or
# nested flow item; a repeated key (ignoring case); a rule key in another
# case; document markers `---` / `...`; directives `%`.
#
# The rules read only values this subset represents exactly, so a rule never
# sees a value GitHub reads differently. `actionlint` (the repository's
# workflow lint) stays the YAML-validity gate.
#
# The tree is an arena: `WorkflowDoc.nodes`, children by index, so no struct
# holds itself.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

comptime NODE_MAP: Int = 0
comptime NODE_LIST: Int = 1
comptime NODE_SCALAR: Int = 2

comptime CANNOT_TELL: String = "cannot tell: "
"""Every refusal of this reader starts so: the caller maps it onto the
INDETERMINATE outcome, never onto a pass or a plain refusal."""


struct WorkflowNode(Copyable, Movable):
    """One node. A MAP has `keys` and `children` (same length); a LIST has
    `children`; a SCALAR has `text`, and `plain` says it was written as a
    plain scalar (not quoted, not a block scalar), and `block` that it was
    written as a block scalar (`|`).

    Layout: owned values only (children are indices into the arena). No
    pointer field."""

    var kind: Int
    var text: String
    var line: Int
    var plain: Bool
    var block: Bool
    var keys: List[String]
    var children: List[Int]

    def __init__(out self, kind: Int, var text: String, line: Int, plain: Bool = True, block: Bool = False):
        self.kind = kind
        self.text = text^
        self.line = line
        self.plain = plain
        self.block = block
        self.keys = List[String]()
        self.children = List[Int]()


struct WorkflowDoc(Copyable, Movable):
    """The arena; node 0 is the root mapping.

    Layout: owned values only. No pointer field."""

    var nodes: List[WorkflowNode]

    def __init__(out self):
        self.nodes = List[WorkflowNode]()

    def add(mut self, var n: WorkflowNode) -> Int:
        self.nodes.append(n^)
        return len(self.nodes) - 1

    def kind(self, i: Int) -> Int:
        return self.nodes[i].kind

    def text(self, i: Int) -> String:
        return self.nodes[i].text.copy()

    def line(self, i: Int) -> Int:
        return self.nodes[i].line

    def is_plain(self, i: Int, text: String) -> Bool:
        """Node `i` is a scalar written plain whose text is exactly `text`.
        A quoted scalar or a block scalar is never plain."""
        return i >= 0 and self.nodes[i].kind == NODE_SCALAR and self.nodes[i].plain and self.nodes[i].text == text

    def is_block(self, i: Int) -> Bool:
        """Node `i` is a scalar written as a block scalar (`|`)."""
        return i >= 0 and self.nodes[i].kind == NODE_SCALAR and self.nodes[i].block

    def child(self, i: Int, key: String) -> Int:
        """The child of mapping `i` under `key`, or -1 (also -1 when `i` is
        -1 or not a mapping)."""
        if i < 0 or self.nodes[i].kind != NODE_MAP:
            return -1
        for k in range(len(self.nodes[i].keys)):
            if self.nodes[i].keys[k] == key:
                return self.nodes[i].children[k]
        return -1

    def keys(self, i: Int) -> List[String]:
        if i < 0 or self.nodes[i].kind != NODE_MAP:
            return List[String]()
        return self.nodes[i].keys.copy()

    def items(self, i: Int) -> List[Int]:
        """The children of a mapping or a list, in order."""
        if i < 0 or self.nodes[i].kind == NODE_SCALAR:
            return List[Int]()
        return self.nodes[i].children.copy()

    def scalar_or_list(self, i: Int) -> List[String]:
        """A scalar as a one-element list (an empty scalar as none), a list
        of scalars as its texts; anything else as none."""
        var out = List[String]()
        if i < 0:
            return out^
        if self.nodes[i].kind == NODE_SCALAR:
            if self.nodes[i].text.byte_length() > 0:
                out.append(self.nodes[i].text.copy())
            return out^
        if self.nodes[i].kind == NODE_LIST:
            for k in range(len(self.nodes[i].children)):
                var c = self.nodes[i].children[k]
                if self.nodes[c].kind == NODE_SCALAR:
                    out.append(self.nodes[c].text.copy())
        return out^


# ---- lines -------------------------------------------------------------------


struct _Line(Copyable, Movable):
    """One content line: its number, indentation and text after it.

    Layout: owned values only. No pointer field."""

    var number: Int
    var indent: Int
    var text: String

    def __init__(out self, number: Int, indent: Int, var text: String):
        self.number = number
        self.indent = indent
        self.text = text^


def _cannot(line: Int, why: String) -> Error:
    return Error(String(CANNOT_TELL) + String("line ") + String(line) + String(": ") + why)


def _check_bytes(raw: String, number: Int, comment: Bool) raises:
    """Every byte of line `raw` is in the subset: printable ASCII; in a
    full-line comment (`comment`) also other UTF-8, but never a YAML 1.1
    line break (U+0085, U+2028, U+2029) or a byte order mark (U+FEFF)."""
    var b = raw.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c == 9:
            raise _cannot(number, String("a TAB"))
        if c == 13:
            raise _cannot(number, String("a carriage return"))
        if c < 32 or c == 127:
            raise _cannot(number, String("a control character"))
        if c < 128:
            continue
        if not comment:
            raise _cannot(number, String("a character outside printable ASCII"))
        var next1 = Int(b[i + 1]) if i + 1 < len(b) else -1
        var next2 = Int(b[i + 2]) if i + 2 < len(b) else -1
        if (
            (c == 0xC2 and next1 == 0x85)
            or (c == 0xE2 and next1 == 0x80 and (next2 == 0xA8 or next2 == 0xA9))
            or (c == 0xEF and next1 == 0xBB and next2 == 0xBF)
        ):
            raise _cannot(number, String("a YAML 1.1 line break (U+0085, U+2028, U+2029) or a byte order mark"))


def _leading_spaces(raw: String) -> Int:
    var b = raw.as_bytes()
    var n = 0
    while n < len(b) and Int(b[n]) == 32:
        n += 1
    return n


def _is_key_byte(c: Int) -> Bool:
    """[A-Za-z0-9_.-]"""
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 46 or c == 45


def _is_flow_item_byte(c: Int) -> Bool:
    """[A-Za-z0-9_./-]"""
    return _is_key_byte(c) or c == 47


def _rule_key(lower: String) -> Bool:
    """A key the rules read: written in another case it would hide what the
    rules look for, so it is refused there."""
    for k in [
        "on",
        "jobs",
        "permissions",
        "id-token",
        "if",
        "needs",
        "environment",
        "steps",
        "run",
        "uses",
        "with",
        "fetch-depth",
        "inputs",
        "push",
        "pull_request",
        "pull_request_target",
        "workflow_dispatch",
    ]:
        if lower == String(k):
            return True
    return False


# ---- scalars -----------------------------------------------------------------

comptime _V_EMPTY: Int = 0
comptime _V_SCALAR: Int = 1
comptime _V_LIST: Int = 2
comptime _V_MAP: Int = 3
comptime _V_BLOCK: Int = 4


struct _Value(Copyable, Movable):
    """A value as written after `key:` or `- `: its form, its text (a
    scalar's), whether it was plain, and a flow list's items.

    Layout: owned values only. No pointer field."""

    var form: Int
    var text: String
    var plain: Bool
    var items: List[String]

    def __init__(out self, form: Int, var text: String, plain: Bool):
        self.form = form
        self.text = text^
        self.plain = plain
        self.items = List[String]()


def _only_comment_after(v: String, j: Int, line: Int, what: String) raises:
    """From byte `j` of `v` to its end there are only spaces, then
    optionally a comment (` #...`); else cannot tell: `what`."""
    var b = v.as_bytes()
    var k = j
    while k < len(b) and Int(b[k]) == 32:
        k += 1
    if k == len(b):
        return
    if Int(b[k]) == 35 and k > j:
        return
    raise _cannot(line, what)


def _quoted(v: String, line: Int) raises -> String:
    """A single- or double-quoted scalar on one line, with no escape."""
    var b = v.as_bytes()
    var q = Int(b[0])
    var j = 1
    while j < len(b) and Int(b[j]) != q:
        if q == 34 and Int(b[j]) == 92:
            raise _cannot(line, String("an escape (a backslash) in a double-quoted scalar"))
        j += 1
    if j >= len(b):
        raise _cannot(line, String("a quoted scalar not closed on its line"))
    if q == 39 and j + 1 < len(b) and Int(b[j + 1]) == 39:
        raise _cannot(line, String("an escaped quote ('') in a single-quoted scalar"))
    _only_comment_after(v, j + 1, line, String("text after a quoted scalar's close"))
    return String(v[byte = 1:j])


def _plain(v: String, line: Int) raises -> String:
    """A plain scalar: to a ` #` comment or the line's end, trailing spaces
    dropped; holding no `: ` and not ending in `:` (YAML reads either as a
    mapping)."""
    var b = v.as_bytes()
    var end = len(b)
    for i in range(1, len(b)):
        if Int(b[i]) == 35 and Int(b[i - 1]) == 32:
            end = i
            break
    while end > 0 and Int(b[end - 1]) == 32:
        end -= 1
    var s = String(v[byte=0:end])
    if s.find(String(": ")) >= 0 or s.endswith(String(":")):
        raise _cannot(line, String("a ': ' or a final ':' in a plain scalar ('") + s + String("')"))
    return s^


def _flow_list(v: String, line: Int) raises -> List[String]:
    """`[]` or `[a, b]` of plain items of [A-Za-z0-9_./-], on one line."""
    var close = v.find(String("]"))
    if close < 0:
        raise _cannot(line, String("a flow list not closed on its line"))
    _only_comment_after(v, close + 1, line, String("text after a flow list's close"))
    var inner = String(v[byte=1:close])
    var out = List[String]()
    if String(inner.strip()).byte_length() == 0:
        return out^
    var parts = inner.split(String(","))
    for i in range(len(parts)):
        var p = String(String(parts[i]).strip())
        var pb = p.as_bytes()
        if len(pb) == 0:
            raise _cannot(line, String("an empty item in a flow list"))
        for k in range(len(pb)):
            if not _is_flow_item_byte(Int(pb[k])):
                raise _cannot(
                    line,
                    String("a flow list item other than plain [A-Za-z0-9_./-] ('") + p + String("')"),
                )
        out.append(p^)
    return out^


def _value_of(v: String, line: Int) raises -> _Value:
    """The value written as `v` (after `key:` or `- `, leading spaces
    dropped)."""
    var b = v.as_bytes()
    if len(b) == 0 or Int(b[0]) == 35:  # nothing, or a comment
        return _Value(_V_EMPTY, String(""), True)
    var c = Int(b[0])
    var c1 = Int(b[1]) if len(b) > 1 else 32
    if c == 39 or c == 34:  # ' "
        return _Value(_V_SCALAR, _quoted(v, line), False)
    if c == 91:  # [
        var out = _Value(_V_LIST, String(""), True)
        out.items = _flow_list(v, line)
        return out^
    if c == 123:  # {
        if v.startswith(String("{}")):
            _only_comment_after(v, 2, line, String("a flow mapping other than {}"))
            return _Value(_V_MAP, String(""), True)
        raise _cannot(line, String("a flow mapping other than {}"))
    if c == 124 or c == 62:  # | >
        var header = String(String(_plain_head(v)).strip())
        if header != String("|"):
            raise _cannot(line, String("a block scalar other than a literal `|` (header '") + header + String("')"))
        return _Value(_V_BLOCK, String(""), False)
    if c == 38 or c == 42 or c == 33:  # & * !
        raise _cannot(line, String("an anchor, alias or tag ('") + v + String("')"))
    if c == 37 or c == 64 or c == 96:  # % @ `
        raise _cannot(line, String("a reserved indicator where a value starts ('") + v + String("')"))
    if c == 44 or c == 93 or c == 125:  # , ] }
        raise _cannot(line, String("a flow indicator where a value starts ('") + v + String("')"))
    if (c == 45 or c == 63 or c == 58) and c1 == 32:  # `- ` `? ` `: `
        raise _cannot(line, String("an indicator where a value starts ('") + v + String("')"))
    return _Value(_V_SCALAR, _plain(v, line), True)


def _plain_head(v: String) -> String:
    """`v` up to a ` #` comment."""
    var b = v.as_bytes()
    for i in range(1, len(b)):
        if Int(b[i]) == 35 and Int(b[i - 1]) == 32:
            return String(v[byte=0:i])
    return v.copy()


def _split_key(text: String, line: Int) raises -> Tuple[String, String, Bool]:
    """`key: rest` as (key, rest, True), the key plain [A-Za-z0-9_.-] and
    `rest` with its leading spaces dropped; a text that does not start so as
    ("", text, False). A quoted key, a complex key `?` and a merge key `<<`
    are cannot tell."""
    var b = text.as_bytes()
    if len(b) == 0:
        return (String(""), text.copy(), False)
    var c = Int(b[0])
    if c == 63:  # ?
        raise _cannot(line, String("a complex key ('? ')"))
    if text.startswith(String("<<")):
        raise _cannot(line, String("a merge key '<<'"))
    var i = 0
    while i < len(b) and _is_key_byte(Int(b[i])):
        i += 1
    if i > 0 and i < len(b) and Int(b[i]) == 58 and (i + 1 == len(b) or Int(b[i + 1]) == 32):
        var key = String(text[byte=0:i])
        var r = i + 1
        while r < len(b) and Int(b[r]) == 32:
            r += 1
        return (key^, String(text[byte=r:]), True)
    if c == 39 or c == 34:
        # a quoted key (`'k': v`, `"k": v`): YAML decodes escapes in it
        var j = 1
        while j < len(b) and Int(b[j]) != c:
            j += 1
        if j + 1 < len(b) and Int(b[j + 1]) == 58 and (j + 2 == len(b) or Int(b[j + 2]) == 32):
            raise _cannot(line, String("a quoted key"))
    return (String(""), text.copy(), False)


# ---- the reader --------------------------------------------------------------


struct _Reader(Movable):
    """The lines and the arena being built. Layout: owned values only. No
    pointer field."""

    var lines: List[_Line]
    var raw: List[String]
    var pos: Int
    var doc: WorkflowDoc

    def __init__(out self, var lines: List[_Line], var raw: List[String]):
        self.lines = lines^
        self.raw = raw^
        self.pos = 0
        self.doc = WorkflowDoc()

    def _literal(mut self, key_indent: Int, line: Int) raises -> String:
        """The literal block scalar whose `|` header is on line `line` (its
        key at column `key_indent`), read exactly: the lines after it more
        indented than the key, dedented by the first one's indentation,
        joined by newlines, with one final newline (clip) and no trailing
        blank lines. `pos` moves past them."""
        var texts = List[String]()
        var content = -1
        var last = line
        var k = line  # 0-based index of the line after the header
        while k < len(self.raw):
            var r = self.raw[k]
            var number = k + 1
            if r.byte_length() == 0:
                texts.append(String(""))
                k += 1
                continue
            var n = _leading_spaces(r)
            if n == r.byte_length():
                raise _cannot(number, String("a line of spaces only in or after a block scalar"))
            if content < 0:
                if n <= key_indent:
                    break
                content = n
            elif n < content:
                if n > key_indent:
                    raise _cannot(number, String("a line in a block scalar indented less than its first line"))
                break
            _check_bytes(r, number, False)
            texts.append(String(r[byte=content:]))
            last = number
            k += 1
        if content < 0:
            raise _cannot(line, String("an empty block scalar"))
        var keep = len(texts)
        while keep > 0 and texts[keep - 1].byte_length() == 0:
            keep -= 1
        var out = String("")
        for j in range(keep):
            out += texts[j]
            out += String("\n")
        while self.pos < len(self.lines) and self.lines[self.pos].number <= last:
            self.pos += 1
        return out^

    def _no_continuation(self, key_indent: Int, line: Int) raises:
        """A one-line value: the next content line is not more indented
        than its key (YAML would read it as the value continued)."""
        if self.pos < len(self.lines) and self.lines[self.pos].indent > key_indent:
            raise _cannot(
                self.lines[self.pos].number,
                String("a line that continues the value on line ") + String(line)
                + String(" (a value is on one line) or is indented in a way no open block holds"),
            )

    def _value(mut self, rest: String, key: String, key_indent: Int, line: Int) raises -> Int:
        """The node for a value written after `key:` (or after `- `, `key`
        empty), the key at column `key_indent`."""
        var v = _value_of(rest, line)
        if v.form == _V_EMPTY:
            # a nested block, or an empty value
            if self.pos < len(self.lines) and self.lines[self.pos].indent > key_indent:
                return self._block(self.lines[self.pos].indent)
            if (
                self.pos < len(self.lines)
                and self.lines[self.pos].indent == key_indent
                and (self.lines[self.pos].text.startswith(String("- ")) or self.lines[self.pos].text == String("-"))
                and key.byte_length() > 0
            ):
                # a list at the same indentation as its key
                return self._list(key_indent)
            return self.doc.add(WorkflowNode(NODE_SCALAR, String(""), line))
        if v.form == _V_BLOCK:
            if key != String("run"):
                raise _cannot(line, String("a block scalar; only a `run:` value may be a literal block scalar `|`"))
            return self.doc.add(WorkflowNode(NODE_SCALAR, self._literal(key_indent, line), line, False, True))
        self._no_continuation(key_indent, line)
        if v.form == _V_LIST:
            var idx = self.doc.add(WorkflowNode(NODE_LIST, String(""), line))
            for i in range(len(v.items)):
                var s = self.doc.add(WorkflowNode(NODE_SCALAR, v.items[i].copy(), line))
                self.doc.nodes[idx].children.append(s)
            return idx
        if v.form == _V_MAP:
            return self.doc.add(WorkflowNode(NODE_MAP, String(""), line))
        return self.doc.add(WorkflowNode(NODE_SCALAR, v.text.copy(), line, v.plain))

    def _list(mut self, indent: Int) raises -> Int:
        var idx = self.doc.add(WorkflowNode(NODE_LIST, String(""), self.lines[self.pos].number))
        while self.pos < len(self.lines):
            ref l = self.lines[self.pos]
            if l.indent < indent:
                break
            if l.indent > indent:
                raise _cannot(l.number, String("a line indented in a way no open block holds"))
            if not (l.text.startswith(String("- ")) or l.text == String("-")):
                break
            var number = l.number
            var after_dash = String(l.text[byte=2:]) if l.text.byte_length() > 1 else String("")
            var item = String(after_dash.strip())
            if after_dash.startswith(String(" ")) and item.byte_length() > 0:
                raise _cannot(number, String("a list item that does not start one space after '-'"))
            var item_indent = indent + 2
            self.pos += 1
            var kv = _split_key(item, number)
            if kv[2]:
                # a mapping item: its first key on the dash line, the rest
                # indented to the item's content column
                var m = self.doc.add(WorkflowNode(NODE_MAP, String(""), number))
                var first = self._value(kv[1], kv[0], item_indent, number)
                self._put(m, kv[0], first, number)
                while self.pos < len(self.lines) and self.lines[self.pos].indent == item_indent:
                    self._map_entry(m, item_indent)
                self.doc.nodes[idx].children.append(m)
            else:
                var v = self._value(item, String(""), indent, number)
                self.doc.nodes[idx].children.append(v)
        return idx

    def _put(mut self, m: Int, key: String, child: Int, line: Int) raises:
        var lower = key.lower()
        if key != lower and _rule_key(lower):
            raise _cannot(line, String("key '") + key + String("' is the key '") + lower + String("' in another case"))
        for k in range(len(self.doc.nodes[m].keys)):
            if self.doc.nodes[m].keys[k].lower() == lower:
                raise _cannot(
                    line,
                    String("key '") + key + String("' repeated in one mapping (keys are compared ignoring case)"),
                )
        self.doc.nodes[m].keys.append(key.copy())
        self.doc.nodes[m].children.append(child)

    def _map_entry(mut self, m: Int, indent: Int) raises:
        ref l = self.lines[self.pos]
        var number = l.number
        if l.text.startswith(String("- ")) or l.text == String("-"):
            raise _cannot(number, String("a list item where a mapping key was expected"))
        var kv = _split_key(l.text, number)
        if not kv[2]:
            raise _cannot(number, String("a line that is not `key: value` with a plain [A-Za-z0-9_.-] key"))
        self.pos += 1
        var v = self._value(kv[1], kv[0], indent, number)
        self._put(m, kv[0], v, number)

    def _block(mut self, indent: Int) raises -> Int:
        """The block (a mapping or a list) whose lines sit at `indent`."""
        if self.lines[self.pos].text.startswith(String("- ")) or self.lines[self.pos].text == String("-"):
            return self._list(indent)
        var m = self.doc.add(WorkflowNode(NODE_MAP, String(""), self.lines[self.pos].number))
        while self.pos < len(self.lines):
            ref l = self.lines[self.pos]
            if l.indent < indent:
                break
            if l.indent > indent:
                raise _cannot(l.number, String("a line indented in a way no open block holds"))
            self._map_entry(m, indent)
        return m


def read_workflow(text: String) raises -> WorkflowDoc:
    """Read a workflow file (file header). Raises `cannot tell: line N: ...`
    for anything outside the subset."""
    var raw = List[String]()
    var parts = text.split(String("\n"))
    for i in range(len(parts)):
        raw.append(String(parts[i]))
    var lines = List[_Line]()
    for i in range(len(raw)):
        var number = i + 1
        var r = raw[i]
        var indent = _leading_spaces(r)
        var body = String(r[byte=indent:])
        var comment = body.startswith(String("#"))
        _check_bytes(r, number, comment)
        if body.byte_length() == 0 or comment:
            continue
        if indent == 0 and body.startswith(String("%")):
            raise _cannot(number, String("a directive ('%')"))
        var bb = body.as_bytes()
        if body.startswith(String("---")) or body.startswith(String("...")):
            if len(bb) == 3 or Int(bb[3]) == 32:
                raise _cannot(number, String("a document marker ('---' or '...')"))
        var end = len(bb)
        while end > 0 and Int(bb[end - 1]) == 32:
            end -= 1
        lines.append(_Line(number, indent, String(body[byte=0:end])))
    var rd = _Reader(lines^, raw^)
    if len(rd.lines) == 0:
        raise Error(String(CANNOT_TELL) + String("the workflow file is empty"))
    if rd.lines[0].indent != 0:
        raise _cannot(rd.lines[0].number, String("the first line is indented"))
    var root = rd._block(0)
    if rd.pos < len(rd.lines):
        raise _cannot(rd.lines[rd.pos].number, String("a line outside the top-level mapping"))
    if rd.doc.nodes[root].kind != NODE_MAP:
        raise _cannot(1, String("the top level is not a mapping"))
    # node 0 is the root: the arena adds the root first
    return rd.doc.copy()
