# =============================================================================
# rule_pattern -- a small byte-pattern matcher for one token.
# =============================================================================
#
# A `Pattern` is compiled from a string the host supplies and tests whether a
# whole token matches it. It is deliberately smaller than a regular-expression
# engine: a pattern is a sequence of atoms, each optionally followed by one
# quantifier, and the whole token must match (there are no anchors because there
# is no partial match).
#
#   atom        a literal byte, `.` (any byte), a class `[a-z0-9_]` or `[^ab]`
#               (members and `lo-hi` ranges, negation with a leading `^`), or an
#               escape: `\d` (digit), `\w` (letter, digit or underscore), and
#               `\` before any other byte for that byte as a literal.
#   quantifier  `?` (zero or one), `*` (zero or more), `+` (one or more).
#
# Groups, alternation, counted repetition and anchors are not supported and are
# refused when the pattern is compiled (escape the byte to use it literally).
# Matching is over bytes, so `.` and a negated class each stand for one byte of
# a multi-byte character.
#
# Matching simulates the pattern's states over the token once, left to right:
# the cost is the token length times the pattern length, with no backtracking,
# so a pattern cannot be made exponentially slow by the text it is run on.
# =============================================================================

comptime PATTERN_MAX_BYTES: Int = 256
"""The longest pattern source, in bytes."""

comptime _Q_ONE: Int = 0
comptime _Q_OPTIONAL: Int = 1
comptime _Q_STAR: Int = 2
comptime _Q_PLUS: Int = 3


struct _Atom(Copyable, Movable):
    """One pattern atom: a 256-entry byte membership table and a quantifier."""

    var members: List[Bool]
    var quant: Int

    def __init__(out self, var members: List[Bool], quant: Int):
        self.members = members^
        self.quant = quant


def _empty_set() -> List[Bool]:
    var s = List[Bool](capacity=256)
    for _ in range(256):
        s.append(False)
    return s^


def _add_range(mut s: List[Bool], lo: Int, hi: Int):
    for c in range(lo, hi + 1):
        s[c] = True


def _add_escape(mut s: List[Bool], c: Int):
    """Add the bytes an escape `\\c` stands for to the set `s`."""
    if c == 0x64:  # d
        _add_range(s, 0x30, 0x39)
    elif c == 0x77:  # w
        _add_range(s, 0x30, 0x39)
        _add_range(s, 0x41, 0x5A)
        _add_range(s, 0x61, 0x7A)
        s[0x5F] = True
    else:
        s[c] = True


def _refuse(pattern: String, at: Int, why: String) raises:
    raise Error(
        "Pattern.compile: "
        + why
        + " at byte "
        + String(at)
        + " of '"
        + pattern
        + "'"
    )


