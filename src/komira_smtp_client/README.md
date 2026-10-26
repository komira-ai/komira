# komira_smtp_client

An SMTP client for sending mail from Mojo: connect to a submission server, secure the connection, authenticate, and send a message built with `komira_mail_message.MessageBuilder` (or any bytes). It is a client only. It does not receive mail and does not run a server (that is `komira_smtp_server`). It speaks RFC 5321, STARTTLS (RFC 3207), AUTH (RFC 4954), the submission rules of RFC 6409, and the size, 8-bit and UTF-8 extensions (RFC 1870, 6152, 6531).

```text
from komira_mail_address import AddrSpec
from komira_mail_message import MessageBuilder
from komira_smtp_client import (
    SmtpClientConfig,
    SmtpCredentials,
    SmtpSecurity,
    send_built_message,
)

def main() raises:
    var b = MessageBuilder()
    b.set_from("Ann", AddrSpec("ann", "example.com"))
    b.add_to("Bob", AddrSpec("bob", "example.org"))
    b.set_subject("hello")
    b.set_text("a line\n.a line that starts with a dot\n")

    var config = SmtpClientConfig(String("smtp.example.com"))  # port 587, STARTTLS
    config.ehlo_name = String("client.example.com")

    var recipients = List[String]()
    recipients.append(String("bob@example.org"))
    var creds = Optional[SmtpCredentials](
        SmtpCredentials(String("ann"), String("her password"))
    )
    var result = send_built_message(
        config, creds, String("ann@example.com"), recipients, b
    )
    if result.is_accepted():
        print("queued:", result.text)   # usually the server's queue id
    elif result.is_transient():
        print("try again later:", result.code, result.text)
    else:
        print("refused:", result.stage, result.code, result.text)
```

The same send against a scripted server, which runs with no network (this is the program the README gate runs):

```mojo
from komira_http_core.transport.scripted import ScriptedStream
from komira_mail_address import AddrSpec
from komira_mail_message import MessageBuilder
from komira_smtp_client import (
    NoWaitHook,
    SmtpClientConfig,
    SmtpSecurity,
    SmtpSession,
    send_via_session,
)


def main() raises:
    var b = MessageBuilder()
    b.set_from("Ann", AddrSpec("ann", "example.com"))
    b.add_to("Bob", AddrSpec("bob", "example.org"))
    b.set_subject("hello")
    b.set_text("a line\n.a line that starts with a dot\n")
    var message = b.build()

    var script = String(
        "220 smtp.example.org ready\r\n250 smtp.example.org\r\n250 ok\r\n"
        "250 ok\r\n354 go ahead\r\n250 2.0.0 queued as Q1\r\n221 bye\r\n"
    )
    var server = List[UInt8]()
    server.extend(script.as_bytes())

    var config = SmtpClientConfig(
        String("smtp.example.org"),
        UInt16(25),
        SmtpSecurity.plaintext(),
        String("client.example.com"),
    )
    var session = SmtpSession[ScriptedStream, NoWaitHook].new(
        ScriptedStream.from_read_script(server^), NoWaitHook(), config
    )
    var recipients = List[String]()
    recipients.append(String("bob@example.org"))
    var result = send_via_session(
        session^,
        config,
        None,
        String("ann@example.com"),
        recipients,
        Span(message),
    )
    if not result.is_accepted():
        raise Error("not accepted: " + result.text)
    print("queued:", result.text)
```

## What does a send do?

`send_message(config, creds, mail_from, recipients, message)` connects, reads the greeting, says EHLO, secures the connection as `config.security` says, authenticates when `creds` is given, sends MAIL FROM, one RCPT TO per recipient and DATA, and QUITs. `send_built_message` is the same for a `MessageBuilder`. A caller that sends several messages on one connection uses `SmtpSession` directly (`read_greeting`, `ehlo`, `starttls_command`, `upgrade_tls`, `authenticate`, `send`, `quit`); an RSET goes before every message after the first. `send_via_session` runs the same steps over a session you opened on any `IoStream`.

- Addresses are `local@domain`, without angle brackets; an empty sender is the null path of a bounce. All of them are checked before any command is sent, with `komira_mail_address.parse_path`. The message must be non-empty.
- The message is sent with every line break written CRLF (a bare LF or CR becomes CRLF, a final CRLF is added), lines that start with `.` stuffed, and `.` CRLF at the end.
- If the server announces `SIZE` and the message is larger, the send is refused before MAIL. A message with bytes above 0x7F is refused when the server does not announce `8BITMIME` (the client does not re-encode it). An address with non-ASCII bytes needs `SMTPUTF8`: it is refused when the server does not announce it, and `SMTPUTF8` is added to MAIL FROM when it does.
- If no recipient is accepted the client sends RSET and does not send DATA. If some are, the message is sent to those and the result lists each recipient's code and text.

