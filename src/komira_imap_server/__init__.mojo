"""An IMAP4rev1 server for reading received mail: the connection table, CRLF
line framing with a cap, the command state machine, durable flags, and a
caller-polled serve loop over non-blocking sockets with STARTTLS. Commands:
CAPABILITY, NOOP, LOGOUT, STARTTLS, LOGIN, SELECT, EXAMINE, LIST, CLOSE, FETCH
(FLAGS, UID, INTERNALDATE, RFC822.SIZE, ENVELOPE, BODYSTRUCTURE, BODY, every
BODY[section]<partial>, RFC822, RFC822.HEADER, RFC822.TEXT, the macros),
SEARCH with every key of RFC 3501, STORE, EXPUNGE and the UID forms of FETCH,
STORE and SEARCH. It is a subset, and its UIDs are not general-purpose IMAP
UIDs: see README.md.

| name | does |
|---|---|
| `ImapRegistry` | the table of connections: `accept`, `feed` (bytes in, replies queued), `tx_copy` and `tx_consume` (replies out), `mark_tls_active`, `drop`, `expired_ids` (`session.mojo`) |
| `FeedOutcome` | what one `feed` did: bytes taken, close, start TLS, and bytes the client pipelined after STARTTLS |
| `ImapLimits`, `ImapServerConfig` | plain values the binary fills from flags (`limits.mojo`) |
| `handle_line` | one command line to queued replies and an action (`commands.mojo`) |
| FETCH and SEARCH, run by `handle_line` | items in `fetch.mojo`, sections in `section.mojo`, ENVELOPE and BODYSTRUCTURE in `bodystructure.mojo`, the header scanner in `headers.mojo`, SEARCH in `search_parse.mojo` and `search.mojo` |
| `MailboxFlagStore`, `FlagSnapshot` | durable, shared message flags and EXPUNGE over `komira_comms_index` (`flags.mojo`) |
| `ListenSocket`, `bind_imap_listener` | the listening socket, which owns its descriptor (`listener.mojo`) |
| `serve_one_iteration`, `ImapServeOutcome` | one caller-polled step over real sockets, with STARTTLS (`serve.mojo`) |
| `ImapTestServer` | a registry, store and verifier with connections a test feeds text to (`fixtures.mojo`) |

Any `CloneableConditionalWriteStore` serves the mail: the registry takes the
store as a parameter of `feed` and opens a flag store over `store.clone()`
for each command that needs one.

See README.md.
"""

from komira_smtp_server import ListenSocket

from .commands import capability_text, greeting, handle_line
from .connection import (
    IMAP_ACTION_CLOSE,
    IMAP_ACTION_CONTINUE,
    IMAP_ACTION_START_TLS,
    IMAP_STATE_AUTH,
    IMAP_STATE_CLOSING,
    IMAP_STATE_NOTAUTH,
    IMAP_STATE_SELECTED,
    ImapConnection,
    ViewRow,
)
from .fixtures import ImapTestServer
from .flags import (
    FLAG_ALL,
    FLAG_ANSWERED,
    FLAG_DELETED,
    FLAG_DRAFT,
    FLAG_FLAGGED,
    FLAG_SEEN,
    FlagSnapshot,
    MailboxFlagStore,
    flag_bit_of,
    flag_scope,
    flags_to_text,
)
from .limits import ImapLimits, ImapServerConfig
from .listener import bind_imap_listener
from .mailbox import resolve_folder
from .serve import ImapServeOutcome, serve_one_iteration
from .session import FeedOutcome, ImapRegistry
from .uid import assign_uid, uidvalidity_for
