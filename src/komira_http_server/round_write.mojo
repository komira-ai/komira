# =============================================================================
# src/komira_http_server/round_write.mojo — write helpers of the h1 rounds
# =============================================================================
#
# Moved out of accept_loop.mojo (§4 there) unchanged; the canned rounds in
# accept_loop.mojo and the dispatch rounds in dispatch.mojo both use them:
#   * _write_all_or_buffer  — write a response; park the unsent tail on
#                             EWOULDBLOCK for resume_pending_write.
#   * _park_behind          — queue a response behind a parked tail.
#   * _write_last           — write the conn's last response (an error).
#   * _park_rest / _take_carry — keep the requests read after a parked
#                             response for the round after the resume.
#   * carry_or_refuse_head  — keep a partial request head for the next
#                             read, or answer 431 when it cannot complete.
# =============================================================================

from komira_async.reactor.socket_io import (
    try_io_write,
)
from komira_http_core.codec.h1.parser import build_error_response_bytes
from komira_http_server.connection import (
    CONN_STATE_WAITING_FOR_WRITABLE,
    ConnEntry,
    REQ_BUF_BYTES,
)


# =============================================================================
# §4 — Write-with-EWOULDBLOCK helper.
# =============================================================================


@always_inline
def _write_all_or_buffer(
    mut entry: ConnEntry,
    src: List[UInt8],
    mut bytes_sent: Int64,
) -> Int:
    """Try to write the bytes from `src` to entry._fd. On EWOULDBLOCK,
    buffer the tail into entry._pending_buf and transition state.

    Returns:
      0  — fully written.
      1  — partial write; pending state set; caller should return True.
     -1  — hard error; caller should close.
    """
    var fd = entry._fd
    var n = len(src)
    var sent_off = 0
    while sent_off < n:
        # Build a Span over the unsent tail via stdlib slice.
        # No raw pointer arithmetic in the public-callable surface;
        # the slice's origin is bound to `src` which is borrowed for
        # the duration of this call.
        var full = Span[UInt8](src)
        var tail_span = full[sent_off:n]
        var wr = try_io_write(fd, tail_span)
        if wr.is_would_block():
            # Kernel send buffer is full. Buffer the FULL remaining tail
            # into entry._pending_buf (a growable List[UInt8]) — NO CAP.
            # A response of any size flushes across multiple EPOLLOUT
            # events via resume_pending_write. (Prior behavior: a fixed
            # 1KB cap returned -1 here, dropping the connection for any
            # response whose unsent tail exceeded the socket send buffer
            # — e.g. a 113KB list_tasks JSON dropped at ~77KB.)
            var rem = n - sent_off
            entry._pending_buf.resize(unsafe_uninit_length=rem)
            var kk = 0
            while kk < rem:
                entry._pending_buf[kk] = src[sent_off + kk]
                kk = kk + 1
            entry._pending_len = rem
            entry._pending_off = 0
            entry._state = CONN_STATE_WAITING_FOR_WRITABLE
            bytes_sent = bytes_sent + Int64(sent_off)
            return 1
        if wr.is_error():
            return -1
        var sent_n = Int(wr.value())
        if sent_n <= 0:
            return -1  # cov: unreachable send of a non-empty buffer returns a byte count or an error, never 0
        sent_off = sent_off + sent_n
    bytes_sent = bytes_sent + Int64(n)
    return 0


def _park_behind(mut entry: ConnEntry, src: List[UInt8]):
    """Queue `src` behind the tail `_write_all_or_buffer` just parked (its
    buffer holds exactly `_pending_len` bytes), so the resume sends both."""
    for i in range(len(src)):
        entry._pending_buf.append(src[i])
    entry._pending_len = entry._pending_len + len(src)


def _write_last(
    mut entry: ConnEntry, src: List[UInt8], mut bytes_sent: Int64
) -> Int:
    """`_write_all_or_buffer` for the conn's last response (an error): if it
    parks, the resume closes the conn once it drains (komira-ai/komira#1285)."""
    entry._keep_alive = False
    return _write_all_or_buffer(entry, src, bytes_sent)


def _park_rest(
    mut entry: ConnEntry,
    io_buf: Array[UInt8, REQ_BUF_BYTES],
    start: Int,
    got: Int,
    close: Bool,
):
    """A response parked: keep `io_buf[start:got)`, the requests read after
    it, for the round after the resume; or, when it was the conn's last
    response, have the resume close the conn (komira-ai/komira#1285)."""
    if close:
        entry._keep_alive = False
        return
    for i in range(start, got):
        entry._carry.append(io_buf[i])


def _take_carry(
    mut entry: ConnEntry, mut io_buf: Array[UInt8, REQ_BUF_BYTES]
) -> Int:
    """Move the carried request bytes to the front of `io_buf`; their count."""
    var n = len(entry._carry)
    for i in range(n):
        io_buf[i] = entry._carry[i]
    entry._carry.clear()
    return n


comptime HEAD_KEPT: Int = 2
"""`carry_or_refuse_head`: the partial head is kept; read again."""


def carry_or_refuse_head(
    mut entry: ConnEntry, part: Span[UInt8, _], mut bytes_sent: Int64
) -> Int:
    """The parser needs more bytes than `part`, the received start of a
    request head: keep it on the entry for the next read (`HEAD_KEPT`). A
    head that already fills the receive buffer cannot complete; it is
    answered 431, the conn's last response, and the result of that write is
    returned (0, 1 or -1, as `_write_last`)."""
    if entry.carry_head(part):
        return HEAD_KEPT
    var err_buf = List[UInt8]()
    build_error_response_bytes(UInt16(431), err_buf)
    return _write_last(entry, err_buf, bytes_sent)
