# =============================================================================
# komira_git/signature.mojo -- identity lines and the header block shared by
# commits and tags.
# =============================================================================
#
# A signature (git calls it an ident) is the value of an `author`,
# `committer` or `tagger` header:
#
#     <name> SP '<' <email> '>' SP <seconds since the epoch> SP <+|-><hhmm>
#
# `parse_signature` refuses what `git fsck` reports for an ident (the
# messages name fsck's rule): a line starting with '<'
# (missingNameBeforeEmail), a '>' before the first '<' (badName), no '<',
# which includes an empty line (missingEmail), no space before '<'
# (missingSpaceBeforeEmail), a '<' or no '>' after the e-mail (badEmail),
# no space after '>' (missingSpaceBeforeDate), a date starting with '0'
# and not followed by a space (zeroPaddedDate), a date above 2^63-1
# (badDateOverflow: fsck's rule is by value, and this is where a 64-bit
# time_t ends), a non-number date (badDate) and a time zone that is not a
# sign and four digits ending the line (badTimezone).
#
# It also refuses one form git accepts, so that an accepted signature
# serializes back to its own bytes: more than one space, or a tab, between
# '>' and the date (fsck skips them; current git writes one space).
#
# The header block of a commit or tag ends at the first empty line. Headers
# after the fixed ones are kept as `ExtraHeader`s in order: `key SP value`,
# where a value spanning several lines continues on lines that start with
# one space (a `gpgsig` signature is the usual case). The space is not part
# of the value; the line break is.
# =============================================================================

from .bytes_util import (
    _append_decimal,
    _append_span,
    _append_str,
    _find_byte,
    _is_digit,
    _to_list,
)
from .object_id import ObjectFormat, ObjectId

comptime _B_TAB: Int = 9
comptime _B_LF: Int = 10
comptime _B_SPACE: Int = 32
comptime _B_PLUS: Int = 43
comptime _B_0: Int = 48
comptime _B_MINUS: Int = 45
comptime _B_LT: Int = 60
comptime _B_GT: Int = 62


def _check_tz(tz: Span[UInt8, _]) -> Bool:
    """A sign then exactly four digits."""
    if len(tz) != 5:
        return False
    var s = Int(tz[0])
    if s != _B_PLUS and s != _B_MINUS:
        return False
    for i in range(1, 5):
        if not _is_digit(Int(tz[i])):
            return False
    return True


struct Signature(Copyable, Movable):
    """An `author`, `committer` or `tagger` value: name and e-mail (bytes),
    seconds since the epoch, and the time zone as written (`+0000`,
    `-0700`)."""

    var name: List[UInt8]
    var email: List[UInt8]
    var time: Int
    var tz: String

    def __init__(
        out self, name: String, email: String, time: Int, tz: String
    ) raises:
        """A signature from text. Refuses a name or e-mail holding '<', '>',
        a line break or NUL, a negative time, and a time zone that is not a
        sign and four digits."""
        _check_ident_text(name.as_bytes(), "name")
        _check_ident_text(email.as_bytes(), "email")
        if time < 0:
            raise Error("komira_git: signature time is negative")
        if not _check_tz(tz.as_bytes()):
            raise Error("komira_git: signature time zone '" + tz + "' is not +hhmm or -hhmm")
        self.name = List[UInt8](name.as_bytes())
        self.email = List[UInt8](email.as_bytes())
        self.time = time
        self.tz = tz

    def __init__(
        out self,
        *,
        var _name: List[UInt8],
        var _email: List[UInt8],
        _time: Int,
        var _tz: String,
    ):
        """The parser's constructor: the fields are already checked."""
        self.name = _name^
        self.email = _email^
        self.time = _time
        self.tz = _tz^

    def append_to(self, mut out: List[UInt8]):
        """Append `<name> <<email>> <time> <tz>` (no line break)."""
        _append_span(out, Span(self.name))
        _append_str(out, " <")
        _append_span(out, Span(self.email))
        _append_str(out, "> ")
        _append_decimal(out, self.time)
        out.append(UInt8(_B_SPACE))
        _append_str(out, self.tz)

    def serialize(self) -> List[UInt8]:
        """The signature as a header value (no line break)."""
        var out = List[UInt8]()
        self.append_to(out)
        return out^


