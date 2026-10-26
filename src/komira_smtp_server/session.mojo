# The connection table and the loop that turns received bytes into replies.
#
# `SmtpRegistry.feed` is the whole receive side of a connection: the serving
# loop reads bytes from a socket (or a TLS connection), hands them to `feed`
# and writes what `tx_copy` returns. Nothing here opens a socket or reads a
# clock; the time is a parameter.

from std.memory import OwnedPointer

from komira_collections.slab import Slab
from komira_mail_auth import MAX_SASL_LINE_BYTES, MailAuthVerifier

from .auth import AUTH_NONE
from .commands import greeting, handle_command_line
from .connection import (
    CommandResult,
    FRAME_BARE,
    FRAME_LINE,
    FRAME_NEED_MORE,
    FRAME_TOO_LONG,
    SMTP_ACTION_CLOSE,
    SMTP_ACTION_START_TLS,
    SMTP_STATE_CLOSING,
    SMTP_STATE_DATA,
    SmtpConnection,
)
from .data import handle_data_line
from .delivery import MailDelivery
from .limits import SmtpServerConfig

# `feed` takes this many received bytes at a time, so the receive buffer
# holds at most about this plus one line however large a read is.
comptime _FEED_SLICE: Int = 4096


struct FeedOutcome(Copyable, Movable):
    """What one `feed` call did.

    `consumed`: bytes of the chunk taken (the rest are ignored because the
    connection is closing). `closing`: write the queued replies, then close.
    `starttls`: the 220 is queued; write it, then start TLS.
    `pending_after_starttls`: bytes the client sent after STARTTLS in the same
    write, in this chunk or earlier. They arrived in the clear and must not be
    run (RFC 3207 section 4.2): when this is not 0 the serving loop closes the
    connection instead of upgrading it."""

    var consumed: Int
    var closing: Bool
    var starttls: Bool
    var pending_after_starttls: Int
    var lines: Int

    def __init__(out self):
        self.consumed = 0
        self.closing = False
        self.starttls = False
        self.pending_after_starttls = 0
        self.lines = 0


