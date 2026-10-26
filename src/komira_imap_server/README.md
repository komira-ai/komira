# komira_imap_server

An IMAP4rev1 server for reading received mail (RFC 3501, with STARTTLS as in
RFC 2595): the connection table, the line framing, the command state machine,
durable message flags, and a serve loop over non-blocking sockets. The mail
lives in any `komira_objectstore` store, laid out by `komira_mail_store`: this
server reads what `komira_smtp_server` wrote there. This is part A of the
server: ENVELOPE, BODYSTRUCTURE, body sections and SEARCH are a later part.

**It is a subset, and its UIDs are not general-purpose IMAP UIDs.** Use it to
read, flag and delete mail with a client that does not need more; do not call
it "an IMAP server" until a per-folder UID counter exists. See "UIDs" below.

**The serve loop is caller-polled.** `serve_one_iteration` never blocks and
never waits for readiness: it does what the sockets allow now and returns. Until
a binary has a readiness driver (epoll or a timer in a program of its own), the
caller must poll it in a loop, and a bare loop spins; the caller also passes the
clock as `now_ms`, which is how idle and session deadlines work. The package is
a library: nothing here starts a thread or a process. A readiness driver must
not wait on the descriptor alone for a TLS connection: bytes already decrypted
or buffered inside TLS do not make the descriptor readable again, and one
iteration reads a bounded amount per connection, so the driver has to call the
loop again while any TLS connection may hold data.

**The mail comes from an unauthenticated MX.** `komira_smtp_server` checks no
SPF, DKIM or DMARC, so a spoofed message is stored like any other and this
server shows it as ordinary mail. What a message says about its sender is what
the sender wrote, except for the trace headers the SMTP side adds on top
(`Return-Path`, `Received`, `Authentication-Results: <host>; none`); a reader
of stored mail should take the first of each.

```mojo
from komira_imap_server import ImapServerConfig, ImapTestServer
from komira_mail_store import store_message
from komira_objectstore import SharedInMemoryConditionalStore
from std.testing import assert_equal, assert_true

var raw = List[UInt8]()
for b in "Subject: hello\r\n\r\nhi\r\n".as_bytes():
    raw.append(b)

# A server over an in-memory store. LOGIN without TLS is allowed here only
# because the example has no socket.
var config = ImapServerConfig("imap.example.com", False)
var server = ImapTestServer[SharedInMemoryConditionalStore](
    config^, SharedInMemoryConditionalStore()
)
server.add_user("bob@example.com", "pw")
_ = store_message(server.store, "bob@example.com", "INBOX", raw)

var conn = server.connect()
_ = server.login(conn, "bob@example.com", "pw")
var selected = server.send(conn, "a1 SELECT INBOX\r\n")
assert_true(selected.startswith("* 1 EXISTS\r\n"))
var fetched = server.send(conn, "a2 FETCH 1 (FLAGS BODY.PEEK[])\r\n")
assert_true(fetched.endswith("a2 OK FETCH completed\r\n"))
assert_equal(
    server.send(conn, "a3 STORE 1 +FLAGS (\\Deleted)\r\n"),
    "* 1 FETCH (FLAGS (\\Deleted))\r\na3 OK STORE completed\r\n",
)
assert_equal(
    server.send(conn, "a4 EXPUNGE\r\n"),
    "* 1 EXPUNGE\r\na4 OK EXPUNGE completed\r\n",
)
```

## Serving

```text
var listener = bind_imap_listener(inet_any_be(), UInt16(143))   # port 0 for a test
var reg = ImapRegistry()
var tls = MailTlsTable.from_cert_pem(cert_pem, key_pem)         # or MailTlsTable(TlsConfig()) with
                                                                # no certificate and offer_starttls False
while running:
    serve_one_iteration(reg, listener, tls, verifier, store, config, now_ms)
```

One call, in order: accepts waiting connections (at `max_conns` the peer gets
`* BYE` and the socket is closed); for each connection advances a STARTTLS
handshake or reads (the socket, or `MailTlsTable.recv` once on TLS), feeds the
registry, and writes the queued replies; starts the TLS upgrade after the OK of
STARTTLS is written; closes what is finished or whose peer is gone; and sends
`* BYE` to and closes what `expired_ids` names. The plaintext and the TLS
connection are one code path. The listener is the `ListenSocket` of
`komira_smtp_server` (it owns its descriptor and closes it when it is
destroyed), so a binary that serves both protocols holds one kind of listener.

