# =============================================================================
# komira_aws_core/_regex.mojo -- a small regular-expression matcher
# =============================================================================
#
# Package-private. The endpoint ruleset data carries regular expressions
# (each partition's `regionRegex` in partitions.json), and the ruleset
# functions check IP literals and S3 ARNs against fixed patterns. This is the
# matcher for both: a Thompson NFA, simulated breadth-first, so the time is
# linear in the input for a given pattern and nothing backtracks.
#
# Accepted syntax, a subset of Python `re` (the dialect botocore matches
# these patterns with):
#   - literals; `.` (any byte but LF);
#   - escapes: \d \D \w \W \s \S (ASCII classes), \n \t \r, and an escaped
#     punctuation byte as itself;
#   - classes `[...]` and `[^...]` with ranges and the escapes above;
#   - groups `( )` and `(?: )`, alternation `|`;
#   - quantifiers `*` `+` `?` `{m}` `{m,}` `{m,n}` (greedy; a lazy or
#     possessive suffix is refused);
#   - anchors `^` (start of input) and `$` (end of input).
# Anything else (lookaround, backreferences, \b, named groups, flags) is
# refused when the pattern is compiled, so a pattern this matcher would
# misread never matches silently.
#
# Matching is over UTF-8 bytes, and the classes are ASCII: a non-ASCII byte
# is in no class but its negation. `matches` has `re.match` semantics: the
# match is anchored at the start of the input and need not reach its end
# (patterns that must match all of it end in `$`). Unlike Python's `$`, the
# `$` here matches only at the very end, never before a final line feed.
# =============================================================================


comptime _CHAR = 0  # consume one byte in set `cls`, go to out1
comptime _SPLIT = 1  # epsilon to out1 and to out2
comptime _JUMP = 2  # epsilon to out1
comptime _BOL = 3  # epsilon to out1 at the start of input only
comptime _EOL = 4  # epsilon to out1 at the end of input only
comptime _MATCH = 5

# A bounded repeat `{m,n}` is expanded into copies of its atom; this caps
# the expansion so a pattern cannot ask for an unbounded state table.
comptime _MAX_REPEAT = 1000


struct _Frag(Copyable, Movable):
    """A partly built NFA: its entry state and the dangling exits, each
    `state * 2 + slot` (slot 0 is out1, 1 is out2)."""

    var start: Int
    var outs: List[Int]

    def __init__(out self, start: Int, var outs: List[Int]):
        self.start = start
        self.outs = outs^


def _set_new() -> List[Bool]:
    var s = List[Bool](capacity=256)
    for _ in range(256):
        s.append(False)
    return s^


def _set_range(mut s: List[Bool], lo: Int, hi: Int):
    for c in range(lo, hi + 1):
        s[c] = True


def _set_digit(mut s: List[Bool]):
    _set_range(s, 0x30, 0x39)


def _set_word(mut s: List[Bool]):
    _set_range(s, 0x30, 0x39)
    _set_range(s, 0x41, 0x5A)
    _set_range(s, 0x61, 0x7A)
    s[0x5F] = True


def _set_space(mut s: List[Bool]):
    s[0x20] = True
    _set_range(s, 0x09, 0x0D)


def _set_negate(mut s: List[Bool]):
    for c in range(256):
        s[c] = not s[c]


def _is_ascii_alnum(c: UInt8) -> Bool:
    return (
        (c >= 0x30 and c <= 0x39)
        or (c >= 0x41 and c <= 0x5A)
        or (c >= 0x61 and c <= 0x7A)
    )


