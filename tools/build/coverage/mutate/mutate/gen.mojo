"""The mutants of one Mojo source file.

Each mutant replaces bytes [start, end) of the file with `replacement`; it
is named `<path>:<line>:<col>:<operator>` (its `id`), where line and col
(1-based, col in bytes) are where the replaced bytes start, or for an early
return where the statement it is inserted before starts. The operators, in
the order they are tried at each token:

| operator | at | replaced by |
|---|---|---|
| `cmp_negate` | `==` `!=` `<` `<=` `>` `>=` | its negation: `!=` `==` `>=` `>` `<=` `<` |
| `arith_swap` | binary `+` `-`, `+=` `-=`, not joining strings | the other one |
| `bool_swap` | `and`, `or` | the other one |
| `not_delete` | `not` | nothing (`x not in y` becomes `x  in y`) |
| `const_inc`, `const_dec` | a decimal integer literal of digits only, at most 18 | the value plus one; minus one (not for 0) |
| `raise_delete` | a `raise` statement, to its end | `pass` |
| `return_early` | the first statement of a function returning nothing | `return` inserted before it |
| `return_true`, `return_false` | the first statement of a function returning `Bool` | `return True`; `return False` inserted before it |

A `+` or `-` is binary when the token before it is an operand: an
identifier that is not a keyword (`_keyword`), a number, a string, or a
closing bracket. A `+` or `+=` joining strings is not swapped (its `-`
would not compile): the operand before it is a string literal or a
`String(...)` call, or the one after it starts with a string literal or
`String` (`_string_operand`). Other string joins (`a + b.reason`) are
still swapped, and come back `error`. An early return is made for a `def` whose header ends its
line with `:`, takes no `out` argument (a constructor must initialize), and
whose first statement (after a docstring) is not `pass`, `...`, or already
the statement it would insert.

Markers (end-of-line comments, on the line where the mutant's location is):
`# cov: unreachable <reason>` suppresses every mutant on the line, and
`# mutation: equivalent <operator>[,<operator>...] <reason>` suppresses
those operators on the line. Suppressed mutants are returned apart, with the
marker's reason, so a reviewer sees each. Any other comment starting
`# mutation:` (a bare `# mutation: equivalent`, a misspelt kind), an
equivalent marker naming an unknown operator, or one with no reason,
raises.
"""

from mutate.lex import COMMENT, IDENT, NEWLINE, NUMBER, OP, STRING, Token, line_of, line_starts, text_of, tokenize

comptime MAX_DIGITS: Int = 18


def operators() -> List[String]:
    var o = List[String]()
    o.append("cmp_negate")
    o.append("arith_swap")
    o.append("bool_swap")
    o.append("not_delete")
    o.append("const_inc")
    o.append("const_dec")
    o.append("raise_delete")
    o.append("return_early")
    o.append("return_true")
    o.append("return_false")
    return o^


struct Mutant(Copyable, Movable):
    var path: String
    var line: Int
    var col: Int
    var start: Int
    var end: Int
    var replacement: String
    var operator: String
    var description: String

    def __init__(out self, path: String, line: Int, col: Int, start: Int, end: Int, replacement: String, operator: String, description: String):
        self.path = path
        self.line = line
        self.col = col
        self.start = start
        self.end = end
        self.replacement = replacement
        self.operator = operator
        self.description = description

    def id(self) -> String:
        return self.path + ":" + String(self.line) + ":" + String(self.col) + ":" + self.operator


struct Suppressed(Copyable, Movable):
    """A mutant a marker suppressed: `kind` is `equivalent` or `unreachable`."""

    var id: String
    var kind: String
    var reason: String

    def __init__(out self, id: String, kind: String, reason: String):
        self.id = id
        self.kind = kind
        self.reason = reason


struct Generated(Movable):
    var mutants: List[Mutant]
    var suppressed: List[Suppressed]

    def __init__(out self):
        self.mutants = List[Mutant]()
        self.suppressed = List[Suppressed]()


