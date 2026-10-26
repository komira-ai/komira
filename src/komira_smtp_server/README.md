# komira_smtp_server

The socket-free core of an SMTP server that receives mail (RFC 5321, with
STARTTLS, RFC 3207, and AUTH, RFC 4954). It holds the connection table, the
line framing, the command state machine, the DATA phase and the seam to
whatever stores the mail. It opens no socket and reads no clock: a serving loop
reads bytes, hands them to `SmtpRegistry.feed`, writes the replies it queued,
and owns TLS. The package is a library, not a server: nothing here listens.

## How a serving loop uses it

```text
accept a socket        id = registry.accept(fd, config, now_ms, peer)
                       (None: send "421 4.3.2" and close the socket)
                       write the queued 220: tx_copy / tx_consume
bytes arrive           outcome = registry.feed(id, bytes, config, verifier, delivery, now_ms)
                       write the queued replies
outcome.closing        flush the replies, then drop(id) and close the socket
outcome.starttls       flush the 220. If pending_after_starttls is not 0, close:
                       the client pipelined bytes in the clear (RFC 3207, 4.2).
                       Otherwise drive the TLS handshake, then mark_tls_active(id)
                       and read and write through TLS from then on
expired connections    expired_ids(now_ms, config) names those to close (send
                       "421 4.4.2" first): no bytes for idle_ms, older than
                       max_session_ms, or in DATA longer than max_data_ms
```

`feed` takes the bytes in pieces of at most 4096, so the receive buffer holds
about that plus one line however large a read is. Bytes after QUIT, a fatal
error or STARTTLS in the same chunk are not run; `consumed` and
`pending_after_starttls` say what happened to them.

## What the server does

- Framing is CRLF only. A command line is at most 512 bytes and a message line
  1000, both counting the CRLF (`SmtpLimits`). A longer line is answered 500
  and the connection closes. A bare LF or CR in a command is answered
  `500 5.5.2` and the rest of that line is dropped, so a command hidden behind
  it never runs; in message text it closes the connection.
- DATA ends only at CRLF, a dot, CRLF (also when the first line is the dot). A
  line with a leading dot loses one. Past `max_message_bytes` nothing more is
  kept: the text up to the terminator is read and dropped, the answer is 552
  and the delivery is not called.
- EHLO and HELO end a transaction like RSET. MAIL needs `FROM:` and RCPT needs
  `TO:`, each with a path that `komira_mail_address` accepts (501 otherwise);
  `STARTTLS` matches the whole word; VRFY, EXPN and HELP are 502. EHLO
  advertises PIPELINING, 8BITMIME, SIZE n and ENHANCEDSTATUSCODES, STARTTLS on
  a clear channel when `offer_starttls` is set, and AUTH PLAIN LOGIN once the
  connection is on TLS.
- MAIL FROM parameters: `SIZE=n` over the cap is 552 at once, `BODY=7BIT` and
  `BODY=8BITMIME` are accepted, anything else is 555. RCPT takes none.
  `max_recipients` answers 452.
- AUTH (PLAIN and LOGIN, through `komira_mail_auth`) works only on TLS unless
  `require_tls_for_auth` is off (538), is refused after a success and inside a
  transaction (503), and the failed attempts of one connection are capped: the
  attempt that reaches `max_auth_failures` is answered 421 and the connection
  closes. On a `submission` listener MAIL needs TLS and AUTH first (530); a
  port-25 listener takes mail from anyone.
- STARTTLS wipes the EHLO name, the transaction and the verified user, and the
  client must send EHLO again.
- The number of command lines in one transaction (`max_commands`; NOOP and a
  line with a bare LF or CR count, and EHLO, RSET and a finished message start
  a new count) and the queued, unwritten replies (`max_tx_bytes`; a bare LF
  or CR line pays for its reply like any other) are capped; a connection past
  either gets 421 and closes. A connection cannot be held open by trickling
  bytes: `expired_ids` also reports it once it is older than `max_session_ms`
  or has been in DATA longer than `max_data_ms`.
- `RCPT TO:<postmaster>` without a domain is accepted in any letter case
  (RFC 5321 section 4.5.1) and reaches the delivery as `postmaster`.
- A user name from AUTH that holds a control character (CR, LF, DEL ...) is
  refused 535 before the verifier is asked and counts as a failed attempt, so
  `SessionInfo.authed_user` is safe to put in a trace header line.

## The delivery seam

`MailDelivery` has two methods. `accept_recipient(session, mail_from, rcpt)` is
called once per RCPT that parsed and is under the recipient cap, and answers a
`RcptDecision`: code 0 (or 250) accepts; a 4xx or 5xx code is the reply, with
its text; any other code is answered 451. `deliver(session, mail_from,
recipients, message, now_ms)` is called once per finished DATA with the
dot-unstuffed message (every line ending in CRLF, borrowed for the call) and
answers a `DeliveryResult`: 250 and a queue id, or 451, 554 or 552; any other
code is answered 451. `deliver` cannot raise, and it is all-or-nothing for one
message. Whatever the answer, the transaction is over afterwards, so a 451 leaves
a clean connection for the retry. Text from a delivery is reduced to printable
ASCII and 200 bytes before it reaches a reply.

`SessionInfo` carries `peer_tls`, `authed_user` (set only by a verified AUTH,
cleared by STARTTLS, free of control characters), `submission`, the `peer` text
given to `accept`, the EHLO name, the `conn_id` of the connection (to key
per-connection state such as a recipient-failure count), and what MAIL declared:
`declared_size` (-1 if none) and `body_8bit`. The `mail_from` argument is the
empty string for the null reverse-path (`MAIL FROM:<>`, a bounce). A recipient
`postmaster` has no domain. `accept_recipient` is a check made at RCPT time;
`deliver` gets the recipients again and must resolve and authorise each one
itself. A text in a decision or result normally starts with an enhanced status
code; the defaults do, and a text without one is sent as given.

## Fixtures

`RecordingDelivery` (a scripted delivery that records every call) and
`SmtpTestSession` (one connection, a `TestAuthVerifier`, a clock the test sets)
are in the package for tests of this server and of the loop that serves it.

## Limits

- No socket, TLS, listener or clock here; those belong to the serving loop.
- The receive-line cap for AUTH is 512 bytes when the initial response is on
  the AUTH line, so a very long initial response needs the two-step form; a
  continuation answer may be 12288 bytes.
- Memory is bounded per connection (`max_message_bytes` of message, about
  twice that while the buffer grows, about 12 KB of receive buffer and
  `max_tx_bytes` of replies) and not over the table: the serving loop must size
  `max_conns` so that `max_conns * (max_message_bytes + max_tx_bytes)` fits the
  machine. The refusal reply when `accept` returns None, and the timers, are the
  loop's.
- The connection lookup by id is linear.
- Source routes, SMTPUTF8, DSN parameters, BDAT and CHUNKING are not supported.
