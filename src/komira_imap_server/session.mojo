# The connection table and the step that turns received bytes into replies.
#
# `ImapRegistry.feed` is the whole receive side of a connection: the serving
# loop reads bytes from a socket (or a TLS connection), hands them to `feed`
# and writes what `tx_copy` returns. Nothing here opens a socket or reads a
# clock; the time is a parameter, and the store the mail lives in is a
# parameter too.

from std.memory import OwnedPointer

from komira_collections.slab import Slab
from komira_mail_auth import MailAuthVerifier
from komira_objectstore.store import CloneableConditionalWriteStore

from .commands import greeting, handle_line
from .connection import (
    FRAME_BARE,
    FRAME_LINE,
    FRAME_NEED_MORE,
    FRAME_TOO_LONG,
    IMAP_ACTION_CLOSE,
    IMAP_ACTION_START_TLS,
    IMAP_STATE_CLOSING,
    IMAP_STATE_NOTAUTH,
    ImapConnection,
)
from .limits import ImapServerConfig

# `feed` takes this many received bytes at a time, so the receive buffer
# holds at most about this plus one line however large a read is.
comptime _FEED_SLICE: Int = 4096


struct FeedOutcome(Copyable, Movable):
    """What one `feed` call did.

    `consumed`: bytes of the chunk taken (the rest are ignored because the
    connection is closing). `closing`: write the queued replies, then close.
    `starttls`: the OK is queued; write it, then start TLS.
    `pending_after_starttls`: bytes the client sent after STARTTLS in the same
    write, in this chunk or earlier. They arrived in the clear and must not be
    run (RFC 3207 section 4.2 and RFC 2595): when this is not 0 the serving
    loop closes the connection instead of upgrading it. `lines`: command lines
    that ran."""

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


