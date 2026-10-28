# The SEARCH command line (RFC 3501 section 6.4.4) as a tree of nodes.
#
# The arguments are tokenised (atoms, quoted strings, parentheses), then read
# by a recursive-descent parser into an arena of `SNode`s. The parser is
# bounded: at most `MAX_NODES` nodes and `MAX_DEPTH` levels of parentheses,
# NOT and OR, so a line cannot make the evaluator recurse deeply or build a
# huge tree; anything malformed (an unknown key, a missing argument, an
# unbalanced parenthesis, a bad date or number, an unterminated string) makes
# `ok` False and the caller answers BAD.
#
# Keys, with what this server does where IMAP leaves room:
# - ALL, SEEN, UNSEEN, ANSWERED, UNANSWERED, FLAGGED, UNFLAGGED, DELETED,
#   UNDELETED, DRAFT, UNDRAFT: the durable flags of the message.
# - RECENT, NEW and OLD: this server keeps no \Recent flag (SELECT says RECENT
#   0 and it is never set), so RECENT matches nothing, NEW (RECENT and UNSEEN)
#   matches nothing, and OLD (NOT RECENT) matches every message.
# - KEYWORD word matches nothing and UNKEYWORD word matches everything: no
#   keyword can be stored.
# - FROM, TO, CC, BCC, SUBJECT, HEADER field string: the string is a
#   case-insensitive ASCII substring of the field's value, as written or with
#   its RFC 2047 encoded words decoded; HEADER with an empty string matches a
#   message that has the field.
# - BODY string, TEXT string: a case-insensitive ASCII substring of the stored
#   bytes after the header block (BODY) or of all of them (TEXT). Nothing is
#   decoded: a body in base64 or quoted-printable is searched as written, and
#   the search string is ASCII (a command line is 7-bit text).
# - BEFORE, ON, SINCE (INTERNALDATE) and SENTBEFORE, SENTON, SENTSINCE (the
#   `Date` field): a date `d-Mon-yyyy`, compared as UTC calendar days.
# - LARGER n, SMALLER n: the size in bytes of the stored message.
# - a sequence set, UID set, NOT key, OR key key, and a parenthesised list of
#   keys (all of them must match). The keys of the command are all required.
#
# Each node knows whether it reads the message (`content`: a header field, a
# body, a date), so evaluation can decide cheap keys first and read a message
# only when they leave it undecided.

from .dates import parse_search_date
from .headers import lower_bytes
from .parse import upper_ascii
from .flags import (
    FLAG_ANSWERED,
    FLAG_DELETED,
    FLAG_DRAFT,
    FLAG_FLAGGED,
    FLAG_SEEN,
)
from .sets import parse_id_set

comptime N_TRUE: Int = 0
comptime N_FALSE: Int = 1
comptime N_FLAG: Int = 2
comptime N_SEQ: Int = 3
comptime N_UID: Int = 4
comptime N_LARGER: Int = 5
comptime N_SMALLER: Int = 6
comptime N_NOT: Int = 7
comptime N_OR: Int = 8
comptime N_AND: Int = 9
comptime N_HEADER: Int = 10
comptime N_BODY: Int = 11
comptime N_TEXT: Int = 12
comptime N_IDATE: Int = 13
comptime N_SDATE: Int = 14

# Date comparisons, in `SNode.a`.
comptime D_BEFORE: Int = 0
comptime D_ON: Int = 1
comptime D_SINCE: Int = 2

comptime MAX_NODES: Int = 256
comptime MAX_DEPTH: Int = 24

comptime T_ATOM: Int = 0
comptime T_STR: Int = 1
comptime T_LP: Int = 2
comptime T_RP: Int = 3


struct Tok(Copyable, Movable):
    var kind: Int
    var text: String

    def __init__(out self, kind: Int, var text: String):
        self.kind = kind
        self.text = text^


def tokenize(args: String) -> Optional[List[Tok]]:
    """The tokens of a SEARCH argument string, or None when a quoted string
    is not closed or has a backslash that does not quote a `"` or `\\`, or
    when a token runs into the next with no space."""
    var out = List[Tok]()
    var b = args.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var c = b[i]
        if c == 0x20:
            i += 1
        elif c == 0x28:
            out.append(Tok(T_LP, String("(")))
            i += 1
        elif c == 0x29:
            out.append(Tok(T_RP, String(")")))
            i += 1
        elif c == 0x22:
            i += 1
            var buf = List[UInt8]()
            var closed = False
            while i < n:
                if b[i] == 0x22:
                    closed = True
                    i += 1
                    break
                if b[i] == 0x5C:
                    if i + 1 >= n or (b[i + 1] != 0x22 and b[i + 1] != 0x5C):
                        return None
                    i += 1
                buf.append(b[i])
                i += 1
            if not closed:
                return None
            if i < n and b[i] != 0x20 and b[i] != 0x29:
                return None
            out.append(Tok(T_STR, String(unsafe_from_utf8=Span(buf))))
        else:
            var start = i
            while i < n and b[i] != 0x20 and b[i] != 0x28 and b[i] != 0x29 and b[i] != 0x22:
                i += 1
            if i < n and b[i] == 0x22:
                return None
            out.append(Tok(T_ATOM, String(unsafe_from_utf8=b[start:i])))
    return out^