def _check_ident_text(s: Span[UInt8, _], what: String) raises:
    for i in range(len(s)):
        var c = Int(s[i])
        if c == _B_LT or c == _B_GT or c == _B_LF or c == 0:
            raise Error(
                "komira_git: signature " + what
                + " holds '<', '>', a line break or NUL"
            )


def _find_angle(s: Span[UInt8, _], start: Int) -> Int:
    """The first '<' or '>' at or after `start`, or -1."""
    for i in range(start, len(s)):
        var c = Int(s[i])
        if c == _B_LT or c == _B_GT:
            return i
    return -1


comptime _DATE_MAX = "9223372036854775807"


def _date_overflows(line: Span[UInt8, _], d: Int, e: Int) -> Bool:
    """True when the digits `line[d:e]` (no leading zero) are above 2^63-1,
    the largest date that fits an Int."""
    var m = _DATE_MAX.as_bytes()
    if e - d != len(m):
        return e - d > len(m)
    for i in range(len(m)):
        if line[d + i] != m[i]:
            return line[d + i] > m[i]
    return False


def parse_signature(line: Span[UInt8, _], what: String) raises -> Signature:
    """Parse an ident value (no line break). `what` names the header in a
    refusal: `komira_git: <what>: <rule>`."""
    var pre = "komira_git: " + what + ": "
    var n = len(line)
    if n > 0 and Int(line[0]) == _B_LT:
        raise Error(pre + "missing name before email")
    var lt = _find_angle(line, 0)
    if lt < 0:
        raise Error(pre + "missing email")
    if Int(line[lt]) == _B_GT:
        raise Error(pre + "bad name")
    if Int(line[lt - 1]) != _B_SPACE:
        raise Error(pre + "missing space before email")
    var gt = _find_angle(line, lt + 1)
    if gt < 0 or Int(line[gt]) == _B_LT:
        raise Error(pre + "bad email")
    if gt + 1 >= n or Int(line[gt + 1]) != _B_SPACE:
        raise Error(pre + "missing space before date")
    var d = gt + 2
    if d < n and (Int(line[d]) == _B_SPACE or Int(line[d]) == _B_TAB):
        raise Error(pre + "extra whitespace before date")
    if d >= n or not _is_digit(Int(line[d])):
        raise Error(pre + "bad date")
    if Int(line[d]) == _B_0 and (d + 1 >= n or Int(line[d + 1]) != _B_SPACE):
        raise Error(pre + "zero-padded date")
    var e = d
    while e < n and _is_digit(Int(line[e])):
        e += 1
    if _date_overflows(line, d, e):
        raise Error(pre + "date overflows")
    if e >= n or Int(line[e]) != _B_SPACE:
        raise Error(pre + "bad date")
    var time = 0
    for i in range(d, e):
        time = time * 10 + (Int(line[i]) - _B_0)
    if not _check_tz(line[e + 1 : n]):
        raise Error(pre + "bad timezone")
    var tz = String()
    for i in range(e + 1, n):
        tz += chr(Int(line[i]))
    return Signature(
        _name=_to_list(line, 0, lt - 1),
        _email=_to_list(line, lt + 1, gt),
        _time=time,
        _tz=tz^,
    )


