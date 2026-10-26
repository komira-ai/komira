# komira_imap_server

An IMAP4rev1 server for reading received mail (RFC 3501, with STARTTLS as in
RFC 2595): the connection table, the line framing, the command state machine,
durable message flags, and a serve loop over non-blocking sockets. The mail
lives in any `komira_objectstore` store, laid out by `komira_mail_store`: this
server reads what `komira_smtp_server` wrote there. Messages are read with
`komira_mail_message` (MIME structure, dates) and `komira_mail_address`
(ENVELOPE addresses): FETCH answers ENVELOPE, BODYSTRUCTURE, every
`BODY[section]<partial>` form and INTERNALDATE, and SEARCH has every key of
RFC 3501.

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
That dependency is temporary: it makes an IMAP-only binary carry the SMTP
library, and `ListenSocket` belongs in a package both servers import.
**Every store call blocks the whole loop.** SELECT lists up to `max_messages`
objects, FETCH reads up to `max_fetch_bytes`, and every flag command folds a
log, all synchronously inside `serve_one_iteration`: one slow command, or a slow
store, stalls every other connection and their deadlines.

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
| `FETCH`, `UID FETCH` | `FLAGS`, `UID`, `INTERNALDATE`, `RFC822.SIZE`, `ENVELOPE`, `BODYSTRUCTURE`, `BODY`, `BODY[section]<partial>` and `BODY.PEEK[...]`, `RFC822`, `RFC822.HEADER`, `RFC822.TEXT`, the macros `ALL`, `FAST` and `FULL`; one item or a list (see "FETCH items") |
| `SEARCH`, `UID SEARCH` | every RFC 3501 key, `NOT`, `OR`, groups, `CHARSET US-ASCII` or `UTF-8` (see "SEARCH") |
| `STORE`, `UID STORE` | `FLAGS`, `+FLAGS`, `-FLAGS`, each with `.SILENT`; the five system flags |
| `EXPUNGE` | deletes the `\Deleted` messages, answering `* n EXPUNGE` highest first |
| `CLOSE` | the silent expunge, then leaves the folder (none after EXAMINE) |

Anything else that IMAP4rev1 defines (`APPEND`, `CREATE`, `DELETE`, `RENAME`,
`SUBSCRIBE`, `LSUB`, `STATUS`, `COPY`, `CHECK`, `AUTHENTICATE`, `UID EXPUNGE`
...) is answered `NO [CANNOT]`; a word that is not a command or a FETCH item
is `BAD`. Not offered: APPEND, IDLE, CONDSTORE
(`HIGHESTMODSEQ` is never sent), LITERAL+, UIDPLUS, NAMESPACE, UNSELECT, ID.
IMAP4rev1 only; RFC 9051 is out of scope.

- SELECT sends `PERMANENTFLAGS` with the five flags; EXAMINE sends `PERMANENTFLAGS ()`
  (RFC 3501 section 6.3.2), since STORE is refused there.
- `BODY[...]` (any section, a partial too), `RFC822` and `RFC822.TEXT` set
  `\Seen` on a folder opened read-write, durably, and the answer carries
  `FLAGS` when the flag changed; `BODY.PEEK[...]` and `RFC822.HEADER` do not,
  and nothing does after EXAMINE. A message that is answered `NO
  [UNAVAILABLE]` is not marked. The message bytes go out exactly as stored.
- A set is `n`, `a:b`, `*` and lists of them (`*` is the largest sequence
  number, or the largest UID for the UID forms); numbers past the end are
  skipped; a 0, an empty item or more than 1024 ranges is `BAD`. A range as
  wide as numbers go costs the messages in the folder, not its width.
- STORE accepts `\Seen`, `\Answered`, `\Flagged`, `\Deleted` and `\Draft`.
  `\Recent` and keywords are `NO [CANNOT]`, and a command that names one of
  them changes nothing.
