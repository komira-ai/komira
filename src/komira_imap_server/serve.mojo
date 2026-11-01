# The serve loop: one caller-polled step over non-blocking sockets.
#
# `serve_one_iteration` accepts, reads, feeds the registry, writes the replies,
# runs the STARTTLS upgrade and closes what is finished or expired. It never
# blocks and reads no clock: the caller polls it (until a binary has a
# readiness driver, that means calling it in a loop) and passes the time. The
# structure is that of `komira_smtp_server`'s loop.
#
# The plaintext and the TLS connection share one path: a connection that has
# TLS state in the `MailTlsTable` and a finished handshake reads and writes
# through the table, every other connection through the socket.

from std.ffi import external_call

from komira_async.reactor.socket_io import (
    errno_is_would_block,
    try_io_accept,
    try_recv,
    try_send,
)
from komira_async.reactor.socket_setup import close_fd
from komira_mail_auth import MailAuthVerifier
from komira_mail_tls import (
    MailTlsTable,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
)
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_smtp_server import ListenSocket

from .limits import ImapServerConfig
from .session import FeedOutcome, ImapRegistry

# Bytes read or written in one call.
comptime _CHUNK: Int = 16 * 1024
# Work done per connection per iteration, so one busy peer cannot starve the
# others.
comptime _MAX_READS: Int = 8
comptime _MAX_WRITES: Int = 16
comptime _MAX_ACCEPTS: Int = 64
# EINTR: try again on the next iteration.
comptime _EINTR: Int32 = Int32(4)


struct ImapServeOutcome(Copyable, Movable):
    """What one `serve_one_iteration` did, as counts. `accepted` connections
    were registered, `refused` were answered `* BYE` at `max_conns`, `expired`
    were answered `* BYE` for their deadline, `upgraded` finished a STARTTLS
    handshake, `dropped` were closed (every cause), `lines` command lines
    ran."""

    var accepted: Int
    var refused: Int
    var expired: Int
    var upgraded: Int
    var dropped: Int
    var lines: Int

    def __init__(out self):
        self.accepted = 0
        self.refused = 0
        self.expired = 0
        self.upgraded = 0
        self.dropped = 0
        self.lines = 0


def serve_one_iteration[
    S: CloneableConditionalWriteStore,
    V: MailAuthVerifier,
](
    mut reg: ImapRegistry,
    listener: ListenSocket,
    mut tls: MailTlsTable,
    verifier: V,
    mut store: S,
    config: ImapServerConfig,
    now_ms: Int,
) -> ImapServeOutcome:
    """One non-blocking step, in this order.

    1. Accept the connections that are waiting. At `max_conns` the peer gets
       `* BYE` and the socket is closed.
    2. For each connection: advance a STARTTLS handshake, or read what has
       arrived (plaintext, or through TLS) and feed the registry; write the
       queued replies; start the TLS upgrade once the OK is written; close
       a connection that is finished or whose peer is gone.
    3. Connections `expired_ids` names get `* BYE` and are closed.

    Bytes a client pipelined behind STARTTLS in the clear close the
    connection (RFC 3207 section 4.2). A socket, TLS or store error closes at
    most the connection it happened on. With `config.offer_starttls` False
    STARTTLS is not offered and never reaches the TLS table, so a server
    without a certificate passes an empty table."""
    var out = ImapServeOutcome()
    _accept_pending(reg, listener.fd(), config, now_ms, out)

    var ids = reg.all_conn_ids()
    var raw = List[UInt8](length=_CHUNK, fill=UInt8(0))
    var plain = List[UInt8]()
    for i in range(len(ids)):
        _serve_connection(
            reg, tls, verifier, store, config, now_ms, ids[i], raw, plain, out
        )

    var late = reg.expired_ids(now_ms, config)
    for i in range(len(late)):
        _expire(reg, tls, late[i], out)
    return out^


