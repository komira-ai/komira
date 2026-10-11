# =============================================================================
# komira_plan_harness/nested_floats.mojo -- float leaves of a nested cell.
# =============================================================================
#
# A float inside a nested value is written as its bits alone: `0x` and
# width/4 UPPER-case hex digits, or `NaN` (render.mojo), and nested values
# compare as text. So `0x3ff0000000000000` in an expected file is a cell no
# result can match. escape.check_nested_cell is structural and cannot tell a
# float leaf from a string leaf that reads the same; this file walks a cell
# along its column's type spelling (type_text.mojo's grammar) to find the
# float leaves and refuses one canon would not write.
#
# The walk checks floats only. Where the type and the cell disagree in shape,
# or the type spells no children (a type spelled from a zero-row column's
# Field), it stops checking that cell rather than guess; it never refuses a
# cell for its shape (check_nested_cell owns that).
# =============================================================================

comptime _K_OTHER: Int = 0  # a leaf that is not a float, or a type it cannot read
comptime _K_FLOAT: Int = 1
comptime _K_LIST: Int = 2
comptime _K_STRUCT: Int = 3
comptime _K_MAP: Int = 4
comptime _K_UNION: Int = 5


@fieldwise_init
struct _TypeNode(Copyable, Movable):
    var kind: Int
    var width: Int
    var kids: List[Int]
    var ids: List[Int]


def _is_delim(b: UInt8) -> Bool:
    # , : ] } )
    return b == 44 or b == 58 or b == 93 or b == 125 or b == 41


def _split_top(s: String, sep: UInt8) -> List[String]:
    """Split on every unescaped `sep` outside `<...>` and `(...)`."""
    var res = List[String]()
    var bs = s.as_bytes()
    var depth = 0
    var start = 0
    var i = 0
    while i < len(bs):
        var b = bs[i]
        if b == 92:
            i += 2
            continue
        if b == 60 or b == 40:
            depth += 1
        elif b == 62 or b == 41:
            depth -= 1
        elif b == sep and depth == 0:
            res.append(String(s[byte=start:i]))
            start = i + 1
        i += 1
    res.append(String(s[byte = start : s.byte_length()]))
    return res^


def _strip_name(entry: String) -> String:
    """`name:type` -> `type`; a bare `type` is returned as is."""
    var parts = _split_top(entry, 58)  # ':'
    if len(parts) >= 2:
        return String(entry[byte = parts[0].byte_length() + 1 : entry.byte_length()])
    return entry


def _ids_of(params: String) -> List[Int]:
    var res = List[Int]()
    for p in params.split(","):
        try:
            res.append(Int(String(p)))
        except:
            return List[Int]()
    return res^


