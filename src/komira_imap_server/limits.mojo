# The limits and the configuration of an IMAP server: plain values the binary
# fills from flags. Defaults are safe, not unlimited.

# A command line with no literals is short. 16 KiB covers a FETCH or STORE
# with a long list of numbers; the line, CRLF included, is never buffered past
# this.
comptime IMAP_DEFAULT_MAX_LINE: Int = 16 * 1024
comptime IMAP_DEFAULT_MAX_CONNS: Int = 1024
# RFC 3501 section 5.4: an inactivity autologout timer is at least 30 minutes.
comptime IMAP_DEFAULT_IDLE_MS: Int = 1_800_000
comptime IMAP_DEFAULT_MAX_SESSION_MS: Int = 28_800_000
# A connection that has not logged in after this long is closed: the greeting
# is cheap to hold open and the slot is not.
comptime IMAP_DEFAULT_MAX_UNAUTH_MS: Int = 60_000
comptime IMAP_DEFAULT_MAX_LOGIN_FAILURES: Int = 3
# One message the SMTP side takes is at most 10 MiB, so one FETCH may carry a
# few of them; the queue may hold two such responses.
comptime IMAP_DEFAULT_MAX_FETCH_BYTES: Int = 32 * 1024 * 1024
comptime IMAP_DEFAULT_MAX_TX_BYTES: Int = 64 * 1024 * 1024
comptime IMAP_DEFAULT_MAX_MESSAGES: Int = 100_000
# Every STORE, \Seen set by a fetch and EXPUNGE appends to a folder's flag
# log, and every command folds it; past this many chunks it is folded into one.
comptime IMAP_DEFAULT_COMPACT_FLAG_LOG_AT: Int = 256


struct ImapLimits(Copyable, Movable):
    """Resource limits, one value each.

    `max_line` counts the CRLF: a longer line closes the connection with a
    `* BYE`, and nothing past `max_line` bytes is ever buffered. `max_conns`
    is read by `ImapRegistry.accept`. `idle_ms`, `max_session_ms` and
    `max_unauth_ms` are read by `ImapRegistry.expired_ids`: no byte received
    for `idle_ms`, a connection older than `max_session_ms`, a connection
    still not logged in after `max_unauth_ms` (a value of 0 or less turns
    `max_session_ms` or `max_unauth_ms` off). The serve loop that owns the
    sockets closes what it reports. `max_login_failures`: the failed LOGINs
    one connection may make; the one that reaches the count is answered `NO`,
    then `* BYE`, and the connection closes.

    `max_fetch_bytes` bounds the message bytes one FETCH may return (the
    command is refused with `NO [LIMIT]` before any is read), `max_tx_bytes`
    the replies queued for a peer that does not read (past it the connection
    is closed), and `max_messages` the messages a SELECT may list (the view of
    the folder is held in memory for the life of the selection).
    `compact_flag_log_at`: a command that changed flags folds the folder's
    flag log into one chunk when it has more than this many.

    Memory: one connection holds at most `max_tx_bytes` of replies, the
    selected folder's view (about 100 bytes per message) and about 20 KB of
    receive buffer. Nothing here bounds the sum over `max_conns` connections:
    the binary's flags must keep `max_conns * max_tx_bytes` within the
    machine."""

    var max_line: Int
    var max_conns: Int
    var idle_ms: Int
    var max_session_ms: Int
    var max_unauth_ms: Int
    var max_login_failures: Int
    var max_fetch_bytes: Int
    var max_tx_bytes: Int
    var max_messages: Int
    var compact_flag_log_at: Int

    def __init__(
        out self,
        max_line: Int = IMAP_DEFAULT_MAX_LINE,
        max_conns: Int = IMAP_DEFAULT_MAX_CONNS,
        idle_ms: Int = IMAP_DEFAULT_IDLE_MS,
        max_session_ms: Int = IMAP_DEFAULT_MAX_SESSION_MS,
        max_unauth_ms: Int = IMAP_DEFAULT_MAX_UNAUTH_MS,
        max_login_failures: Int = IMAP_DEFAULT_MAX_LOGIN_FAILURES,
        max_fetch_bytes: Int = IMAP_DEFAULT_MAX_FETCH_BYTES,
        max_tx_bytes: Int = IMAP_DEFAULT_MAX_TX_BYTES,
        max_messages: Int = IMAP_DEFAULT_MAX_MESSAGES,
        compact_flag_log_at: Int = IMAP_DEFAULT_COMPACT_FLAG_LOG_AT,
    ):
        self.max_line = max_line
        self.max_conns = max_conns
        self.idle_ms = idle_ms
        self.max_session_ms = max_session_ms
        self.max_unauth_ms = max_unauth_ms
        self.max_login_failures = max_login_failures
        self.max_fetch_bytes = max_fetch_bytes
        self.max_tx_bytes = max_tx_bytes
        self.max_messages = max_messages
        self.compact_flag_log_at = compact_flag_log_at


struct ImapServerConfig(Copyable, Movable):
    """What a listener is.

    `hostname` appears in the greeting. `require_tls_for_login`: LOGIN is
    refused with `NO [PRIVACYREQUIRED]` and `LOGINDISABLED` is advertised
    until the connection is on TLS. `offer_starttls`: advertise and accept
    STARTTLS; a server without a certificate sets it False (and then, with
    `require_tls_for_login` True, nobody can log in)."""

    var hostname: String
    var require_tls_for_login: Bool
    var offer_starttls: Bool
    var limits: ImapLimits

    def __init__(
        out self,
        hostname: String,
        require_tls_for_login: Bool = True,
        offer_starttls: Bool = True,
        limits: ImapLimits = ImapLimits(),
    ):
        self.hostname = hostname
        self.require_tls_for_login = require_tls_for_login
        self.offer_starttls = offer_starttls
        self.limits = limits.copy()
