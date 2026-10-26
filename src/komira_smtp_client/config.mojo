# What a send is told: where to connect, how the connection is protected, what
# to say in EHLO, what to trust, and how long each stage may take. Values only.

from .clock import SmtpClock

comptime SMTP_DEFAULT_SUBMISSION_PORT: UInt16 = 587
"""The submission port (RFC 6409); STARTTLS is the usual security on it."""

comptime SMTP_DEFAULT_CONNECT_BUDGET_US: Int = 30_000_000
comptime SMTP_DEFAULT_COMMAND_BUDGET_US: Int = 120_000_000
comptime SMTP_DEFAULT_DATA_BUDGET_US: Int = 600_000_000

comptime SMTP_DEFAULT_MAX_REPLY_LINE_BYTES: Int = 4096
"""The longest reply line the client buffers (RFC 5321 section 4.5.3.1.5 says
512 including CRLF; real servers send more in EHLO and AUTH lines)."""


struct SmtpSecurity(Copyable, Movable):
    """How the connection is protected."""

    var _kind: Int

    def __init__(out self, kind: Int):
        self._kind = kind

    @staticmethod
    def starttls() -> SmtpSecurity:
        """Plain connect, then STARTTLS (RFC 3207), required: a server that
        does not offer it, or whose handshake or certificate check fails, ends
        the send with an error. There is no fallback to the clear."""
        return SmtpSecurity(0)

    @staticmethod
    def implicit_tls() -> SmtpSecurity:
        """TLS from the first byte (port 465, RFC 8314)."""
        return SmtpSecurity(1)

    @staticmethod
    def plaintext() -> SmtpSecurity:
        """No TLS, and AUTH is sent in the clear. For tests and for a relay on
        a private loopback or socket only; never across a network you do not
        control."""
        return SmtpSecurity(2)

    def is_starttls(self) -> Bool:
        return self._kind == 0

    def is_implicit_tls(self) -> Bool:
        return self._kind == 1

    def is_plaintext(self) -> Bool:
        return self._kind == 2


struct SmtpCredentials(Copyable, Movable):
    """A user name and a password for AUTH. They are passed to one send and
    the client keeps neither. The type has no `Writable` form, so printing it
    does not compile, and no error text of this package holds the password."""

    var username: String
    var password: String

    def __init__(out self, var username: String, var password: String):
        self.username = username^
        self.password = password^


struct SmtpClientConfig(Copyable, Movable):
    """The settings of one connection. Build one with the constructor and set
    the public fields you need to change.

    `host` and `port` are connected to over IPv4 (a name is resolved with
    getaddrinfo on the calling thread). `tls_server_name` is the name the
    server's certificate must carry (and the SNI value); empty means `host`.
    `tls_trust_pem` empty means the system's root certificates; a PEM text
    means exactly those roots and no others. A certificate that does not chain
    to the roots, or does not name `tls_server_name`, fails the handshake.

    Budgets are microseconds on `clock`: `connect_budget_us` for the TCP
    connect, `command_budget_us` for each command with its reply (and for the
    TLS handshake), `data_budget_us` for the message body with the reply that
    ends DATA."""

    var host: String
    var port: UInt16
    var security: SmtpSecurity
    var ehlo_name: String
    var tls_server_name: String
    var tls_trust_pem: String
    var connect_budget_us: Int
    var command_budget_us: Int
    var data_budget_us: Int
    var max_reply_line_bytes: Int
    var clock: SmtpClock

    def __init__(
        out self,
        var host: String,
        port: UInt16 = SMTP_DEFAULT_SUBMISSION_PORT,
        var security: SmtpSecurity = SmtpSecurity.starttls(),
        var ehlo_name: String = String("localhost"),
    ):
        self.host = host^
        self.port = port
        self.security = security^
        self.ehlo_name = ehlo_name^
        self.tls_server_name = String("")
        self.tls_trust_pem = String("")
        self.connect_budget_us = SMTP_DEFAULT_CONNECT_BUDGET_US
        self.command_budget_us = SMTP_DEFAULT_COMMAND_BUDGET_US
        self.data_budget_us = SMTP_DEFAULT_DATA_BUDGET_US
        self.max_reply_line_bytes = SMTP_DEFAULT_MAX_REPLY_LINE_BYTES
        self.clock = SmtpClock.system()

    def effective_tls_server_name(self) -> String:
        """The name the certificate is checked against."""
        if self.tls_server_name.byte_length() > 0:
            return self.tls_server_name
        return self.host


def check_ehlo_name(name: String) raises:
    """Refuse an EHLO argument that could break the command line: it must be
    printable ASCII without a space (a domain or an address literal)."""
    var b = name.as_bytes()
    if len(b) == 0 or len(b) > 255:
        raise Error("SmtpConfig: ehlo_name must be 1 to 255 bytes")
    for i in range(len(b)):
        if b[i] <= 0x20 or b[i] >= 0x7F:
            raise Error(
                "SmtpConfig: ehlo_name must be printable ASCII without a space"
            )


def check_config(config: SmtpClientConfig) raises:
    """Refuse a config that cannot work, before any connection is made."""
    check_ehlo_name(config.ehlo_name)
    if config.host.byte_length() == 0:
        raise Error("SmtpConfig: host is empty")
    if config.connect_budget_us <= 0 or config.command_budget_us <= 0:
        raise Error("SmtpConfig: budgets must be positive")
    if config.data_budget_us <= 0:
        raise Error("SmtpConfig: budgets must be positive")
    if config.max_reply_line_bytes < 16:
        raise Error("SmtpConfig: max_reply_line_bytes must be at least 16")