struct SNode(Copyable, Movable):
    """One node of the search tree; see the module header. `a` and `b` are
    what the kind needs (a flag bit and whether it must be set, a number, a
    date comparison and a day), `needle` the lower-case string with its
    failure table `fail`, `name` a lower-case header field name, `kids` the
    children, `los` and `his` the ranges of a set."""

    var kind: Int
    var a: Int
    var b: Int
    var content: Bool
    var needle: List[UInt8]
    var fail: List[Int]
    var name: String
    var kids: List[Int]
    var los: List[Int]
    var his: List[Int]

    def __init__(out self, kind: Int):
        self.kind = kind
        self.a = 0
        self.b = 0
        self.content = False
        self.needle = List[UInt8]()
        self.fail = List[Int]()
        self.name = String("")
        self.kids = List[Int]()
        self.los = List[Int]()
        self.his = List[Int]()


def failure_table(needle: List[UInt8]) -> List[Int]:
    """The Knuth-Morris-Pratt failure table of `needle`."""
    var fail = List[Int](capacity=len(needle))
    for _ in range(len(needle)):
        fail.append(0)
    var k = 0
    for i in range(1, len(needle)):
        while k > 0 and needle[i] != needle[k]:
            k = fail[k - 1]
        if needle[i] == needle[k]:
            k += 1
        fail[i] = k
    return fail^


def _is_set_text(text: String) -> Bool:
    var b = text.as_bytes()
    if len(b) == 0:
        return False
    if not ((b[0] >= 0x30 and b[0] <= 0x39) or b[0] == 0x2A):
        return False
    for i in range(len(b)):
        var c = b[i]
        if not ((c >= 0x30 and c <= 0x39) or c == 0x2A or c == 0x3A or c == 0x2C):
            return False
    return True


def _number(text: String) -> Int:
    """A number of 1 to 10 digits, else -1."""
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 10:
        return -1
    var v = 0
    for i in range(len(b)):
        if b[i] < 0x30 or b[i] > 0x39:
            return -1
        v = v * 10 + Int(b[i] - 0x30)
    return v


