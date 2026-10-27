# komira_mail_tls

STARTTLS for a mail server. SMTP and IMAP servers start in plaintext and move a
connection to TLS when the client sends `STARTTLS`. `MailTlsTable` is the part
that holds the TLS state: the server's certificate and key once, and one
server-mode TLS connection per upgraded connection, keyed by the server's
connection id. It is a separate table, so a server's own connection records are
not touched. The server asks `is_tls(conn_id)` and, for an upgraded connection,
reads with `recv` and writes with `send` instead of its plaintext calls.

The TLS layer is `komira_http_core.tls` (s2n-tls). s2n is bound to the
connection's socket and does its own reads and writes on it, with no IO
callbacks.

| call | does |
|---|---|
| `MailTlsTable.from_cert_pem(cert_pem, key_pem)` | build the table from a PEM certificate chain and a PKCS#8 PEM key; the caller reads the files; raises on a bad PEM or a key that does not match, without echoing either |
| `begin_upgrade(conn_id, fd, pending_plaintext_bytes)` | start TLS on `conn_id` over `fd`; raises, creating nothing, when `pending_plaintext_bytes` is not 0; a second call for the same id and socket changes nothing, for another socket it raises; `fd` must be non-blocking and the `220` fully flushed |
| `drive_handshake_burst(conn_id)` | advance the handshake once and return `TLS_OUTCOME_DONE`, `TLS_OUTCOME_BLOCKED_ON_READ`, `TLS_OUTCOME_BLOCKED_ON_WRITE` or `TLS_OUTCOME_ERROR` |
| `is_tls`, `handshake_done`, `tls_conn_count`, `conn_fd` | queries; `conn_fd` is the socket an id is bound to, -1 for an unknown id |
| `recv(conn_id, into, max_bytes)` | decrypt at most `max_bytes` (and at most 16 KiB) of plaintext, appended to `into`; `(DONE, 0)` is the peer's close_notify |
| `send(conn_id, data)` | encrypt and send; the count may be short of `len(data)` |
| `drop(conn_id)` | free the connection's TLS state; an unknown id does nothing; the socket stays open and the caller closes it |
| `tls_entries_created`, `tls_entries_freed` | TEST-HOOK: process-wide tallies of entries made and freed (they count the entry wrapper's destructor, not the s2n handle inside) |

The server drives it from its poll loop:

```text
on STARTTLS:   reply "220 Ready to start TLS" and flush it
               begin_upgrade(conn_id, fd, bytes still unconsumed in the rx buffer)
               (it raises if there are any: close the connection)
each iteration until done:   drive_handshake_burst(conn_id)
afterwards:    recv / send in place of the plaintext read and write
on close:      drop(conn_id), then close the fd
```

## Pipelined plaintext after STARTTLS

A client can send commands after `STARTTLS` in the same write. Those bytes
arrived in the clear and must not be run as commands once the connection is on
TLS (RFC 3207, section 4.2). The table cannot see the server's read buffer, so `begin_upgrade` takes its length and refuses a
non-zero one. The server passes the number of bytes it has read and not
consumed, and closes the connection when the call raises.

## Storage

The per-connection state is a `Slab[OwnedPointer[...]]`. `komira_collections`
slabs keep their elements inline in a byte buffer, so a heap-owning element must
not be moved by value; the slab holds only the 8-byte `OwnedPointer` and the TLS
connection stays at a stable heap address. `tests/test_entry_lifetime.mojo`
checks it: a thousand add-and-drop rounds, growth past the slab's first
capacities, removal from the middle, and a table destroyed with live entries
each free every entry exactly once.

## Limits

- The socket must be non-blocking (the table cannot check it) and `drop` sends no close_notify.
- Single-threaded, like the poll loop that uses it. The id lookup is linear.
- The TLS version and cipher policy are `default_tls13`: TLS 1.3 with the
  older versions the s2n policy still allows. No minimum version is pinned.
- No client certificates, no session tickets, no SNI-based certificate choice.
- Server mode only.