struct SmtpRegistry(Movable):
    """The server's table of live connections.

    Storage: `Slab[OwnedPointer[SmtpConnection]]`. A connection owns heap
    buffers (lists and strings), and `komira_collections` slabs keep their
    elements inline in a byte buffer, so the slab holds only the 8-byte
    handle and each connection stays at a stable heap address; removal is
    `swap_remove`, which moves the whole handle (the same arrangement and
    reason as `komira_mail_tls`). `tests/test_framing.mojo` adds and drops a
    thousand connections that hold buffered bytes. Lookup by id is linear."""

    var _conns: Slab[OwnedPointer[SmtpConnection]]
    var _next_id: Int

    def __init__(out self):
        self._conns = Slab[OwnedPointer[SmtpConnection]]()
        self._next_id = 1

    # ---- lifecycle ----------------------------------------------------------

    def accept(
        mut self,
        fd: Int32,
        config: SmtpServerConfig,
        now_ms: Int,
        peer: String = "",
    ) -> Optional[Int]:
        """Register a new connection and queue the 220 greeting. None when
        `max_conns` connections are live: the serving loop then sends
        `421 4.3.2` and closes the socket. `fd` is only remembered for the
        loop (`fd_of`); this package never touches it. `peer` reaches
        deliveries as `SessionInfo.peer`."""
        if self._conns.len() >= config.limits.max_conns:
            return None
        var id = self._next_id
        self._next_id += 1
        var conn = SmtpConnection(id, fd, peer, now_ms)
        conn.enqueue(greeting(config))
        self._conns.append(OwnedPointer[SmtpConnection](conn^))
        return Optional[Int](id)

    def _index_of(self, conn_id: Int) -> Int:
        for i in range(self._conns.len()):
            if self._conns[i][].conn_id == conn_id:
                return i
        return -1

    def drop(mut self, conn_id: Int) -> Int32:
        """Remove a connection and return its fd (-1 if it is not there)."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return Int32(-1)
        var fd = self._conns[idx][].fd
        var removed = self._conns.swap_remove(idx)
        _ = removed^
        return fd

    def has(self, conn_id: Int) -> Bool:
        return self._index_of(conn_id) >= 0

    def conn_count(self) -> Int:
        return self._conns.len()

    def all_conn_ids(self) -> List[Int]:
        var out = List[Int]()
        for i in range(self._conns.len()):
            out.append(self._conns[i][].conn_id)
        return out^

    def idle_ids(self, now_ms: Int, idle_ms: Int) -> List[Int]:
        """The connections that have not been fed for more than `idle_ms`. A
        peer that sends a byte now and then is never idle: use `expired_ids`."""
        var out = List[Int]()
        for i in range(self._conns.len()):
            if now_ms - self._conns[i][].last_active_ms > idle_ms:
                out.append(self._conns[i][].conn_id)
        return out^

    def expired_ids(self, now_ms: Int, config: SmtpServerConfig) -> List[Int]:
        """The connections the serving loop should close (a 421 4.4.2 first):
        no bytes received for `idle_ms`, older than `max_session_ms`, or in
        the DATA phase for more than `max_data_ms`. The last two hold however
        often the peer sends, so a peer that trickles one byte at a time is
        reported too."""
        var out = List[Int]()
        for i in range(self._conns.len()):
            ref c = self._conns[i][]
            var expired = now_ms - c.last_active_ms > config.limits.idle_ms
            if config.limits.max_session_ms > 0 and now_ms - c.accepted_ms > config.limits.max_session_ms:
                expired = True
            if (
                config.limits.max_data_ms > 0
                and c.state == SMTP_STATE_DATA
                and now_ms - c.data_started_ms > config.limits.max_data_ms
            ):
                expired = True
            if expired:
                out.append(c.conn_id)
        return out^

    # ---- reply queue ----------------------------------------------------------

    def tx_len(self, conn_id: Int) -> Int:
        var idx = self._index_of(conn_id)
        if idx < 0:
            return 0
        return self._conns[idx][].tx_pending()

    def tx_copy(self, conn_id: Int, max_bytes: Int) -> List[UInt8]:
        """A copy of at most `max_bytes` reply bytes waiting to be written."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return List[UInt8]()
        return self._conns[idx][].tx_copy(max_bytes)

    def tx_moved(self, conn_id: Int) -> Int:
        """Bytes moved to compact the reply queue so far (a test oracle: it
        stays within the bytes written, so the cost per byte is constant)."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return 0
        return self._conns[idx][].tx_moved

    def tx_consume(mut self, conn_id: Int, n: Int):
        """`n` bytes from the front of the queue were written."""
        var idx = self._index_of(conn_id)
        if idx >= 0:
            self._conns[idx][].tx_consume(n)

    def enqueue(mut self, conn_id: Int, reply: String):
        """Queue a reply the loop itself decided on (a 421 at shutdown)."""
        var idx = self._index_of(conn_id)
        if idx >= 0:
            self._conns[idx][].enqueue(reply)

    # ---- TLS -------------------------------------------------------------------

    def mark_tls_active(mut self, conn_id: Int):
        """The TLS handshake finished. The connection is on TLS and SMTP
        state starts over: the transaction, the EHLO name and the verified
        user are cleared (RFC 3207 section 4.2) and the client must send EHLO
        again. Bytes still in the receive buffer are dropped."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return
        ref conn = self._conns[idx][]
        conn.tls_active = True
        conn.starttls_pending = False
        conn.reset_for_tls()
        conn.clear_rx()

    def starttls_pending_of(self, conn_id: Int) -> Bool:
        """True from the 220 of a STARTTLS until `mark_tls_active`: the
        serving loop owes this connection a handshake."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return False
        return self._conns[idx][].starttls_pending

    def close_after_flush(mut self, conn_id: Int):
        """The serving loop decided to close (a refused STARTTLS, an expired
        connection): no more input is run and the connection is dropped once
        the replies queued so far are written."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return
        ref conn = self._conns[idx][]
        conn.mark_closing()
        conn.clear_rx()

    def pending_rx_bytes(self, conn_id: Int) -> Int:
        """Received bytes not yet run as commands."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return 0
        return self._conns[idx][].rx_pending()

    # ---- queries -----------------------------------------------------------------

    def fd_of(self, conn_id: Int) -> Int32:
        var idx = self._index_of(conn_id)
        if idx < 0:
            return Int32(-1)
        return self._conns[idx][].fd

    def state_of(self, conn_id: Int) -> UInt8:
        var idx = self._index_of(conn_id)
        if idx < 0:
            return SMTP_STATE_CLOSING
        return self._conns[idx][].state

    def is_closing(self, conn_id: Int) -> Bool:
        var idx = self._index_of(conn_id)
        if idx < 0:
            return True
        return self._conns[idx][].closing

    def tls_active_of(self, conn_id: Int) -> Bool:
        var idx = self._index_of(conn_id)
        if idx < 0:
            return False
        return self._conns[idx][].tls_active

    def authed_user_of(self, conn_id: Int) -> String:
        var idx = self._index_of(conn_id)
        if idx < 0:
            return String("")
        return self._conns[idx][].authed_user

    def mail_from_of(self, conn_id: Int) -> String:
        var idx = self._index_of(conn_id)
        if idx < 0:
            return String("")
        return self._conns[idx][].mail_from

    def recipient_count(self, conn_id: Int) -> Int:
        var idx = self._index_of(conn_id)
        if idx < 0:
            return 0
        return len(self._conns[idx][].recipients)

    def data_len(self, conn_id: Int) -> Int:
        """Bytes of message text buffered for the transaction."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return 0
        return len(self._conns[idx][].data)

    def rx_peak(self, conn_id: Int) -> Int:
        """The most unconsumed received bytes the connection ever held."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return 0
        return self._conns[idx][].rx_peak

    def rx_moved(self, conn_id: Int) -> Int:
        """Bytes moved to compact the receive buffer so far (a test oracle:
        it stays within the bytes received, so cost per byte is constant)."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return 0
        return self._conns[idx][].rx_moved

    def messages_accepted_of(self, conn_id: Int) -> Int:
        var idx = self._index_of(conn_id)
        if idx < 0:
            return 0
        return self._conns[idx][].messages_accepted

    # ---- the loop ----------------------------------------------------------------

    def feed[
        V: MailAuthVerifier,
        D: MailDelivery,
    ](
        mut self,
        conn_id: Int,
        data: Span[UInt8, _],
        config: SmtpServerConfig,
        verifier: V,
        mut delivery: D,
        now_ms: Int,
    ) -> FeedOutcome:
        """Take bytes the peer sent and run every complete line in them.

        Replies are queued on the connection (`tx_copy`). The bytes may split
        a line anywhere and may hold many pipelined lines. At most 4096 bytes
        are buffered at a time and a line over its cap closes the connection,
        so the receive buffer stays bounded whatever the peer sends. After
        QUIT, a fatal error, a STARTTLS or a full reply queue the rest of the
        chunk is not run: `consumed` says how much was taken."""
        var out = FeedOutcome()
        var idx = self._index_of(conn_id)
        if idx < 0:
            out.closing = True
            return out^
        ref conn = self._conns[idx][]
        conn.last_active_ms = now_ms
        if conn.closing:
            out.closing = True
            return out^
        if conn.starttls_pending:
            # The 220 is out and the upgrade has not happened: whatever
            # arrives now was sent before the handshake.
            out.starttls = True
            out.pending_after_starttls = len(data) + conn.rx_pending()
            out.consumed = len(data)
            return out^
        var pos = 0
        var n = len(data)
        while pos < n:
            var take = n - pos
            if take > _FEED_SLICE:
                take = _FEED_SLICE
            conn.rx_append(data[pos : pos + take])
            pos += take
            _drain(conn, config, verifier, delivery, now_ms, out)
            if out.closing or out.starttls:
                break
        out.consumed = pos
        if out.starttls:
            out.pending_after_starttls = conn.rx_pending() + (n - pos)
            out.consumed = n
        return out^


