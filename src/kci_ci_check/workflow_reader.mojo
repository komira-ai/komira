# =============================================================================
# src/kci_ci_check/workflow_reader.mojo -- a RESTRICTED reader of the YAML
#   subset a CI workflow file uses, into a tree of maps, lists and scalars.
# =============================================================================
#
# This is not a YAML parser. It reads exactly what kci needs to hold a
# workflow to a machine file, and says CANNOT TELL (raises
# `WorkflowUnreadable`'s message, prefixed `cannot tell:`) for anything else,
# so a construct it does not understand is never read as a pass:
#
#   read      block mappings `key: value` / `key:`; block lists `- value` and
#             `- key: value` (a list item that is a mapping); plain, single-
#             and double-quoted scalars; `# comments`; block scalars `|` and
#             `>` (with `-`/`+`), kept as their raw lines; the flow forms `[]`,
#             `[a, b]` (plain or quoted scalars only) and `{}`
#   refused   (cannot tell) a TAB in indentation; an anchor `&x`, an alias
#             `*x` or a tag `!x` where a value starts; a flow mapping other
#             than `{}`; a nested flow list; a second document (`---` after
#             content, or `...`); a key repeated in one mapping; a complex
#             key `? `; a merge key `<<` (in any form); an escape (`\`) in a
#             double-quoted key or value; a line indented in a way no open
#             block can hold; a quoted scalar that is not closed on its line
#
# `actionlint` (the repository's workflow lint) stays the YAML-validity
# gate; this reader only has to be right on what it accepts.
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
    written as a block scalar (`|` or `>`, with or without a chomping
    indicator).

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
        """Node `i` is a scalar written as a block scalar (`|` or `>`)."""
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


def _strip_comment(s: String) -> String:
    """`s` without a trailing ` #...` comment that is outside quotes, and
    without trailing spaces."""
    var b = s.as_bytes()
    var in_single = False
    var in_double = False
    var escaped = False
    var end = len(b)
    for i in range(len(b)):
        var c = Int(b[i])
        if in_single:
            if c == 39:
                in_single = False
            continue
        if in_double:
            if escaped:
                escaped = False
            elif c == 92:  # a backslash escapes the next byte
                escaped = True
            elif c == 34:
                in_double = False
            continue
        if c == 39:
            in_single = True
        elif c == 34:
            in_double = True
        elif c == 35 and (i == 0 or Int(b[i - 1]) == 32):
            end = i
            break
    while end > 0 and Int(b[end - 1]) == 32:
        end -= 1
    return String(s[byte = 0:end])


def _indent_of(raw: String, number: Int) raises -> Int:
    var b = raw.as_bytes()
    var n = 0
    while n < len(b):
        var c = Int(b[n])
        if c == 9:
            raise _cannot(number, String("a TAB in indentation"))
        if c != 32:
            break
        n += 1
    return n


# ---- scalars -----------------------------------------------------------------


def _unquote(v: String, line: Int) raises -> String:
    """A plain, single- or double-quoted scalar's value."""
    if v.byte_length() == 0:
        return String("")
    var b = v.as_bytes()
    var first = Int(b[0])
    if first == 38 or first == 42 or first == 33:  # & * !
        raise _cannot(line, String("an anchor, alias or tag ('") + v + String("')"))
    if first == 39 or first == 34:
        if len(b) < 2 or Int(b[len(b) - 1]) != first:
            raise _cannot(line, String("a quoted scalar not closed on its line"))
        var inner = String(v[byte = 1 : len(b) - 1])
        if first == 39:
            return inner.replace(String("''"), String("'"))
        if inner.find(String("\\")) >= 0:
            raise _cannot(line, String("an escape in a double-quoted scalar"))
        return inner^
    if first == 123:  # {
        if v == String("{}"):
            return String("{}")
        raise _cannot(line, String("a flow mapping other than {}"))
    return v.copy()