struct ImapRegistry(Movable):
    """The server's table of live connections.

    Storage: `Slab[OwnedPointer[ImapConnection]]`. A connection owns heap
    buffers (lists and strings), and `komira_collections` slabs keep their
    elements inline in a byte buffer, so the slab holds only the 8-byte handle
    and each connection stays at a stable heap address; removal is
    `swap_remove`, which moves the whole handle (the same arrangement and
    reason as `komira_smtp_server`). Lookup by id is linear."""

    var _conns: Slab[OwnedPointer[ImapConnection]]
    var _next_id: Int

    def __init__(out self):
        self._conns = Slab[OwnedPointer[ImapConnection]]()
        self._next_id = 1

    # ---- lifecycle ----------------------------------------------------------

    def accept(
        mut self,
        fd: Int32,
        config: ImapServerConfig,
        now_ms: Int,
        peer: String = "",
    ) -> Optional[Int]:
        """Register a new connection and queue the greeting. None when
        `max_conns` connections are live: the serving loop then sends
        `* BYE` and closes the socket. `fd` is only remembered for the loop
        (`fd_of`); this package never touches it."""
        if self._conns.len() >= config.limits.max_conns:
            return None
        var id = self._next_id
        self._next_id += 1
        var conn = ImapConnection(id, fd, peer, now_ms)
        conn.enqueue(greeting(config, False))
        self._conns.append(OwnedPointer[ImapConnection](conn^))
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

    def expired_ids(self, now_ms: Int, config: ImapServerConfig) -> List[Int]:
        """The connections the serving loop should close (a `* BYE` first):
        no bytes received for `idle_ms`, older than `max_session_ms`, or not
        logged in after `max_unauth_ms`. The last two hold however often the
        peer sends, so a peer that trickles one byte at a time is reported
        too. Every comparison is strict: a connection is expired one
        millisecond after its limit."""
        var out = List[Int]()
        for i in range(self._conns.len()):
            ref c = self._conns[i][]
            var expired = now_ms - c.last_active_ms > config.limits.idle_ms
            if config.limits.max_session_ms > 0 and now_ms - c.accepted_ms > config.limits.max_session_ms:
                expired = True
            if (
                config.limits.max_unauth_ms > 0
                and c.state == IMAP_STATE_NOTAUTH
                and now_ms - c.accepted_ms > config.limits.max_unauth_ms
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

    def tx_consume(mut self, conn_id: Int, n: Int):
        """`n` bytes from the front of the queue were written."""
        var idx = self._index_of(conn_id)
        if idx >= 0:
            self._conns[idx][].tx_consume(n)

    def tx_moved(self, conn_id: Int) -> Int:
        """Bytes moved to compact the reply queue so far (a test oracle: it
        stays within the bytes written)."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return 0
        return self._conns[idx][].tx_moved

    def enqueue(mut self, conn_id: Int, reply: String):
        """Queue a reply the loop itself decided on (a `* BYE` at expiry)."""
        var idx = self._index_of(conn_id)
        if idx >= 0:
            self._conns[idx][].enqueue(reply)

    # ---- TLS -------------------------------------------------------------------

    def mark_tls_active(mut self, conn_id: Int):
        """The TLS handshake finished. The connection is on TLS and starts
        over: the user, the selection and any buffered bytes are dropped, and
        the client must LOGIN (and should ask for the capabilities) again."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return
        ref conn = self._conns[idx][]
        conn.tls_active = True
        conn.starttls_pending = False
        conn.reset_for_tls()
        conn.clear_rx()

    def starttls_pending_of(self, conn_id: Int) -> Bool:
        """True from the OK of a STARTTLS until `mark_tls_active`: the serving
        loop owes this connection a handshake."""
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
            return IMAP_STATE_CLOSING
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

    def username_of(self, conn_id: Int) -> String:
        var idx = self._index_of(conn_id)
        if idx < 0:
            return String("")
        return self._conns[idx][].username

    def mailbox_of(self, conn_id: Int) -> String:
        """The address of the logged-in user's mailbox; empty before LOGIN
        and for a name that maps to none."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return String("")
        return self._conns[idx][].mailbox

    def folder_of(self, conn_id: Int) -> String:
        """The normalized name of the selected folder; empty when none."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return String("")
        return self._conns[idx][].folder

    def is_read_only(self, conn_id: Int) -> Bool:
        var idx = self._index_of(conn_id)
        if idx < 0:
            return True
        return self._conns[idx][].read_only

    def view_count(self, conn_id: Int) -> Int:
        """The messages in the selected folder's view (`* n EXISTS`)."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return 0
        return len(self._conns[idx][].view)

    def uid_at(self, conn_id: Int, seq: Int) -> Int:
        """The UID of the message with sequence number `seq` (1-based), or -1."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return -1
        ref view = self._conns[idx][].view
        if seq < 1 or seq > len(view):
            return -1
        return view[seq - 1].uid

    def login_failures_of(self, conn_id: Int) -> Int:
        var idx = self._index_of(conn_id)
        if idx < 0:
            return 0
        return self._conns[idx][].login_failures

    def rx_peak(self, conn_id: Int) -> Int:
        """The most unconsumed received bytes the connection ever held."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return 0
        return self._conns[idx][].rx_peak

    # ---- the loop ----------------------------------------------------------------

    def feed[
        S: CloneableConditionalWriteStore,
        V: MailAuthVerifier,
    ](
        mut self,
        conn_id: Int,
        data: Span[UInt8, _],
        config: ImapServerConfig,
        verifier: V,
        mut store: S,
        now_ms: Int,
    ) -> FeedOutcome:
        """Take bytes the peer sent and run every complete line in them.

        Replies are queued on the connection (`tx_copy`). The bytes may split
        a line anywhere and may hold many pipelined lines. At most 4096 bytes
        are buffered at a time and a line over `max_line` closes the
        connection, so the receive buffer stays bounded whatever the peer
        sends. After LOGOUT, a fatal error, a STARTTLS or a full reply queue
        the rest of the chunk is not run: `consumed` says how much was
        taken."""
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
            # The OK is out and the upgrade has not happened: whatever
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
            _drain(conn, config, verifier, store, now_ms, out)
            if out.closing or out.starttls:
                break
        out.consumed = pos
        if out.starttls:
            out.pending_after_starttls = conn.rx_pending() + (n - pos)
            out.consumed = n
        return out^


def _close_with(mut conn: ImapConnection, text: String, mut out: FeedOutcome):
    conn.enqueue(text)
    conn.mark_closing()
    conn.clear_rx()
    out.closing = True


def _drain[
    S: CloneableConditionalWriteStore,
    V: MailAuthVerifier,
](
    mut conn: ImapConnection,
    config: ImapServerConfig,
    verifier: V,
    mut store: S,
    now_ms: Int,
    mut out: FeedOutcome,
):
    """Run every complete line in the receive buffer."""
    while True:
        var found = conn.next_frame(config.limits.max_line)
        if found == FRAME_NEED_MORE:
            return
        if found == FRAME_TOO_LONG:
            _close_with(conn, String("* BYE Command line too long\r\n"), out)
            return
        if found == FRAME_BARE:
            _close_with(
                conn, String("* BYE Bare CR or LF is not allowed\r\n"), out
            )
            return
        # FRAME_LINE
        out.lines += 1
        var line = conn.copy_line()
        conn.consume_line()
        var action = handle_line(conn, Span(line), config, verifier, store, now_ms)
        if action == IMAP_ACTION_CLOSE:
            conn.mark_closing()
            conn.clear_rx()
            out.closing = True
            return
        if action == IMAP_ACTION_START_TLS:
            out.starttls = True
            return
        if conn.tx_pending() > config.limits.max_tx_bytes:
            # The peer is not reading: past `max_tx_bytes` of queued replies,
            # say so and close.
            _close_with(
                conn, String("* BYE Too many unread replies, closing\r\n"), out
            )
            return
