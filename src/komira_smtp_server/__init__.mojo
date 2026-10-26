"""The socket-free core of an SMTP server for receiving mail (RFC 5321, with
STARTTLS, RFC 3207, and AUTH, RFC 4954): the connection table, the line
framing, the command state machine, the DATA phase and the seam to whatever
stores the mail. The registry reads no socket and no clock; `serve_one_iteration` is the
serving loop that owns the sockets and TLS, caller-polled.

| name | does |
|---|---|
| `SmtpRegistry` | the table of connections: `accept`, `feed` (bytes in, replies queued), `tx_copy` and `tx_consume` (replies out), `mark_tls_active`, `drop`, `idle_ids`, `expired_ids` (`session.mojo`) |
| `FeedOutcome` | what one `feed` did: bytes taken, close, start TLS, and bytes the client pipelined after STARTTLS |
| `SmtpLimits`, `SmtpServerConfig` | plain values the binary fills from flags (`limits.mojo`) |
| `MailDelivery`, `SessionInfo`, `RcptDecision`, `DeliveryResult` | the seam: `accept_recipient` per RCPT and `deliver` once per DATA (`delivery.mojo`) |
| `handle_command_line` | one command line to a reply and an action (`commands.mojo`) |
| `RecordingDelivery`, `SmtpTestSession` | fixtures for tests (`fixtures.mojo`) |
| `ListenSocket`, `bind_smtp_listener` | the listening socket, which owns its descriptor (`listener.mojo`) |
| `serve_one_iteration`, `SmtpServeOutcome` | one caller-polled step over real sockets, with STARTTLS (`serve.mojo`) |
| `LocalMailboxDelivery`, `LocalDomains`, `MailReceiveHook`, `NoopMailReceiveHook` | delivery into komira_mail_store with trace headers and an on-receipt hook (`local_delivery.mojo`) |

Framing is CRLF only. A command line is at most 512 bytes and a message line
1000 (both counting the CRLF); a longer line is answered 500 and the connection
closes, so the receive buffer is bounded. A bare LF or CR in a command is
answered 500 5.5.2 and the rest of that line is discarded; in message text it
closes the connection. DATA ends only at CRLF, a dot, CRLF.

See README.md.
"""

from .commands import (
    ehlo_reply,
    greeting,
    handle_command_line,
)
from .connection import (
    CommandResult,
    SMTP_ACTION_CLOSE,
    SMTP_ACTION_CONTINUE,
    SMTP_ACTION_ENTER_DATA,
    SMTP_ACTION_START_TLS,
    SMTP_STATE_CLOSING,
    SMTP_STATE_DATA,
    SMTP_STATE_GREETED,
    SMTP_STATE_MAIL,
    SMTP_STATE_RCPT,
    SMTP_STATE_READY,
    SmtpConnection,
)
from .delivery import (
    DeliveryResult,
    MailDelivery,
    RcptDecision,
    SessionInfo,
    clean_reply_text,
    delivery_reply,
    rcpt_reply,
)
from .fixtures import RecordingDelivery, SmtpTestSession
from .limits import SmtpLimits, SmtpServerConfig
from .listener import ListenSocket, bind_smtp_listener
from .local_delivery import (
    LocalDomains,
    LocalMailboxDelivery,
    MailReceiveHook,
    NoopMailReceiveHook,
    normalize_local_domain,
)
from .serve import SmtpServeOutcome, serve_one_iteration
from .session import FeedOutcome, SmtpRegistry
from .trace import trace_headers
