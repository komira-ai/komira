"""`komira_chat_store`: the storage of a small Slack-like chat over
komira_db's backend-neutral `Database` trait.

`ChatStore[DB, P]` holds users (keyed by a token's iss and sub), public and
private channels, DMs, members, each channel's timeline (MESSAGE, EDIT,
DELETE, JOIN and LEAVE events numbered 1, 2, 3, ... with no gaps), one-level
threads, mentions, read cursors and file records, and erases one user. The
kinds and states it stores carry the numbers of `komira.chat.v1`
(komira_chat_proto).

A SQL backend gets its schema from `chat_migrations()` and each connection
goes through `prepare_sql_connection`; a document store declares
`CHAT_DOCUMENT_KEYS` and `CHAT_DOCUMENT_INDEXES`. After an erasure on
SQLite, `finish_sql_erasure` moves the write-ahead log into the file so the
erased bytes are gone from both.

No pointer crosses this package's API: values, Lists and `ref` accessors
only.
"""

from .keys import (
    dm_channel_id,
    is_valid_id,
    join_ids,
    split_ids,
    subject_key,
    MAX_ID_BYTES,
)
from .probe import NoSendProbe, SendProbe
from .records import (
    ChatChannel,
    ChatEvent,
    ChatFile,
    ChatMember,
    ChatUser,
    EraseCounts,
    EventPage,
    IdPage,
    MentionPage,
    MentionRef,
    ReadState,
    CHANNEL_DM,
    CHANNEL_PRIVATE,
    CHANNEL_PUBLIC,
    EVENT_DELETE,
    EVENT_EDIT,
    EVENT_JOIN,
    EVENT_LEAVE,
    EVENT_MESSAGE,
    FILE_COMPLETE,
    FILE_PENDING,
)
from .schema import (
    chat_migrations,
    CHAT_DOCUMENT_INDEXES,
    CHAT_DOCUMENT_KEYS,
    CHAT_MIGRATION_LEDGER,
    T_CHANNELS,
    T_CURSORS,
    T_EVENTS,
    T_FILES,
    T_MEMBERS,
    T_MENTIONS,
    T_SUBJECTS,
    T_USERS,
)
from .erasure import finish_sql_erasure, prepare_sql_connection
from .ops import MAX_PAGE_SIZE
from .store import ChatStore
from .timeline import MAX_APPEND_ATTEMPTS