def _accept_pending(
    mut reg: ImapRegistry,
    listen_fd: Int32,
    config: ImapServerConfig,
    now_ms: Int,
    mut out: ImapServeOutcome,
):
    for _ in range(_MAX_ACCEPTS):
        var r = try_io_accept(listen_fd)
        if not r.is_ready():
            return
        var fd = Int32(Int(r.value()))
        if not _set_nonblocking(fd):
            # A blocking descriptor would stall the whole caller-polled loop.
            _refuse(fd)
            out.refused += 1
            continue
        var id = reg.accept(fd, config, now_ms)
        if not id:
            _refuse(fd)
            out.refused += 1
            continue
        out.accepted += 1


def _set_nonblocking(fd: Int32) -> Bool:
    """Make `fd` non-blocking; False when that failed."""
    # FFI-BOUNDARY: `komira_fcntl_set_nonblock` is the C shim defined in
    # komira_libc (native/komira_libc_posix.c), which komira_async links; it
    # takes a descriptor and returns 0 or -1. `fd` stays owned by the caller,
    # who closes it when this returns False.
    return external_call["komira_fcntl_set_nonblock", Int32](fd) >= Int32(0)


def _refuse(fd: Int32):
    """`max_conns` is reached: one best-effort reply, then close. The reply
    is short and the socket's send buffer is empty, so one write holds it."""
    var text = String("* BYE Too many connections, try again later\r\n")
    _ = try_send(fd, text.as_bytes())
    close_fd(fd)


def _drop(mut reg: ImapRegistry, mut tls: MailTlsTable, cid: Int, mut out: ImapServeOutcome):
    """Forget a connection: its registry entry, its TLS state and its socket."""
    var fd = reg.drop(cid)
    tls.drop(cid)
    close_fd(fd)
    out.dropped += 1


def _expire(
    mut reg: ImapRegistry,
    mut tls: MailTlsTable,
    cid: Int,
    mut out: ImapServeOutcome,
):
    if not reg.has(cid):
        return
    if reg.is_closing(cid):
        # It already had one iteration to take its last replies. Under
        # back-pressure (the peer's receive window full) that BYE may never be
        # written: the deadline wins over the reply, so a peer that does not
        # read cannot hold the slot.
        _drop(reg, tls, cid, out)
        return
    out.expired += 1
    var fd = reg.fd_of(cid)
    if tls.is_tls(cid) and not reg.tls_active_of(cid):
        # Mid-handshake: a plaintext reply would corrupt the handshake.
        _drop(reg, tls, cid, out)
        return
    reg.enqueue(cid, String("* BYE Autologout: the connection was idle or open too long\r\n"))
    reg.close_after_flush(cid)
    var ok = _flush(reg, tls, cid, fd)
    if not ok or reg.tx_len(cid) == 0:
        _drop(reg, tls, cid, out)


