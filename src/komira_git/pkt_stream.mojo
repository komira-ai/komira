# =============================================================================
# komira_git/pkt_stream.mojo -- a pkt-line reader over input that arrives in
# pieces, and side-band framing (gitprotocol-pack, "side-band, side-band-64k";
# gitprotocol-v2, "packfile").
# =============================================================================
#
# `PktReader` buffers the bytes a caller feeds it and hands out one pkt-line
# at a time. The protocol state machines read a whole request or response
# section through it: they note `mark()`, read, and on `PKT_NEED_MORE`
# `rewind(mark)` so the same lines are read again once more input is fed.
#
# Side-band: each pkt-line's payload starts with a band byte, 1 for data, 2
# for progress text and 3 for a fatal error, and carries at most 65515 bytes
# after it (git's LARGE_PACKET_MAX of 65520 less the four length digits and
# the band byte).
# =============================================================================

from .bytes_util import _to_list
from .pkt_line import PktLine, _append_len, read_pkt_line

comptime SIDEBAND_DATA: Int = 1
"""Band 1: the packfile, or the report a receive-pack server sends."""
comptime SIDEBAND_PROGRESS: Int = 2
"""Band 2: progress and messages for the user."""
comptime SIDEBAND_ERROR: Int = 3
"""Band 3: a fatal error; the sender stops."""
comptime SIDEBAND_MAX_CHUNK: Int = 65515
"""The most bytes one side-band pkt-line carries after its band byte."""


def append_sideband(mut out: List[UInt8], band: Int, data: Span[UInt8, _]) raises:
    """Append `data` on side-band `band` (1, 2 or 3), split into pkt-lines of
    at most `SIDEBAND_MAX_CHUNK` bytes each. Empty `data` appends nothing."""
    if band < SIDEBAND_DATA or band > SIDEBAND_ERROR:
        raise Error(
            "komira_git: side-band: band " + String(band) + " is not 1, 2 or 3"
        )
    var n = len(data)
    var pos = 0
    while pos < n:
        var k = n - pos
        if k > SIDEBAND_MAX_CHUNK:
            k = SIDEBAND_MAX_CHUNK
        _append_len(out, k + 5)
        out.append(UInt8(band))
        for i in range(pos, pos + k):
            out.append(data[i])
        pos += k


struct PktReader(Movable):
    """The bytes fed so far and the offset of the next pkt-line in them."""

    var _buf: List[UInt8]
    var _pos: Int

    def __init__(out self):
        self._buf = List[UInt8]()
        self._pos = 0

    def feed(mut self, data: Span[UInt8, _]):
        """Append `data` to the unread input."""
        if self._pos > 0 and self._pos == len(self._buf):
            self._buf.clear()
            self._pos = 0
        elif self._pos >= 65536:
            var rest = _to_list(Span(self._buf), self._pos, len(self._buf))
            self._buf = rest^
            self._pos = 0
        for i in range(len(data)):
            self._buf.append(data[i])

    def read(mut self) raises -> PktLine:
        """The next pkt-line, consumed; kind `PKT_NEED_MORE` (nothing
        consumed) when the input ends before it does."""
        var line = read_pkt_line(Span(self._buf), self._pos)
        self._pos += line.consumed
        return line^

    def mark(self) -> Int:
        """A position `rewind` can return to (valid until the next `feed`)."""
        return self._pos

    def rewind(mut self, mark: Int):
        """Unread everything read since `mark`."""
        self._pos = mark

    def buffered(self) -> Int:
        """How many fed bytes are not read yet."""
        return len(self._buf) - self._pos

    def take_buffered(mut self) -> List[UInt8]:
        """The fed bytes not read yet, which the reader then forgets (the
        packfile after a push's commands is not pkt-lines)."""
        var rest = _to_list(Span(self._buf), self._pos, len(self._buf))
        self._buf.clear()
        self._pos = 0
        return rest^


def _utf8(b: Span[UInt8, _], start: Int, end: Int, what: String) raises -> String:
    """`b[start:end]` as text; `what` names the line in the refusal."""
    var tmp = _to_list(b, start, end)
    try:
        return String(StringSlice(from_utf8=Span(tmp)))
    except e:
        raise Error("komira_git: " + what + ": line is not UTF-8")


def _pkt_text(line: PktLine, what: String) raises -> String:
    """A data line's payload as text, without one trailing LF (git reads
    protocol lines with PACKET_READ_CHOMP_NEWLINE)."""
    var n = len(line.payload)
    if n > 0 and line.payload[n - 1] == 10:
        n -= 1
    return _utf8(Span(line.payload), 0, n, what)