struct _Marker(Copyable, Movable):
    var line: Int
    var kind: String
    var ops: List[String]
    var reason: String

    def __init__(out self, line: Int, kind: String, var ops: List[String], reason: String):
        self.line = line
        self.kind = kind
        self.ops = ops^
        self.reason = reason


def _keyword(word: String) -> Bool:
    comptime KEYWORDS = " return in and or not if elif else while for yield raise assert is lambda comptime var ref del with as from import await case match "
    return String(KEYWORDS).find(String(" ") + word + " ") >= 0


def _split_ws(s: String) -> List[String]:
    """`s` split at runs of spaces."""
    var out = List[String]()
    var b = s.as_bytes()
    var start = -1
    for i in range(len(b) + 1):
        var sp = i == len(b) or Int(b[i]) == 32
        if sp and start >= 0:
            out.append(String(s[byte=start:i]))
            start = -1
        elif not sp and start < 0:
            start = i
    return out^


def _rest_after(s: String, prefix: String) -> String:
    return String(s[byte = prefix.byte_length() : s.byte_length()])


def _markers(src: String, toks: List[Token], starts: List[Int], path: String) raises -> List[_Marker]:
    var out = List[_Marker]()
    var known = operators()
    for t in toks:
        if t.kind != COMMENT:
            continue
        var c = text_of(src, t)
        var line = line_of(starts, t.start)
        if c.startswith("# cov: unreachable"):
            var reason = String(c[byte=18 : c.byte_length()]).strip()
            out.append(_Marker(line, String("unreachable"), List[String](), String(reason)))
        elif c.startswith("# mutation:"):
            if not c.startswith("# mutation: equivalent "):
                raise Error(path + ":" + String(line) + ": a `# mutation:` comment is `# mutation: equivalent <operator>[,<operator>...] <reason>`")
            var words = _split_ws(_rest_after(c, String("# mutation: equivalent ")))
            if len(words) < 2:
                raise Error(path + ":" + String(line) + ": a `# mutation: equivalent` marker needs operators and a reason")
            var ops = List[String]()
            var names = words[0]
            var b = names.as_bytes()
            var s0 = 0
            for i in range(len(b) + 1):
                if i == len(b) or Int(b[i]) == 44:
                    var op = String(names[byte=s0:i])
                    var ok = False
                    for k in known:
                        if k == op:
                            ok = True
                    if not ok:
                        raise Error(path + ":" + String(line) + ": `" + op + "` is not a mutation operator")
                    ops.append(op)
                    s0 = i + 1
            var reason = String("")
            for i in range(1, len(words)):
                reason += (String(" ") if i > 1 else String("")) + words[i]
            out.append(_Marker(line, String("equivalent"), ops^, reason))
    return out^


def _prev_sig(toks: List[Token], i: Int) -> Int:
    """The index of the token before `i` that is not a comment, or -1."""
    var j = i - 1
    while j >= 0 and toks[j].kind == COMMENT:
        j -= 1
    return j


def _next_sig(toks: List[Token], i: Int) -> Int:
    var j = i + 1
    while j < len(toks) and toks[j].kind == COMMENT:
        j += 1
    return j


def _operand_before(src: String, toks: List[Token], i: Int) -> Bool:
    var p = _prev_sig(toks, i)
    if p < 0:
        return False
    var t = toks[p]
    if t.kind == NUMBER or t.kind == STRING:
        return True
    if t.kind == IDENT:
        return not _keyword(text_of(src, t))
    if t.kind == OP:
        var s = text_of(src, t)
        return s == ")" or s == "]" or s == "}"
    return False


def _string_operand(src: String, toks: List[Token], i: Int) -> Bool:
    """Whether the `+` at token `i` joins strings: the operand before it is
    a string literal or a `String(...)` call, or the one after it starts
    with a string literal or `String`. Its `-` would not compile."""
    var n = _next_sig(toks, i)
    if n < len(toks) and (toks[n].kind == STRING or (toks[n].kind == IDENT and text_of(src, toks[n]) == "String")):
        return True
    var p = _prev_sig(toks, i)
    if p < 0:
        return False
    if toks[p].kind == STRING:
        return True
    if toks[p].kind != OP or text_of(src, toks[p]) != ")":
        return False
    var depth = 0
    var j = p
    while j >= 0:
        if toks[j].kind == OP:
            var s = text_of(src, toks[j])
            if s == ")" or s == "]" or s == "}":
                depth += 1
            elif s == "(" or s == "[" or s == "{":
                depth -= 1
                if depth == 0:
                    var c = _prev_sig(toks, j)
                    return c >= 0 and toks[c].kind == IDENT and text_of(src, toks[c]) == "String"
        j -= 1
    return False


