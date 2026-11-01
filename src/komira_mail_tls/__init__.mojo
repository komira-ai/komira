"""STARTTLS for a mail server: a side table of server-mode TLS connections
keyed by connection id.

A mail server speaks plaintext first and upgrades a connection when the client
sends `STARTTLS`. `MailTlsTable` holds the server's certificate and key once
and, for each upgraded connection, a TLS connection bound to the connection's
socket. The server's own connection table is not touched: the loop asks
`is_tls(conn_id)` and routes that connection's reads and writes through
`recv` and `send` instead of the plaintext calls.

| name | does |
|---|---|
| `MailTlsTable.from_cert_pem` | build the table from a PEM certificate chain and a PKCS#8 PEM key (the caller loads the files) |
| `begin_upgrade` | start TLS on `conn_id` over its socket; refuses while undecoded plaintext is buffered |
| `drive_handshake_burst` | advance the handshake once; the loop calls it each iteration until `DONE` |
| `recv`, `send` | decrypt into a buffer, encrypt from a span |
| `conn_fd` | the socket a connection's TLS state is bound to |
| `drop` | free a connection's TLS state when it closes (the socket stays the caller's) |
| `tls_entries_created`, `tls_entries_freed` | TEST-HOOK: process-wide tallies that let a test see every entry freed exactly once |
"""

from .ledger import tls_entries_created, tls_entries_freed
from .mail_tls import MailTlsTable
from komira_http_core.tls import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
)
