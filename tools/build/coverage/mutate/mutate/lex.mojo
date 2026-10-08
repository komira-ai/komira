"""The tokens of a Mojo source, enough to find operators outside strings and
comments.

`tokenize` reads the bytes once and returns, in order:

- `IDENT`: a run of identifier bytes (letters, digits, `_`, any byte >= 128)
  starting with a non-digit; keywords are identifiers;
- `NUMBER`: a numeric literal: a digit, then identifier bytes and `.`, and
  a sign right after an exponent `e`/`E` of a decimal literal (`1e-5` is one
  token, `0x1e-5` is not);
- `STRING`: a string literal, its prefix letters (`r b f u t`, one or two,
  either case) included: `"..."` and `'...'`, which end at the same quote or
  at the line end, triple-quoted strings spanning lines, and backtick-quoted
  MLIR text (`` `...` ``, ending at the next backtick); a backslash inside a
  quoted string keeps the next byte from closing it;
- `COMMENT`: `#` outside every string, to the line end (the LF not
  included);
- `OP`: punctuation, the longest operator of `_OPS` that starts there, else
  one byte;
- `NEWLINE`: the end of a logical line: an LF outside every string while no
  `(`, `[` or `{` is open and the line does not end with a backslash, and
  once at the end of the source (a zero-width token there).

Spaces, tabs, form feeds, carriage returns and a backslash continuing a line
make no token. Unbalanced brackets never go below depth 0. The lexer does not
refuse anything: a source the compiler rejects still yields tokens, and the
mutants made of them are counted `error` by the scorer (tools/build/coverage/README.md,
"Mutation score").
"""

comptime IDENT: Int = 1
comptime NUMBER: Int = 2
comptime STRING: Int = 3
comptime COMMENT: Int = 4
comptime OP: Int = 5
comptime NEWLINE: Int = 6

comptime _LF: Int = 10
comptime _HASH: Int = 35
comptime _DQUOTE: Int = 34
comptime _SQUOTE: Int = 39
comptime _BACKTICK: Int = 96
comptime _BACKSLASH: Int = 92


struct Token(Copyable, ImplicitlyCopyable, Movable):
    """Bytes [start, end) of the source, of kind `kind`."""

    var kind: Int
    var start: Int
    var end: Int

    def __init__(out self, kind: Int, start: Int, end: Int):
        self.kind = kind
        self.start = start
        self.end = end


