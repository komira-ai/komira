# One IMAP connection's state, and its line framing over the received bytes.
#
# Every field is an owned value. The registry keeps a connection behind an
# OwnedPointer (session.mojo), because it owns heap buffers.

comptime IMAP_STATE_NOTAUTH: UInt8 = 0  # greeting sent, waiting for LOGIN
comptime IMAP_STATE_AUTH: UInt8 = 1  # logged in, no mailbox selected
comptime IMAP_STATE_SELECTED: UInt8 = 2  # a mailbox is selected
comptime IMAP_STATE_CLOSING: UInt8 = 3  # the connection closes after its replies

# What `next_frame` found.
comptime FRAME_NEED_MORE: Int = 0
comptime FRAME_LINE: Int = 1
comptime FRAME_TOO_LONG: Int = 2
comptime FRAME_BARE: Int = 3

comptime _CR: UInt8 = 0x0D
comptime _LF: UInt8 = 0x0A

# Consumed bytes are dropped from the front of a buffer once there are this
# many of them (or the buffer is empty), so dropping them is amortised
# constant.
comptime _COMPACT_AT: Int = 2048

# What the serving loop does after a line.
comptime IMAP_ACTION_CONTINUE: UInt8 = 0
comptime IMAP_ACTION_CLOSE: UInt8 = 1  # flush the replies, then close
comptime IMAP_ACTION_START_TLS: UInt8 = 2  # flush the OK, then start TLS


struct ViewRow(Copyable, Movable):
    """One message of the selected folder: its leaf in the store, its UID and
    its size in bytes. The sequence number is the 1-based index in the view."""

    var leaf: String
    var uid: Int
    var size: Int

    def __init__(out self, var leaf: String, uid: Int, size: Int):
        self.leaf = leaf^
        self.uid = uid
        self.size = size