def _frame_cap(conn: SmtpConnection, config: SmtpServerConfig) -> Int:
    if conn.state == SMTP_STATE_DATA:
        return config.limits.max_data_line
    if conn.auth_stage != AUTH_NONE:
        # RFC 4954 section 4: 12288 octets of answer to a 334, and the CRLF.
        return MAX_SASL_LINE_BYTES + 2
    return config.limits.max_line


def _tx_overflow(
    mut conn: SmtpConnection, config: SmtpServerConfig, mut out: FeedOutcome
) -> Bool:
    """The peer is not reading: past `max_tx_bytes` of queued replies, queue
    one 421 and close. True when it closed."""
    if conn.tx_pending() <= config.limits.max_tx_bytes:
        return False
    conn.enqueue(String("421 4.7.0 Too many unread replies, closing\r\n"))
    conn.mark_closing()
    conn.clear_rx()
    out.closing = True
    return True


def _drain[
    V: MailAuthVerifier,
    D: MailDelivery,
](
    mut conn: SmtpConnection,
    config: SmtpServerConfig,
    verifier: V,
    mut delivery: D,
    now_ms: Int,
    mut out: FeedOutcome,
):
    """Run every complete line in the receive buffer."""
    while True:
        if conn.skipping:
            conn.run_skip()
            if conn.skipping:
                return
        var found = conn.next_frame(_frame_cap(conn, config))
        if found == FRAME_NEED_MORE:
            return
        if found == FRAME_TOO_LONG:
            var text = String("500 5.5.2 Line too long\r\n")
            if conn.auth_stage != AUTH_NONE:
                text = String("500 5.5.6 Authentication exchange line is too long\r\n")
            conn.enqueue(text)
            conn.mark_closing()
            conn.clear_rx()
            out.closing = True
            return
        if found == FRAME_BARE:
            if conn.state == SMTP_STATE_DATA:
                conn.enqueue(
                    String("500 5.5.2 Bare CR or LF in message data, closing\r\n")
                )
                conn.mark_closing()
                conn.clear_rx()
                conn.data = List[UInt8]()
                out.closing = True
                return
            conn.enqueue(String("500 5.5.2 Bare CR or LF is not allowed\r\n"))
            conn.auth_stage = AUTH_NONE
            conn.auth_user_b64 = String("")
            conn.consume_bare()
            # The reply costs more than the bytes that earned it, so it counts
            # against the same caps as any command line.
            conn.commands_in_txn += 1
            if conn.commands_in_txn > config.limits.max_commands:
                conn.enqueue(String("421 4.7.0 Too many commands, closing\r\n"))
                conn.mark_closing()
                conn.clear_rx()
                out.closing = True
                return
            if _tx_overflow(conn, config, out):
                return
            continue
        # FRAME_LINE
        out.lines += 1
        var result: CommandResult
        if conn.state == SMTP_STATE_DATA:
            result = handle_data_line(conn, config, delivery, now_ms)
            conn.consume_line()
        else:
            var line = conn.copy_line()
            conn.consume_line()
            result = handle_command_line(
                conn, Span(line), config, verifier, delivery, now_ms
            )
        if result.reply.byte_length() > 0:
            conn.enqueue(result.reply)
        if result.action == SMTP_ACTION_CLOSE:
            conn.mark_closing()
            conn.clear_rx()
            out.closing = True
            return
        if result.action == SMTP_ACTION_START_TLS:
            out.starttls = True
            return
        if _tx_overflow(conn, config, out):
            return