- A message another connection deleted since SELECT is skipped, and the FETCH
  ends `NO [EXPUNGEISSUED]`. A FETCH whose message bytes would pass
  `max_fetch_bytes` is `NO [LIMIT]` before any is read (a section with a
  partial counts as its length at most), and so is one that would read more
  than `max_scan_bytes` of messages.
- A store failure is `NO [SERVERBUG] Internal error, try again`, with nothing
  of the failure in the text (store errors quote keys, and keys hold mailbox
  names). The connection stays. A message whose delete failed stays, and no
  `* n EXPUNGE` is sent for it.

## FETCH items

| item | answer |
|---|---|
| `FLAGS`, `UID` | as before |
| `RFC822.SIZE` | the stored size in octets |
| `INTERNALDATE` | `" 1-Sep-2026 10:00:00 +0000"`, see below |
| `ENVELOPE` | RFC 3501 section 7.4.2, see below |
| `BODYSTRUCTURE`, `BODY` | the MIME structure with and without extension data, see below |
| `BODY[]`, `RFC822` | the stored message |
| `BODY[HEADER]`, `RFC822.HEADER` | the header block with its empty line |
| `BODY[TEXT]`, `RFC822.TEXT` | everything after it |
| `BODY[HEADER.FIELDS (...)]`, `BODY[HEADER.FIELDS.NOT (...)]` | the lines of the header block whose field is (is not) named, as written (folds included), in the message's order, then an empty line (CRLF, also for a message with bare LF line ends); names in any case, atoms or quoted |
| `BODY[n.n.n]` | a part's body as written; `n.n.MIME` its header block |
| `BODY[n.n.HEADER]`, `.HEADER.FIELDS`, `.HEADER.FIELDS.NOT`, `.TEXT` | of a part that is a `message/rfc822`: the nested message's, reached through it (`2.2.1` is the first part inside the nested message) |
| `BODY[...]<origin.length>` | the window, answered `BODY[...]<origin>`; truncated at the end of the section, an empty literal at or past it; a length of 0 is not IMAP (`BAD`) |

`ALL` is `FLAGS INTERNALDATE RFC822.SIZE ENVELOPE`, `FAST` the first three,
`FULL` is `ALL BODY`. The reply names a section by its numbers, then the
keyword in capitals (field names as the client wrote them); `PEEK` is not
echoed. A section that does not exist (a part past the end, a number under a
leaf, `HEADER` or `TEXT` of a part that is not a message) is `NIL`, and does
not fail the command. A reply sends a quoted string for 7-bit text, and a
literal for anything with a byte over 0x7F, a CR, an LF or a NUL.

**What parses what.** The stored message is read from the store once per
FETCH and parsed at most once, and only for `BODYSTRUCTURE`, `BODY` and a
numbered section. The whole message, its header and text, a field subset,
`ENVELOPE`, `INTERNALDATE` and `RFC822.SIZE` read the header block with a
lenient scanner (a line without a colon is skipped, nothing raises), so they
work on mail a MIME parser refuses. The section bytes go to the reply queue
from a borrowed view of the parsed message: one copy per item.

**MIME limits.** `komira_mail_message` reads at most 8 nested multiparts and
128 parts. A message over them, a multipart without a boundary and a header
line without a colon make `BODYSTRUCTURE`, `BODY` and the numbered sections
`NO [UNAVAILABLE]` for that message: nothing of it is sent, it is not marked
`\Seen`, the other messages of the command are answered, and the connection
goes on. A nested `message/rfc822` is opened with the parent's depth and part
budget (a chain of 9 nested messages is over it), and one with a transfer
encoding other than 7bit, 8bit or binary cannot be opened: the structure of a
message that holds it is `NO [UNAVAILABLE]` too.

### INTERNALDATE

The time of the first `Received` field (what follows its last `;`: the trace
header the SMTP side adds on delivery, so when the mail arrived); if there is
none or it is not a date, the time of the `Date` field; if neither is a date,
the Unix epoch (`" 1-Jan-1970 00:00:00 +0000"`). It is written in UTC with a
space-padded day: a zone in the field is converted, not kept.

