# One SMTP connection's state, and its line framing over the received bytes.
#
# Every field is an owned value. The registry keeps a connection behind an
# OwnedPointer (session.mojo), because it owns heap buffers.

comptime SMTP_STATE_GREETED: UInt8 = 0  # 220 sent, waiting for EHLO or HELO
comptime SMTP_STATE_READY: UInt8 = 1  # greeted, waiting for MAIL
comptime SMTP_STATE_MAIL: UInt8 = 2  # MAIL accepted, waiting for RCPT
comptime SMTP_STATE_RCPT: UInt8 = 3  # one recipient or more, RCPT or DATA
comptime SMTP_STATE_DATA: UInt8 = 4  # 354 sent, reading message lines
comptime SMTP_STATE_CLOSING: UInt8 = 5  # the connection closes after its replies

# What `next_frame` found.
comptime FRAME_NEED_MORE: Int = 0
comptime FRAME_LINE: Int = 1
comptime FRAME_TOO_LONG: Int = 2
comptime FRAME_BARE: Int = 3

comptime _CR: UInt8 = 0x0D
comptime _LF: UInt8 = 0x0A

# Consumed bytes are dropped from the front of `rx` once there are this many
# of them (or the buffer is empty), so dropping them is amortised constant.
comptime _COMPACT_AT: Int = 2048


