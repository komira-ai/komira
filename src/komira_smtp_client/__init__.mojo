"""An SMTP client for submitting mail: connect, secure the connection, AUTH,
send one message or several. See README.md.

| name | what it is |
|---|---|
| `send_message` | connect over TCP, STARTTLS or implicit TLS, AUTH, send one message, QUIT |
| `send_built_message` | the same for a `komira_mail_message.MessageBuilder` |
| `connect_session`, `send_via_session` | a session over a new TCP connection; the one-message send over a session you opened |
| `send_message_with_hook`, `send_built_message_with_hook`, `WaitHook` | test seams: run a peer in the same thread while the client waits; production code uses `NoWaitHook` |
| `SmtpClientConfig`, `SmtpSecurity`, `SmtpCredentials`, `SmtpClock` | the settings: host, security, trust, budgets, clock |
| `SendResult`, `RecipientResult` | the server's answer; `error_is_retryable` classifies a raised error |
| `SmtpSession` | one connection for several messages: `read_greeting`, `ehlo`, `starttls_command`, `upgrade_tls`, `authenticate`, `send`, `quit` |
"""

from .clock import SmtpClock
from .config import (
    SMTP_DEFAULT_COMMAND_BUDGET_US,
    SMTP_DEFAULT_CONNECT_BUDGET_US,
    SMTP_DEFAULT_DATA_BUDGET_US,
    SMTP_DEFAULT_MAX_REPLY_LINE_BYTES,
    SMTP_DEFAULT_SUBMISSION_PORT,
    SmtpClientConfig,
    SmtpCredentials,
    SmtpSecurity,
)
from .reply import SmtpCapabilities, SmtpReply
from .result import (
    RecipientResult,
    SEND_ACCEPTED,
    SEND_PERMANENT,
    SEND_TRANSIENT,
    SendResult,
    error_is_retryable,
)
from .send import (
    connect_session,
    send_built_message,
    send_built_message_with_hook,
    send_message,
    send_message_with_hook,
    send_via_session,
)
from .session import NoWaitHook, SmtpSession, WaitHook