## Security

`SmtpSecurity.starttls()` (the default) connects in the clear, requires the server to offer STARTTLS, and runs the TLS handshake on the same connection. If the server does not offer it, the handshake fails, or the certificate does not verify, the send raises `SmtpSecurity` and nothing else is written. There is no fallback to the clear. The capabilities announced before TLS are discarded and EHLO is sent again (RFC 3207 section 4.2). Bytes the server sends behind its `220 Ready` to STARTTLS end the send too: they could have been injected.

`SmtpSecurity.implicit_tls()` runs TLS from the first byte (port 465). `SmtpSecurity.plaintext()` does neither; it is for tests and for a relay on a private loopback only, and AUTH then goes in the clear.

The certificate must chain to `tls_trust_pem` (a PEM text: exactly those roots) or, when that is empty, to the system roots, and must name `tls_server_name` (default: `host`). There is no setting that turns verification off. TLS is TLS 1.3 and 1.2 (`default_tls13`). The connection is IPv4.

AUTH is PLAIN, or LOGIN when PLAIN is not offered, and only over TLS unless the security is `plaintext()`. Credentials are passed to the one call and are not stored. The password appears in no error or result text: a reply that echoes it, or its base64 forms, comes back with `***` in its place.

## What does a result and an error say?

A server's answer comes back as a value. `SendResult.outcome` is `SEND_ACCEPTED` (a 2xx after DATA: `text` is the final text, usually the queue id, `enhanced` its RFC 3463 code), `SEND_TRANSIENT` (a 4xx: try again later) or `SEND_PERMANENT` (a 5xx, or an unexpected reply). `stage` says where it ended (`greeting`, `ehlo`, `starttls`, `auth`, `mail`, `rcpt`, `data`, `end-of-data`), and `recipients` has one entry per RCPT TO. A message accepted for some recipients and refused for others is accepted, with `accepted_count()` below the recipient count.

Everything that is not a reply is raised as an error whose text starts with a kind: `SmtpTimeout` and `SmtpTransport` (retryable: `error_is_retryable`), `SmtpProtocol` (a malformed or over-long reply), `SmtpSecurity`, `SmtpAuth`, `SmtpEnvelope` (a bad address, SIZE, 8-bit or SMTPUTF8 refusal), `SmtpConfig`. After one the connection is closed.

## Budgets

`connect_budget_us`, `command_budget_us` (each command with its reply, and the TLS handshake) and `data_budget_us` (the message body and the reply that ends DATA) are microseconds on `config.clock`. The system's monotonic clock is the default; a test passes `SmtpClock.manual(cell)` and moves time itself. When a budget runs out the connection is closed and a `SmtpTimeout` naming the stage is raised. A reply line is at most `max_reply_line_bytes` (4096), a reply at most 512 lines and 64 KiB, so a hostile server cannot grow memory without bound. The connect budget is passed to the TCP connect; DNS resolution is not bounded by it.

## What it does not do

- No pipelining: each command is written and its reply read before the next, whatever the server announces.
- No OAUTH2, XOAUTH2, CRAM-MD5 or SCRAM; no DSN, no CHUNKING or BINARYMIME, no `BDAT`.
- No MX lookup, no queue, no retry: it submits to the one host in the config and tells the caller whether to retry.
- No re-encoding of an 8-bit message to 7-bit, and no IPv6 connect.
- It blocks the calling thread for the length of one send. `WaitHook` lets a test run the server in the same thread.

## Tests

`tests/test_reply_wire.mojo` (parsing, DATA bytes, the envelope), `tests/test_session.mojo` (every command and reply path over `ScriptedStream`, the budgets on a manual clock), `tests/test_policy.mojo` (STARTTLS and implicit-TLS policy: what is never written), and `tests/test_loopback.mojo` (a message over STARTTLS with AUTH PLAIN to `komira_smtp_server` on 127.0.0.1 with the real handshake, a bad password, an untrusted certificate, a wrong certificate name, a server without STARTTLS, a refused connection). The server has no implicit-TLS listener, so that path is tested on `ScriptedStream` only.