- STARTTLS: the OK is written and flushed first. If the client sent bytes behind
  STARTTLS in the clear (`pending_after_starttls`), the connection is closed and
  none of them runs; `begin_upgrade` also refuses a connection with buffered
  plaintext, so the rule holds at two layers. When TLS starts, the connection
  starts over: the client must LOGIN and may ask for the capabilities again.
- No certificate: build the table with `MailTlsTable(TlsConfig())` and set
  `offer_starttls` False. STARTTLS is then neither offered nor accepted
  (`NO [CANNOT]`).
- A socket, TLS or store error drops or refuses only what it happened to. The
  loop does not raise.
- `ImapRegistry` opens no socket and reads no clock. `feed` takes the bytes, the
  verifier, the store and `now_ms`, and queues the replies.

## The commands

| command | does |
|---|---|
| `CAPABILITY`, `NOOP`, `LOGOUT` | as RFC 3501; `NOOP` does not report mail that arrived since SELECT |
| `STARTTLS` | before LOGIN, on a clear channel with a certificate |
| `LOGIN` | through `komira_mail_auth.MailAuthVerifier`; only on TLS unless `require_tls_for_login` is off |
| `SELECT`, `EXAMINE` | opens a folder: EXISTS, RECENT 0, FLAGS, PERMANENTFLAGS, UIDVALIDITY, UIDNEXT, `[READ-WRITE]` or `[READ-ONLY]` |
| `LIST` | the user's folders, with `\HasChildren` or `\HasNoChildren`, `*` and `%` patterns |
| `FETCH`, `UID FETCH` | `FLAGS`, `UID`, `BODY[]`, `BODY.PEEK[]`, `RFC822`, one item or a list |
| `STORE`, `UID STORE` | `FLAGS`, `+FLAGS`, `-FLAGS`, each with `.SILENT`; the five system flags |
| `EXPUNGE` | deletes the `\Deleted` messages, answering `* n EXPUNGE` highest first |
| `CLOSE` | the silent expunge, then leaves the folder (none after EXAMINE) |

Anything else that IMAP4rev1 defines (`SEARCH`, `APPEND`, `CREATE`, `DELETE`,
`RENAME`, `SUBSCRIBE`, `LSUB`, `STATUS`, `COPY`, `CHECK`, `AUTHENTICATE`, `UID
SEARCH`, `UID EXPUNGE` ...) is answered `NO [CANNOT]`; a FETCH item it does not
do (`ENVELOPE`, `BODYSTRUCTURE`, `INTERNALDATE`, `RFC822.SIZE`,
`RFC822.HEADER`, `RFC822.TEXT`, a `BODY[<section>]`, a partial fetch, the macros
`ALL`, `FAST` and `FULL`) is `NO [CANNOT]` before any message is read; a word
that is not a command or an item is `BAD`. Not offered: APPEND, IDLE, CONDSTORE
(`HIGHESTMODSEQ` is never sent), LITERAL+, UIDPLUS, NAMESPACE, UNSELECT, ID.
IMAP4rev1 only; RFC 9051 is out of scope.

- `BODY[]` and `RFC822` set `\Seen` on a folder opened read-write, durably, and
  the answer carries `FLAGS` when the flag changed; `BODY.PEEK[]` does not,
  and nothing does after EXAMINE. The message bytes go out exactly as stored.
- A set is `n`, `a:b`, `*` and lists of them (`*` is the largest sequence
  number, or the largest UID for the UID forms); numbers past the end are
  skipped; a 0, an empty item or more than 1024 ranges is `BAD`. A range as
  wide as numbers go costs the messages in the folder, not its width.
- STORE accepts `\Seen`, `\Answered`, `\Flagged`, `\Deleted` and `\Draft`.
  `\Recent` and keywords are `NO [CANNOT]`, and a command that names one of
  them changes nothing.
- A message another connection deleted since SELECT is skipped, and the FETCH
  ends `NO [EXPUNGEISSUED]`. A FETCH whose message bytes would pass
  `max_fetch_bytes` is `NO [LIMIT]` before any is read.
- A store failure is `NO [SERVERBUG] Internal error, try again`, with nothing
  of the failure in the text (store errors quote keys, and keys hold mailbox
  names). The connection stays. A message whose delete failed stays, and no
  `* n EXPUNGE` is sent for it.

## Input rules