def _statement_start(src: String, toks: List[Token], i: Int) -> Bool:
    var p = _prev_sig(toks, i)
    if p < 0 or toks[p].kind == NEWLINE:
        return True
    var s = text_of(src, toks[p])
    return toks[p].kind == OP and (s == ";" or s == ":")


def _stmt_end(src: String, toks: List[Token], i: Int) -> Int:
    """The index of the last non-comment token of the statement starting at `i`."""
    var last = i
    var j = i + 1
    while j < len(toks) and toks[j].kind != NEWLINE:
        if toks[j].kind == OP and text_of(src, toks[j]) == ";":
            break
        if toks[j].kind != COMMENT:
            last = j
        j += 1
    return last


def _negation(op: String) -> String:
    if op == "==":
        return "!="
    if op == "!=":
        return "=="
    if op == "<":
        return ">="
    if op == "<=":
        return ">"
    if op == ">":
        return "<="
    if op == ">=":
        return "<"
    return ""


def _decimal(s: String) -> Int:
    """`s` as a decimal integer of digits only, or -1."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > MAX_DIGITS:
        return -1
    var v = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 48 or c > 57:
            return -1
        v = v * 10 + (c - 48)
    return v


struct _Ctx(Movable):
    var path: String
    var starts: List[Int]
    var out: List[Mutant]

    def __init__(out self, path: String, var starts: List[Int]):
        self.path = path
        self.starts = starts^
        self.out = List[Mutant]()

    def add(mut self, at: Int, start: Int, end: Int, replacement: String, operator: String, description: String):
        var line = line_of(self.starts, at)
        var col = at - self.starts[line - 1] + 1
        self.out.append(Mutant(self.path, line, col, start, end, replacement, operator, description))


def _early_returns(src: String, toks: List[Token], i: Int, mut cx: _Ctx):
    """The early-return mutants of the `def` at token `i`, if any."""
    # The header: to the `:` that ends its logical line.
    var j = i + 1
    var colon = -1
    var arrow = -1
    var has_out = False
    var depth = 0
    while j < len(toks) and toks[j].kind != NEWLINE:
        var t = toks[j]
        if t.kind == OP:
            var s = text_of(src, t)
            if s == "(" or s == "[" or s == "{":
                depth += 1
            elif s == ")" or s == "]" or s == "}":
                depth -= 1
            elif s == "->" and depth == 0:
                arrow = j
            elif s == ":" and depth == 0:
                colon = j
        elif t.kind == IDENT and text_of(src, t) == "out" and depth == 1:
            has_out = True
        j += 1
    if colon < 0 or has_out or _next_sig(toks, colon) != j:
        return
    var ret = String("")
    if arrow >= 0:
        for k in range(arrow + 1, colon):
            if toks[k].kind != COMMENT:
                ret += text_of(src, toks[k])
    var inserts = List[String]()
    var names = List[String]()
    if ret == "" or ret == "None":
        inserts.append("return")
        names.append("return_early")
    elif ret == "Bool":
        inserts.append("return True")
        names.append("return_true")
        inserts.append("return False")
        names.append("return_false")
    else:
        return
    # The first body statement, past blank lines, comments and a docstring.
    var k = j
    while k < len(toks) and (toks[k].kind == NEWLINE or toks[k].kind == COMMENT):
        k += 1
    if k < len(toks) and toks[k].kind == STRING:
        var after = _next_sig(toks, k)
        if after < len(toks) and toks[after].kind == NEWLINE:
            k = after
            while k < len(toks) and (toks[k].kind == NEWLINE or toks[k].kind == COMMENT):
                k += 1
    if k >= len(toks) or toks[k].start >= src.byte_length():
        return
    var first = toks[k]
    var line = line_of(cx.starts, first.start)
    var ls = cx.starts[line - 1]
    var indent = String(src[byte = ls : first.start])
    for c in indent.as_bytes():
        if Int(c) != 32 and Int(c) != 9:
            return
    var last = _stmt_end(src, toks, k)
    var stmt = String(src[byte = first.start : toks[last].end])
    if stmt == "pass" or stmt == "...":
        return
    for m in range(len(inserts)):
        if stmt == inserts[m]:
            continue
        cx.add(first.start, first.start, first.start, inserts[m] + "\n" + indent, names[m], String("insert `") + inserts[m] + "`")


def generate(path: String, src: String) raises -> Generated:
    """The mutants of `src` (the file at `path` in its package), in source
    order, and those its markers suppress (module docstring)."""
    if path.byte_length() == 0:
        raise Error("an empty path")
    for c in path.as_bytes():
        if Int(c) == 58 or Int(c) == 9 or Int(c) == 10:
            raise Error(path + ": a path may not hold `:`, a tab or a line end")
    var toks = tokenize(src)
    var cx = _Ctx(path, line_starts(src))
    var markers = _markers(src, toks, cx.starts, path)
    for i in range(len(toks)):
        var t = toks[i]
        var s = text_of(src, t)
        if t.kind == OP:
            var neg = _negation(s)
            if neg != "":
                cx.add(t.start, t.start, t.end, neg, "cmp_negate", s + " -> " + neg)
            elif (s == "+=" or s == "-=") and not (s == "+=" and _string_operand(src, toks, i)):
                var other = String("-=") if s == "+=" else String("+=")
                cx.add(t.start, t.start, t.end, other, "arith_swap", s + " -> " + other)
            elif (s == "+" or s == "-") and _operand_before(src, toks, i) and not (s == "+" and _string_operand(src, toks, i)):
                var other = String("-") if s == "+" else String("+")
                cx.add(t.start, t.start, t.end, other, "arith_swap", s + " -> " + other)
        elif t.kind == IDENT:
            if s == "and" or s == "or":
                var other = String("or") if s == "and" else String("and")
                cx.add(t.start, t.start, t.end, other, "bool_swap", s + " -> " + other)
            elif s == "not":
                cx.add(t.start, t.start, t.end, String(""), "not_delete", String("delete `not`"))
            elif s == "raise" and _statement_start(src, toks, i):
                var last = _stmt_end(src, toks, i)
                cx.add(t.start, t.start, toks[last].end, String("pass"), "raise_delete", String("raise ... -> pass"))
            elif s == "def" and _statement_start(src, toks, i):
                _early_returns(src, toks, i, cx)
        elif t.kind == NUMBER:
            var v = _decimal(s)
            if v >= 0:
                cx.add(t.start, t.start, t.end, String(v + 1), "const_inc", s + " -> " + String(v + 1))
                if v > 0:
                    cx.add(t.start, t.start, t.end, String(v - 1), "const_dec", s + " -> " + String(v - 1))
    # Source order: an early return is found at its `def` but placed at the
    # statement it is inserted before. A stable insertion sort by start.
    for i in range(1, len(cx.out)):
        var j = i
        while j > 0 and cx.out[j - 1].start > cx.out[j].start:
            cx.out.swap_elements(j - 1, j)
            j -= 1
    var g = Generated()
    for m in cx.out:
        var kind = String("")
        var reason = String("")
        for mk in markers:
            if mk.line != m.line:
                continue
            if mk.kind == "unreachable":
                kind = mk.kind
                reason = mk.reason
            else:
                for op in mk.ops:
                    if op == m.operator:
                        kind = mk.kind
                        reason = mk.reason
        if kind != "":
            g.suppressed.append(Suppressed(m.id(), kind, reason))
        else:
            g.mutants.append(m.copy())
    return g^


def apply(src: String, m: Mutant) -> String:
    """`src` with mutant `m` applied."""
    return String(src[byte = 0 : m.start]) + m.replacement + String(src[byte = m.end : src.byte_length()])
