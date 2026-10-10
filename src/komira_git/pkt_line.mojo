# =============================================================================
# komira_git/pkt_line.mojo -- pkt-line framing (gitprotocol-common,
# gitprotocol-v2).
# =============================================================================
#
# A pkt-line is four lowercase hex digits giving the line's total length
# (the four digits included) followed by that many minus four payload bytes,
# at most 65516 of them. Three lengths are special packets with no payload:
# `0000` flush, `0001` delimiter (protocol v2) and `0002` response end
# (protocol v2). `0003` is never valid. `0004` is an empty data line, which
# senders should not write but receivers accept.
#
# The reader is sans-I/O: `read_pkt_line(data, offset)` decodes one
# pkt-line at `offset` and says how many bytes it took, or returns kind
# `PKT_NEED_MORE` (taking nothing) when `data` ends before the line does, so
# a caller can append more input and call again. The payload is returned as
# is; a trailing LF is not stripped.
# =============================================================================

from .bytes_util import _append_span, _hex_value, _to_list

comptime PKT_MAX_PAYLOAD: Int = 65516
"""The largest payload one pkt-line carries."""
comptime PKT_MAX_LENGTH: Int = 65520
"""The largest pkt-len (payload plus the four length digits)."""

comptime PKT_NEED_MORE: Int = -1
"""`read_pkt_line` needs more input to decode the next line."""
comptime PKT_FLUSH: Int = 0
"""`0000`, flush-pkt."""
comptime PKT_DELIM: Int = 1
"""`0001`, delim-pkt (protocol v2)."""
comptime PKT_RESPONSE_END: Int = 2
"""`0002`, response-end-pkt (protocol v2)."""
comptime PKT_DATA: Int = 3
"""A data line (pkt-len 4 or more)."""


struct PktLine(Copyable, Movable):
    """One decoded pkt-line: its kind (`PKT_*`), its payload (data lines
    only) and the input bytes it occupied (0 for `PKT_NEED_MORE`)."""

    var kind: Int
    var payload: List[UInt8]
    var consumed: Int

    def __init__(out self, kind: Int, var payload: List[UInt8], consumed: Int):
        self.kind = kind
        self.payload = payload^
        self.consumed = consumed


def _append_len(mut out: List[UInt8], n: Int):
    """Append `n` as four lowercase hex digits."""
    var shift = 12
    while shift >= 0:
        var v = (n >> shift) & 15
        out.append(UInt8(48 + v if v < 10 else 87 + v))
        shift -= 4


def append_pkt_data(mut out: List[UInt8], payload: Span[UInt8, _]) raises:
    """Append one data pkt-line carrying `payload` (at most
    `PKT_MAX_PAYLOAD` bytes; an empty payload writes `0004`)."""
    var n = len(payload)
    if n > PKT_MAX_PAYLOAD:
        raise Error(
            "komira_git: pkt-line: payload of " + String(n)
            + " bytes exceeds " + String(PKT_MAX_PAYLOAD)
        )
    _append_len(out, n + 4)
    _append_span(out, payload)


def append_pkt_text(mut out: List[UInt8], text: String) raises:
    """`append_pkt_data` over the bytes of `text` (no LF is added)."""
    append_pkt_data(out, text.as_bytes())


def append_pkt_flush(mut out: List[UInt8]):
    """Append `0000`."""
    _append_len(out, 0)


def append_pkt_delim(mut out: List[UInt8]):
    """Append `0001`."""
    _append_len(out, 1)


def append_pkt_response_end(mut out: List[UInt8]):
    """Append `0002`."""
    _append_len(out, 2)


def read_pkt_line(data: Span[UInt8, _], offset: Int) raises -> PktLine:
    """Decode the pkt-line at `data[offset:]`. Refuses a length that is not
    four hex digits (either case), the length 3, and a length above
    `PKT_MAX_LENGTH`."""
    var avail = len(data) - offset
    if avail < 4:
        return PktLine(PKT_NEED_MORE, List[UInt8](), 0)
    var n = 0
    for i in range(4):
        var v = _hex_value(Int(data[offset + i]))
        if v < 0:
            raise Error("komira_git: pkt-line: length is not four hex digits")
        n = n * 16 + v
    if n == 0:
        return PktLine(PKT_FLUSH, List[UInt8](), 4)
    if n == 1:
        return PktLine(PKT_DELIM, List[UInt8](), 4)
    if n == 2:
        return PktLine(PKT_RESPONSE_END, List[UInt8](), 4)
    if n == 3:
        raise Error("komira_git: pkt-line: bad length 3")
    if n > PKT_MAX_LENGTH:
        raise Error(
            "komira_git: pkt-line: length " + String(n) + " exceeds "
            + String(PKT_MAX_LENGTH)
        )
    if avail < n:
        return PktLine(PKT_NEED_MORE, List[UInt8](), 0)
    return PktLine(PKT_DATA, _to_list(data, offset + 4, offset + n), n)