### ENVELOPE

The fields as the sender wrote them (unfolded; RFC 2047 encoded words are not
decoded, a client does that): date, subject, in-reply-to and message-id are
strings, NIL when the field is absent and `""` when it is empty (the first
field of a name is used). The address fields are read with
`komira_mail_address.parse_address_list`: a mailbox is `(name NIL mailbox
host)` (the host in lower case, as that package keeps it), a group is
`(NIL NIL "name" NIL)`, its members, and `(NIL NIL NIL NIL)`. An absent field
is NIL, and so is one that does not parse (a list that package refuses is not
guessed at). sender and reply-to are from when absent; there is no source
route.

### BODYSTRUCTURE and BODY

A multipart is `(part part ... "SUBTYPE" ("BOUNDARY" "b") dsp lang loc)`, with
no separator between the parts and to any depth; a leaf is `("TYPE" "SUBTYPE"
params id description "ENCODING" octets [lines] md5 dsp lang loc)`. The octets
and lines are of the body as stored (the line break before a delimiter belongs
to the delimiter; a last line with no break counts as a line), lines only for
a text part, and for a `message/rfc822` the nested envelope, structure and
lines come after the octets. Parameter names are in capitals and their values
as written (RFC 2231 values decoded); a text part with no Content-Type has
`("CHARSET" "US-ASCII")`; md5, disposition, language and location come from
Content-MD5, Content-Disposition, Content-Language and Content-Location. `BODY`
is the same without the extension data (the multipart's parameters, and md5
onward).

## SEARCH

`SEARCH [CHARSET x] key ...` and `UID SEARCH`, answered `* SEARCH n n ...`
(sequence numbers, or UIDs, ascending) and OK. All keys given are required.

- `ALL`, `SEEN`, `UNSEEN`, `ANSWERED`, `UNANSWERED`, `FLAGGED`, `UNFLAGGED`,
  `DELETED`, `UNDELETED`, `DRAFT`, `UNDRAFT`: the durable flags.
- `RECENT`, `NEW` (RECENT and UNSEEN) and `OLD` (NOT RECENT): there is no
  `\Recent` flag, so `RECENT` and `NEW` find nothing and `OLD` everything.
  `KEYWORD word` finds nothing and `UNKEYWORD word` everything: no keyword can
  be stored.
- `FROM`, `TO`, `CC`, `BCC`, `SUBJECT`, `HEADER field string`: the string is a
  case-insensitive substring of the field's value as written or with its
  encoded words decoded; `HEADER field ""` finds a message that has the field.
- `BODY string`, `TEXT string`: a case-insensitive ASCII substring of the
  stored bytes after the header block (`BODY`) or of all of them (`TEXT`).
  Nothing is decoded: base64 and quoted-printable are searched as written, and
  text in another charset is searched by its bytes. The command line is 7-bit
  text (literals are refused), so a search string is ASCII; `CHARSET` accepts
  `US-ASCII` and `UTF-8` and anything else is `NO [BADCHARSET (US-ASCII
  UTF-8)]`.
- `BEFORE`, `ON`, `SINCE`: the INTERNALDATE; `SENTBEFORE`, `SENTON`,
  `SENTSINCE`: the `Date` field, with no fallback (a message without a
  readable `Date` is found by none of the three, and by `NOT` of them). A date
  is `d-Mon-yyyy` or `dd-Mon-yyyy` (from 1900, the day must exist) and days
  are UTC calendar days: the zone of a `Date` field is not kept.
- `LARGER n`, `SMALLER n`: the stored size in octets.
- a sequence set, `UID set`, `NOT key`, `OR key key`, `( key ... )`.