struct ExtraHeader(Copyable, Movable):
    """A header after the fixed ones (`encoding`, `gpgsig`, `mergetag`,
    ...): its key and its value, the value's lines joined by line breaks."""

    var key: List[UInt8]
    var value: List[UInt8]

    def __init__(out self, key: String, value: String) raises:
        """A header from text. Refuses an empty key, a key holding a space,
        a line break or NUL, and a value holding NUL."""
        self.key = List[UInt8](key.as_bytes())
        self.value = List[UInt8](value.as_bytes())
        _check_extra_header(Span(self.key), Span(self.value))

    def __init__(out self, *, var _key: List[UInt8], var _value: List[UInt8]):
        """The parser's constructor: the fields are already checked."""
        self.key = _key^
        self.value = _value^

    def append_to(self, mut out: List[UInt8]):
        """Append `key SP value LF`, each line break inside the value
        followed by the one-space continuation marker."""
        _append_span(out, Span(self.key))
        out.append(UInt8(_B_SPACE))
        for i in range(len(self.value)):
            out.append(self.value[i])
            if Int(self.value[i]) == _B_LF:
                out.append(UInt8(_B_SPACE))
        out.append(UInt8(_B_LF))


def _check_extra_header(key: Span[UInt8, _], value: Span[UInt8, _]) raises:
    if len(key) == 0:
        raise Error("komira_git: header key is empty")
    for i in range(len(key)):
        var c = Int(key[i])
        if c == _B_SPACE or c == _B_LF or c == 0:
            raise Error("komira_git: header key holds a space, line break or NUL")
    for i in range(len(value)):
        if Int(value[i]) == 0:
            raise Error("komira_git: header value holds NUL")


def _header_end(payload: Span[UInt8, _], what: String) raises -> Int:
    """The index of the empty line ending the header block (the second '\\n'
    of the first "\\n\\n"). Refuses a NUL in the block and a block with no
    empty line after it."""
    var n = len(payload)
    for i in range(n):
        var c = Int(payload[i])
        if c == 0:
            raise Error("komira_git: " + what + ": NUL in header")
        if c == _B_LF and i + 1 < n and Int(payload[i + 1]) == _B_LF:
            return i + 1
    raise Error("komira_git: " + what + ": no empty line after the header")


def _line_end(payload: Span[UInt8, _], pos: Int) -> Int:
    """The index of the '\\n' ending the line at `pos` (the header block
    always ends in one)."""
    return _find_byte(payload, pos, _B_LF)


def _parse_header_id(
    format: ObjectFormat,
    payload: Span[UInt8, _],
    start: Int,
    end: Int,
    pre: String,
) raises -> ObjectId:
    """The id spelled by `payload[start:end]`: exactly the format's number of
    lowercase hex digits (git writes no other spelling)."""
    if end - start != format.hex_size():
        raise Error(pre)
    for i in range(start, end):
        var c = Int(payload[i])
        if not (_is_digit(c) or (c >= 97 and c <= 102)):
            raise Error(pre)
    return ObjectId._from_hex_span(format, payload, start)


def _parse_extra_headers(
    payload: Span[UInt8, _], start: Int, hend: Int, what: String
) raises -> List[ExtraHeader]:
    """The headers from `start` to the empty line at `hend`."""
    var out = List[ExtraHeader]()
    var pos = start
    while pos < hend:
        var e = _line_end(payload, pos)
        if Int(payload[pos]) == _B_SPACE:
            raise Error(
                "komira_git: " + what + ": continuation line without a header"
            )
        var sp = _find_byte(payload[pos:e], 0, _B_SPACE)
        if sp < 0:
            raise Error("komira_git: " + what + ": header line without a space")
        var key = _to_list(payload, pos, pos + sp)
        var value = _to_list(payload, pos + sp + 1, e)
        pos = e + 1
        while pos < hend and Int(payload[pos]) == _B_SPACE:
            var ce = _line_end(payload, pos)
            value.append(UInt8(_B_LF))
            for i in range(pos + 1, ce):
                value.append(payload[i])
            pos = ce + 1
        out.append(ExtraHeader(_key=key^, _value=value^))
    return out^