def _quoted(v: String) -> Bool:
    """`v` (a value as written) is a single- or double-quoted scalar."""
    var b = v.as_bytes()
    return len(b) > 0 and (Int(b[0]) == 39 or Int(b[0]) == 34)


def _flow_list(v: String, line: Int) raises -> List[Tuple[String, Bool]]:
    """`[a, b]` as its scalars, each with whether it was written plain."""
    var inner = String(v[byte = 1 : v.byte_length() - 1])
    var out = List[Tuple[String, Bool]]()
    if inner.strip().byte_length() == 0:
        return out^
    if inner.find(String("[")) >= 0 or inner.find(String("{")) >= 0:
        raise _cannot(line, String("a nested flow collection"))
    var parts = inner.split(String(","))
    for i in range(len(parts)):
        var p = String(String(parts[i]).strip())
        if p.byte_length() == 0:
            raise _cannot(line, String("an empty item in a flow list"))
        out.append((_unquote(p, line), not _quoted(p)))
    return out^


def _split_key(text: String, line: Int) raises -> Tuple[String, String, Bool]:
    """`key: rest` as (key, rest, True); a text with no mapping colon as
    ("", text, False). The colon must be followed by a space or end the
    text, and sit outside quotes and outside `${{ }}`."""
    var b = text.as_bytes()
    if len(b) > 0 and Int(b[0]) == 63:  # ?
        raise _cannot(line, String("a complex key ('? ')"))
    if len(b) > 0 and (Int(b[0]) == 39 or Int(b[0]) == 34):
        # a quoted key: find its close, then expect ':'
        var q = Int(b[0])
        var j = 1
        while j < len(b) and Int(b[j]) != q:
            j += 1
        if j + 1 < len(b) and Int(b[j + 1]) == 58 and (j + 2 == len(b) or Int(b[j + 2]) == 32):
            var key = String(text[byte = 1:j])
            if q == 34 and key.find(String("\\")) >= 0:
                # YAML decodes escapes in a double-quoted key as in a value:
                # `"id\x2dtoken"` is `id-token`
                raise _cannot(line, String("an escape in a double-quoted key"))
            var rest = String(String(text[byte = j + 2 :]).strip())
            return (key^, rest^, True)
        return (String(""), text.copy(), False)
    var depth = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c == 123:
            depth += 1
        elif c == 125:
            depth -= 1
        elif c == 58 and depth == 0 and (i + 1 == len(b) or Int(b[i + 1]) == 32):
            var key = String(String(text[byte = 0:i]).strip())
            var rest = String(String(text[byte = i + 1 :]).strip())
            return (key^, rest^, True)
        elif c == 32 and depth == 0 and i + 1 < len(b) and Int(b[i + 1]) == 35:
            break
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

    def _block_scalar(mut self, parent_indent: Int, line: Int) -> String:
        """The raw lines more indented than `parent_indent`, joined by
        newlines (blank lines inside kept); `pos` moves past them."""
        var out = String("")
        var start_raw = line  # 1-based number of the key line
        var last = start_raw
        var k = start_raw  # raw index of the first candidate line (0-based = number)
        while k < len(self.raw):
            var r = self.raw[k]
            var stripped = String(r.strip())
            if stripped.byte_length() == 0:
                k += 1
                continue
            var b = r.as_bytes()
            var n = 0
            while n < len(b) and Int(b[n]) == 32:
                n += 1
            if n <= parent_indent:
                break
            last = k + 1
            k += 1
        for j in range(start_raw, last):
            if j > start_raw:
                out += String("\n")
            out += self.raw[j]
        while self.pos < len(self.lines) and self.lines[self.pos].number <= last:
            self.pos += 1
        return out^

    def _value(mut self, rest: String, key_indent: Int, line: Int) raises -> Int:
        """The node for a value written after `key:` (or after `- `)."""
        if rest.byte_length() == 0:
            # a nested block, or an empty value
            if self.pos < len(self.lines) and self.lines[self.pos].indent > key_indent:
                return self._block(self.lines[self.pos].indent)
            if (
                self.pos < len(self.lines)
                and self.lines[self.pos].indent == key_indent
                and self.lines[self.pos].text.startswith(String("- "))
            ):
                # a list at the same indentation as its key
                return self._list(key_indent)
            return self.doc.add(WorkflowNode(NODE_SCALAR, String(""), line))
        var b = rest.as_bytes()
        var c = Int(b[0])
        if c == 124 or c == 62:  # | >
            var ind = String(rest[byte = 1:])
            if ind != String("") and ind != String("-") and ind != String("+"):
                raise _cannot(line, String("a block scalar header '") + rest + String("'"))
            return self.doc.add(WorkflowNode(NODE_SCALAR, self._block_scalar(key_indent, line), line, False, True))
        if c == 91:  # [
            if Int(b[len(b) - 1]) != 93:
                raise _cannot(line, String("a flow list not closed on its line"))
            var items = _flow_list(rest, line)
            var node = WorkflowNode(NODE_LIST, String(""), line)
            var idx = self.doc.add(node^)
            for i in range(len(items)):
                var s = self.doc.add(WorkflowNode(NODE_SCALAR, items[i][0].copy(), line, items[i][1]))
                self.doc.nodes[idx].children.append(s)
            return idx
        var v = _unquote(rest, line)
        if v == String("{}"):
            return self.doc.add(WorkflowNode(NODE_MAP, String(""), line))
        return self.doc.add(WorkflowNode(NODE_SCALAR, v^, line, not _quoted(rest)))

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
            var item = String(String(l.text[byte = 1:]).strip())
            var item_indent = indent + 2
            self.pos += 1
            var kv = _split_key(item, number)
            if kv[2]:
                # a mapping item: its first key on the dash line, the rest
                # indented to the item's content column
                var m = self.doc.add(WorkflowNode(NODE_MAP, String(""), number))
                var first = self._value(kv[1], item_indent, number)
                self._put(m, kv[0], first, number)
                while self.pos < len(self.lines) and self.lines[self.pos].indent == item_indent:
                    self._map_entry(m, item_indent)
                self.doc.nodes[idx].children.append(m)
            else:
                var v = self._value(item, indent, number)
                self.doc.nodes[idx].children.append(v)
        return idx

    def _put(mut self, m: Int, key: String, child: Int, line: Int) raises:
        if key == String("<<"):
            # a merge key folds another mapping's keys into this one; read
            # as an ordinary key, the merged keys would never be seen
            raise _cannot(line, String("a merge key '<<'"))
        for k in range(len(self.doc.nodes[m].keys)):
            if self.doc.nodes[m].keys[k] == key:
                raise _cannot(line, String("key '") + key + String("' repeated in one mapping"))
        self.doc.nodes[m].keys.append(key.copy())
        self.doc.nodes[m].children.append(child)

    def _map_entry(mut self, m: Int, indent: Int) raises:
        ref l = self.lines[self.pos]
        var number = l.number
        if l.text.startswith(String("- ")):
            raise _cannot(number, String("a list item where a mapping key was expected"))
        var kv = _split_key(l.text, number)
        if not kv[2]:
            raise _cannot(number, String("a line that is not `key: value`"))
        self.pos += 1
        var key = _unquote(kv[0], number)
        var v = self._value(kv[1], indent, number)
        self._put(m, key, v, number)

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
    var seen_content = False
    for i in range(len(raw)):
        var number = i + 1
        var r = raw[i]
        var stripped = String(r.strip())
        if stripped.byte_length() == 0 or stripped.startswith(String("#")):
            continue
        if stripped == String("---"):
            if seen_content:
                raise _cannot(number, String("a second document ('---')"))
            continue
        if stripped == String("..."):
            raise _cannot(number, String("a document end ('...')"))
        var indent = _indent_of(r, number)
        var body = _strip_comment(String(r[byte = indent:]))
        lines.append(_Line(number, indent, body^))
        seen_content = True
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