- Framing is CRLF only. A bare LF or CR ends the connection with `* BYE`.
- A line is at most `max_line` bytes with its CRLF (16 KiB by default) and is
  never buffered past that: a longer one gets `* BYE` and the connection closes.
  The receive buffer holds at most `max_line` plus one 4096-byte slice.
- A line must be printable ASCII (0x20 to 0x7E). A control byte or a byte over
  0x7F is `* BAD`. The tag must be one to 64 ASTRING characters other than `+`,
  or the line is `* BAD`: the server echoes the tag, so it cannot be allowed to
  carry anything else.
- Literals are not supported. A line ending in `{n}` is answered `BAD
  [CLIENTBUG]` and nothing is buffered; the client, which waits for a `+` that
  never comes, abandons the command. A line ending in `{n+}` is answered the
  same and then `* BYE`, and the connection closes: its n bytes are already on
  the way and must not run as commands. So a client must send LOGIN and
  mailbox names as atoms or quoted strings (with `\"` and `\\`).
- Unquoted arguments are ASTRING-CHARs; anything else is `BAD`.

## Login and mailboxes

- LOGIN on a clear channel while `require_tls_for_login` is set (the default) is
  `NO [PRIVACYREQUIRED]` and not counted as a failure; the greeting and
  CAPABILITY advertise `LOGINDISABLED` until TLS, and `STARTTLS` while it can be
  done. After `max_login_failures` (3) failed LOGINs the connection is told
  `* BYE` and closed.
- The user's mailbox is the one `komira_mail_store.normalize_recipient(login
  name)` names: the address the SMTP side stored the mail under (the case of
  letters does not matter). **There is no shared default mailbox**: a login
  without an `@`, or for an address nobody delivered to, opens an empty INBOX
  of its own. A login name that cannot be a mailbox (empty, or too long once
  escaped) can log in but every SELECT, EXAMINE and LIST is
  `NO [NONEXISTENT] This user has no mailbox`.
- A folder name from the client goes through `normalize_folder` (lower case,
  letters, digits and `._-/` kept, `INBOX` in any case is the INBOX), after a
  check that no `/`-separated part is empty, `.` or `..`. `SELECT ..`,
  `../x`, `a//b`, a trailing `/` and the empty name are
  `NO [NONEXISTENT] No such mailbox`; the connection stays, and the selection
  that came before ends. A folder that holds no message can still be selected
  (it is empty); LIST shows only folders that hold a message.
- Objects in a folder whose name is not a message of this server (not 16
  lowercase hex digits and `.eml`) are ignored.
- SELECT lists the folder once. That list is the view for the selection:
  sequence numbers are positions in it, and mail that arrives later shows after
  the next SELECT (there is no `* n EXISTS` update, no IDLE). `max_messages`
  (100,000) bounds the list.

## Flags

Flags are durable and shared. Each folder has its own flag log on the same store
as the messages (`mail/<mailbox>/_flags` for INBOX, `mail/<mailbox>/<folder>/_flags`
for another folder, `<mailbox>` being the normalized name), kept by `komira_comms_index` as a delta log: STORE and the
`\Seen` of a read append one immutable delta, EXPUNGE appends a tombstone, and
every command that needs flags folds the log. So two connections to a mailbox
see the same flags, and they survive a restart. The same message in two folders
has two sets of flags.

`MailboxFlagStore[S]` is that, with `flags_of`, `set_flags`, `expunge` and
`snapshot` (one fold, many lookups). A handle that has written keeps the tail of
the log it knows and does not see what another handle appends afterwards, so
the server opens a new handle (over `store.clone()`) for each command.

EXPUNGE first drops the flags of a message, then deletes the message. If the
delete fails the message stays (without its flags) and the command is `NO`; the
other order could leave a stale `\Deleted` flag that a later message of the same
content would inherit and lose to an EXPUNGE.

The log grows with every flag change and each command folds all of it, so a
command that changed flags folds the log into one base chunk when it has more
than `compact_flag_log_at` chunks (256). A failed compaction is ignored.

## UIDs

**These are not RFC 3501 section 2.3.1.1 UIDs.** A message's UID is 31 bits of a
hash of its leaf (the content hash of the stored bytes), the same in every
session and every folder; UIDVALIDITY is 31 bits of a hash of the folder's
flag scope (the mailbox for INBOX, the mailbox and the folder otherwise), so it
never changes. Consequences, until a per-folder counter in `komira_comms_index`
allocates UIDs:

1. UIDs can collide: two messages of one folder share a UID with about even odds
   near 55,000 messages (a birthday bound). They then share flags and cannot be
   told apart by `UID FETCH`.
2. UIDs do not follow delivery order. A view is sorted by UID, so within one
   selection sequence numbers and UIDs both ascend, as a client needs; but a
   message delivered later can get a smaller UID and a smaller sequence number
   than one a client already knows, and UIDNEXT (the largest UID plus one) is a
   guess. A client that syncs by "everything above the last UID I saw" will miss
   mail.
3. A message deleted and delivered again with identical bytes has the same UID.
   The SMTP side adds a per-delivery trace header, so two deliveries are two
   different messages; a message restored by hand is not.

Use a client that fetches by sequence number or re-lists a folder, or wait for
the counter. Nothing here sends `HIGHESTMODSEQ`, because CONDSTORE is not
offered.

## Stores

`serve_one_iteration` and `feed` take `S: CloneableConditionalWriteStore` (a
`ConditionalWriteStore` with `clone()`), because each command that needs flags
opens a `MailboxFlagStore` over `store.clone()`. Declared in the source as
conformers: `LocalFsConditionalStore`, `SharedInMemoryConditionalStore`,
`DelimiterFaithfulConditionalStore`, `S3ConditionalStore` and
`GcsConditionalStore`. This package's tests run over the first two; the others
are not exercised here, so check one before promising a cloud-backed IMAP
server (every command costs a listing of the folder and a fold of its flag log).
`InMemoryConditionalStore` has no `clone()` and cannot serve. A binary that
serves SMTP and IMAP over one store needs one that satisfies the bound.

## Limits

`ImapLimits` carries them as plain values, defaults safe and not unlimited.

| limit | default | meaning |
|---|---|---|
| `max_line` | 16 KiB | a line with its CRLF; never buffered beyond it |
| `max_conns` | 1024 | at the limit the peer gets `* BYE` and is closed |
| `idle_ms` | 30 minutes | no byte received for longer |
| `max_session_ms` | 8 hours | a connection older than this (0 turns it off) |
| `max_unauth_ms` | 60 seconds | not logged in after this long (0 turns it off) |
| `max_login_failures` | 3 | failed LOGINs, then `* BYE` |
| `max_fetch_bytes` | 32 MiB | message bytes one FETCH may return |
| `max_tx_bytes` | 64 MiB | replies queued for a peer that does not read, then `* BYE` |
| `max_messages` | 100,000 | messages a SELECT may list |
| `compact_flag_log_at` | 256 | flag log chunks before it is folded |

Every deadline compares strictly: a connection expires one millisecond after its
limit. Time comes in as `now_ms`; tests pass it and never wait for it. Memory is
bounded per connection (`max_tx_bytes` of replies, the view of the folder at
about 100 bytes a message, about 20 KB of receive buffer) and not over the
table: the binary must size `max_conns` so that `max_conns * max_tx_bytes` fits
the machine. The connection lookup by id is linear.

## Fixtures

`ImapTestServer[S]` is a registry, a store, a `TestAuthVerifier` and a clock the
test sets, with `connect`, `send`, `send_chunks`, `login`, `take` and
`take_bytes`, for tests of this server and of what feeds it. No socket.

## Not here

- IPv4 listeners only. A TLS connection is closed with a plain TCP close, without
  a TLS `close_notify`, also after the `* BYE` of LOGOUT.
- No live updates: NOOP does not report new or removed mail. SELECT again.
- No implicit TLS (a port of its own); STARTTLS only.
- `LOGIN` is the only way in; there is no AUTHENTICATE. The verifier is the
  caller's; `TestAuthVerifier` is a fixture, not a password store.
- Message bytes are held in memory while a FETCH answers (bounded by
  `max_fetch_bytes`).

## Tests

The welded tests include `test_serve_loop`, which runs over real loopback sockets
with the `Peer` client of `komira_mail_test_support`, TLS included. They wait for
progress (a reply, a finished handshake, the end of a connection) and never for a
time; deadlines are tested by passing `now_ms`. The others (`test_framing`,
`test_commands`, `test_mailbox`, `test_fetch`, `test_flags_store`,
`test_folders`) drive the registry with no socket. `test_mailbox` and
`test_folders` run over two stores; `test_flags_store` includes a store that
fails on request.