struct SmtpConnection(Movable):
    """One live connection: protocol state, the receive buffer, the reply
    queue and the transaction in progress.

    `rx[rx_off:]` is the received bytes not yet consumed; `rx_scan` is how far
    `next_frame` has already looked, so a line split over many reads is
    scanned once. `tx[tx_off:]` is the reply bytes not yet written. All state
    changes go through the methods below and through commands.mojo, data.mojo
    and auth.mojo."""

    var conn_id: Int
    var fd: Int32
    var state: UInt8
    var closing: Bool
    var last_active_ms: Int
    var accepted_ms: Int
    var data_started_ms: Int
    var peer: String
    var helo: String
    # Receive side.
    var rx: List[UInt8]
    var rx_off: Int
    var rx_scan: Int
    var rx_peak: Int
    var rx_moved: Int
    var line_end: Int
    var skipping: Bool
    var skip_after_cr: Bool
    # Reply side.
    var tx: List[UInt8]
    var tx_off: Int
    var tx_moved: Int
    # The transaction.
    var mail_from: String
    var declared_size: Int
    var body_8bit: Bool
    var recipients: List[String]
    var data: List[UInt8]
    var data_overflow: Bool
    var commands_in_txn: Int
    var messages_accepted: Int
    # TLS and AUTH.
    var tls_active: Bool
    var starttls_pending: Bool
    var authed_user: String
    var auth_stage: UInt8
    var auth_user_b64: String
    var auth_failures: Int

    def __init__(out self, conn_id: Int, fd: Int32, peer: String, now_ms: Int):
        self.conn_id = conn_id
        self.fd = fd
        self.state = SMTP_STATE_GREETED
        self.closing = False
        self.last_active_ms = now_ms
        self.accepted_ms = now_ms
        self.data_started_ms = now_ms
        self.peer = peer
        self.helo = String("")
        self.rx = List[UInt8]()
        self.rx_off = 0
        self.rx_scan = 0
        self.rx_peak = 0
        self.rx_moved = 0
        self.line_end = 0
        self.skipping = False
        self.skip_after_cr = False
        self.tx = List[UInt8]()
        self.tx_off = 0
        self.tx_moved = 0
        self.mail_from = String("")
        self.declared_size = -1
        self.body_8bit = False
        self.recipients = List[String]()
        self.data = List[UInt8]()
        self.data_overflow = False
        self.commands_in_txn = 0
        self.messages_accepted = 0
        self.tls_active = False
        self.starttls_pending = False
        self.authed_user = String("")
        self.auth_stage = 0
        self.auth_user_b64 = String("")
        self.auth_failures = 0

    # ---- replies ----------------------------------------------------------

    def enqueue(mut self, reply: String):
        """Queue reply bytes for the peer."""
        self.tx.extend(reply.as_bytes())

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
            # so the bytes moved never exceed the bytes written (a writer that
            # takes a few KB at a time from a long queue costs O(1) per byte).
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
        """Move the unconsumed bytes to the front. The bytes moved are
        counted in `rx_moved`, a test oracle for the amortised cost."""
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
        self.skipping = False

    def begin_skip(mut self):
        """Discard received bytes up to and including the next CRLF."""
        self.skipping = True
        self.skip_after_cr = False

    def run_skip(mut self):
        """Consume bytes while skipping; stop after the CRLF that ends the
        skipped line. Nothing is buffered."""
        var n = len(self.rx)
        var i = self.rx_off
        while i < n:
            var c = self.rx[i]
            i += 1
            if self.skip_after_cr and c == _LF:
                self.skipping = False
                break
            self.skip_after_cr = c == _CR
        self.rx_off = i
        if self.rx_scan < i:
            self.rx_scan = i

    def next_frame(mut self, max_line: Int) -> Int:
        """Look for the next CRLF-terminated line in the received bytes.

        A line, CRLF included, is at most `max_line` bytes. FRAME_LINE: the
        content is `rx[rx_off:line_end]`; call `consume_line` after using it.
        FRAME_TOO_LONG: `max_line` bytes are buffered and none ends a line.
        FRAME_BARE: a LF not preceded by CR, or a CR not followed by LF, is at
        `rx_scan`. FRAME_NEED_MORE: nothing yet. Framing is CRLF only: a bare
        LF or CR is never a line end."""
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

    def consume_bare(mut self):
        """Drop the line that holds the offending byte at `rx_scan`, up to
        the next CRLF, so a command hidden behind a bare LF or CR cannot run."""
        self.rx_off = self.rx_scan + 1
        self.rx_scan = self.rx_off
        self.begin_skip()

    def consume_line(mut self):
        """Drop the line `next_frame` found, and its CRLF."""
        self.rx_off = self.line_end + 2
        self.rx_scan = self.rx_off

    def line_len(self) -> Int:
        return self.line_end - self.rx_off

    def copy_line(self) -> List[UInt8]:
        """A copy of the line `next_frame` found, CRLF excluded."""
        var out = List[UInt8]()
        out.extend(Span(self.rx)[self.rx_off : self.line_end])
        return out^

    # ---- transaction ------------------------------------------------------

    def reset_transaction(mut self):
        """Forget the envelope and the message; a connection that is not
        closing goes back to waiting for MAIL."""
        self.mail_from = String("")
        self.declared_size = -1
        self.body_8bit = False
        self.recipients = List[String]()
        self.data = List[UInt8]()
        self.data_overflow = False
        self.commands_in_txn = 0
        if self.state != SMTP_STATE_CLOSING and self.state != SMTP_STATE_GREETED:
            self.state = SMTP_STATE_READY

    def reset_for_tls(mut self):
        """RFC 3207 section 4.2: the server forgets what the client said before
        the handshake. The transaction, the greeting name, the verified user
        and any AUTH exchange are cleared and the client must send EHLO again."""
        self.reset_transaction()
        self.helo = String("")
        self.authed_user = String("")
        self.auth_stage = 0
        self.auth_user_b64 = String("")
        if self.state != SMTP_STATE_CLOSING:
            self.state = SMTP_STATE_GREETED

    def mark_closing(mut self):
        self.closing = True
        self.state = SMTP_STATE_CLOSING


# What the serving loop does after a line.
comptime SMTP_ACTION_CONTINUE: UInt8 = 0
comptime SMTP_ACTION_CLOSE: UInt8 = 1  # flush the replies, then close
comptime SMTP_ACTION_START_TLS: UInt8 = 2  # flush the 220, then start TLS
comptime SMTP_ACTION_ENTER_DATA: UInt8 = 3  # the next lines are message text


struct CommandResult(Copyable, Movable):
    """The reply text for one line and what to do next. The reply is ASCII
    ending in CRLF (several lines for EHLO)."""

    var reply: String
    var action: UInt8

    def __init__(out self, reply: String, action: UInt8 = SMTP_ACTION_CONTINUE):
        self.reply = reply
        self.action = action