struct ImapConnection(Movable):
    """One live connection: protocol state, the receive buffer, the reply
    queue and the selected folder's view.

    `rx[rx_off:]` is the received bytes not yet consumed; `rx_scan` is how far
    `next_frame` has already looked, so a line split over many reads is
    scanned once. `tx[tx_off:]` is the reply bytes not yet written.

    `mailbox` is the address of the store mailbox the logged-in user owns: the
    login name, which `komira_mail_store` folds with `normalize_recipient`
    wherever it builds a key. It is empty when the name cannot be a mailbox.
    `folder` is the normalized name of the selected folder, `scope` the name
    its flags and UIDVALIDITY are kept under (`flag_scope`), and `view` its
    messages, a snapshot taken by SELECT, ascending by UID."""

    var conn_id: Int
    var fd: Int32
    var state: UInt8
    var closing: Bool
    var last_active_ms: Int
    var accepted_ms: Int
    var peer: String
    # Receive side.
    var rx: List[UInt8]
    var rx_off: Int
    var rx_scan: Int
    var rx_peak: Int
    var rx_moved: Int
    var line_end: Int
    # Reply side.
    var tx: List[UInt8]
    var tx_off: Int
    var tx_moved: Int
    # TLS and LOGIN.
    var tls_active: Bool
    var starttls_pending: Bool
    var login_failures: Int
    var username: String
    var mailbox: String
    # The selected folder.
    var folder: String
    var scope: String
    var read_only: Bool
    var view: List[ViewRow]

    def __init__(out self, conn_id: Int, fd: Int32, peer: String, now_ms: Int):
        self.conn_id = conn_id
        self.fd = fd
        self.state = IMAP_STATE_NOTAUTH
        self.closing = False
        self.last_active_ms = now_ms
        self.accepted_ms = now_ms
        self.peer = peer
        self.rx = List[UInt8]()
        self.rx_off = 0
        self.rx_scan = 0
        self.rx_peak = 0
        self.rx_moved = 0
        self.line_end = 0
        self.tx = List[UInt8]()
        self.tx_off = 0
        self.tx_moved = 0
        self.tls_active = False
        self.starttls_pending = False
        self.login_failures = 0
        self.username = String("")
        self.mailbox = String("")
        self.folder = String("")
        self.scope = String("")
        self.read_only = False
        self.view = List[ViewRow]()

    # ---- replies ----------------------------------------------------------

    def enqueue(mut self, reply: String):
        """Queue reply bytes for the peer."""
        self.tx.extend(reply.as_bytes())

    def enqueue_bytes(mut self, data: Span[UInt8, _]):
        """Queue raw bytes (a message literal) for the peer."""
        self.tx.extend(data)

    def tx_pending(self) -> Int:
        return len(self.tx) - self.tx_off

    def tx_copy(self, max_bytes: Int) -> List[UInt8]:
        """A copy of at most `max_bytes` queued reply bytes, front first."""
        var n = self.tx_pending()
        if n > max_bytes:
            n = max_bytes
        var out = List[UInt8]()
        if n <= 0:
            return out^
        out.reserve(n)
        out.extend(Span(self.tx)[self.tx_off : self.tx_off + n])
        return out^

    def tx_consume(mut self, n: Int):
        """The first `n` queued bytes were written."""
        if n <= 0:
            return
        self.tx_off += n
        if self.tx_off >= len(self.tx):
            self.tx.clear()
            self.tx_off = 0
        elif self.tx_off >= _COMPACT_AT and self.tx_off * 2 >= len(self.tx):
            # Compact only once the written part is at least half the queue,
            # so the bytes moved never exceed the bytes written.
            var keep = len(self.tx) - self.tx_off
            for i in range(keep):
                self.tx[i] = self.tx[self.tx_off + i]
            self.tx.resize(keep, UInt8(0))
            self.tx_off = 0
            self.tx_moved += keep

    # ---- receive framing --------------------------------------------------

    def rx_pending(self) -> Int:
        return len(self.rx) - self.rx_off

    def rx_append(mut self, data: Span[UInt8, _]):
        """Append received bytes. Consumed bytes are dropped first, with an
        offset and a compaction at a threshold, never a rebuild per line."""
        if self.rx_off >= len(self.rx):
            self.rx.clear()
            self.rx_off = 0
            self.rx_scan = 0
        elif self.rx_off >= _COMPACT_AT:
            self._compact_rx()
        self.rx.extend(data)
        var live = len(self.rx) - self.rx_off
        if live > self.rx_peak:
            self.rx_peak = live

    def _compact_rx(mut self):
        var keep = len(self.rx) - self.rx_off
        for i in range(keep):
            self.rx[i] = self.rx[self.rx_off + i]
        self.rx.resize(keep, UInt8(0))
        self.rx_scan -= self.rx_off
        self.rx_off = 0
        self.rx_moved += keep

    def clear_rx(mut self):
        self.rx.clear()
        self.rx_off = 0
        self.rx_scan = 0

    def next_frame(mut self, max_line: Int) -> Int:
        """Look for the next CRLF-terminated line in the received bytes.

        A line, CRLF included, is at most `max_line` bytes. FRAME_LINE: the
        content is `rx[rx_off:line_end]`; call `consume_line` after using it.
        FRAME_TOO_LONG: `max_line` bytes are buffered and none ends a line.
        FRAME_BARE: a LF not preceded by CR, or a CR not followed by LF.
        FRAME_NEED_MORE: nothing yet. Framing is CRLF only."""
        var n = len(self.rx)
        var start = self.rx_off
        var i = self.rx_scan
        if i < start:
            i = start
        # A CR that can still be followed by a LF inside the cap sits before
        # this index.
        var cr_limit = start + max_line - 1
        var stop = n
        if stop > cr_limit:
            stop = cr_limit
        while i < stop:
            var c = self.rx[i]
            if c == _LF:
                self.rx_scan = i
                return FRAME_BARE
            if c == _CR:
                if i + 1 >= n:
                    # The byte that decides it has not arrived.
                    self.rx_scan = i
                    return FRAME_NEED_MORE
                if self.rx[i + 1] == _LF:
                    self.line_end = i
                    self.rx_scan = i
                    return FRAME_LINE
                self.rx_scan = i
                return FRAME_BARE
            i += 1
        self.rx_scan = i
        if n - start >= max_line:
            return FRAME_TOO_LONG
        return FRAME_NEED_MORE

    def consume_line(mut self):
        """Drop the line `next_frame` found, and its CRLF."""
        self.rx_off = self.line_end + 2
        self.rx_scan = self.rx_off

    def copy_line(self) -> List[UInt8]:
        """A copy of the line `next_frame` found, CRLF excluded."""
        var out = List[UInt8]()
        out.extend(Span(self.rx)[self.rx_off : self.line_end])
        return out^

    # ---- state ------------------------------------------------------------

    def mark_closing(mut self):
        self.closing = True
        self.state = IMAP_STATE_CLOSING

    def deselect(mut self):
        """Leave the selected folder: no view, no folder. A connection that
        is logged in goes back to the authenticated state."""
        self.folder = String("")
        self.scope = String("")
        self.read_only = False
        self.view = List[ViewRow]()
        if self.state == IMAP_STATE_SELECTED:
            self.state = IMAP_STATE_AUTH

    def reset_for_tls(mut self):
        """RFC 2595: after the handshake the server forgets everything the
        client said in the clear. The client asks for the capabilities again."""
        self.username = String("")
        self.mailbox = String("")
        self.deselect()
        if self.state != IMAP_STATE_CLOSING:
            self.state = IMAP_STATE_NOTAUTH