struct SearchParser(Movable):
    var toks: List[Tok]
    var pos: Int
    var nodes: List[SNode]
    var ok: Bool
    var seq_star: Int
    var uid_star: Int
    var uses_flags: Bool
    var uses_content: Bool

    def __init__(
        out self, var toks: List[Tok], start: Int, seq_star: Int, uid_star: Int
    ):
        self.toks = toks^
        self.pos = start
        self.nodes = List[SNode]()
        self.ok = True
        self.seq_star = seq_star
        self.uid_star = uid_star
        self.uses_flags = False
        self.uses_content = False

    def _add(mut self, var node: SNode) -> Int:
        if len(self.nodes) >= MAX_NODES:
            self.ok = False
            return 0
        if node.content:
            self.uses_content = True
        self.nodes.append(node^)
        return len(self.nodes) - 1

    def _fail(mut self) -> Int:
        self.ok = False
        return 0

    def _string(mut self) -> String:
        """The next token as a string argument (an atom or a quoted string)."""
        if self.pos >= len(self.toks):
            self.ok = False
            return String("")
        var t = self.toks[self.pos].copy()
        if t.kind != T_ATOM and t.kind != T_STR:
            self.ok = False
            return String("")
        self.pos += 1
        return t.text

    def _group(mut self, var kids: List[Int], content: Bool) -> Int:
        var node = SNode(N_AND)
        node.kids = kids^
        node.content = content
        return self._add(node^)

    def parse_all(mut self) -> Int:
        """Every remaining token is a key, all required: the root node."""
        var kids = List[Int]()
        var content = False
        while self.ok and self.pos < len(self.toks):
            var k = self.parse_key(0)
            if not self.ok:
                break
            kids.append(k)
            if self.nodes[k].content:
                content = True
        if len(kids) == 0:
            self.ok = False
        if not self.ok:
            return 0
        return self._group(kids^, content)

    def _flag(mut self, bit: UInt8, want: Bool) -> Int:
        var node = SNode(N_FLAG)
        node.a = Int(bit)
        node.b = 1 if want else 0
        self.uses_flags = True
        return self._add(node^)

    def _header(mut self, name: String, needle: String) -> Int:
        var node = SNode(N_HEADER)
        node.name = name
        node.needle = lower_bytes(needle.as_bytes())
        node.fail = failure_table(node.needle)
        node.content = True
        return self._add(node^)

    def _text(mut self, kind: Int, needle: String) -> Int:
        var node = SNode(kind)
        node.needle = lower_bytes(needle.as_bytes())
        node.fail = failure_table(node.needle)
        node.content = True
        return self._add(node^)

    def _date(mut self, kind: Int, cmp: Int) -> Int:
        var text = self._string()
        if not self.ok:
            return 0
        var day = parse_search_date(text)
        if not day:
            return self._fail()
        var node = SNode(kind)
        node.a = cmp
        node.b = day.value()
        node.content = True
        return self._add(node^)

    def _set(mut self, kind: Int, text: String, star: Int) -> Int:
        var ids = parse_id_set(text, star)
        if not ids.ok:
            return self._fail()
        var node = SNode(kind)
        node.los = ids.los.copy()
        node.his = ids.his.copy()
        return self._add(node^)

    def parse_key(mut self, depth: Int) -> Int:
        """One key, as a node index. Sets `ok` False on anything malformed."""
        if depth > MAX_DEPTH or self.pos >= len(self.toks):
            return self._fail()
        var t = self.toks[self.pos].copy()
        self.pos += 1
        if t.kind == T_LP:
            var kids = List[Int]()
            var content = False
            while self.ok:
                if self.pos >= len(self.toks):
                    return self._fail()
                if self.toks[self.pos].kind == T_RP:
                    self.pos += 1
                    break
                var k = self.parse_key(depth + 1)
                if not self.ok:
                    return 0
                kids.append(k)
                if self.nodes[k].content:
                    content = True
            if len(kids) == 0:
                return self._fail()
            return self._group(kids^, content)
        if t.kind != T_ATOM:
            return self._fail()
        var w = upper_ascii(t.text)
        if w == "ALL":
            return self._add(SNode(N_TRUE))
        if w == "SEEN":
            return self._flag(FLAG_SEEN, True)
        if w == "UNSEEN":
            return self._flag(FLAG_SEEN, False)
        if w == "ANSWERED":
            return self._flag(FLAG_ANSWERED, True)
        if w == "UNANSWERED":
            return self._flag(FLAG_ANSWERED, False)
        if w == "FLAGGED":
            return self._flag(FLAG_FLAGGED, True)
        if w == "UNFLAGGED":
            return self._flag(FLAG_FLAGGED, False)
        if w == "DELETED":
            return self._flag(FLAG_DELETED, True)
        if w == "UNDELETED":
            return self._flag(FLAG_DELETED, False)
        if w == "DRAFT":
            return self._flag(FLAG_DRAFT, True)
        if w == "UNDRAFT":
            return self._flag(FLAG_DRAFT, False)
        if w == "RECENT" or w == "NEW":
            return self._add(SNode(N_FALSE))
        if w == "OLD":
            return self._add(SNode(N_TRUE))
        if w == "KEYWORD" or w == "UNKEYWORD":
            _ = self._string()
            if not self.ok:
                return 0
            return self._add(SNode(N_FALSE if w == "KEYWORD" else N_TRUE))
        if w == "FROM" or w == "TO" or w == "CC" or w == "BCC" or w == "SUBJECT":
            var s = self._string()
            if not self.ok:
                return 0
            return self._header(w.lower(), s)
        if w == "HEADER":
            var field = self._string()
            var s = self._string()
            if not self.ok or field.byte_length() == 0:
                return self._fail()
            var fb = field.as_bytes()
            for i in range(len(fb)):
                if fb[i] <= 0x20 or fb[i] == 0x3A:
                    return self._fail()
            return self._header(field.lower(), s)
        if w == "BODY":
            var s = self._string()
            if not self.ok:
                return 0
            return self._text(N_BODY, s)
        if w == "TEXT":
            var s = self._string()
            if not self.ok:
                return 0
            return self._text(N_TEXT, s)
        if w == "BEFORE":
            return self._date(N_IDATE, D_BEFORE)
        if w == "ON":
            return self._date(N_IDATE, D_ON)
        if w == "SINCE":
            return self._date(N_IDATE, D_SINCE)
        if w == "SENTBEFORE":
            return self._date(N_SDATE, D_BEFORE)
        if w == "SENTON":
            return self._date(N_SDATE, D_ON)
        if w == "SENTSINCE":
            return self._date(N_SDATE, D_SINCE)
        if w == "LARGER" or w == "SMALLER":
            var s = self._string()
            if not self.ok:
                return 0
            var v = _number(s)
            if v < 0:
                return self._fail()
            var node = SNode(N_LARGER if w == "LARGER" else N_SMALLER)
            node.a = v
            return self._add(node^)
        if w == "UID":
            var s = self._string()
            if not self.ok:
                return 0
            return self._set(N_UID, s, self.uid_star)
        if w == "NOT":
            var k = self.parse_key(depth + 1)
            if not self.ok:
                return 0
            var node = SNode(N_NOT)
            node.kids.append(k)
            node.content = self.nodes[k].content
            return self._add(node^)
        if w == "OR":
            var x = self.parse_key(depth + 1)
            if not self.ok:
                return 0
            var y = self.parse_key(depth + 1)
            if not self.ok:
                return 0
            var node = SNode(N_OR)
            node.kids.append(x)
            node.kids.append(y)
            node.content = self.nodes[x].content or self.nodes[y].content
            return self._add(node^)
        if _is_set_text(t.text):
            return self._set(N_SEQ, t.text, self.seq_star)
        return self._fail()
