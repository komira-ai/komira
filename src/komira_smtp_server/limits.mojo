# The limits and the configuration of an SMTP server: plain values the binary
# fills from flags. Defaults are safe, not unlimited.

# RFC 5321 section 4.5.3.1.4: a command line is at most 512 octets including
# the CRLF.
comptime SMTP_DEFAULT_MAX_LINE: Int = 512
# RFC 5321 section 4.5.3.1.6: a text line is at most 1000 octets including the
# CRLF.
comptime SMTP_DEFAULT_MAX_DATA_LINE: Int = 1000
comptime SMTP_DEFAULT_MAX_MESSAGE_BYTES: Int = 10 * 1024 * 1024
# RFC 5321 section 4.5.3.1.8: at least 100 recipients per transaction.
comptime SMTP_DEFAULT_MAX_RECIPIENTS: Int = 100
comptime SMTP_DEFAULT_MAX_CONNS: Int = 1024
comptime SMTP_DEFAULT_IDLE_MS: Int = 300_000
# One session may last an hour, and the DATA phase of one message ten minutes
# (RFC 5321 section 4.5.3.2.5 sets the same time for the data block).
comptime SMTP_DEFAULT_MAX_SESSION_MS: Int = 3_600_000
comptime SMTP_DEFAULT_MAX_DATA_MS: Int = 600_000
comptime SMTP_DEFAULT_MAX_COMMANDS: Int = 1000
comptime SMTP_DEFAULT_MAX_AUTH_FAILURES: Int = 3
comptime SMTP_DEFAULT_MAX_TX_BYTES: Int = 1024 * 1024


struct SmtpLimits(Copyable, Movable):
    """Resource limits, one value each.

    `max_line` and `max_data_line` count the CRLF. `max_commands` is the
    number of command lines (a line with a bare LF or CR counts) one
    transaction may carry; EHLO, RSET and a finished message start a new
    count, so it bounds a transaction and not the life of a connection (see
    `max_session_ms`). NOOP counts. `max_conns` is read by
    `SmtpRegistry.accept`; `idle_ms`, `max_session_ms` and `max_data_ms` by
    `SmtpRegistry.expired_ids`: no byte received for `idle_ms`, a connection
    older than `max_session_ms`, a DATA phase older than `max_data_ms` (a
    value of 0 or less turns that one off). The serve loop that owns the
    sockets closes what it reports. `max_tx_bytes` bounds the replies queued
    for a peer that does not read: past it the connection is closed.

    Memory: one connection buffers at most `max_message_bytes` of message
    (about twice that while the list grows) plus about 12 KB of receive buffer
    and `max_tx_bytes` of replies. Nothing here bounds the sum over
    `max_conns` connections: the serve loop's flags must keep
    `max_conns * (max_message_bytes + max_tx_bytes)` within the machine."""

    var max_line: Int
    var max_data_line: Int
    var max_message_bytes: Int
    var max_recipients: Int
    var max_conns: Int
    var idle_ms: Int
    var max_session_ms: Int
    var max_data_ms: Int
    var max_commands: Int
    var max_auth_failures: Int
    var max_tx_bytes: Int

    def __init__(
        out self,
        max_line: Int = SMTP_DEFAULT_MAX_LINE,
        max_data_line: Int = SMTP_DEFAULT_MAX_DATA_LINE,
        max_message_bytes: Int = SMTP_DEFAULT_MAX_MESSAGE_BYTES,
        max_recipients: Int = SMTP_DEFAULT_MAX_RECIPIENTS,
        max_conns: Int = SMTP_DEFAULT_MAX_CONNS,
        idle_ms: Int = SMTP_DEFAULT_IDLE_MS,
        max_session_ms: Int = SMTP_DEFAULT_MAX_SESSION_MS,
        max_data_ms: Int = SMTP_DEFAULT_MAX_DATA_MS,
        max_commands: Int = SMTP_DEFAULT_MAX_COMMANDS,
        max_auth_failures: Int = SMTP_DEFAULT_MAX_AUTH_FAILURES,
        max_tx_bytes: Int = SMTP_DEFAULT_MAX_TX_BYTES,
    ):
        self.max_line = max_line
        self.max_data_line = max_data_line
        self.max_message_bytes = max_message_bytes
        self.max_recipients = max_recipients
        self.max_conns = max_conns
        self.idle_ms = idle_ms
        self.max_session_ms = max_session_ms
        self.max_data_ms = max_data_ms
        self.max_commands = max_commands
        self.max_auth_failures = max_auth_failures
        self.max_tx_bytes = max_tx_bytes


struct SmtpServerConfig(Copyable, Movable):
    """What a listener is.

    `require_tls_for_auth`: AUTH is refused with 538 and not advertised until
    the connection is on TLS. `submission`: MAIL needs AUTH (and TLS when
    `require_tls_for_auth`) first, answered 530; a port-25 listener
    (`submission` False) takes mail from anyone and leaves TLS opportunistic.
    `offer_starttls`: advertise and accept STARTTLS; a server without a
    certificate sets it False."""

    var hostname: String
    var require_tls_for_auth: Bool
    var submission: Bool
    var offer_starttls: Bool
    var limits: SmtpLimits

    def __init__(
        out self,
        hostname: String,
        require_tls_for_auth: Bool = True,
        submission: Bool = False,
        offer_starttls: Bool = True,
        limits: SmtpLimits = SmtpLimits(),
    ):
        self.hostname = hostname
        self.require_tls_for_auth = require_tls_for_auth
        self.submission = submission
        self.offer_starttls = offer_starttls
        self.limits = limits.copy()