def is_ident_byte(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c >= 128


def _is_digit(c: Int) -> Bool:
    return c >= 48 and c <= 57


def _is_prefix_letter(c: Int) -> Bool:
    # r b f u t, either case
    return c == 114 or c == 82 or c == 98 or c == 66 or c == 102 or c == 70 or c == 117 or c == 85 or c == 116 or c == 84


def _ops() -> List[String]:
    """Every multi-byte operator, longest first."""
    var all = String("<<= >>= **= //= ... <= >= == != -> << >> ** // += -= *= /= %= &= |= ^= @= :=")
    var o = List[String]()
    var b = all.as_bytes()
    var start = 0
    for i in range(len(b) + 1):
        if i == len(b) or Int(b[i]) == 32:
            o.append(String(all[byte=start:i]))
            start = i + 1
    return o^


def _string_end(src: String, i: Int) -> Int:
    """The end of the quoted string whose opening quote is at byte `i`."""
    var b = src.as_bytes()
    var n = len(b)
    var q = Int(b[i])
    if q == _BACKTICK:
        var j = i + 1
        while j < n and Int(b[j]) != _BACKTICK:
            j += 1
        return min(j + 1, n)
    var triple = i + 2 < n and Int(b[i + 1]) == q and Int(b[i + 2]) == q
    var j = i + (3 if triple else 1)
    while j < n:
        var c = Int(b[j])
        if c == _BACKSLASH:
            j += 2
            continue
        if c == q:
            if not triple:
                return j + 1
            if j + 2 < n and Int(b[j + 1]) == q and Int(b[j + 2]) == q:
                return j + 3
        if c == _LF and not triple:
            return j
        j += 1
    return n


def tokenize(src: String) -> List[Token]:
    """The tokens of `src`, in order (see the module docstring)."""
    var b = src.as_bytes()
    var n = len(b)
    var ops = _ops()
    var out = List[Token]()
    var depth = 0
    var i = 0
    while i < n:
        var c = Int(b[i])
        if c == 32 or c == 9 or c == 12 or c == 13:
            i += 1
            continue
        if c == _LF:
            if depth == 0:
                out.append(Token(NEWLINE, i, i + 1))
            i += 1
            continue
        if c == _BACKSLASH:
            # A continuation: the backslash and the line end make no token.
            i += 1
            if i < n and Int(b[i]) == 13:
                i += 1
            if i < n and Int(b[i]) == _LF:
                i += 1
            continue
        if c == _HASH:
            var j = i
            while j < n and Int(b[j]) != _LF:
                j += 1
            out.append(Token(COMMENT, i, j))
            i = j
            continue
        if c == _DQUOTE or c == _SQUOTE or c == _BACKTICK:
            var j = _string_end(src, i)
            out.append(Token(STRING, i, j))
            i = j
            continue
        if is_ident_byte(c) and not _is_digit(c):
            var j = i
            while j < n and is_ident_byte(Int(b[j])):
                j += 1
            # A string prefix: one or two prefix letters right before a quote.
            if j < n and (Int(b[j]) == _DQUOTE or Int(b[j]) == _SQUOTE) and j - i <= 2:
                var all_prefix = True
                for k in range(i, j):
                    if not _is_prefix_letter(Int(b[k])):
                        all_prefix = False
                if all_prefix:
                    var e = _string_end(src, j)
                    out.append(Token(STRING, i, e))
                    i = e
                    continue
            out.append(Token(IDENT, i, j))
            i = j
            continue
        if _is_digit(c) or (c == 46 and i + 1 < n and _is_digit(Int(b[i + 1]))):
            var hexish = c == 48 and i + 1 < n and (Int(b[i + 1]) == 120 or Int(b[i + 1]) == 88)
            var j = i + 1
            while j < n:
                var d = Int(b[j])
                if is_ident_byte(d) or d == 46:
                    j += 1
                    continue
                if (d == 43 or d == 45) and not hexish and (Int(b[j - 1]) == 101 or Int(b[j - 1]) == 69):
                    j += 1
                    continue
                break
            out.append(Token(NUMBER, i, j))
            i = j
            continue
        var width = 1
        for k in range(len(ops)):
            var ob = ops[k].as_bytes()
            var w = len(ob)
            if i + w <= n:
                var same = True
                for m in range(w):
                    if b[i + m] != ob[m]:
                        same = False
                        break
                if same:
                    width = w
                    break
        if width == 1:
            if c == 40 or c == 91 or c == 123:
                depth += 1
            elif (c == 41 or c == 93 or c == 125) and depth > 0:
                depth -= 1
        out.append(Token(OP, i, i + width))
        i += width
    out.append(Token(NEWLINE, n, n))
    return out^


def text_of(src: String, t: Token) -> String:
    return String(src[byte = t.start : t.end])


def line_starts(src: String) -> List[Int]:
    """The byte offset each line starts at (line 1 at index 0)."""
    var b = src.as_bytes()
    var out = List[Int]()
    out.append(0)
    for i in range(len(b)):
        if Int(b[i]) == _LF:
            out.append(i + 1)
    return out^


def line_of(starts: List[Int], offset: Int) -> Int:
    """The 1-based line holding byte `offset`."""
    var lo = 0
    var hi = len(starts) - 1
    while lo < hi:
        var mid = (lo + hi + 1) // 2
        if starts[mid] <= offset:
            lo = mid
        else:
            hi = mid - 1
    return lo + 1
