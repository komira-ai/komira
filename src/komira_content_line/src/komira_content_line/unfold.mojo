# =============================================================================
# unfold.mojo -- physical lines to logical content lines (RFC 6350 §3.2,
# RFC 5545 §3.1), with input limits and UTF-8 validation.
# =============================================================================
#
# A physical line ends at CRLF or at a bare LF (a trailing CR before the LF is
# removed). A physical line that starts with SPACE or HTAB continues the
# logical line before it: that one white-space octet is removed and the rest
# is appended. The joining is done on octets, so a fold that falls inside a
# multi-octet UTF-8 sequence is restored before the line is validated (RFC
# 6350 §3.2, the note on improperly folded lines).
#
# Only CRLF (or LF) followed by SPACE or HTAB is a fold (RFC 6350 §3.2,
# RFC 5545 §3.1), so an empty physical line ends the logical line before it.
# The empty line starts a logical line of its own: a white-space line right
# after it continues that empty line, not the line before the blank, and the
# logical line's number is the blank line's. An empty logical line (a blank
# no fold follows, a blank whose continuations are only white space, or the
# end of input) is skipped together with its folds. So the physical lines of
# one logical line are always consecutive: it spans `line_number` to
# `line_number + len(folds)`, and a first fold at offset 0 means it began
# with an empty line.
#
# Every join is recorded in `LogicalLine.folds`: the octet offset
# in `text` where the continuation's octets start, and the white-space octet
# that was removed. A reader whose own rules join a line differently (vCard
# 2.1 quoted-printable soft breaks, where that octet is data) rebuilds the
# physical lines from them.
#
# Limits: the whole input and every logical line are bounded in octets
# (`ContentLimits`); the line bound is checked while the line grows, so an
# over-long line is refused before it is copied whole. Each logical line is
# validated as UTF-8 after it is joined.
# =============================================================================

from .utf8 import utf8_invalid_at


comptime DEFAULT_MAX_INPUT_OCTETS: Int = 64 * 1024 * 1024
comptime DEFAULT_MAX_LINE_OCTETS: Int = 1024 * 1024


struct ContentLimits(Copyable, Movable):
    """Upper bounds on an input and on each unfolded line, in octets."""

    var max_input_octets: Int
    var max_line_octets: Int

    def __init__(
        out self,
        *,
        max_input_octets: Int = DEFAULT_MAX_INPUT_OCTETS,
        max_line_octets: Int = DEFAULT_MAX_LINE_OCTETS,
    ):
        self.max_input_octets = max_input_octets
        self.max_line_octets = max_line_octets


struct Fold(Copyable, Movable):
    """One join: the octet offset in the unfolded text where the
    continuation line's octets start, and the white-space octet removed."""

    var at: Int
    var removed: UInt8

    def __init__(out self, at: Int, removed: UInt8):
        self.at = at
        self.removed = removed


struct LogicalLine(Copyable, Movable):
    """One unfolded line, the 1-based physical line it starts on, and where
    it was joined (in increasing `at` order)."""

    var text: String
    var line_number: Int
    var folds: List[Fold]

    def __init__(
        out self,
        var text: String,
        line_number: Int,
        var folds: List[Fold] = List[Fold](),
    ):
        self.text = text^
        self.line_number = line_number
        self.folds = folds^


def _finish(
    mut out: List[LogicalLine],
    mut buf: List[UInt8],
    mut folds: List[Fold],
    start_line: Int,
) raises:
    if len(buf) == 0:
        # An empty logical line is skipped, and so are its folds (a blank
        # line's white-space-only continuations): they belong to no line.
        folds = List[Fold]()
        return
    var bad = utf8_invalid_at(Span(buf))
    if bad >= 0:
        raise Error(
            String("content line: line ")
            + String(start_line)
            + String(" is not valid UTF-8 (octet ")
            + String(bad)
            + String(" of the unfolded line)")
        )
    out.append(
        LogicalLine(
            String(StringSlice(from_utf8=Span(buf))), start_line, folds^
        )
    )
    buf.clear()
    folds = List[Fold]()


def _too_long(start_line: Int, limit: Int) -> Error:
    return Error(
        String("content line: line ")
        + String(start_line)
        + String(" is longer than the ")
        + String(limit)
        + String("-octet limit")
    )


def unfold(
    data: Span[UInt8, _], limits: ContentLimits = ContentLimits()
) raises -> List[LogicalLine]:
    """Split `data` into unfolded logical lines (file header)."""
    var n = len(data)
    if n > limits.max_input_octets:
        raise Error(
            String("content line: input is ")
            + String(n)
            + String(" octets; the limit is ")
            + String(limits.max_input_octets)
        )
    var out = List[LogicalLine]()
    var buf = List[UInt8]()
    var folds = List[Fold]()
    var start_line = 0
    var line_no = 0
    var i = 0
    while i < n:
        line_no += 1
        # [i, end) is one physical line without its terminator.
        var end = i
        while end < n and data[end] != 10:
            end += 1
        var next = end + 1 if end < n else n
        if end > i and data[end - 1] == 13:
            end -= 1
        if end > i:
            var c = data[i]
            var from_ = i
            if c == 32 or c == 9:
                if start_line == 0:
                    raise Error(
                        String("content line: line ")
                        + String(line_no)
                        + String(" starts with white space and continues no line")
                    )
                from_ = i + 1
                folds.append(Fold(len(buf), c))
            else:
                _finish(out, buf, folds, start_line)
                start_line = line_no
            if len(buf) + (end - from_) > limits.max_line_octets:
                raise _too_long(start_line, limits.max_line_octets)
            for k in range(from_, end):
                buf.append(data[k])
        else:
            # An empty line: the CRLF before it was not a fold.
            _finish(out, buf, folds, start_line)
            start_line = line_no
        i = next
    _finish(out, buf, folds, start_line)
    return out^