struct Regex(Copyable, Movable):
    """A compiled pattern; see the module header for the syntax."""

    var pattern: String
    var kind: List[Int]
    var cls: List[Int]
    var out1: List[Int]
    var out2: List[Int]
    var sets: List[List[Bool]]
    var start: Int

    def __init__(out self, pattern: String) raises:
        """Compiles `pattern`; raises naming the construct it refuses."""
        self.pattern = pattern
        self.kind = List[Int]()
        self.cls = List[Int]()
        self.out1 = List[Int]()
        self.out2 = List[Int]()
        self.sets = List[List[Bool]]()
        self.start = 0
        var p = List[UInt8]()
        p.extend(Span(pattern.as_bytes()))
        var pos = 0
        var f = self._alt(p, pos)
        if pos != len(p):
            raise self._err("unbalanced ')'", pos)
        var m = self._add(_MATCH)
        self._patch(f.outs, m)
        self.start = f.start

    # ---- construction ---------------------------------------------------

    def _err(self, what: String, pos: Int) -> Error:
        return Error(
            "regex: "
            + what
            + " at byte "
            + String(pos)
            + " of pattern '"
            + self.pattern
            + "'"
        )

    def _add(mut self, kind: Int, cls: Int = -1) -> Int:
        self.kind.append(kind)
        self.cls.append(cls)
        self.out1.append(-1)
        self.out2.append(-1)
        return len(self.kind) - 1

    def _patch(mut self, outs: List[Int], target: Int):
        for i in range(len(outs)):
            var s = outs[i] // 2
            if outs[i] % 2 == 0:
                self.out1[s] = target
            else:
                self.out2[s] = target

    def _class_state(mut self, var s: List[Bool]) -> _Frag:
        self.sets.append(s^)
        var st = self._add(_CHAR, len(self.sets) - 1)
        return _Frag(st, [st * 2])

    def _alt(mut self, p: List[UInt8], mut pos: Int) raises -> _Frag:
        var f = self._seq(p, pos)
        while pos < len(p) and p[pos] == UInt8(ord("|")):
            pos += 1
            var g = self._seq(p, pos)
            var s = self._add(_SPLIT)
            self.out1[s] = f.start
            self.out2[s] = g.start
            var outs = f.outs.copy()
            outs.extend(g.outs.copy())
            f = _Frag(s, outs^)
        return f^

    def _seq(mut self, p: List[UInt8], mut pos: Int) raises -> _Frag:
        var j = self._add(_JUMP)
        var f = _Frag(j, [j * 2])
        while (
            pos < len(p)
            and p[pos] != UInt8(ord("|"))
            and p[pos] != UInt8(ord(")"))
        ):
            var g = self._quantified(p, pos)
            self._patch(f.outs, g.start)
            f = _Frag(f.start, g.outs.copy())
        return f^

    def _read_int(self, p: List[UInt8], mut pos: Int) -> Int:
        """Reads decimal digits at `pos`; -1 when there are none."""
        var n = -1
        while pos < len(p) and p[pos] >= 0x30 and p[pos] <= 0x39:
            if n < 0:
                n = 0
            n = n * 10 + Int(p[pos] - 0x30)
            if n > 1_000_000:
                n = 1_000_000
            pos += 1
        return n

    def _brace_quant(
        self, p: List[UInt8], pos: Int, mut lo: Int, mut hi: Int
    ) -> Int:
        """Parses `{m}`, `{m,}` or `{m,n}` at `pos`; returns the position
        after it, or -1 when the brace is not a quantifier (Python then
        reads it as a literal)."""
        var q = pos + 1
        var m = self._read_int(p, q)
        if m < 0:
            return -1
        if q < len(p) and p[q] == UInt8(ord("}")):
            lo = m
            hi = m
            return q + 1
        if q >= len(p) or p[q] != UInt8(ord(",")):
            return -1
        q += 1
        var n = self._read_int(p, q)
        if q >= len(p) or p[q] != UInt8(ord("}")):
            return -1
        lo = m
        hi = n  # -1: unbounded
        return q + 1

    def _quantified(mut self, p: List[UInt8], mut pos: Int) raises -> _Frag:
        var atom_at = pos
        var f = self._atom(p, pos)
        if pos >= len(p):
            return f^
        var c = p[pos]
        var lo = 0
        var hi = 0
        if c == UInt8(ord("*")):
            lo = 0
            hi = -1
            pos += 1
        elif c == UInt8(ord("+")):
            lo = 1
            hi = -1
            pos += 1
        elif c == UInt8(ord("?")):
            lo = 0
            hi = 1
            pos += 1
        elif c == UInt8(ord("{")):
            var after = self._brace_quant(p, pos, lo, hi)
            if after < 0:
                return f^
            pos = after
        else:
            return f^
        if pos < len(p) and (
            p[pos] == UInt8(ord("?")) or p[pos] == UInt8(ord("+"))
        ):
            raise self._err("a lazy or possessive quantifier", pos)
        if hi >= 0 and hi < lo:
            raise self._err("a repeat whose maximum is below its minimum", pos)
        if lo > _MAX_REPEAT or hi > _MAX_REPEAT:
            raise self._err("a repeat count above 1000", pos)
        return self._repeat(p, atom_at, f^, lo, hi)

    def _copy_atom(mut self, p: List[UInt8], atom_at: Int) raises -> _Frag:
        """A fresh copy of the atom at `atom_at` (its states rebuilt)."""
        var q = atom_at
        return self._atom(p, q)

    def _repeat(
        mut self,
        p: List[UInt8],
        atom_at: Int,
        var first: _Frag,
        lo: Int,
        hi: Int,
    ) raises -> _Frag:
        var j = self._add(_JUMP)
        var acc = _Frag(j, [j * 2])
        var used_first = False
        for _ in range(lo):
            var g: _Frag
            if not used_first:
                g = _Frag(first.start, first.outs.copy())
                used_first = True
            else:
                g = self._copy_atom(p, atom_at)
            self._patch(acc.outs, g.start)
            acc = _Frag(acc.start, g.outs.copy())
        if hi < 0:
            var g: _Frag
            if not used_first:
                g = _Frag(first.start, first.outs.copy())
                used_first = True
            else:
                g = self._copy_atom(p, atom_at)
            var s = self._add(_SPLIT)
            self.out1[s] = g.start
            self._patch(g.outs, s)
            self._patch(acc.outs, s)
            acc = _Frag(acc.start, [s * 2 + 1])
        else:
            for _ in range(hi - lo):
                var g: _Frag
                if not used_first:
                    g = _Frag(first.start, first.outs.copy())
                    used_first = True
                else:
                    g = self._copy_atom(p, atom_at)
                var s = self._add(_SPLIT)
                self.out1[s] = g.start
                self._patch(acc.outs, s)
                var outs = g.outs.copy()
                outs.append(s * 2 + 1)
                acc = _Frag(acc.start, outs^)
        return acc^

    def _escape_into(
        self, p: List[UInt8], mut pos: Int, mut s: List[Bool]
    ) raises:
        """Reads the escape after a backslash at `pos` into set `s`."""
        if pos >= len(p):
            raise self._err("a trailing backslash", pos)
        var c = p[pos]
        pos += 1
        if c == UInt8(ord("d")):
            _set_digit(s)
        elif c == UInt8(ord("w")):
            _set_word(s)
        elif c == UInt8(ord("s")):
            _set_space(s)
        elif (
            c == UInt8(ord("D")) or c == UInt8(ord("W")) or c == UInt8(ord("S"))
        ):
            var t = _set_new()
            if c == UInt8(ord("D")):
                _set_digit(t)
            elif c == UInt8(ord("W")):
                _set_word(t)
            else:
                _set_space(t)
            _set_negate(t)
            for i in range(256):
                if t[i]:
                    s[i] = True
        elif c == UInt8(ord("n")):
            s[0x0A] = True
        elif c == UInt8(ord("t")):
            s[0x09] = True
        elif c == UInt8(ord("r")):
            s[0x0D] = True
        elif c < 0x80 and not _is_ascii_alnum(c):
            s[Int(c)] = True
        else:
            raise self._err("an unsupported escape", pos - 2)

    def _class(self, p: List[UInt8], mut pos: Int) raises -> List[Bool]:
        """Reads `[...]` (pos is past the '[')."""
        var s = _set_new()
        var neg = False
        if pos < len(p) and p[pos] == UInt8(ord("^")):
            neg = True
            pos += 1
        var first = True
        while True:
            if pos >= len(p):
                raise self._err("an unterminated class", pos)
            var c = p[pos]
            if c == UInt8(ord("]")) and not first:
                pos += 1
                break
            first = False
            if c == UInt8(ord("[")) and pos + 1 < len(p) and (
                p[pos + 1] == UInt8(ord(":"))
                or p[pos + 1] == UInt8(ord("="))
                or p[pos + 1] == UInt8(ord("."))
            ):
                raise self._err("a POSIX class", pos)
            var lo = -1
            if c == UInt8(ord("\\")):
                pos += 1
                if pos < len(p) and (
                    p[pos] == UInt8(ord("d"))
                    or p[pos] == UInt8(ord("w"))
                    or p[pos] == UInt8(ord("s"))
                    or p[pos] == UInt8(ord("D"))
                    or p[pos] == UInt8(ord("W"))
                    or p[pos] == UInt8(ord("S"))
                ):
                    self._escape_into(p, pos, s)
                    continue
                var one = _set_new()
                self._escape_into(p, pos, one)
                for i in range(256):
                    if one[i]:
                        lo = i
            else:
                lo = Int(c)
                pos += 1
            # A range `lo-hi`, unless the '-' ends the class.
            if (
                pos + 1 < len(p)
                and p[pos] == UInt8(ord("-"))
                and p[pos + 1] != UInt8(ord("]"))
            ):
                pos += 1
                var hi = -1
                if p[pos] == UInt8(ord("\\")):
                    pos += 1
                    var one = _set_new()
                    self._escape_into(p, pos, one)
                    var count = 0
                    for i in range(256):
                        if one[i]:
                            hi = i
                            count += 1
                    if count != 1:
                        raise self._err("a class escape as a range end", pos)
                else:
                    hi = Int(p[pos])
                    pos += 1
                if hi < lo:
                    raise self._err("a reversed range", pos)
                _set_range(s, lo, hi)
            else:
                s[lo] = True
        if neg:
            _set_negate(s)
        return s^

    def _atom(mut self, p: List[UInt8], mut pos: Int) raises -> _Frag:
        var c = p[pos]
        if c == UInt8(ord("(")):
            pos += 1
            if pos < len(p) and p[pos] == UInt8(ord("?")):
                if pos + 1 < len(p) and p[pos + 1] == UInt8(ord(":")):
                    pos += 2
                else:
                    raise self._err("a group extension other than (?:", pos)
            var f = self._alt(p, pos)
            if pos >= len(p) or p[pos] != UInt8(ord(")")):
                raise self._err("an unclosed group", pos)
            pos += 1
            return f^
        if c == UInt8(ord("[")):
            pos += 1
            return self._class_state(self._class(p, pos))
        if c == UInt8(ord("\\")):
            pos += 1
            var s = _set_new()
            if pos < len(p) and (
                p[pos] == UInt8(ord("b"))
                or p[pos] == UInt8(ord("B"))
                or p[pos] == UInt8(ord("A"))
                or p[pos] == UInt8(ord("Z"))
            ):
                raise self._err("an assertion escape", pos - 1)
            if pos < len(p) and p[pos] >= 0x31 and p[pos] <= 0x39:
                raise self._err("a backreference", pos - 1)
            self._escape_into(p, pos, s)
            return self._class_state(s^)
        if c == UInt8(ord(".")):
            pos += 1
            var s = _set_new()
            _set_negate(s)
            s[0x0A] = False
            return self._class_state(s^)
        if c == UInt8(ord("^")):
            pos += 1
            var st = self._add(_BOL)
            return _Frag(st, [st * 2])
        if c == UInt8(ord("$")):
            pos += 1
            var st = self._add(_EOL)
            return _Frag(st, [st * 2])
        if c == UInt8(ord("*")) or c == UInt8(ord("+")) or c == UInt8(ord("?")):
            raise self._err("nothing to repeat", pos)
        pos += 1
        var s = _set_new()
        s[Int(c)] = True
        return self._class_state(s^)

    # ---- matching -------------------------------------------------------

    def _close(
        self,
        mut into: List[Int],
        mut mark: List[Int],
        gen: Int,
        state: Int,
        at: Int,
        n: Int,
    ):
        """Adds `state` and its epsilon closure at input position `at`."""
        var stack = List[Int]()
        stack.append(state)
        while len(stack) > 0:
            var s = stack.pop()
            if s < 0 or mark[s] == gen:
                continue
            mark[s] = gen
            var k = self.kind[s]
            if k == _SPLIT:
                stack.append(self.out2[s])
                stack.append(self.out1[s])
            elif k == _JUMP:
                stack.append(self.out1[s])
            elif k == _BOL:
                if at == 0:
                    stack.append(self.out1[s])
            elif k == _EOL:
                if at == n:
                    stack.append(self.out1[s])
            else:
                into.append(s)

    def _has_match(self, states: List[Int]) -> Bool:
        for i in range(len(states)):
            if self.kind[states[i]] == _MATCH:
                return True
        return False

    def matches(self, s: String) -> Bool:
        """`re.match`: the pattern matches a prefix of `s` (all of it when
        the pattern ends in `$`)."""
        var b = s.as_bytes()
        var n = len(b)
        var mark = List[Int](capacity=len(self.kind))
        for _ in range(len(self.kind)):
            mark.append(-1)
        var gen = 0
        var cur = List[Int]()
        self._close(cur, mark, gen, self.start, 0, n)
        for i in range(n):
            if self._has_match(cur):
                return True
            gen += 1
            var nxt = List[Int]()
            var c = Int(b[i])
            for k in range(len(cur)):
                var st = cur[k]
                if self.kind[st] == _CHAR and self.sets[self.cls[st]][c]:
                    self._close(nxt, mark, gen, self.out1[st], i + 1, n)
            if len(nxt) == 0:
                return False
            cur = nxt^
        return self._has_match(cur)
