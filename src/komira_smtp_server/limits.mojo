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
comptime SMTP_DEFAULT_MAX_COMMANDS: Int = 1000
comptime SMTP_DEFAULT_MAX_AUTH_FAILURES: Int = 3
comptime SMTP_DEFAULT_MAX_TX_BYTES: Int = 1024 * 1024


struct SmtpLimits(Copyable, Movable):
    """Resource limits, one value each.

    `max_line` and `max_data_line` count the CRLF. `max_commands` is the
    number of command lines one transaction may carry (EHLO, RSET and a
    finished message start a new count). `max_conns` and `idle_ms` are read by
    `SmtpRegistry.accept` and `SmtpRegistry.idle_ids`; the serve loop that
    owns the sockets enforces them. `max_tx_bytes` bounds the replies queued
    for a peer that does not read: past it the connection is closed."""

    var max_line: Int
    var max_data_line: Int
    var max_message_bytes: Int
    var max_recipients: Int
    var max_conns: Int
    var idle_ms: Int
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