struct NestedFloatType(Copyable, Movable):
    """A column's type spelling parsed for its float leaves."""

    var _nodes: List[_TypeNode]
    var _root: Int
    var has_float: Bool

    def __init__(out self, spelling: String):
        self._nodes = List[_TypeNode]()
        self._root = -1
        self.has_float = False
        var t = spelling
        if t.endswith("?"):
            t = String(spelling[byte = 0 : spelling.byte_length() - 1])
        self._root = self._parse(t)

    def _add(mut self, kind: Int, width: Int, var kids: List[Int], var ids: List[Int]) -> Int:
        if kind == _K_FLOAT:
            self.has_float = True
        self._nodes.append(_TypeNode(kind, width, kids^, ids^))
        return len(self._nodes) - 1

    def _parse(mut self, spelling: String) -> Int:
        var bs = spelling.as_bytes()
        var i = 0
        while i < len(bs) and (
            (bs[i] >= 97 and bs[i] <= 122) or (bs[i] >= 48 and bs[i] <= 57) or bs[i] == 95
        ):
            i += 1
        var base = String(spelling[byte=0:i])
        var params = String()
        if i < len(bs) and bs[i] == 40:  # '('
            var close = i + 1
            while close < len(bs) and bs[close] != 41:
                close += 2 if bs[close] == 92 else 1
            params = String(spelling[byte = i + 1 : min(close, len(bs))])
            i = close + 1
        var children = List[String]()
        if i < len(bs) and bs[i] == 60 and spelling.endswith(">"):  # '<'
            for c in _split_top(String(spelling[byte = i + 1 : len(bs) - 1]), 44):
                children.append(_strip_name(c))
        if base == "float16":
            return self._add(_K_FLOAT, 16, List[Int](), List[Int]())
        if base == "float32":
            return self._add(_K_FLOAT, 32, List[Int](), List[Int]())
        if base == "float64":
            return self._add(_K_FLOAT, 64, List[Int](), List[Int]())
        if base == "dictionary":
            if len(children) == 2:
                var v = children[1].copy()
                if v == "float16" or v == "float32" or v == "float64":
                    return self._parse(v)
            return self._add(_K_OTHER, 0, List[Int](), List[Int]())
        var kids = List[Int]()
        for c in children:
            kids.append(self._parse(c))
        if (base == "list" or base == "large_list" or base == "fixed_size_list") and len(kids) == 1:
            return self._add(_K_LIST, 0, kids^, List[Int]())
        if base == "struct" and len(kids) > 0:
            return self._add(_K_STRUCT, 0, kids^, List[Int]())
        if base == "map" and len(kids) == 2:
            return self._add(_K_MAP, 0, kids^, List[Int]())
        if base == "union_sparse" or base == "union_dense":
            var ids = _ids_of(params)
            if len(ids) == len(kids) and len(kids) > 0:
                return self._add(_K_UNION, 0, kids^, ids^)
        return self._add(_K_OTHER, 0, List[Int](), List[Int]())

    def check(self, cell: String) raises:
        """Refuse a float leaf of `cell` that is not `\\N`, `NaN` or `0x` and
        width/4 upper-case hex digits."""
        if not self.has_float or self._root < 0:
            return
        _ = self._walk(cell, self._root, 0)

    def _token_end(self, bs: Span[UInt8, _], pos: Int) -> Int:
        var i = pos
        while i < len(bs) and not _is_delim(bs[i]):
            i += 2 if bs[i] == 92 else 1
        return min(i, len(bs))

    def _skip_value(self, bs: Span[UInt8, _], pos: Int) -> Int:
        if pos >= len(bs):
            return -1
        var b = bs[pos]
        if not (b == 91 or b == 123 or b == 40):
            return self._token_end(bs, pos)
        var depth = 0
        var i = pos
        while i < len(bs):
            var c = bs[i]
            if c == 92:
                i += 2
                continue
            if c == 91 or c == 123 or c == 40:
                depth += 1
            elif c == 93 or c == 125 or c == 41:
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
        return -1

    def _walk(self, cell: String, node: Int, pos: Int) raises -> Int:
        """Check the value at `pos` against `node`; the position after it,
        or -1 when the cell's shape is not the type's (checking stops)."""
        var bs = cell.as_bytes()
        var n = len(bs)
        if pos + 1 < n and bs[pos] == 92 and bs[pos + 1] == 78:  # \N
            return pos + 2
        ref t = self._nodes[node]
        if t.kind == _K_FLOAT:
            var end = self._token_end(bs, pos)
            _check_float_leaf(String(cell[byte=pos:end]), t.width, cell)
            return end
        if t.kind == _K_OTHER:
            return self._skip_value(bs, pos)
        var opener: UInt8 = UInt8(91 if t.kind == _K_LIST else (40 if t.kind == _K_UNION else 123))
        var closer: UInt8 = UInt8(93 if t.kind == _K_LIST else (41 if t.kind == _K_UNION else 125))
        if pos >= n or bs[pos] != opener:
            return -1
        var i = pos + 1
        if i < n and bs[i] == closer and t.kind != _K_UNION:
            return i + 1
        var field = 0
        while i < n:
            var p: Int
            if t.kind == _K_LIST:
                p = self._walk(cell, t.kids[0], i)
            elif t.kind == _K_UNION:
                var colon = self._token_end(bs, i)
                if colon >= n or bs[colon] != 58:
                    return -1
                var child = -1
                try:
                    var code = Int(String(cell[byte=i:colon]))
                    for k in range(len(t.ids)):
                        if t.ids[k] == code:
                            child = k
                except:
                    return -1
                if child < 0:
                    return -1
                p = self._walk(cell, t.kids[child], colon + 1)
            elif t.kind == _K_STRUCT:
                var colon = self._token_end(bs, i)
                if colon >= n or bs[colon] != 58 or field >= len(t.kids):
                    return -1
                p = self._walk(cell, t.kids[field], colon + 1)
            else:  # map
                var k = self._walk(cell, t.kids[0], i)
                if k < 0 or k >= n or bs[k] != 58:
                    return -1
                p = self._walk(cell, t.kids[1], k + 1)
            if p < 0 or p >= n:
                return -1
            field += 1
            if bs[p] == closer:
                return p + 1
            if bs[p] != 44 or t.kind == _K_UNION:
                return -1
            i = p + 1
        return -1


def _check_float_leaf(text: String, width: Int, cell: String) raises:
    if text == "NaN":
        return
    var bs = text.as_bytes()
    var ok = len(bs) == 2 + width // 4 and bs[0] == 48 and bs[1] == 120  # 0x
    if ok:
        for k in range(2, len(bs)):
            var b = bs[k]
            if not ((b >= 48 and b <= 57) or (b >= 65 and b <= 70)):
                ok = False
    if not ok:
        raise Error(
            "canon: nested cell '" + cell + "' has a nested float '" + text
            + "' canon does not write (float" + String(width) + " is 0x and "
            + String(width // 4) + " upper-case hex digits, or NaN)"
        )