The parser is bounded: 256 nodes and 24 levels of groups, `NOT` and `OR`;
anything malformed (an unknown key, a missing argument, a bad date, number or
set, an unbalanced group, a string that is not closed) is `BAD`. A message is
read from the store at most once per search and only when the cheap keys
(flags, sets, sizes) leave it undecided, its header block is scanned once, and
`BODY` and `TEXT` are one linear pass (Knuth-Morris-Pratt) over its bytes: a
search costs at most one scan of the header block and one pass of the body per
message. A search with a key that reads messages is `NO [LIMIT]` before any
is read when the folder's messages together are over `max_scan_bytes`. A
message another connection deleted since SELECT is found only by keys that
read nothing.

## Input rules

- Framing is CRLF only. A bare LF or CR ends the connection with `* BYE`.
- A line is at most `max_line` bytes with its CRLF (16 KiB by default) and is
  never buffered past that: a longer one gets `* BYE` and the connection closes.
  The receive buffer holds at most `max_line` plus one 4096-byte slice.
- A line must be printable ASCII (0x20 to 0x7E). A control byte or a byte over
  0x7F is `* BAD`, before LOGIN's arguments are read: a password with a
  non-ASCII byte cannot be sent, as an atom, a quoted string or a literal. The tag must be one to 64 ASTRING characters other than `+`,
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
  `* BYE` and closed. The count is per connection and starts again on a new
  one: it is not brute-force protection, and throttling by source address
  belongs in the verifier or the binary.
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
as the messages (`mail/<mailbox>/_flags` for INBOX, `mail/<mailbox>~<folder>/_flags` for another
folder, `<mailbox>` being the normalized name; a `/` of the folder is written `~`, which no
mailbox or folder name holds, so no log lies under another's prefix, a folder
named `_flags` included), kept by `komira_comms_index` as a delta log. A flag is
keyed by the message's leaf and not by its UID, so messages that share a UID
still have their own flags and their own EXPUNGE: STORE and the
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

The flag logs are outside the mailbox's message tree: removing a mailbox by its
message prefix leaves them, and a mailbox recreated under the same name finds
the old flags of any message whose bytes it receives again. A session whose
view still holds a message another session expunged can STORE on it, which
writes a flag entry for a message that is gone; redelivered identical bytes
inherit it. Take the mailbox's logs away with its messages.

One IMAP serving process per store: a delta carries the sequence number its
writer guessed (the log's head plus one) as the last-writer-wins tiebreak, and
two processes writing one store (a second server, a command-line tool) can
guess the same one. The commands of one process never interleave, so within a
process the order is exact.

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
   near 55,000 messages (a birthday bound). Their flags, `\Seen`, EXPUNGE and
   CLOSE are still their own (they are keyed by leaf), but a UID-addressed
   command (`UID FETCH`, `UID STORE`) names both of them, and a client that
   keeps a UID cannot tell them apart.
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
| `max_scan_bytes` | 256 MiB | message bytes one FETCH that reads messages, or one SEARCH with a key that does, may read (sizes summed, checked first) |
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
- A store call is synchronous (see "Serving").
- Message bytes are held in memory while a FETCH answers (one message at a
  time, at most the SMTP side's message cap; the reply queue by
  `max_fetch_bytes`).
- No `BINARY`, `ESEARCH`, `SORT`, `THREAD`, `SEARCHRES` or `CONDSTORE` forms.
- `BODY` and `TEXT` searches and `BODY[...]` do not decode a transfer encoding
  or a charset.

## Tests

The welded tests include `test_serve_loop`, which runs over real loopback sockets
with the `Peer` client of `komira_mail_test_support`, TLS included. They wait for
progress (a reply, a finished handshake, the end of a connection) and never for a
time; deadlines are tested by passing `now_ms`. The others (`test_framing`,
`test_commands`, `test_mailbox`, `test_fetch`, `test_bodystructure`,
`test_sections`, `test_mime_limits`, `test_search`, `test_search_syntax`,
`test_read_sequence`, `test_flags_store`, `test_folders`, `test_flag_identity`)
drive the registry with no socket. `test_mailbox` and
`test_folders` run over two stores; `test_flags_store` includes a store that
fails on request.