struct Pattern(Copyable, Movable):
    """A compiled whole-token byte pattern (see the file header for the syntax).
    """

    var _atoms: List[_Atom]

    def __init__(out self, var atoms: List[_Atom]):
        self._atoms = atoms^

    @staticmethod
    def compile(pattern: String) raises -> Pattern:
        """Compile `pattern`.

        Args:
            pattern: The pattern source, at most `PATTERN_MAX_BYTES` bytes.

        Returns:
            The compiled pattern.

        Raises:
            If the pattern is empty, too long, or malformed: an unterminated
            class or escape, an empty class, a descending range, a quantifier
            with nothing to repeat, or an unsupported operator.
        """
        var b = pattern.as_bytes()
        var n = len(b)
        if n == 0:
            raise Error("Pattern.compile: the pattern is empty")
        if n > PATTERN_MAX_BYTES:
            raise Error(
                "Pattern.compile: the pattern is "
                + String(n)
                + " bytes, over the limit of "
                + String(PATTERN_MAX_BYTES)
            )
        var atoms = List[_Atom]()
        var i = 0
        while i < n:
            var c = Int(b[i])
            var members = _empty_set()
            if c == 0x2A or c == 0x2B or c == 0x3F:  # * + ?
                _refuse(pattern, i, "a quantifier with nothing to repeat")
            elif (
                c == 0x28
                or c == 0x29
                or c == 0x7C
                or c == 0x7B
                or c == 0x7D
                or c == 0x5E
                or c == 0x24
            ):  # ( ) | { } ^ $
                _refuse(
                    pattern,
                    i,
                    "an unsupported operator (escape it to match it literally)",
                )
            elif c == 0x2E:  # .
                _add_range(members, 0, 255)
                i += 1
            elif c == 0x5C:  # backslash
                if n - i < 2:
                    _refuse(pattern, i, "an escape with nothing after it")
                _add_escape(members, Int(b[i + 1]))
                i += 2
            elif c == 0x5B:  # [
                i += 1
                var negate = False
                if i < n and Int(b[i]) == 0x5E:
                    negate = True
                    i += 1
                var count = 0
                var closed = False
                while i < n:
                    var m = Int(b[i])
                    if m == 0x5D:  # ]
                        closed = True
                        i += 1
                        break
                    var lo = m
                    var is_class_escape = False
                    if m == 0x5C:
                        if n - i < 2:
                            _refuse(pattern, i, "an escape with nothing after it")
                        lo = Int(b[i + 1])
                        is_class_escape = lo == 0x64 or lo == 0x77
                        i += 2
                    else:
                        i += 1
                    if is_class_escape:
                        _add_escape(members, lo)
                        count += 1
                        continue
                    # `lo-hi` is a range unless the dash is the last byte.
                    if n - i >= 2 and Int(b[i]) == 0x2D and Int(b[i + 1]) != 0x5D:
                        var hi = Int(b[i + 1])
                        var skip = 2
                        if hi == 0x5C:
                            if n - i < 3:
                                _refuse(
                                    pattern, i, "an escape with nothing after it"
                                )
                            hi = Int(b[i + 2])
                            skip = 3
                        if hi < lo:
                            _refuse(pattern, i, "a descending range")
                        _add_range(members, lo, hi)
                        i += skip
                    else:
                        members[lo] = True
                    count += 1
                if not closed:
                    _refuse(pattern, n, "an unterminated class")
                if count == 0:
                    _refuse(pattern, n, "an empty class")
                if negate:
                    for k in range(256):
                        members[k] = not members[k]
            else:
                members[c] = True
                i += 1
            var quant = _Q_ONE
            if i < n:
                var q = Int(b[i])
                if q == 0x3F:
                    quant = _Q_OPTIONAL
                    i += 1
                elif q == 0x2A:
                    quant = _Q_STAR
                    i += 1
                elif q == 0x2B:
                    quant = _Q_PLUS
                    i += 1
            atoms.append(_Atom(members^, quant))
        return Pattern(atoms^)

    def num_atoms(self) -> Int:
        """The number of atoms in the compiled pattern."""
        return len(self._atoms)

    def _close(self, mut live: List[Bool]):
        """Let every live state that may match nothing also stand for the next.
        """
        for s in range(len(self._atoms)):
            if live[s]:
                var q = self._atoms[s].quant
                if q == _Q_OPTIONAL or q == _Q_STAR:
                    live[s + 1] = True

    def matches(self, token: String) -> Bool:
        """True iff the whole of `token` matches the pattern.

        Args:
            token: The token to test.

        Returns:
            Whether the token, from its first byte to its last, is matched.
        """
        var m = len(self._atoms)
        var live = List[Bool](capacity=m + 1)
        for _ in range(m + 1):
            live.append(False)
        live[0] = True
        self._close(live)
        var b = token.as_bytes()
        for k in range(len(b)):
            var c = Int(b[k])
            var next = List[Bool](capacity=m + 1)
            for _ in range(m + 1):
                next.append(False)
            for s in range(m):
                if live[s] and self._atoms[s].members[c]:
                    var q = self._atoms[s].quant
                    next[s + 1] = True
                    if q == _Q_STAR or q == _Q_PLUS:
                        next[s] = True
            self._close(next)
            live = next^
        return live[m]