def _serve_connection[
    S: CloneableConditionalWriteStore,
    V: MailAuthVerifier,
](
    mut reg: ImapRegistry,
    mut tls: MailTlsTable,
    verifier: V,
    mut store: S,
    config: ImapServerConfig,
    now_ms: Int,
    cid: Int,
    mut raw: List[UInt8],
    mut plain: List[UInt8],
    mut out: ImapServeOutcome,
):
    if not reg.has(cid):
        return
    var fd = reg.fd_of(cid)
    if fd < Int32(0):
        _drop(reg, tls, cid, out)
        return

    # A STARTTLS handshake in progress: s2n reads the socket itself, so the
    # plaintext path must not touch it until the handshake is done.
    if tls.is_tls(cid) and not reg.tls_active_of(cid):
        var hs = tls.drive_handshake_burst(cid)
        if hs == TLS_OUTCOME_ERROR:
            _drop(reg, tls, cid, out)
            return
        if hs != TLS_OUTCOME_DONE:
            return
        reg.mark_tls_active(cid)
        out.upgraded += 1

    var gone = False
    for _ in range(_MAX_READS):
        if reg.is_closing(cid):
            break
        var n = _read_some(tls, cid, fd, raw, plain)
        if n < 0:
            gone = True
            break
        if n == 0:
            break
        var result: FeedOutcome
        if tls.is_tls(cid):
            result = reg.feed(
                cid, Span(plain), config, verifier, store, now_ms
            )
        else:
            result = reg.feed(
                cid, Span(raw)[0:n], config, verifier, store, now_ms
            )
        out.lines += result.lines
        if result.starttls:
            if result.pending_after_starttls != 0:
                # RFC 3207 section 4.2: bytes sent in the clear behind
                # STARTTLS. Write the OK and close; nothing of them runs.
                reg.close_after_flush(cid)
            break
        if result.closing:
            break

    var flushed = _flush(reg, tls, cid, fd)

    # The OK is written and nothing is buffered: start the handshake.
    if (
        flushed
        and not gone
        and reg.starttls_pending_of(cid)
        and not reg.is_closing(cid)
        and not tls.is_tls(cid)
        and reg.tx_len(cid) == 0
    ):
        var started = True
        try:
            tls.begin_upgrade(cid, fd, reg.pending_rx_bytes(cid))
        except:
            started = False
        if not started:
            _drop(reg, tls, cid, out)
            return
        var hs = tls.drive_handshake_burst(cid)
        if hs == TLS_OUTCOME_ERROR:
            _drop(reg, tls, cid, out)
            return
        if hs == TLS_OUTCOME_DONE:
            reg.mark_tls_active(cid)
            out.upgraded += 1

    if gone or not flushed:
        _drop(reg, tls, cid, out)
        return
    if reg.is_closing(cid) and reg.tx_len(cid) == 0:
        _drop(reg, tls, cid, out)


def _read_some(
    mut tls: MailTlsTable,
    cid: Int,
    fd: Int32,
    mut raw: List[UInt8],
    mut plain: List[UInt8],
) -> Int:
    """Read what is waiting on connection `cid`. Returns the byte count (the
    bytes are `plain` on a TLS connection, `raw[0:n]` otherwise), 0 when there
    is nothing now, -1 when the peer closed or the connection failed."""
    if tls.is_tls(cid):
        plain.clear()
        var r = tls.recv(cid, plain, _CHUNK)
        if r[0] == TLS_OUTCOME_ERROR:
            return -1
        if r[0] == TLS_OUTCOME_DONE:
            if r[1] == 0:
                return -1  # the peer's close_notify
            return r[1]
        return 0
    var n = try_recv(fd, Span(raw))
    if n > Int64(0):
        return Int(n)
    if n == Int64(0):
        return -1  # end of stream: the buffer is not empty
    var err = Int32(-Int(n))
    if errno_is_would_block(err) or err == _EINTR:
        return 0
    return -1


def _flush(
    mut reg: ImapRegistry, mut tls: MailTlsTable, cid: Int, fd: Int32
) -> Bool:
    """Write queued replies until the queue is empty or the socket is full.
    False when the connection failed. A short write consumes only what went
    out (`tx_consume`); the next call offers the queue from its front again.
    On TLS a call that wrote nothing (`BLOCKED_ON_WRITE`, 0 bytes accepted)
    leaves the queue as it was; the retry begins with the same bytes and may
    carry more behind them, because replies are only ever appended to the
    queue. s2n counts nothing consumed after a 0-byte block, so a longer
    buffer satisfies its size check."""
    var on_tls = tls.is_tls(cid)
    for _ in range(_MAX_WRITES):
        if reg.tx_len(cid) == 0:
            return True
        var chunk = reg.tx_copy(cid, _CHUNK)
        var sent = 0
        if on_tls:
            var r = tls.send(cid, Span(chunk))
            if r[0] == TLS_OUTCOME_ERROR:
                return False
            if r[0] != TLS_OUTCOME_DONE or r[1] <= 0:
                return True
            sent = r[1]
        else:
            var n = try_send(fd, Span(chunk))
            if n < Int64(0):
                var err = Int32(-Int(n))
                if errno_is_would_block(err) or err == _EINTR:
                    return True
                return False
            if n == Int64(0):
                return True
            sent = Int(n)
        reg.tx_consume(cid, sent)
        if sent < len(chunk):
            return True
    return True
